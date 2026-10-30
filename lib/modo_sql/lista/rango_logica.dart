import '../cache/trozo_cache.dart';
import '../comun/campos.dart';
import '../media_server/media_server.dart';
import '../tool/create_molde_sql.dart';

/// Lógica de pedir rangos: devuelve el texto para la bitácora/línea.
/// La pantalla solo parsea y hace setState.

Future<String> pedirRangoTexto({
  required String claveSql,
  required String molde,
  required String archivo,
  required int desde,
  required int hasta,
  TrozoCache? cache,
  MoldeInfo? info,
  List<FichaArchivo>? filas,
}) async {
  try {
    final datos = await CreateMoldeSql.pedirRango(
      claveSql: claveSql,
      molde: molde,
      archivo: archivo,
      desde: desde,
      hasta: hasta,
      cache: cache,
      info: info,
      filas: filas,
    );
    final hex = datos
        .take(64)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(' ');
    return '✓ [$desde, $hasta) de "$archivo": ${datos.length} bytes '
        'descifrados\n$hex${datos.length > 64 ? '…' : ''}';
  } catch (e) {
    return '✗ pedir: $e';
  }
}

Future<String> pedirArchivoTexto({
  required String claveSql,
  required String molde,
  required FichaArchivo ficha,
  TrozoCache? cache,
  MoldeInfo? info,
  List<FichaArchivo>? filas,
}) async {
  if (ficha.tamano == 0) return '✓ "${ficha.nombre}" vacío (0 bytes)';
  try {
    final datos = await CreateMoldeSql.pedirRango(
      claveSql: claveSql,
      molde: molde,
      archivo: ficha.nombre,
      desde: 0,
      hasta: ficha.tamano,
      cache: cache,
      info: info,
      filas: filas,
    );
    return '✓ "${ficha.nombre}" entero: '
        '${fmtBytes(datos.length)} descifrados';
  } catch (e) {
    return '✗ pedir: $e';
  }
}
