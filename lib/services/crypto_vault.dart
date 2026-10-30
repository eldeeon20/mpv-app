import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:pointycastle/export.dart'
    show
        AEADParameters,
        AESEngine,
        GCMBlockCipher,
        InvalidCipherTextException,
        KeyParameter;

/// Cifrado fuerte de archivos (AES-256-GCM + PBKDF2-HMAC-SHA256).
///
/// Reemplaza al XOR de ToolSec para datos en reposo: clave derivada con
/// salt aleatorio por archivo, nonce único y tag de autenticación que
/// detecta cualquier manipulación del ciphertext.
///
/// Formato del envelope v1:
///   MAGIC "PRBX" | version u8 | salt 16B | nonce 12B | ciphertext | tag 16B
class CryptoVault {
  static const List<int> _magic = [0x50, 0x52, 0x42, 0x58]; // "PRBX"
  static const int _version = 1;
  static const int _saltLen = 16;
  static const int _nonceLen = 12;
  static const int _tagLen = 16;
  static const int _headerLen = 4 + 1 + _saltLen + _nonceLen;
  static const int _streamChunkSize = 1024 * 1024;
  static const int _kdfIterations = 200000;

  static final AesGcm _algo = AesGcm.with256bits();
  static final Pbkdf2 _kdf = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: _kdfIterations,
    bits: 256,
  );

  /// ¿Parece un envelope CryptoVault?
  static bool isEnvelope(Uint8List data) {
    if (data.length < _magic.length + 1 + _saltLen + 12 + 16) return false;
    for (var i = 0; i < _magic.length; i++) {
      if (data[i] != _magic[i]) return false;
    }
    return true;
  }

  /// Cifra [plain] con [passphrase]. El salt y el nonce son aleatorios,
  /// así que dos llamadas idénticas producen ciphertexts distintos.
  static Future<Uint8List> encrypt(Uint8List plain, String passphrase) async {
    final salt = _random(_saltLen);
    final nonce = Uint8List.fromList(_algo.newNonce());
    final key = await _deriveKey(passphrase, salt);

    final box = await _algo.encrypt(plain, secretKey: key, nonce: nonce);

    final out = BytesBuilder()
      ..add(_magic)
      ..addByte(_version)
      ..add(salt)
      ..add(nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return out.toBytes();
  }

  /// Descifra un envelope. null = passphrase incorrecta o datos alterados.
  /// Si no es un envelope válido retorna null también (el caller decide
  /// probar el legado).
  static Future<Uint8List?> decrypt(Uint8List data, String passphrase) async {
    if (!isEnvelope(data)) return null;
    try {
      var off = _magic.length;
      final version = data[off];
      if (version != _version) return null;
      off += 1;

      final salt = Uint8List.sublistView(data, off, off + _saltLen);
      off += _saltLen;

      final nonceLen = _algo.newNonce().length; // 12 para AES-GCM
      final nonce = Uint8List.sublistView(data, off, off + nonceLen);
      off += nonceLen;

      final cipherText = Uint8List.sublistView(data, off, data.length - 16);
      final mac = Mac(Uint8List.sublistView(data, data.length - 16));

      final key = await _deriveKey(passphrase, salt);
      final clear = await _algo.decrypt(
        SecretBox(cipherText, mac: mac, nonce: nonce),
        secretKey: key,
      );
      return Uint8List.fromList(clear);
    } catch (_) {
      return null;
    }
  }

  /// Descifra un envelope PRBX v1 existente a disco, con memoria acotada.
  ///
  /// El texto claro se escribe primero a un temporal junto al destino. Solo
  /// se publica [outputPath] cuando AES-GCM valida el tag; ante error se
  /// elimina el temporal y el destino queda intacto.
  static Future<String> decryptFile({
    required String inputPath,
    required String outputPath,
    required String passphrase,
  }) async {
    final input = File(inputPath);
    if (!await input.exists()) {
      throw FileSystemException('Archivo PRBX no encontrado', inputPath);
    }
    _validateOutput(input, outputPath);
    final inputLength = await input.length();
    if (inputLength < _headerLen + _tagLen) {
      throw FormatException('Envelope PRBX truncado');
    }

    final raf = input.openSync(mode: FileMode.read);
    RandomAccessFile? waf;
    File? temp;
    var published = false;
    try {
      final header = _readExactSync(raf, _headerLen);
      if (!_hasMagic(header)) {
        throw FormatException('No es un envelope PRBX');
      }
      if (header[4] != _version) {
        throw FormatException('Versión PRBX no soportada: ${header[4]}');
      }
      final salt = Uint8List.sublistView(header, 5, 5 + _saltLen);
      final nonce = Uint8List.sublistView(header, 5 + _saltLen);
      final key = await _deriveKey(passphrase, salt);
      final keyBytes = Uint8List.fromList(await key.extractBytes());
      final cipher = GCMBlockCipher(AESEngine())
        ..init(
          false,
          AEADParameters<KeyParameter>(
            KeyParameter(keyBytes),
            _tagLen * 8,
            nonce,
            Uint8List(0),
          ),
        );

      temp = await _createTempFile(File(outputPath));
      waf = temp.openSync(mode: FileMode.write);
      var remaining = inputLength - _headerLen;
      while (remaining > 0) {
        final chunk = _readExactSync(
          raf,
          remaining < _streamChunkSize ? remaining : _streamChunkSize,
        );
        remaining -= chunk.length;
        final out = Uint8List(chunk.length + 32);
        final written = cipher.processBytes(
          chunk,
          0,
          chunk.length,
          out,
          0,
        );
        if (written > 0) waf.writeFromSync(out, 0, written);
      }

      final tail = Uint8List(32);
      final tailLength = cipher.doFinal(tail, 0);
      if (tailLength > 0) waf.writeFromSync(tail, 0, tailLength);

      final outputHandle = waf;
      outputHandle.closeSync();
      waf = null;
      if (await File(outputPath).exists()) {
        throw FileSystemException(
          'El archivo destino ya existe',
          outputPath,
        );
      }
      await temp.rename(outputPath);
      published = true;
      return outputPath;
    } on InvalidCipherTextException catch (e) {
      throw FormatException(
        'Autenticación PRBX fallida (clave incorrecta o datos alterados): $e',
      );
    } finally {
      raf.closeSync();
      waf?.closeSync();
      if (!published && temp != null && await temp.exists()) {
        await temp.delete();
      }
    }
  }

  /// Cifra un archivo a un envelope PRBX v1 compatible, por bloques a disco.
  static Future<String> encryptFile({
    required String inputPath,
    required String outputPath,
    required String passphrase,
  }) async {
    final input = File(inputPath);
    if (!await input.exists()) {
      throw FileSystemException('Archivo de entrada no encontrado', inputPath);
    }
    _validateOutput(input, outputPath);

    final salt = _random(_saltLen);
    final nonce = Uint8List.fromList(_algo.newNonce());
    final key = await _deriveKey(passphrase, salt);
    final keyBytes = Uint8List.fromList(await key.extractBytes());
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters<KeyParameter>(
          KeyParameter(keyBytes),
          _tagLen * 8,
          nonce,
          Uint8List(0),
        ),
      );
    final header = Uint8List.fromList([
      ..._magic,
      _version,
      ...salt,
      ...nonce,
    ]);

    final raf = input.openSync(mode: FileMode.read);
    RandomAccessFile? waf;
    File? temp;
    var published = false;
    try {
      temp = await _createTempFile(File(outputPath));
      waf = temp.openSync(mode: FileMode.write);
      waf.writeFromSync(header);
      while (true) {
        final chunk = raf.readSync(_streamChunkSize);
        if (chunk.isEmpty) break;
        final out = Uint8List(chunk.length + 32);
        final written = cipher.processBytes(
          chunk,
          0,
          chunk.length,
          out,
          0,
        );
        if (written > 0) waf.writeFromSync(out, 0, written);
      }

      final tail = Uint8List(32);
      final tailLength = cipher.doFinal(tail, 0);
      if (tailLength > 0) waf.writeFromSync(tail, 0, tailLength);

      final outputHandle = waf;
      outputHandle.closeSync();
      waf = null;
      if (await File(outputPath).exists()) {
        throw FileSystemException(
          'El archivo destino ya existe',
          outputPath,
        );
      }
      await temp.rename(outputPath);
      published = true;
      return outputPath;
    } finally {
      raf.closeSync();
      waf?.closeSync();
      if (!published && temp != null && await temp.exists()) {
        await temp.delete();
      }
    }
  }

  static void _validateOutput(File input, String outputPath) {
    final source = input.absolute.path;
    final destination = File(outputPath).absolute.path;
    final same = Platform.isWindows
        ? source.toLowerCase() == destination.toLowerCase()
        : source == destination;
    if (same) {
      throw ArgumentError(
          'La entrada y el destino no pueden ser el mismo archivo');
    }
    if (File(outputPath).existsSync()) {
      throw FileSystemException('El archivo destino ya existe', outputPath);
    }
  }

  static Future<File> _createTempFile(File output) async {
    await output.parent.create(recursive: true);
    for (var attempt = 0; attempt < 10; attempt++) {
      final suffix =
          _random(16).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final temp = File('${output.path}.prbx-$suffix.tmp');
      try {
        await temp.create(exclusive: true);
        return temp;
      } on FileSystemException {
        if (!await temp.exists()) rethrow;
      }
    }
    throw FileSystemException(
        'No se pudo reservar un temporal PRBX', output.path);
  }

  static Uint8List _readExactSync(RandomAccessFile file, int length) {
    final result = Uint8List(length);
    var offset = 0;
    while (offset < length) {
      final chunk = file.readSync(length - offset);
      if (chunk.isEmpty) {
        throw FormatException('Envelope PRBX truncado durante la lectura');
      }
      result.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return result;
  }

  static bool _hasMagic(List<int> data) {
    if (data.length < _magic.length) return false;
    for (var i = 0; i < _magic.length; i++) {
      if (data[i] != _magic[i]) return false;
    }
    return true;
  }

  static Future<SecretKey> _deriveKey(String passphrase, List<int> salt) {
    return _kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt,
    );
  }

  static Uint8List _random(int len) {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(len, (_) => r.nextInt(256)));
  }

  /// Cifra un lote v2: `global(cdn_pass + cdn)` con el maestro.
  /// `PRBX(maestro, [LOTE][u32be len][pass][datos])`.
  static Future<Uint8List> encryptLote(
      Uint8List datos, String passMaestro, String passLote) async {
    final pb = utf8.encode(passLote);
    final plano = BytesBuilder()
      ..add([0x4C, 0x4F, 0x54, 0x45]) // LOTE
      ..add([
        (pb.length >> 24) & 0xFF,
        (pb.length >> 16) & 0xFF,
        (pb.length >> 8) & 0xFF,
        pb.length & 0xFF
      ])
      ..add(pb)
      ..add(datos);
    return encrypt(plano.toBytes(), passMaestro);
  }
}

/// Lote v2: pass del lote pegada al inicio + contenido, todo con
/// el maestro. El pass global descifra TODO: pass + dato origen.
class LoteAbierto {
  final int version; // 1 o 2
  final String passLote; // '' en v1
  final Uint8List contenido;
  const LoteAbierto({
    required this.version,
    required this.passLote,
    required this.contenido,
  });
}

/// Abre v1 (PRBX directo) o v2 (marca LOTE). En v2 devuelve el
/// pass del lote en texto además del contenido descifrado.
Future<LoteAbierto?> decryptLote(Uint8List data, String passMaestro) {
  return _decryptLote(data, passMaestro);
}

Future<LoteAbierto?> _decryptLote(Uint8List data, String passMaestro) async {
  try {
    final pt = await CryptoVault.decrypt(data, passMaestro);
    if (pt == null) return null;
    if (pt.length >= 8 &&
        pt[0] == 0x4C &&
        pt[1] == 0x4F &&
        pt[2] == 0x54 &&
        pt[3] == 0x45) {
      final len = ByteData.sublistView(pt, 4, 8).getUint32(0, Endian.big);
      if (len <= 0 || pt.length < 8 + len) return null;
      final passLote = utf8.decode(Uint8List.sublistView(pt, 8, 8 + len));
      final contenido = Uint8List.sublistView(pt, 8 + len);
      return LoteAbierto(version: 2, passLote: passLote, contenido: contenido);
    }
    return LoteAbierto(version: 1, passLote: '', contenido: pt);
  } catch (_) {
    return null;
  }
}
