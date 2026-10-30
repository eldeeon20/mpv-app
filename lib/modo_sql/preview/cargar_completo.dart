import 'dart:typed_data';

import '../cache/trozo_cache.dart';
import '../media_server/media_server.dart';
import '../tool/create_molde_sql.dart';

/// Bytes completos memoizados para el visor (por molde+archivo).
class CargadorCompleto {
  final Map<String, Future<Uint8List?>> _futs = {};

  /// Minis ya descifradas (el tap reusa lo que el grid ya pidió:
  /// abrir es instantáneo si la mini está).
  Map<String, Uint8List> minis = {};

  void limpiar() => _futs.clear();

  Future<Uint8List?> de({
    required String claveSql,
    required String molde,
    required FichaArchivo f,
    TrozoCache? cache,
    MoldeInfo? info,
    List<FichaArchivo>? filas,
  }) {
    final mini = minis[f.nombre];
    if (mini != null) return Future.value(mini);
    final k = '$molde\n${f.nombre}';
    final ya = _futs[k];
    if (ya != null) return ya;
    final fut = () async {
      try {
        if (f.tamano <= 0 || f.tamano > 15 * 1024 * 1024) return null;
        final datos = await CreateMoldeSql.pedirRango(
          claveSql: claveSql,
          molde: molde,
          archivo: f.nombre,
          desde: 0,
          hasta: f.tamano,
          cache: cache,
          info: info,
          filas: filas,
        );
        return Uint8List.fromList(datos);
      } catch (_) {
        return null;
      }
    }();
    _futs[k] = fut;
    while (_futs.length > 20) {
      _futs.remove(_futs.keys.first);
    }
    return fut;
  }
}
