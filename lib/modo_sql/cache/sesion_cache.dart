import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../db/caja_sql.dart';
import '../media_server/media_server.dart';

/// Sesión de cachés: DOS `.db` cifradas con sqlite3mc ChaCha20
/// (clave = pass del índice, se pide al iniciar, no se guarda):
///
///   `cache_trozos.db`   bloques pedidos del .mld (no re-pedir)
///   `cache_previas.db`  previas decodificadas (no re-abrir)
///
/// Sin temporales descifrados en disco: el cifrado es transparente.
/// La vieja `media_cache.db` (GCM entero) se migra una vez y se borra.
class SesionCache {
  static const archivoTrozos = 'cache_trozos.db';
  static const archivoPrevias = 'cache_previas.db';
  static const archivoViejo = 'media_cache.db';

  CajaSql? _trozos;
  CajaSql? _previas;

  bool get abierta => _trozos != null;

  /// Tope global disco (trozos+previas, todos los moldes). 0 = sin tope.
  /// Lo pone la pantalla desde Ajustes; la evicción es por LRU entre
  /// moldes (no por cantidad de moldes).
  int limiteGlobalBytes = 0;

  /// Última evicción global (para no correrla en cada escritura: el
  /// grid escribe decenas de veces por segundo al scrollear).
  int _ultEviccionMs = 0;

  /// Evicción global atenuada: como máximo 1 vez cada 30s en camino
  /// caliente (escrituras). La medición explícita usa evictarGlobal().
  Future<void> evictarGlobalSiToca() async {
    final ahora = DateTime.now().millisecondsSinceEpoch;
    if (ahora - _ultEviccionMs < 30000) return;
    _ultEviccionMs = ahora;
    await evictarGlobal();
  }

  /// Evicción global por LRU entre moldes hasta el tope. Solo corre
  /// al pasar el tope; con lugar no borra nada. No toca nada si la
  /// sesión está cerrada.
  Future<void> evictarGlobal() async {
    final tope = limiteGlobalBytes;
    final t = _trozos;
    final p = _previas;
    if (tope <= 0 || t == null || p == null) return;
    try {
      int sumarTotal() {
        var s = 0;
        for (final db in [t.db, p.db]) {
          final tabla = identical(db, t.db) ? 'cache_trozos' : 'cache_previas';
          final r =
              db.select('SELECT COALESCE(SUM(tamano), 0) AS x FROM "$tabla";');
          s += (r.first['x'] as int?) ?? 0;
        }
        return s;
      }

      var total = sumarTotal();
      while (total > tope) {
        final candT =
            t.db.select('SELECT rowid AS id, tamano, ultimo FROM cache_trozos '
                'ORDER BY ultimo ASC LIMIT 8;');
        final candP =
            p.db.select('SELECT rowid AS id, tamano, ultimo FROM cache_previas '
                'ORDER BY ultimo ASC LIMIT 8;');
        final cands = <(bool, int, int, int)>[
          for (final r in candT)
            (
              true,
              (r['id'] as int?) ?? -1,
              (r['tamano'] as int?) ?? 0,
              (r['ultimo'] as int?) ?? 0
            ),
          for (final r in candP)
            (
              false,
              (r['id'] as int?) ?? -1,
              (r['tamano'] as int?) ?? 0,
              (r['ultimo'] as int?) ?? 0
            ),
        ]..sort((a, b) => a.$4.compareTo(b.$4));
        if (cands.isEmpty) break;
        var borro = false;
        for (final c in cands.take(8)) {
          if (c.$2 < 0) continue;
          if (c.$1) {
            t.db.execute('DELETE FROM cache_trozos WHERE rowid = ?;', [c.$2]);
          } else {
            p.db.execute('DELETE FROM cache_previas WHERE rowid = ?;', [c.$2]);
          }
          total -= c.$3;
          borro = true;
          if (total <= tope) break;
        }
        if (!borro) break;
      }
    } catch (_) {}
  }

  /// Desbloquea con la pass del índice (la pide la app al iniciar).
  Future<void> abrir(String pass) async {
    if (pass.isEmpty) {
      throw ArgumentError('caché: sin pass del índice');
    }
    await cerrar();
    final dir = await getApplicationSupportDirectory();
    await _migrarLegacy(pass, dir);
    final t = CajaSql();
    await t.abrir('cache_trozos', carpeta: dir.path, clave: pass);
    t.db.execute('CREATE TABLE IF NOT EXISTS cache_trozos('
        'molde TEXT, archivo TEXT, indice INTEGER, tamano INTEGER, '
        'ultimo INTEGER, datos BLOB, '
        'PRIMARY KEY(molde, archivo, indice));');
    final p = CajaSql();
    await p.abrir('cache_previas', carpeta: dir.path, clave: pass);
    p.db.execute('CREATE TABLE IF NOT EXISTS cache_previas('
        'molde TEXT, archivo TEXT, tamano INTEGER, ultimo INTEGER, '
        'datos BLOB, primer_frame BLOB, PRIMARY KEY(molde, archivo));');
    final columnas = p.db.select('PRAGMA table_info(cache_previas);');
    if (!columnas.any((c) => c['name'] == 'primer_frame')) {
      p.db.execute('ALTER TABLE cache_previas ADD COLUMN primer_frame BLOB;');
    }
    _trozos = t;
    _previas = p;
  }

  Database get base {
    final c = _trozos;
    if (c == null) {
      throw StateError('caché: bloqueada (abrí el índice primero)');
    }
    return c.db;
  }

  Database get basePrevias {
    final c = _previas;
    if (c == null) {
      throw StateError('caché: bloqueada (abrí el índice primero)');
    }
    return c.db;
  }

  /// Sin-op: sqlite3mc persiste solo en cada escritura.
  Future<void> persistir() async {}

  Future<void> cerrar() async {
    try {
      _trozos?.cerrar();
    } catch (_) {}
    _trozos = null;
    try {
      _previas?.cerrar();
    } catch (_) {}
    _previas = null;
  }

  static String _salHex(Uint8List sal) {
    return sal.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
  }

  static Future<Uint8List> _clave(String pass, String salHex) {
    return Duro.claveArchivoHilo(
      clave: pass,
      molde: 'cache',
      nombre: 'sesion',
      salHex: salHex,
    );
  }

  /// Migra la caché vieja (GCM entero) a `cache_trozos.db`, una vez.
  /// Lee todo en memoria, lo inserta y borra el archivo viejo.
  Future<void> _migrarLegacy(String pass, Directory dir) async {
    final viejo = File('${dir.path}/$archivoViejo');
    if (!await viejo.exists()) return;
    CajaSql.log?.call('⚠ caché vieja (GCM) → migrando a SQL cifrada…');
    final t = await getTemporaryDirectory();
    final tmp = File('${t.path}/cache_tmp.db');
    try {
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {}
    var n = 0;
    try {
      final raw = await viejo.readAsBytes();
      if (raw.length < 16 + 12 + 16) {
        throw StateError('caché: archivo corrupto');
      }
      final sal = raw.sublist(0, 16);
      final nonce = raw.sublist(16, 28);
      final resto = raw.sublist(28);
      final key = await _clave(pass, _salHex(sal));
      final mac = Mac(resto.sublist(resto.length - 16));
      final cipher = resto.sublist(12, resto.length - 16);
      final claro = await AesGcm.with256bits().decrypt(
        SecretBox(cipher, nonce: nonce, mac: mac),
        secretKey: SecretKey(key),
      );
      await tmp.writeAsBytes(claro, flush: true);
      final origen = sqlite3.open(tmp.path);
      final filas =
          origen.select('SELECT molde, archivo, indice, tamano, ultimo, datos '
              'FROM cache_trozos;');
      origen.dispose();
      final caja = CajaSql();
      await caja.abrir('cache_trozos', carpeta: dir.path, clave: pass);
      try {
        caja.db.execute('CREATE TABLE IF NOT EXISTS cache_trozos('
            'molde TEXT, archivo TEXT, indice INTEGER, tamano INTEGER, '
            'ultimo INTEGER, datos BLOB, '
            'PRIMARY KEY(molde, archivo, indice));');
        for (final r in filas) {
          try {
            caja.db.execute(
              'INSERT OR REPLACE INTO cache_trozos(molde, archivo, '
              'indice, tamano, ultimo, datos) '
              'VALUES (?, ?, ?, ?, ?, ?);',
              [
                '${r['molde'] ?? ''}',
                '${r['archivo'] ?? ''}',
                (r['indice'] as int?) ?? 0,
                (r['tamano'] as int?) ?? 0,
                (r['ultimo'] as int?) ?? 0,
                r['datos'],
              ],
            );
            n++;
          } catch (_) {}
        }
      } finally {
        caja.cerrar();
      }
    } catch (e) {
      CajaSql.log?.call('⚠ caché vieja no migró (sigue en plano viejo): $e');
      return;
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
    try {
      await viejo.delete();
    } catch (_) {}
    CajaSql.log?.call('✓ caché migrada a SQL cifrada ($n trozo(s))');
  }
}
