import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pr_app/modo_sql/media_server/claves_molde_v3.dart';
import 'package:pr_app/modo_sql/media_server/duro.dart';

void main() {
  test('v3 derives stable, distinct per-file keys and authenticates blocks',
      () async {
    final salt = Duro.nuevaSal();
    final master = await ClavesMoldeV3.derivarMaestra(
      clave: 'una clave de prueba suficientemente larga',
      salHex: salt,
    );
    final first = await ClavesMoldeV3.derivarArchivo(
      claveMaestra: master,
      molde: 'molde',
      nombre: 'uno.bin',
      salHex: salt,
    );
    final same = await ClavesMoldeV3.derivarArchivo(
      claveMaestra: master,
      molde: 'molde',
      nombre: 'uno.bin',
      salHex: salt,
    );
    final other = await ClavesMoldeV3.derivarArchivo(
      claveMaestra: master,
      molde: 'molde',
      nombre: 'dos.bin',
      salHex: salt,
    );
    final delimiterCollision = await ClavesMoldeV3.derivarArchivo(
      claveMaestra: master,
      molde: 'a|b',
      nombre: 'c',
      salHex: salt,
    );
    final distinctPath = await ClavesMoldeV3.derivarArchivo(
      claveMaestra: master,
      molde: 'a',
      nombre: 'b|c',
      salHex: salt,
    );
    expect(same, first);
    expect(other, isNot(first));
    expect(delimiterCollision, isNot(distinctPath));

    final clear = Uint8List.fromList(List<int>.generate(4096, (i) => i % 251));
    final packet = await Duro.cifrarTrozo(
      claveArchivo: first,
      indice: 0,
      claro: clear,
    );
    expect(
      await Duro.descifrarTrozo(
        claveArchivo: first,
        indice: 0,
        paquete: packet,
      ),
      clear,
    );
    packet[packet.length - 1] ^= 1;
    await expectLater(
      Duro.descifrarTrozo(
        claveArchivo: first,
        indice: 0,
        paquete: packet,
      ),
      throwsStateError,
    );
  });
}
