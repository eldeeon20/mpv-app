import 'dart:typed_data';

import '../src/rust/api/shamir.dart' as rust;

/// Shamir Secret Sharing — porte del `Shamir` de Gtool.
/// Divide un secreto/mensaje en N partes; con `threshold` se reconstruye.
class Shamir {
  /// Divide [data] en [count] partes (se necesitan [threshold] para unir).
  Future<List<Uint8List>> split(Uint8List data, int count, int threshold) async {
    final parts =
        await rust.shamirSplit(data: data, count: count, threshold: threshold);
    return parts.map(Uint8List.fromList).toList();
  }

  /// Reconstruye los datos desde >= threshold partes.
  /// null = secreto perdido (partes insuficientes o corruptas).
  Future<Uint8List?> combine(List<Uint8List> shares) async {
    final out = await rust.shamirCombine(shares: shares);
    return out == null ? null : Uint8List.fromList(out);
  }
}
