import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

/// KV único de la app (`app.db`, tabla `kv`): reemplaza los .pr
/// privados y los json sueltos (config.pr, ajustes_modo.json,
/// filosoia_*.pr, media_library.pr).
///
/// El archivo completo va cifrado con sqlite3mc ChaCha20. Por eso los
/// valores pueden guardarse en claro: la protección está a nivel de
/// páginas SQLite, no valor por valor.
///
/// Las agendas NO van acá: tienen su base propia en Download con su
/// pass (orden explícita: dejarlas quietas).
abstract final class AppDb {
  /// Clave del archivo `app.db`. Se comparte con Settings solo para
  /// migrar blobs viejos.
  static const String claveDb = '1234';

  /// Apertura ÚNICA de app.db (cifrada ChaCha20, migra el plano una
  /// vez). Todos los dueños (Settings, ClavesApp) pasan por acá: abrir
  /// el mismo archivo en plano y cifrado a la vez rompe con
  /// "file is not a database".
  static Future<Database> abrirDb() async {
    final dir = await getApplicationSupportDirectory();
    final ruta = '${dir.path}/app.db';
    final archivo = File(ruta);
    final existia = await archivo.exists();
    final enPlano = existia && _esPlano(ruta);
    final respaldo = File('$ruta.migracion.bak');
    final hizoRespaldo = enPlano && !await respaldo.exists();
    if (hizoRespaldo) await archivo.copy(respaldo.path);

    Database? db;
    try {
      db = sqlite3.open(ruta);
      // Orden sqlite3mc: primero el cifrador, después la clave.
      db.execute("PRAGMA cipher = 'chacha20';");
      if (!existia || !enPlano) {
        db.execute("PRAGMA key = '$claveDb';");
      } else {
        // Base vieja en plano: se cifra in situ, una sola vez.
        db.execute("PRAGMA rekey = '$claveDb';");
      }
      db.execute(
          'CREATE TABLE IF NOT EXISTS kv(clave TEXT PRIMARY KEY, datos BLOB);');
      // Con clave mala o migración fallida, esto lanza.
      db.select('SELECT count(*) AS n FROM sqlite_master;');
      if (hizoRespaldo) await respaldo.delete();
      final abierta = db;
      db = null;
      return abierta;
    } finally {
      final pendiente = db;
      if (pendiente != null) {
        try {
          pendiente.dispose();
        } catch (_) {}
        if (hizoRespaldo) {
          try {
            await respaldo.copy(ruta);
            await respaldo.delete();
          } catch (_) {}
        }
      }
    }
  }

  /// true si el archivo es una `.db` en plano (cabecera SQLite).
  /// Inexistente o vacío = false (nace cifrada con su clave).
  static bool _esPlano(String ruta) {
    try {
      final f = File(ruta);
      if (!f.existsSync() || f.lengthSync() < 16) return false;
      final raf = f.openSync(mode: FileMode.read);
      try {
        final h = raf.readSync(16);
        const magic = 'SQLite format 3';
        if (h.length < magic.length) return false;
        for (var i = 0; i < magic.length; i++) {
          if (h[i] != magic.codeUnitAt(i)) return false;
        }
        return true;
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      return false;
    }
  }

  static Uint8List? _bytes(Object? v) {
    if (v is Uint8List) return v;
    if (v is List) return Uint8List.fromList(v.cast<int>());
    return null;
  }

  /// Bytes guardados o null (no hay clave).
  static Future<Uint8List?> leer(String clave) async {
    final db = await abrirDb();
    try {
      final r =
          db.select('SELECT datos FROM kv WHERE clave = ?;', [clave]);
      if (r.isEmpty) return null;
      return _bytes(r.first['datos']);
    } finally {
      db.dispose();
    }
  }

  /// Guarda (o pisa) los bytes de una clave.
  static Future<void> guardar(String clave, Uint8List datos) async {
    final db = await abrirDb();
    try {
      db.execute(
          'INSERT OR REPLACE INTO kv(clave, datos) VALUES (?, ?);',
          [clave, datos]);
    } finally {
      db.dispose();
    }
  }

  /// Borra una clave (si no existe, nada).
  static Future<void> borrar(String clave) async {
    try {
      final db = await abrirDb();
      try {
        db.execute('DELETE FROM kv WHERE clave = ?;', [clave]);
      } finally {
        db.dispose();
      }
    } catch (_) {}
  }

  /// Borra un archivo viejo de appSupport (los .pr no importan: no se
  /// migran, se tachan; app.db manda con defaults). No falla si no hay.
  static Future<void> tachar(String nombre) async {
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}/$nombre');
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
