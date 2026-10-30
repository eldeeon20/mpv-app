import 'dart:convert';
import 'dart:typed_data';

import '../src/rust/api/unarc.dart' as rust;

/// Unarc: extracción universal de archives (7z/ZIP/RAR5/tar/gz/arj/lha/zoo…)
/// vía unarc-rs. Port del Unarc de Gtool sin Godot.
///
/// Las funciones reciben [List<String> paths]: una o VARIAS partes
/// (.7z.001 + .002 + …). El file_picker de Android copia suelto al cache,
/// así que para multivolumen hay que elegir las partes juntas.
class Unarc {
  /// true si la extensión del archivo es soportada.
  Future<bool> soportado(List<String> paths) =>
      rust.unarcSoportado(pathsCsv: _csv(paths));

  /// Nombre legible del formato ('7-Zip', 'RAR', 'ZIP'…) o '' si no detecta.
  Future<String> formato(List<String> paths) =>
      rust.unarcFormato(pathsCsv: _csv(paths));

  /// Partes resueltas: {"total":N,"nombres":[...]}.
  Future<UnarcPartes> volumenes(List<String> paths) async {
    final raw = await rust.unarcVolumenes(pathsCsv: _csv(paths));
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return UnarcPartes(
      total: (m['total'] as num).toInt(),
      nombres: [
        for (final n in (m['nombres'] as List<dynamic>)) n as String,
      ],
    );
  }

  /// true si alguna entrada pide password (o el archive no abre sin ella).
  Future<bool> encriptado(List<String> paths) =>
      rust.unarcEncriptado(pathsCsv: _csv(paths));

  /// Lista de entradas (nombre, tamaño, dir, cifrado).
  Future<List<UnarcEntry>> listar(
    List<String> paths, {
    String password = '',
  }) async {
    final raw =
        await rust.unarcListar(pathsCsv: _csv(paths), password: password);
    final lista = jsonDecode(raw) as List<dynamic>;
    return [
      for (final e in lista)
        UnarcEntry(
          name: e['name'] as String,
          size: (e['size'] as num).toInt(),
          isDir: e['isDir'] as bool,
          encrypted: e['encrypted'] as bool,
        ),
    ];
  }

  /// Extrae todo el archive a [destDir]; devuelve archivos extraídos y bytes.
  Future<UnarcResumen> extraerTodo(
    List<String> paths,
    String destDir, {
    String password = '',
  }) async {
    final raw = await rust.unarcExtraerTodo(
      pathsCsv: _csv(paths),
      outputDir: destDir,
      password: password,
    );
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return UnarcResumen(
      files: (m['files'] as num).toInt(),
      bytes: (m['bytes'] as num).toInt(),
      partes: (m['partes'] as num?)?.toInt() ?? 1,
    );
  }

  /// Extrae UNA entrada al archivo [destPath]. Devuelve bytes escritos.
  Future<int> extraerEntrada(
    List<String> paths,
    String entryName,
    String destPath, {
    String password = '',
  }) async {
    final raw = await rust.unarcExtraerEntrada(
      pathsCsv: _csv(paths),
      entryName: entryName,
      destPath: destPath,
      password: password,
    );
    return ((jsonDecode(raw) as Map<String, dynamic>)['bytes'] as num).toInt();
  }

  /// Lee una entrada a memoria (preview), cortada a [maxBytes].
  Future<Uint8List> leerEntrada(
    List<String> paths,
    String entryName, {
    String password = '',
    int maxBytes = 8 * 1024 * 1024,
  }) {
    return rust.unarcLeerEntrada(
      pathsCsv: _csv(paths),
      entryName: entryName,
      password: password,
      maxBytes: maxBytes,
    );
  }

  static String _csv(List<String> paths) => paths.join('\n');
}

class UnarcPartes {
  final int total;
  final List<String> nombres;
  const UnarcPartes({required this.total, required this.nombres});
}

class UnarcEntry {
  final String name;
  final int size;
  final bool isDir;
  final bool encrypted;
  const UnarcEntry({
    required this.name,
    required this.size,
    required this.isDir,
    required this.encrypted,
  });
}

class UnarcResumen {
  final int files;
  final int bytes;
  final int partes;
  const UnarcResumen({
    required this.files,
    required this.bytes,
    this.partes = 1,
  });
}
