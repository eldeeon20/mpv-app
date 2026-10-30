import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Cifrado DURO por trozos (AES-256-GCM). Solo gcm-c (sin xor legacy).
class Duro {
  Duro._();

  static const trozoClaro = 64 * 1024;
  static const overhead = 12 + 16;
  static const _pbkdf2Vueltas = 20000;

  static String nuevaSal() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    return b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
  }

  static List<int> _salBytes(String salHex) {
    final s = salHex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    final out = <int>[];
    for (var i = 0; i + 1 < s.length; i += 2) {
      out.add(int.parse(s.substring(i, i + 2), radix: 16));
    }
    if (out.isEmpty) {
      throw StateError('mediablock: sal del molde vacía o inválida');
    }
    return out;
  }

  /// Clave de 32 bytes. [clave] = LA MISMA que abre tu SQL.
  static Future<Uint8List> claveArchivo({
    required String clave,
    required String molde,
    required String nombre,
    required String salHex,
  }) async {
    if (clave.isEmpty) {
      throw ArgumentError('mediablock: clave vacía');
    }
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: _pbkdf2Vueltas,
      bits: 256,
    );
    final derivada = await pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode('$clave|$molde|$nombre')),
      nonce: _salBytes(salHex),
    );
    return Uint8List.fromList(await derivada.extractBytes());
  }

  /// Igual que [claveArchivo] pero en HILO aparte (Isolate.run):
  /// el PBKDF2 (20k vueltas) no tranca el scroll ni la UI.
  static Future<Uint8List> claveArchivoHilo({
    required String clave,
    required String molde,
    required String nombre,
    required String salHex,
  }) {
    if (clave.isEmpty) {
      throw ArgumentError('mediablock: clave vacía');
    }
    return Isolate.run(() => _derivarHilo({
          'semilla': '$clave|$molde|$nombre',
          'sal': _salBytes(salHex),
        }));
  }

  /// Cifra en un isolate y agrega cada paquete al archivo de destino.
  /// La memoria usada queda limitada a un trozo claro y uno cifrado.
  static Future<int> cifrarArchivoADiscoHilo({
    required Uint8List claveArchivo,
    required int trozoClaro,
    required String origen,
    required String destino,
    required int tamanoEsperado,
  }) {
    final origenAbs = File(origen).absolute.path;
    final destinoAbs = File(destino).absolute.path;
    final mismoArchivo = Platform.isWindows
        ? origenAbs.toLowerCase() == destinoAbs.toLowerCase()
        : origenAbs == destinoAbs;
    if (mismoArchivo) {
      throw ArgumentError('mediablock: origen y destino no pueden coincidir');
    }
    return Isolate.run(() => _cifrarArchivoADisco({
          'clave': claveArchivo,
          'trozo': trozoClaro,
          'origen': origen,
          'destino': destino,
          'tamanoEsperado': tamanoEsperado,
        }));
  }

  /// Descifra un rango en HILO aparte (el GCM por trozo sale del UI).
  static Future<Uint8List> descifrarRangoHilo({
    required Uint8List claveArchivo,
    required RangoCrudo rango,
  }) {
    return Isolate.run(() => _descifrarHilo({
          'clave': claveArchivo,
          'modo': rango.modo,
          'archivo': rango.archivo,
          'desde': rango.desde,
          'hasta': rango.hasta,
          'trozo': rango.trozo,
          'tamano': rango.tamano,
          'packs': [
            for (final p in rango.paquetes) [p.indice, p.bytes]
          ],
        }));
  }

  /// Clave del MOLDE (para cifrar el ÍNDICE: nombres+tags en plano no).
  static Future<Uint8List> claveMolde({
    required String clave,
    required String molde,
    required String salHex,
  }) async {
    if (clave.isEmpty) {
      throw ArgumentError('mediablock: clave vacía');
    }
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: _pbkdf2Vueltas,
      bits: 256,
    );
    final derivada = await pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode('$clave|$molde|__molde__')),
      nonce: _salBytes(salHex),
    );
    return Uint8List.fromList(await derivada.extractBytes());
  }

  /// Igual en HILO aparte (no tranca al abrir/listar).
  static Future<Uint8List> claveMoldeHilo({
    required String clave,
    required String molde,
    required String salHex,
  }) {
    if (clave.isEmpty) {
      throw ArgumentError('mediablock: clave vacía');
    }
    return Isolate.run(() => _derivarHilo({
          'semilla': '$clave|$molde|__molde__',
          'sal': _salBytes(salHex),
        }));
  }

  /// Cifra un texto corto (nombre/tag) con nonce al azar.
  /// Sale `'v1:' + base64(nonce+ct+mac)`.
  static Future<String> cifrarTexto({
    required Uint8List claveMolde,
    required String texto,
  }) async {
    final r = Random.secure();
    final nonce =
        Uint8List.fromList(List<int>.generate(12, (_) => r.nextInt(256)));
    final box = await AesGcm.with256bits().encrypt(
      utf8.encode(texto),
      secretKey: SecretKey(claveMolde),
      nonce: nonce,
    );
    return 'v1:' + base64Encode(box.concatenation());
  }

  static Future<String> descifrarTexto({
    required Uint8List claveMolde,
    required String dato,
  }) async {
    if (!dato.startsWith('v1:')) return dato; // legacy en plano
    final raw = base64Decode(dato.substring(3));
    final claro = await AesGcm.with256bits().decrypt(
      SecretBox.fromConcatenation(
        Uint8List.fromList(raw),
        nonceLength: 12,
        macLength: 16,
      ),
      secretKey: SecretKey(claveMolde),
    );
    return utf8.decode(claro);
  }

  /// Descifra una tanda en HILO aparte (listar cientos no tranca).
  static Future<List<String>> descifrarTextosHilo({
    required Uint8List claveMolde,
    required List<String> datos,
  }) {
    return Isolate.run(() => _descifrarTextosHilo({
          'clave': claveMolde,
          'datos': datos,
        }));
  }

  static Uint8List _nonce(int i) {
    final b = Uint8List(12);
    final v = ByteData.sublistView(b);
    v.setUint64(4, i.toUnsigned(64), Endian.big);
    return b;
  }

  static Future<Uint8List> _claveTrozo(Uint8List claveArchivo, int i) async {
    final mac = await Hmac.sha256().calculateMac(
      utf8.encode('molde-chunk|$i'),
      secretKey: SecretKey(claveArchivo),
    );
    return Uint8List.fromList(mac.bytes);
  }

  /// Subclave por entrada, para que archivos y previas nunca reutilicen
  /// la misma pareja clave/nonce aunque ambos empiecen en el bloque cero.
  static Future<Uint8List> claveEntrada({
    required Uint8List claveArchivo,
    required String nombreEntrada,
  }) async {
    final mac = await Hmac.sha256().calculateMac(
      utf8.encode('mediablock-entry|$nombreEntrada'),
      secretKey: SecretKey(claveArchivo),
    );
    return Uint8List.fromList(mac.bytes);
  }

  static Future<Uint8List> cifrarTrozo({
    required Uint8List claveArchivo,
    required int indice,
    required Uint8List claro,
  }) async {
    final aes = AesGcm.with256bits();
    final box = await aes.encrypt(
      claro,
      secretKey: SecretKey(await _claveTrozo(claveArchivo, indice)),
      nonce: _nonce(indice),
    );
    return Uint8List.fromList(box.concatenation());
  }

  static Future<Uint8List> descifrarTrozo({
    required Uint8List claveArchivo,
    required int indice,
    required Uint8List paquete,
  }) async {
    if (paquete.length < overhead) {
      throw StateError(
          'mediablock: trozo $indice truncado (${paquete.length} bytes)');
    }
    final aes = AesGcm.with256bits();
    try {
      final claro = await aes.decrypt(
        SecretBox.fromConcatenation(
          paquete,
          nonceLength: 12,
          macLength: 16,
        ),
        secretKey: SecretKey(await _claveTrozo(claveArchivo, indice)),
      );
      return Uint8List.fromList(claro);
    } catch (e) {
      throw StateError('mediablock: trozo $indice no autentica '
          '(¿clave mal o bloque alterado?): $e');
    }
  }

  static int claroDe(int indice, int tamano, int trozo) {
    final ini = indice * trozo;
    final resto = tamano - ini;
    if (resto <= 0) return 0;
    return resto < trozo ? resto : trozo;
  }

  static int offsetDe(int inicio, int indice, int trozo) {
    return inicio + indice * (trozo + overhead);
  }

  static int largoDe(int indice, int tamano, int trozo) {
    return claroDe(indice, tamano, trozo) + overhead;
  }

  static Future<Uint8List> descifrarRango({
    required Uint8List claveArchivo,
    required RangoCrudo rango,
  }) async {
    if (rango.modo != 'gcm-c') {
      throw StateError(
          'mediablock: modo ${rango.modo} no soportado (solo gcm-c)');
    }
    final fuera = <int>[];
    for (final p in rango.paquetes) {
      final claro = await descifrarTrozo(
        claveArchivo: claveArchivo,
        indice: p.indice,
        paquete: p.bytes,
      );
      final iniTrozo = p.indice * rango.trozo;
      final d = (rango.desde - iniTrozo).clamp(0, claro.length);
      var h = (rango.hasta - iniTrozo).clamp(0, claro.length);
      if (h < d) h = d;
      fuera.addAll(claro.sublist(d, h));
    }
    final want = rango.hasta - rango.desde;
    if (fuera.length != want) {
      throw StateError('mediablock: rango con ${fuera.length} bytes '
          '(esperaba $want)');
    }
    return Uint8List.fromList(fuera);
  }
}

/// Corre en el hilo aparte: sin capturas, solo el mensaje.
Future<Uint8List> _derivarHilo(Map<String, Object?> m) async {
  final pbkdf2 = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: Duro._pbkdf2Vueltas,
    bits: 256,
  );
  final derivada = await pbkdf2.deriveKey(
    secretKey: SecretKey(utf8.encode(m['semilla'] as String)),
    nonce: (m['sal'] as List).cast<int>(),
  );
  return Uint8List.fromList(await derivada.extractBytes());
}

/// Procesa un archivo a la vez; nunca conserva la lista de paquetes cifrados.
Future<int> _cifrarArchivoADisco(Map<String, Object?> m) async {
  final entrada = File(m['origen'] as String).openSync(mode: FileMode.read);
  RandomAccessFile? salida;
  final tamanoEsperado = m['tamanoEsperado'] as int;
  var procesado = 0;
  try {
    final archivoSalida =
        File(m['destino'] as String).openSync(mode: FileMode.append);
    salida = archivoSalida;
    var indice = 0;
    while (true) {
      final trozo = entrada.readSync(m['trozo'] as int);
      if (trozo.isEmpty) break;
      final paquete = await Duro.cifrarTrozo(
        claveArchivo: m['clave'] as Uint8List,
        indice: indice,
        claro: trozo,
      );
      archivoSalida.writeFromSync(paquete);
      procesado += trozo.length;
      indice++;
    }
    if (procesado != tamanoEsperado) {
      throw StateError(
        'mediablock: archivo cambió mientras se leía '
        '($procesado bytes leídos, $tamanoEsperado esperados)',
      );
    }
    return procesado;
  } finally {
    try {
      entrada.closeSync();
    } finally {
      salida?.closeSync();
    }
  }
}

/// Corre en el hilo aparte: rearma el rango y descifra ahí.
Future<Uint8List> _descifrarHilo(Map<String, Object?> m) async {
  final packs = [
    for (final e in (m['packs'] as List))
      PaqueteCrudo((e as List)[0] as int, e[1] as Uint8List)
  ];
  return Duro.descifrarRango(
    claveArchivo: m['clave'] as Uint8List,
    rango: RangoCrudo(
      modo: m['modo'] as String,
      archivo: m['archivo'] as String,
      desde: m['desde'] as int,
      hasta: m['hasta'] as int,
      trozo: m['trozo'] as int,
      tamano: m['tamano'] as int,
      paquetes: packs,
    ),
  );
}

/// Corre en el hilo aparte: descifra textos del índice ahí.
Future<List<String>> _descifrarTextosHilo(Map<String, Object?> m) async {
  final clave = m['clave'] as Uint8List;
  final fuera = <String>[];
  for (final d in (m['datos'] as List).cast<String>()) {
    fuera.add(await Duro.descifrarTexto(claveMolde: clave, dato: d));
  }
  return fuera;
}

class PaqueteCrudo {
  final int indice;
  final Uint8List bytes;
  PaqueteCrudo(this.indice, this.bytes);
}

class RangoCrudo {
  final String modo;
  final String archivo;
  final int desde;
  final int hasta;
  final int trozo;
  final int tamano;
  final List<PaqueteCrudo> paquetes;
  RangoCrudo({
    required this.modo,
    required this.archivo,
    required this.desde,
    required this.hasta,
    required this.trozo,
    required this.tamano,
    required this.paquetes,
  });
}
