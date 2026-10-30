import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import 'sesion_cache.dart';

/// Caché de trozos EN BRUTO (sin descifrar, sin re-cifrar): lo que da
/// el server se guarda tal cual. La protección es la sesión (el
/// archivo va cifrado con la pass del índice, que se pide al iniciar).
///
/// LRU por `ultimo`: cada hit lo refresca; lo viejo/menos visto se
/// evicta al pasar [limiteBytes].
class TrozoCache {
  static const tabla = 'cache_trozos';

  final SesionCache sesion;
  final String molde;
  int limiteBytes;

  int hits = 0;
  int fallos = 0;

  TrozoCache({
    required this.sesion,
    required this.molde,
    this.limiteBytes = 512 * 1024,
  });

  static Uint8List _bytes(Object? v) {
    if (v is Uint8List) return v;
    if (v is List) return Uint8List.fromList(v.cast<int>());
    throw StateError('cache: blob inválido');
  }

  /// Trozo crudo o null = miss. Cada hit actualiza `ultimo`.
  Future<Uint8List?> leer({
    required String archivo,
    required int indice,
  }) async {
    final lote = await leerLote(archivo: archivo, indices: [indice]);
    return lote[indice];
  }

  /// Lee varios trozos con UN solo SELECT (el grid pedía 47 SELECTs
  /// por imagen en el hilo UI y el scroll se trancaba).
  Future<Map<int, Uint8List>> leerLote({
    required String archivo,
    required List<int> indices,
  }) async {
    final fuera = <int, Uint8List>{};
    if (indices.isEmpty) return fuera;
    final db = sesion.base;
    final marcas = List.filled(indices.length, '?').join(', ');
    final rs = db.select(
      'SELECT rowid AS id, indice, datos FROM "$tabla" '
      'WHERE molde = ? AND archivo = ? AND indice IN ($marcas);',
      [molde, archivo, ...indices],
    );
    if (rs.isEmpty) {
      fallos += indices.length;
      return fuera;
    }
    try {
      final ids = <int>[];
      for (final r in rs) {
        final i = (r['indice'] as int?) ?? -1;
        if (i < 0) continue;
        fuera[i] = _bytes(r['datos']);
        ids.add(r['id'] as int);
      }
      final ahora = DateTime.now().microsecondsSinceEpoch;
      final m2 = List.filled(ids.length, '?').join(', ');
      db.execute(
        'UPDATE "$tabla" SET ultimo = ? WHERE rowid IN ($m2);',
        [ahora, ...ids],
      );
      hits += fuera.length;
      fallos += indices.length - fuera.length;
      return fuera;
    } catch (_) {
      fallos += indices.length;
      return {};
    }
  }

  /// Guarda el paquete crudo y evicta lo más viejo si pasa el límite.
  Future<void> guardar({
    required String archivo,
    required int indice,
    required Uint8List paquete,
  }) async {
    await guardarLote(archivo: archivo, paquetes: {indice: paquete});
  }

  /// Guarda varios trozos con UN solo persist (un pedido = un cifrado,
  /// no uno por trozo: eso trancaba el scroll).
  Future<void> guardarLote({
    required String archivo,
    required Map<int, Uint8List> paquetes,
  }) async {
    if (paquetes.isEmpty) return;
    final db = sesion.base;
    final ahora = DateTime.now().microsecondsSinceEpoch;
    for (final e in paquetes.entries) {
      db.execute(
        'INSERT OR REPLACE INTO "$tabla"'
        '(molde, archivo, indice, tamano, ultimo, datos) '
        'VALUES (?, ?, ?, ?, ?, ?);',
        [molde, archivo, e.key, e.value.length, ahora, e.value],
      );
    }
    await _evictar(db);
    // Tope por molde y después tope global entre moldes (LRU,
    // atenuado: como máximo 1 vez cada 30s en escrituras).
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
        'ORDER BY ultimo ASC LIMIT 8;',
        [molde],
      );
      if (vict.isEmpty) break;
      for (final v in vict) {
        db.execute('DELETE FROM "$tabla" WHERE rowid = ?;',
            [v['id'] as int]);
        total -= (v['tamano'] as int?) ?? 0;
      }
    }
  }

  /// Cuánto ocupa la caché de este molde (para el log).
  Future<int> bytesEnCache() async => _total(sesion.base);

  /// Vacía TODA la caché (todos los moldes). Se reconstruye sola.
  static Future<void> limpiarTodo(SesionCache sesion) async {
    sesion.base.execute('DELETE FROM "$tabla";');
    await sesion.persistir();
  }

  /// Total de todos los moldes (para el Admin).
  static Future<int> bytesTotales(SesionCache sesion) async {
    final rs = sesion.base.select(
      'SELECT COALESCE(SUM(tamano), 0) AS t FROM "$tabla";',
    );
    return (rs.first['t'] as int?) ?? 0;
  }

  String resumen() =>
      'caché $hits hits/$fallos miss (molde "$molde")';

  Future<void> limpiarMolde() async {
    sesion.base.execute(
        'DELETE FROM "$tabla" WHERE molde = ?;', [molde]);
    await sesion.persistir();
  }

  /// Limpieza estática (borrar/recrear molde: los offsets viejos
  /// envenenan la caché y todo falla con MAC).
  static Future<void> limpiarMoldeDe(
      SesionCache sesion, String molde) async {
    try {
      sesion.base.execute(
          'DELETE FROM "$tabla" WHERE molde = ?;', [molde]);
      await sesion.persistir();
    } catch (_) {}
  }

  /// Purga un archivo (MAC falló: paquetes de otro .mld).
  Future<void> limpiarArchivo(String archivo) async {
    try {
      sesion.base.execute(
          'DELETE FROM "$tabla" WHERE molde = ? AND archivo = ?;',
          [molde, archivo]);
      await sesion.persistir();
    } catch (_) {}
  }
}
