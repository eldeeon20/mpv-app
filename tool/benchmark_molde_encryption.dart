import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pr_app/modo_sql/media_server/claves_molde_v3.dart';
import 'package:pr_app/modo_sql/media_server/duro.dart';

Future<void> main(List<String> args) async {
  final fileCount = args.isEmpty ? 16 : int.tryParse(args[0]);
  final sizeMiB = args.length < 2 ? 1 : int.tryParse(args[1]);
  if (fileCount == null ||
      sizeMiB == null ||
      fileCount <= 0 ||
      fileCount > 10000 ||
      sizeMiB <= 0 ||
      sizeMiB > 1024) {
    throw ArgumentError(
      'Uso: dart run tool/benchmark_molde_encryption.dart [archivos] [MiB-por-archivo]',
    );
  }

  final root = await Directory.systemTemp.createTemp('mpv_mld_benchmark_');
  try {
    final inputs = Directory('${root.path}${Platform.pathSeparator}inputs');
    await inputs.create();
    final salt = Duro.nuevaSal();
    for (var i = 0; i < fileCount; i++) {
      await _writeInput(
        File('${inputs.path}${Platform.pathSeparator}file-$i.bin'),
        sizeMiB * 1024 * 1024,
        seed: i,
      );
    }

    final totalBytes = fileCount * sizeMiB * 1024 * 1024;
    final v2 = await _encryptMode(
      root: root,
      inputs: inputs,
      fileCount: fileCount,
      sizeMiB: sizeMiB,
      salt: salt,
      mode: 'v2',
    );
    final v3 = await _encryptMode(
      root: root,
      inputs: inputs,
      fileCount: fileCount,
      sizeMiB: sizeMiB,
      salt: salt,
      mode: 'v3',
    );

    stdout.writeln('files=$fileCount MiB_per_file=$sizeMiB '
        'total_MiB=${totalBytes ~/ (1024 * 1024)}');
    stdout.writeln('mode_v2_elapsed_ms=${v2.elapsedMilliseconds}');
    stdout.writeln('mode_v3_elapsed_ms=${v3.elapsedMilliseconds}');
    stdout.writeln(
      'v3_vs_v2=${v2.elapsedMicroseconds / v3.elapsedMicroseconds}x '
      '(includes KDF, AES-GCM, isolates, and disk I/O; excludes previews and SQL)',
    );
  } finally {
    await root.delete(recursive: true);
  }
}

Future<Stopwatch> _encryptMode({
  required Directory root,
  required Directory inputs,
  required int fileCount,
  required int sizeMiB,
  required String salt,
  required String mode,
}) async {
  final output = File(
    '${root.path}${Platform.pathSeparator}$mode.mld',
  );
  await output.create();
  final watch = Stopwatch()..start();
  final master = mode == 'v3'
      ? await ClavesMoldeV3.derivarMaestra(
          clave: 'benchmark-only password',
          salHex: salt,
        )
      : null;

  for (var i = 0; i < fileCount; i++) {
    final name = 'file-$i.bin';
    final source = File('${inputs.path}${Platform.pathSeparator}$name');
    final key = master == null
        ? await Duro.claveArchivoHilo(
            clave: 'benchmark-only password',
            molde: 'benchmark',
            nombre: name,
            salHex: salt,
          )
        : await ClavesMoldeV3.derivarArchivo(
            claveMaestra: master,
            molde: 'benchmark',
            nombre: name,
            salHex: salt,
          );
    await Duro.cifrarArchivoADiscoHilo(
      claveArchivo: key,
      trozoClaro: Duro.trozoClaro,
      origen: source.path,
      destino: output.path,
      tamanoEsperado: sizeMiB * 1024 * 1024,
    );
  }
  watch.stop();
  return watch;
}

Future<void> _writeInput(
  File file,
  int length, {
  required int seed,
}) async {
  final random = Random(seed);
  final sink = file.openWrite();
  var remaining = length;
  try {
    while (remaining > 0) {
      final chunkLength = min(64 * 1024, remaining);
      final chunk = Uint8List.fromList(
        List<int>.generate(chunkLength, (_) => random.nextInt(256)),
      );
      sink.add(chunk);
      remaining -= chunkLength;
    }
  } finally {
    await sink.close();
  }
}
