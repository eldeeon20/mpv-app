import 'dart:convert';
import 'dart:typed_data';

import '../services/app_db.dart';
import '../toolsec/toolsec.dart';

/// Biblioteca del reproductor: historial + favoritos + listas + grupos.
///
/// Persistencia cifrada en `app.db` (clave `media_library`),
/// esquema fuerte V2 (AES-256-GCM + PBKDF2) vía ToolSec.processBytesStrong.
/// Las claves nuevas (playlists/groups) son opcionales al leer: un archivo
/// viejo carga igual (listas y grupos vacíos).
///
/// El viejo `media_library.pr` no importa: se borra sin migrar.
///
/// - Historial: últimas reproducciones (más reciente primero).
/// - Favoritos: marcados con la estrella.
/// - Listas (playlists): colecciones nombradas de temas.
/// - Grupos: colecciones nombradas de listas.
class MediaLibraryStore {
  static final MediaLibraryStore instance = MediaLibraryStore._();

  MediaLibraryStore._();

  static const int maxHistory = 20000;
  static const _kv = 'media_library';

  /// Nombre del archivo viejo (solo migración, después se borra).
  static const _fileName = 'media_library.pr';

  final List<Map<String, String>> _history = [];
  final List<Map<String, String>> _favorites = [];
  final List<Map<String, dynamic>> _playlists = [];
  final List<Map<String, dynamic>> _groups = [];
  bool _loaded = false;

  /// Avisa a la UI cuando algo cambió para que la estrella/conteos se
  /// vean AL MOMENTO (sin esperar a reentrar a la pantalla).
  void Function()? onChanged;
  void _emit() => onChanged?.call();

  /// Historial más reciente primero (copia inmutable para la UI).
  List<Map<String, String>> get history => List.unmodifiable(_history);

  /// Favoritos en orden de agregado (copia inmutable para la UI).
  List<Map<String, String>> get favorites => List.unmodifiable(_favorites);

  /// Listas en orden de creación (mapas con id/name/ts/items).
  List<Map<String, dynamic>> get playlists => List.unmodifiable(_playlists);

  /// Grupos en orden de creación (mapas con id/name/ts/ids de listas).
  List<Map<String, dynamic>> get groups => List.unmodifiable(_groups);

  bool isFavorite(String path) =>
      _favorites.any((e) => e['uri'] == path);

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    // El .pr no importa: se borra, app.db manda.
    await AppDb.tachar(_fileName);
    try {
      final enc = await AppDb.leer(_kv);
      if (enc == null) return;
      final plain = await ToolSec('media_library').processBytesAuto(enc);
      if (plain == null) return;
      final map = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
      final h = (map['history'] as List?) ?? const [];
      final f = (map['favorites'] as List?) ?? const [];
      final p = (map['playlists'] as List?) ?? const [];
      final g = (map['groups'] as List?) ?? const [];
      _history
        ..clear()
        ..addAll(h
            .whereType<Map>()
            .map((e) => e.map((k, v) => MapEntry('$k', '$v'))));
      _favorites
        ..clear()
        ..addAll(f
            .whereType<Map>()
            .map((e) => e.map((k, v) => MapEntry('$k', '$v'))));
      _playlists
        ..clear()
        ..addAll(p.whereType<Map>().map(
            (e) => _sanearLista(Map<String, dynamic>.from(e as Map))));
      _groups
        ..clear()
        ..addAll(g.whereType<Map>().map(
            (e) => _sanearGrupo(Map<String, dynamic>.from(e as Map))));
    } catch (e) {
      print('MediaLibraryStore.load error: $e');
    }
  }

  Future<void> _persist() async {
    try {
      final plain = utf8.encode(jsonEncode({
        'history': _history,
        'favorites': _favorites,
        'playlists': _playlists,
        'groups': _groups,
      }));
      final enc = await ToolSec('media_library')
          .processBytesStrong(Uint8List.fromList(plain));
      await AppDb.guardar(_kv, enc);
    } catch (e) {
      print('MediaLibraryStore.persist error: $e');
    }
  }

  String _titleOf(String path) =>
      path.split('/').last.split('\\').last.split('?').first;

  String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_playlists.length}-${_groups.length}';

  Map<String, dynamic>? _buscar(List<Map<String, dynamic>> lista, String id) {
    for (final e in lista) {
      if (e['id'] == id) return e;
    }
    return null;
  }

  /// Normaliza una lista leída del disco (claves que falten → defaults).
  static Map<String, dynamic> _sanearLista(Map<String, dynamic> e) {
    final items = (e['items'] as List?) ?? const [];
    return {
      'id': '${e['id'] ?? ''}',
      'name': '${e['name'] ?? 'Sin nombre'}',
      'ts': '${e['ts'] ?? ''}',
      'items': items
          .whereType<Map>()
          .map((m) => m.map((k, v) => MapEntry('$k', '$v')))
          .toList(),
    };
  }

  /// Normaliza un grupo leído del disco (claves que falten → defaults).
  static Map<String, dynamic> _sanearGrupo(Map<String, dynamic> e) {
    final ids = (e['ids'] as List?) ?? const [];
    return {
      'id': '${e['id'] ?? ''}',
      'name': '${e['name'] ?? 'Sin nombre'}',
      'ts': '${e['ts'] ?? ''}',
      'ids': ids.map((v) => '$v').toList(),
    };
  }

  // ===========================================================================
  // Historial
  // ===========================================================================

  /// Registra una reproducción (dedupe por uri, más reciente primero).
  Future<void> addHistory(String path, {String? title}) async {
    if (path.isEmpty) return;
    await load();
    _history.removeWhere((e) => e['uri'] == path);
    _history.insert(0, {
      'uri': path,
      'title': (title == null || title.isEmpty) ? _titleOf(path) : title,
      'ts': DateTime.now().millisecondsSinceEpoch.toString(),
    });
    while (_history.length > maxHistory) {
      _history.removeLast();
    }
    await _persist();
    _emit();
  }

  /// Registra VARIOS archivos de una vez (selector múltiple): el primero
  /// queda como más reciente. Un solo guardado en disco + un aviso.
  Future<void> addHistoryMany(List<String> paths) async {
    final validos = paths.where((p) => p.isNotEmpty).toList();
    if (validos.isEmpty) return;
    await load();
    for (final path in validos.reversed) {
      _history.removeWhere((e) => e['uri'] == path);
      _history.insert(0, {
        'uri': path,
        'title': _titleOf(path),
        'ts': DateTime.now().millisecondsSinceEpoch.toString(),
      });
    }
    while (_history.length > maxHistory) {
      _history.removeLast();
    }
    await _persist();
    _emit();
  }

  Future<void> removeHistory(String path) async {
    _history.removeWhere((e) => e['uri'] == path);
    await _persist();
    _emit();
  }

  Future<void> clearHistory() async {
    _history.clear();
    await _persist();
    _emit();
  }

  // ===========================================================================
  // Favoritos
  // ===========================================================================

  /// Agrega/quita de favoritos. Retorna true si quedó como favorito.
  Future<bool> toggleFavorite(String path, {String? title}) async {
    if (path.isEmpty) return false;
    await load();
    final idx = _favorites.indexWhere((e) => e['uri'] == path);
    if (idx >= 0) {
      _favorites.removeAt(idx);
      await _persist();
      _emit();
      return false;
    }
    _favorites.insert(0, {
      'uri': path,
      'title': (title == null || title.isEmpty) ? _titleOf(path) : title,
      'ts': DateTime.now().millisecondsSinceEpoch.toString(),
    });
    await _persist();
    _emit();
    return true;
  }

  Future<void> clearFavorites() async {
    _favorites.clear();
    await _persist();
    _emit();
  }

  // ===========================================================================
  // Listas (playlists)
  // ===========================================================================

  /// Crea una lista y retorna su id ('' si el nombre está vacío).
  Future<String> createPlaylist(String name) async {
    final n = name.trim();
    if (n.isEmpty) return '';
    await load();
    final id = _newId();
    _playlists.add({
      'id': id,
      'name': n,
      'ts': DateTime.now().millisecondsSinceEpoch.toString(),
      'items': <Map<String, String>>[],
    });
    await _persist();
    _emit();
    return id;
  }

  Future<void> renamePlaylist(String id, String name) async {
    final n = name.trim();
    if (n.isEmpty) return;
    final p = _buscar(_playlists, id);
    if (p == null) return;
    p['name'] = n;
    await _persist();
    _emit();
  }

  /// Borra la lista y la saca de los grupos que la contenían.
  Future<void> deletePlaylist(String id) async {
    _playlists.removeWhere((p) => p['id'] == id);
    for (final g in _groups) {
      (g['ids'] as List).removeWhere((v) => v == id);
    }
    await _persist();
    _emit();
  }

  Map<String, dynamic>? playlist(String id) => _buscar(_playlists, id);

  List<Map<String, String>> playlistItems(String id) {
    final p = _buscar(_playlists, id);
    if (p == null) return const [];
    final items = (p['items'] as List?) ?? const [];
    return items
        .whereType<Map>()
        .map((e) => e.map((k, v) => MapEntry('$k', '$v')))
        .toList();
  }

  List<String> playlistUris(String id) =>
      playlistItems(id).map((e) => e['uri'] ?? '').where((u) => u.isNotEmpty).toList();

  bool playlistHas(String id, String uri) =>
      playlistItems(id).any((e) => e['uri'] == uri);

  Future<void> playlistAdd(String id, String uri, {String? title}) async {
    if (uri.isEmpty) return;
    await load();
    final p = _buscar(_playlists, id);
    if (p == null) return;
    final items = (p['items'] as List);
    if (items.any((m) => m is Map && '${m['uri']}' == uri)) return;
    items.add({
      'uri': uri,
      'title': (title == null || title.isEmpty) ? _titleOf(uri) : title,
      'ts': DateTime.now().millisecondsSinceEpoch.toString(),
    });
    await _persist();
    _emit();
  }

  Future<void> playlistRemove(String id, String uri) async {
    final p = _buscar(_playlists, id);
    if (p == null) return;
    (p['items'] as List).removeWhere((m) => m is Map && '${m['uri']}' == uri);
    await _persist();
    _emit();
  }

  // ===========================================================================
  // Grupos (colecciones de listas)
  // ===========================================================================

  /// Crea un grupo y retorna su id ('' si el nombre está vacío).
  Future<String> createGroup(String name) async {
    final n = name.trim();
    if (n.isEmpty) return '';
    await load();
    final id = _newId();
    _groups.add({
      'id': id,
      'name': n,
      'ts': DateTime.now().millisecondsSinceEpoch.toString(),
      'ids': <String>[],
    });
    await _persist();
    _emit();
    return id;
  }

  Future<void> renameGroup(String id, String name) async {
    final n = name.trim();
    if (n.isEmpty) return;
    final g = _buscar(_groups, id);
    if (g == null) return;
    g['name'] = n;
    await _persist();
    _emit();
  }

  Future<void> deleteGroup(String id) async {
    _groups.removeWhere((g) => g['id'] == id);
    await _persist();
    _emit();
  }

  Map<String, dynamic>? group(String id) => _buscar(_groups, id);

  List<String> groupPlaylistIds(String id) {
    final g = _buscar(_groups, id);
    if (g == null) return const [];
    return ((g['ids'] as List?) ?? const []).map((v) => '$v').toList();
  }

  Future<void> groupAdd(String groupId, String playlistId) async {
    await load();
    final g = _buscar(_groups, groupId);
    if (g == null || _buscar(_playlists, playlistId) == null) return;
    final ids = (g['ids'] as List);
    if (!ids.contains(playlistId)) ids.add(playlistId);
    await _persist();
    _emit();
  }

  Future<void> groupRemove(String groupId, String playlistId) async {
    final g = _buscar(_groups, groupId);
    if (g == null) return;
    (g['ids'] as List).removeWhere((v) => v == playlistId);
    await _persist();
    _emit();
  }
}
