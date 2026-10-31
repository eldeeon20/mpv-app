import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Derivación de claves del formato v3; el cifrado de bloques vive en Duro.
class ClavesMoldeV3 {
  ClavesMoldeV3._();

  static const marker = 'gcm-c-entry-v3-argon2id-m131072-t2-p1';
  static const memoriaKiB = 128 * 1024;
  static const iteraciones = 2;

  static Future<Uint8List> derivarMaestra({
    required String clave,
    required String salHex,
  }) {
    if (clave.isEmpty) {
      throw ArgumentError('mediablock: clave vacía');
    }
    return Isolate.run(() => _derivarMaestra({
          'clave': clave,
          'sal': _salBytes(salHex),
        }));
  }

  static Future<Uint8List> derivarArchivo({
    required Uint8List claveMaestra,
    required String molde,
    required String nombre,
    required String salHex,
  }) async {
    if (claveMaestra.length != 32) {
      throw ArgumentError.value(
        claveMaestra.length,
        'claveMaestra',
        'debe tener 32 bytes',
      );
    }
    final derivada = await Hkdf(
      hmac: Hmac.sha256(),
      outputLength: 32,
    ).deriveKey(
      secretKey: SecretKey(claveMaestra),
      nonce: _salBytes(salHex),
      info: utf8.encode('mediablock-file-v3\u0000$molde\u0000$nombre'),
    );
    return Uint8List.fromList(await derivada.extractBytes());
  }
}

List<int> _salBytes(String salHex) {
  if (salHex.length.isOdd || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(salHex)) {
    throw ArgumentError('mediablock: sal v3 inválida');
  }
  final bytes = <int>[];
  for (var i = 0; i < salHex.length; i += 2) {
    bytes.add(int.parse(salHex.substring(i, i + 2), radix: 16));
  }
  if (bytes.length < 16) {
    throw ArgumentError('mediablock: la sal v3 debe tener al menos 16 bytes');
  }
  return bytes;
}

Future<Uint8List> _derivarMaestra(Map<String, Object?> message) async {
  final key = await Argon2id(
    parallelism: 1,
    memory: ClavesMoldeV3.memoriaKiB,
    iterations: ClavesMoldeV3.iteraciones,
    hashLength: 32,
  ).deriveKey(
    secretKey: SecretKey(utf8.encode(message['clave'] as String)),
    nonce: (message['sal'] as List).cast<int>(),
  );
  return Uint8List.fromList(await key.extractBytes());
}
