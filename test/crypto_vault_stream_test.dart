import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pr_app/services/crypto_vault.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('prbx_stream_test_');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('streams existing PRBX v1 envelopes to disk', () async {
    const passphrase = 'test-passphrase';
    final plain = Uint8List.fromList(List.generate(8193, (i) => i & 0xff));
    final encrypted = await CryptoVault.encrypt(plain, passphrase);
    final input = File('${tempDir.path}/existing.prbx');
    final output = File('${tempDir.path}/clear.bin');
    await input.writeAsBytes(encrypted);

    await CryptoVault.decryptFile(
      inputPath: input.path,
      outputPath: output.path,
      passphrase: passphrase,
    );

    expect(await output.readAsBytes(), equals(plain));
  });

  test('streams encryption in the compatible PRBX v1 format', () async {
    const passphrase = 'test-passphrase';
    final input = File('${tempDir.path}/clear.bin');
    final encrypted = File('${tempDir.path}/streamed.prbx');
    final plain =
        Uint8List.fromList(List.generate(15001, (i) => (i * 13) & 0xff));
    await input.writeAsBytes(plain);

    await CryptoVault.encryptFile(
      inputPath: input.path,
      outputPath: encrypted.path,
      passphrase: passphrase,
    );

    final decoded = await CryptoVault.decrypt(
      await encrypted.readAsBytes(),
      passphrase,
    );
    expect(decoded, equals(plain));
  });

  test('does not publish plaintext when PRBX authentication fails', () async {
    final encrypted = await CryptoVault.encrypt(Uint8List(0), 'correct-pass');
    encrypted[encrypted.length - 1] ^= 1;
    final input = File('${tempDir.path}/damaged.prbx');
    final output = File('${tempDir.path}/must-not-exist.bin');
    await input.writeAsBytes(encrypted);

    await expectLater(
      CryptoVault.decryptFile(
        inputPath: input.path,
        outputPath: output.path,
        passphrase: 'correct-pass',
      ),
      throwsA(isA<FormatException>()),
    );

    expect(await output.exists(), isFalse);
    expect(await tempDir.list().length, 1);
  });

  test('keeps memory use bounded for multi-chunk files', () async {
    const passphrase = 'test-passphrase';
    const totalBytes = 3 * 1024 * 1024 + 97;
    final input = File('${tempDir.path}/large-clear.bin');
    final encrypted = File('${tempDir.path}/large.prbx');
    final output = File('${tempDir.path}/large-decoded.bin');

    final source = input.openSync(mode: FileMode.write);
    try {
      for (var offset = 0; offset < totalBytes; offset += 64 * 1024) {
        final count =
            (totalBytes - offset) < 64 * 1024 ? totalBytes - offset : 64 * 1024;
        source.writeFromSync(
          Uint8List.fromList([
            for (var i = 0; i < count; i++) ((offset + i) * 31 + 7) & 0xff,
          ]),
        );
      }
    } finally {
      source.closeSync();
    }

    await CryptoVault.encryptFile(
      inputPath: input.path,
      outputPath: encrypted.path,
      passphrase: passphrase,
    );
    await CryptoVault.decryptFile(
      inputPath: encrypted.path,
      outputPath: output.path,
      passphrase: passphrase,
    );

    expect(await output.length(), totalBytes);
    final decoded = output.openSync(mode: FileMode.read);
    try {
      var offset = 0;
      while (offset < totalBytes) {
        final expectedLength =
            (totalBytes - offset) < 64 * 1024 ? totalBytes - offset : 64 * 1024;
        final actual = decoded.readSync(expectedLength);
        expect(actual, hasLength(expectedLength));
        final expected = Uint8List.fromList([
          for (var i = 0; i < expectedLength; i++)
            ((offset + i) * 31 + 7) & 0xff,
        ]);
        expect(actual, equals(expected));
        offset += actual.length;
      }
    } finally {
      decoded.closeSync();
    }
  });
}
