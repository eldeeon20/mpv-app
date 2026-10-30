import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../cache/trozo_cache.dart';
import '../comun/archivos_fs.dart';
import '../comun/campos.dart';
import '../media_server/media_server.dart';
import '../tool/create_molde_sql.dart';

/// Descarga un archivo del molde a Download (o Documentos):
/// lo pide por partes de 1MB (con caché) y lo escribe directo,
/// sin tope de RAM.
Future<void> descargarArchivo({
  required String claveSql,
  required String molde,
  required FichaArchivo ficha,
  TrozoCache? cache,
  MoldeInfo? info,
  List<FichaArchivo>? filas,
  required void Function(String s) log,
}) async {
  if (ficha.tamano == 0) {
    log('· "${ficha.nombre}" vacío (0 bytes, nada que bajar)');
    return;
  }
  if (!await accesoCarpeta()) {
    log('✗ sin permiso de almacenamiento para descargar');
    return;
  }
  Directory dir;
  if (Platform.isAndroid) {
    final descargas = Directory('/storage/emulated/0/Download');
    dir = await descargas.exists()
        ? descargas
        : await getApplicationDocumentsDirectory();
  } else {
    dir = await getApplicationDocumentsDirectory();
  }
  final base = ficha.nombre.split('/').last;
  final dest = File('${dir.path}/$base');
  const paso = 1024 * 1024;
  log('· bajando "${ficha.nombre}" (${fmtBytes(ficha.tamano)})…');
  final sink = dest.openWrite();
  try {
    var desde = 0;
    while (desde < ficha.tamano) {
      var hasta = desde + paso;
      if (hasta > ficha.tamano) hasta = ficha.tamano;
      final datos = await CreateMoldeSql.pedirRango(
        claveSql: claveSql,
        molde: molde,
        archivo: ficha.nombre,
        desde: desde,
        hasta: hasta,
        cache: cache,
        info: info,
        filas: filas,
      );
      sink.add(datos);
      desde = hasta;
    }
    await sink.close();
    log('✓ "${ficha.nombre}" en ${dest.path} '
        '(${fmtBytes(ficha.tamano)})');
  } catch (e) {
    try {
      await sink.close();
    } catch (_) {}
    log('✗ descargar: $e');
  }
}
