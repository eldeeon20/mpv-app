import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../src/rust/api/hf.dart' as rust;

/// Cliente HuggingFace — porte del `hf_godot` de Gtool.
///
/// Buscar modelos, subir/bajar archivos (con token write para upload),
/// crear/borrar repos y leer RANGOS de archivos grandes sin bajar todo.
class HuggingFace {
  rust.HfClient? _client;

  bool get ready => _client != null;

  /// Inicializa con token (vacío = anónimo, solo lectura pública).
  Future<void> init(String token) async {
    _client = await rust.hfClientNew(token: token);
  }

  /// SHA-256 hex de un archivo local (streaming en Rust).
  /// Los uploads a HF se nombran SOLO con el hash (se comprueba).
  static Future<String> sha256Archivo(String ruta) {
    return rust.sha256Archivo(ruta: ruta);
  }

  /// Busca modelos de un autor → ids "autor/modelo".
  Future<List<String>> searchModels(
      {required String author, int limit = 10}) async {
    return _require().searchModels(author: author, limit: limit);
  }

  /// Caché escribible para Xet (uploads/descargas hf-hub). En Android
  /// HOME no existe y sin esto Xet intenta "/" → Read-only (os error 30).
  Future<String> _cacheDir() async {
    final d = await getApplicationSupportDirectory();
    return '${d.path}/xet_cache';
  }

  /// Descarga un archivo del repo a [localDir]; retorna el path final.
  Future<String> downloadFile({
    required String repoId,
    required String filename,
    required String localDir,
    String repoType = 'model',
  }) async {
    return _require().downloadFile(
      repoId: repoId,
      filename: filename,
      localDir: localDir,
      repoType: repoType,
      cacheDir: await _cacheDir(),
    );
  }

  /// Sube un archivo local al repo (requiere token con permiso write).
  Future<void> uploadFile({
    required String repoId,
    required String localFilePath,
    required String pathInRepo,
    String commitMessage = 'upload desde pr_app',
    String repoType = 'model',
  }) async {
    await _require().uploadFile(
      repoId: repoId,
      localFilePath: localFilePath,
      pathInRepo: pathInRepo,
      commitMessage: commitMessage,
      repoType: repoType,
      cacheDir: await _cacheDir(),
    );
  }

  Future<void> deleteFile({
    required String repoId,
    required String pathInRepo,
    String repoType = 'model',
  }) async {
    await _require().deleteFile(
      repoId: repoId,
      pathInRepo: pathInRepo,
      repoType: repoType,
    );
  }

  Future<void> createRepository({
    required String repoId,
    String repoType = 'model',
    bool private = true,
  }) async {
    await _require().createRepository(
      repoId: repoId,
      repoType: repoType,
      private: private,
    );
  }

  Future<void> deleteRepository({
    required String repoId,
    String repoType = 'model',
  }) async {
    await _require().deleteRepository(repoId: repoId, repoType: repoType);
  }

  Future<bool> repoExists({required String repoId, String repoType = 'model'}) =>
      _require().repoExists(repoId: repoId, repoType: repoType);

  Future<bool> fileExists({
    required String repoId,
    required String filename,
    String repoType = 'model',
  }) =>
      _require().fileExists(
        repoId: repoId,
        filename: filename,
        repoType: repoType,
      );

  /// Lista archivos del repo.
  Future<List<String>> listRepoFiles({
    required String repoId,
    bool recursive = false,
    String repoType = 'model',
  }) {
    return _require().listRepoFiles(
      repoId: repoId,
      recursive: recursive,
      repoType: repoType,
    );
  }

  /// Baja un RANGO de bytes de un checkpoint grande SIN cliente ni login
  /// (token opcional). Ej: primeros 64KB para inspeccionar un header.
  static Future<Uint8List> downloadFileRange({
    required String repoId,
    required String filename,
    required int start,
    required int end,
    String token = '',
    String repoType = 'model',
  }) async {
    final bytes = await rust.hfDownloadFileRange(
      repoId: repoId,
      filename: filename,
      start: start,
      end: end,
      token: token,
      repoType: repoType,
    );
    return Uint8List.fromList(bytes);
  }

  void dispose() => _client = null;

  rust.HfClient _require() {
    final c = _client;
    if (c == null) throw StateError('HuggingFace sin inicializar (llamá init)');
    return c;
  }
}
