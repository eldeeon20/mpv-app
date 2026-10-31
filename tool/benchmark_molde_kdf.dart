import 'dart:io';

import 'package:pr_app/modo_sql/media_server/claves_molde_v3.dart';
import 'package:pr_app/modo_sql/media_server/duro.dart';

Future<void> main(List<String> args) async {
  final fileCount = args.isEmpty ? 64 : int.tryParse(args.first);
  if (fileCount == null || fileCount <= 0 || fileCount > 10000) {
    throw ArgumentError(
        'Uso: dart run tool/benchmark_molde_kdf.dart [1..10000]');
  }

  final password = 'benchmark-only password';
  const mold = 'benchmark';
  final salt = Duro.nuevaSal();
  var checksum = 0;

  final startedV2 = DateTime.now();
  final timerV2 = Stopwatch()..start();
  for (var i = 0; i < fileCount; i++) {
    final key = await Duro.claveArchivoHilo(
      clave: password,
      molde: mold,
      nombre: 'file-$i.bin',
      salHex: salt,
    );
    checksum ^= key.first;
  }
  timerV2.stop();

  final startedV3 = DateTime.now();
  final timerV3 = Stopwatch()..start();
  final master = await ClavesMoldeV3.derivarMaestra(
    clave: password,
    salHex: salt,
  );
  for (var i = 0; i < fileCount; i++) {
    final key = await ClavesMoldeV3.derivarArchivo(
      claveMaestra: master,
      molde: mold,
      nombre: 'file-$i.bin',
      salHex: salt,
    );
    checksum ^= key.first;
  }
  timerV3.stop();

  stdout.writeln('started_v2=${startedV2.toIso8601String()}');
  stdout.writeln(
      'mode_v2_files=$fileCount elapsed_ms=${timerV2.elapsedMilliseconds}');
  stdout.writeln('started_v3=${startedV3.toIso8601String()}');
  stdout.writeln(
      'mode_v3_files=$fileCount elapsed_ms=${timerV3.elapsedMilliseconds}');
  stdout.writeln(
    'v3_vs_v2=${timerV2.elapsedMicroseconds / timerV3.elapsedMicroseconds}x '
    '(KDF only; excludes file encryption, previews, and disk I/O)',
  );
  stdout.writeln('checksum=$checksum');
}
