import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pr_app/services/telegram_bot_storage.dart';
import 'package:pr_app/services/telegram_mld_manifest_store.dart';

void main() {
  test('stores the Bot API manifest in an encrypted SQLite file', () async {
    final directory = await Directory.systemTemp.createTemp('manifest_test_');
    addTearDown(() => directory.delete(recursive: true));
    final source = TelegramMldManifest(
      size: 12,
      parts: const [
        TelegramMldPart(
          offset: 0,
          length: 8,
          messageId: 31,
          fileId: 'file-one',
        ),
        TelegramMldPart(
          offset: 8,
          length: 4,
          messageId: 32,
          fileId: 'file-two',
        ),
      ],
    );

    final file = await TelegramMldManifestStore.crear(
      nombre: 'drive_test',
      clave: 'mold-secret',
      manifest: source,
      directory: directory,
    );
    final header = await file.open(mode: FileMode.read);
    final prefix = await header.read(16);
    await header.close();
    expect(String.fromCharCodes(prefix), isNot(startsWith('SQLite format 3')));

    final restored = await TelegramMldManifestStore.leer(
      ruta: file.path,
      clave: 'mold-secret',
    );
    expect(restored.size, 12);
    expect(restored.parts.map((part) => part.fileId), ['file-one', 'file-two']);
    await expectLater(
      TelegramMldManifestStore.leer(ruta: file.path, clave: 'wrong-secret'),
      throwsA(isA<StateError>()),
    );
  });
}
