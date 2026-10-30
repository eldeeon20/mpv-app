import 'dart:io';
import 'dart:typed_data';

/// SERVIDOR idiota: solo bytes crudos del `.mld` por offset absoluto.
/// Sin clave, sin SQL.
class MediaServer {
  MediaServer._();

  static Future<MoldeAbierto> abrir({required String rutaMld}) async {
    final f = File(rutaMld);
    if (!await f.exists()) {
      throw StateError('mediablock: no existe el bloque "$rutaMld"');
    }
    return MoldeAbierto._(ruta: rutaMld, total: await f.length());
  }
}

class MoldeAbierto {
  final String ruta;
  final int total;

  MoldeAbierto._({required this.ruta, required this.total});

  Future<Uint8List> leer({
    required int absoluto,
    required int largo,
  }) async {
    final r = await leerVarios([
      [absoluto, largo]
    ]);
    return r.first;
  }

  /// Lee varios rangos con UNA sola apertura (un pedido = un open,
  /// no uno por trozo: 47 opens por imagen trancaban).
  Future<List<Uint8List>> leerVarios(List<List<int>> rangos) async {
    for (final r in rangos) {
      final absoluto = r[0];
      final largo = r[1];
      if (absoluto < 0 || largo < 0) {
        throw ArgumentError(
            'mediablock: lectura negativa [$absoluto, $largo)');
      }
      if (absoluto + largo > total) {
        throw ArgumentError(
            'mediablock: [$absoluto, $largo) pasa el bloque ($total)');
      }
    }
    final raf = File(ruta).openSync(mode: FileMode.read);
    try {
      final fuera = <Uint8List>[];
      for (final r in rangos) {
        if (r[1] == 0) {
          fuera.add(Uint8List(0));
          continue;
        }
        raf.setPositionSync(r[0]);
        final datos = raf.readSync(r[1]);
        if (datos.length != r[1]) {
          throw StateError(
              'mediablock: bloque cortado en [${r[0]}, ${r[1]})');
        }
        fuera.add(datos);
      }
      return fuera;
    } finally {
      try {
        raf.closeSync();
      } catch (_) {}
    }
  }
}
