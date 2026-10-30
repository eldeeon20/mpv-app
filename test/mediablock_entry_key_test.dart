import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:pr_app/modo_sql/media_server/duro.dart';

void main() {
  test('derives an independent authenticated key for each preview entry',
      () async {
    final archivoKey = await Duro.claveArchivo(
      clave: 'molde-password',
      molde: 'ejemplo',
      nombre: 'video.mp4',
      salHex: Duro.nuevaSal(),
    );
    final previewKey = await Duro.claveEntrada(
      claveArchivo: archivoKey,
      nombreEntrada: '.prev/video.mp4#0',
    );
    final otherPreviewKey = await Duro.claveEntrada(
      claveArchivo: archivoKey,
      nombreEntrada: '.prev/video.mp4#1',
    );
    final clear = Uint8List.fromList(List.generate(4096, (i) => i & 0xff));

    expect(previewKey, isNot(equals(archivoKey)));
    expect(previewKey, isNot(equals(otherPreviewKey)));

    final package = await Duro.cifrarTrozo(
      claveArchivo: previewKey,
      indice: 0,
      claro: clear,
    );
    expect(
      await Duro.descifrarTrozo(
        claveArchivo: previewKey,
        indice: 0,
        paquete: package,
      ),
      equals(clear),
    );
    await expectLater(
      Duro.descifrarTrozo(
        claveArchivo: archivoKey,
        indice: 0,
        paquete: package,
      ),
      throwsA(isA<StateError>()),
    );
  });
}
