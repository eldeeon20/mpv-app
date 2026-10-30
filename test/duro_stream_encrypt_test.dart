import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pr_app/modo_sql/media_server/duro.dart';

void main() {
  test('encrypts source chunks directly to disk and preserves bytes', () async {
    final directory = await Directory.systemTemp.createTemp('duro_stream_');
    addTearDown(() => directory.delete(recursive: true));

    const chunkSize = 16 * 1024;
    final sourceBytes = Uint8List.fromList(
      List<int>.generate(100000, (index) => index % 251),
    );
    final source = File('${directory.path}/source.bin');
    final destination = File('${directory.path}/encrypted.mld');
    await source.writeAsBytes(sourceBytes, flush: true);
    await destination.create();
    final key = Uint8List.fromList(List<int>.generate(32, (index) => index));

    final processed = await Duro.cifrarArchivoADiscoHilo(
      claveArchivo: key,
      trozoClaro: chunkSize,
      origen: source.path,
      destino: destination.path,
      tamanoEsperado: sourceBytes.length,
    );

    expect(processed, sourceBytes.length);
    final expectedChunks = (sourceBytes.length + chunkSize - 1) ~/ chunkSize;
    expect(
      await destination.length(),
      sourceBytes.length + expectedChunks * Duro.overhead,
    );

    final file = destination.openSync(mode: FileMode.read);
    try {
      var sourceOffset = 0;
      var chunkIndex = 0;
      while (sourceOffset < sourceBytes.length) {
        final clearLength = min(chunkSize, sourceBytes.length - sourceOffset);
        final packet = file.readSync(clearLength + Duro.overhead);
        final clear = await Duro.descifrarTrozo(
          claveArchivo: key,
          indice: chunkIndex,
          paquete: Uint8List.fromList(packet),
        );
        expect(
          clear,
          sourceBytes.sublist(sourceOffset, sourceOffset + clearLength),
        );
        sourceOffset += clearLength;
        chunkIndex++;
      }
    } finally {
      file.closeSync();
    }
  });

  test('rejects using the source as the encryption destination', () async {
    final directory = await Directory.systemTemp.createTemp('duro_stream_');
    addTearDown(() => directory.delete(recursive: true));

    final source = File('${directory.path}/source.bin');
    await source.writeAsBytes([1, 2, 3], flush: true);

    expect(
      () => Duro.cifrarArchivoADiscoHilo(
        claveArchivo: Uint8List(32),
        trozoClaro: Duro.trozoClaro,
        origen: source.path,
        destino: source.path,
        tamanoEsperado: 3,
      ),
      throwsArgumentError,
    );
    expect(await source.readAsBytes(), [1, 2, 3]);
  });
}
