import 'dart:typed_data';

import '../src/rust/api/nostringer.dart' as rust;

/// Nostringer: firmas de anillo BLSAG/SAG (anonimato dentro de un grupo).
///
/// Firmás como miembro del ring sin revelar CUÁL clave es tuya.
/// Ejemplo: 5 votantes, 1 firma válida → se sabe que votó ALGUIEN del
/// ring, no quién; la key image impide que firme dos veces.
///
/// Todas las llamadas al codegen FRB son async.
class Nostringer {
  /// Genera par de claves. [variant]: 'blsag' | 'sag'.
  Future<RingKeypair> generateKeypair({String variant = 'blsag'}) async {
    final kp = await rust.ringGenerateKeypair(variant: variant);
    return RingKeypair(publicKey: kp.publicKey, privateKey: kp.privateKey);
  }

  /// Firma [message] como miembro de [ring] (debe incluir tu pública).
  Future<RingSignature> sign({
    required Uint8List message,
    required String privateKey,
    required List<String> ring,
    String variant = 'blsag',
  }) async {
    final s = await rust.ringSign(
      message: message,
      privateKey: privateKey,
      ring: ring,
      variant: variant,
    );
    return RingSignature(signature: s.signature, keyImage: s.keyImage);
  }

  /// Verifica una firma (string compacta) contra el ring.
  Future<RingVerifyResult> verify({
    required String signature,
    required Uint8List message,
    required List<String> ring,
  }) async {
    final r = await rust.ringVerify(
        signature: signature, message: message, ring: ring);
    return RingVerifyResult(valid: r.valid, keyImage: r.keyImage);
  }

  /// Verificación estricta BLSAG con key image explícita.
  Future<bool> verifyBlsag({
    required String signature,
    required String keyImage,
    required Uint8List message,
    required List<String> ring,
  }) {
    return rust.ringVerifyBlsag(
      signature: signature,
      keyImage: keyImage,
      message: message,
      ring: ring,
    );
  }

  /// true si ambas key images son la misma identidad (doble firmante).
  Future<bool> keyImagesMatch(String ki1, String ki2) =>
      rust.ringKeyImagesMatch(ki1: ki1, ki2: ki2);
}

class RingKeypair {
  final String publicKey;
  final String privateKey;
  RingKeypair({required this.publicKey, required this.privateKey});
}

class RingSignature {
  final String signature;
  final String keyImage;
  RingSignature({required this.signature, required this.keyImage});
}

class RingVerifyResult {
  final bool valid;
  final String keyImage;
  RingVerifyResult({required this.valid, required this.keyImage});
}
