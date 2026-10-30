import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import 'sesion_cache.dart';

/// Caché de PREVIAS decodificadas (jpeg chicos del .mld, no re-abrir
/// originales). Vive en `cache_previas.db` (sqlite3mc, misma pass).
/// LRU por `ultimo`, libre por defecto (8MB: miles de previas).
class PreviaCache {
  static const tabla = 'cache_previas';

  final SesionCache sesion;
  final String molde;
  int limiteBytes;

  PreviaCache({
    required this.sesion,
    required this.molde,
    this.limiteBytes = 8 * 1024 * 1024,
  });

  static Uint8List _bytes(Object? v) {
    if (v is Uint8List) return v;
    if (v is List) return Uint8List.fromList(v.cast<int>());
    throw StateError('previas: blob inválido');
  }

  /// Empaqueta frames: [u32be len][bytes]… (un solo blob por archivo).
  static Uint8List _empaquetar(List<Uint8List> frames) {
    var n = 0;
    for (final f in frames) {
      n += 4 + f.length;
    }
    final fuera = Uint8List(n);
    final vista = ByteData.sublistView(fuera);
    var o = 0;
    for (final f in frames) {
      vista.setUint32(o, f.length, Endian.big);
      fuera.setRange(o + 4, o + 4 + f.length, f);
      o += 4 + f.length;
    }
    return fuera;
  }

  /// Desempaqueta; null si no cierra exacto (filas viejas de 1 frame
  /// sin empaquetar → se releen de SQL y se pisan solas).
  static List<Uint8List>? _desempaquetar(Uint8List blob) {
    try {
      final vista = ByteData.sublistView(blob);
      final fuera = <Uint8List>[];
      var o = 0;
      while (o < blob.length) {
        if (o + 4 > blob.length) return null;
        final len = vista.getUint32(o, Endian.big);
        o += 4;
        if (len <= 0 || o + len > blob.length) return null;
        fuera.add(Uint8List.sublistView(blob, o, o + len));
        o += len;
      }
      if (o != blob.length || fuera.isEmpty) return null;
      return fuera;
    } catch (_) {
      return null;
    }
  }

  /// Todos los frames guardados o null = miss.
  Future<List<Uint8List>?> leerTodos({required String archivo}) async {
    final db = sesion.basePrevias;
    final rs = db.select(
      'SELECT rowid AS id, datos FROM "$tabla" '
      'WHERE molde = ? AND archivo = ?;',
      [molde, archivo],
    );
    if (rs.isEmpty) return null;
    try {
      final ahora = DateTime.now().microsecondsSinceEpoch;
      db.execute(
        'UPDATE "$tabla" SET ultimo = ? WHERE rowid = ?;',
        [ahora, rs.first['id'] as int],
      );
      return _desempaquetar(_bytes(rs.first['datos']));
    } catch (_) {
      return null;
    }
  }

  /// Guarda TODOS los frames (la transición sobrevive a reabrir).
  Future<void> guardarTodos({
    required String archivo,
    required List<Uint8List> frames,
  }) async {
    if (frames.isEmpty) return;
    final db = sesion.basePrevias;
    final blob = _empaquetar(frames);
    final ahora = DateTime.now().microsecondsSinceEpoch;
    db.execute(
      'INSERT OR REPLACE INTO "$tabla"'
      '(molde, archivo, tamano, ultimo, datos, primer_frame) '
      'VALUES (?, ?, ?, ?, ?, ?);',
      [
        molde,
        archivo,
        blob.length + frames.first.length,
        ahora,
        blob,
        frames.first
      ],
    );
    await _evictar(db);
    // Tope por molde y después tope global entre moldes (LRU,
    // atenuado: como máximo 1 vez cada 30s en escrituras).
    await sesion.evictarGlobalSiToca();
    await sesion.persistir();
  }

  /// Guarda solo el primer frame para que el grid de videos no tenga
  /// que desempaquetar o leer todos los frames antes de mostrarse.
  Future<void> guardarUno({
    required String archivo,
    required Uint8List frame,
  }) async {
    if (frame.isEmpty) return;
    final db = sesion.basePrevias;
    final ahora = DateTime.now().microsecondsSinceEpoch;
    db.execute(
      'INSERT OR REPLACE INTO "$tabla"'
      '(molde, archivo, tamano, ultimo, datos, primer_frame) '
      'VALUES (?, ?, ?, ?, ?, ?);',
      [molde, archivo, frame.length, ahora, Uint8List(0), frame],
    );
    await _evictar(db);
    await sesion.evictarGlobalSiToca();
    await sesion.persistir();
  }

  Future<int> _total(Database db) async {
    final rs = db.select(
      'SELECT COALESCE(SUM(tamano), 0) AS t FROM "$tabla" '
      'WHERE molde = ?;',
      [molde],
    );
    return (rs.first['t'] as int?) ?? 0;
  }

  Future<void> _evictar(Database db) async {
    var total = await _total(db);
    while (total > limiteBytes) {
      final vict = db.select(
        'SELECT rowid AS id, tamano FROM "$tabla" WHERE molde = ? '
        'ORDER BY ultimo ASC LIMIT 16;',
        [molde],
      );
      if (vict.isEmpty) break;
      for (final v in vict) {
        db.execute('DELETE FROM "$tabla" WHERE rowid = ?;', [v['id'] as int]);
        total -= (v['tamano'] as int?) ?? 0;
      }
    }
  }

  /// UN solo frame (el primero) para el grid de videos.
  /// Lee la misma fila pero desempaqueta solo el primer frame.
  Future<Uint8List?> leerUno({required String archivo}) async {
    final db = sesion.basePrevias;
    final rs = db.select(
      'SELECT rowid AS id, primer_frame FROM "$tabla" '
      'WHERE molde = ? AND archivo = ?;',
      [molde, archivo],
    );
    if (rs.isEmpty) return null;
    try {
      final ahora = DateTime.now().microsecondsSinceEpoch;
      db.execute(
        'UPDATE "$tabla" SET ultimo = ? WHERE rowid = ?;',
        [ahora, rs.first['id'] as int],
      );
      final primerFrame = rs.first['primer_frame'];
      if (primerFrame != null) {
        final bytes = _bytes(primerFrame);
        return bytes.isEmpty ? null : bytes;
      }
      final legacy = db.select(
        'SELECT datos FROM "$tabla" WHERE molde = ? AND archivo = ?;',
        [molde, archivo],
      );
      if (legacy.isEmpty) return null;
      final blob = _bytes(legacy.first['datos']);
      final vista = ByteData.sublistView(blob);
      if (blob.length < 4) return null;
      final len = vista.getUint32(0, Endian.big);
      if (len <= 0 || 4 + len > blob.length) return null;
      final frame = Uint8List.sublistView(blob, 4, 4 + len);
      db.execute(
        'UPDATE "$tabla" SET primer_frame = ?, tamano = tamano + ? '
        'WHERE rowid = ?;',
        [frame, frame.length, rs.first['id'] as int],
      );
      return frame;
    } catch (_) {
      return null;
    }
  }

  Future<int> bytesEnCache() async => _total(sesion.basePrevias);

  Future<void> limpiarMolde() async {
    sesion.basePrevias
        .execute('DELETE FROM "$tabla" WHERE molde = ?;', [molde]);
  }

  /// Limpieza estática (borrar/recrear molde).
  static Future<void> limpiarMoldeDe(SesionCache sesion, String molde) async {
    try {
      sesion.basePrevias
          .execute('DELETE FROM "$tabla" WHERE molde = ?;', [molde]);
    } catch (_) {}
  }

  static Future<void> limpiarTodo(SesionCache sesion) async {
    sesion.basePrevias.execute('DELETE FROM "$tabla";');
  }

  static Future<int> bytesTotales(SesionCache sesion) async {
    final rs = sesion.basePrevias.select(
      'SELECT COALESCE(SUM(tamano), 0) AS t FROM "$tabla";',
    );
    return (rs.first['t'] as int?) ?? 0;
  }
}
