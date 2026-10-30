import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pr_app/services/telegram_bot_storage.dart';

void main() {
  group('TelegramMldManifest', () {
    test('round trips a contiguous manifest', () {
      final manifest = TelegramMldManifest(
        size: 8,
        parts: const [
          TelegramMldPart(
            offset: 0,
            length: 4,
            messageId: 10,
            fileId: 'first',
          ),
          TelegramMldPart(
            offset: 4,
            length: 4,
            messageId: 11,
            fileId: 'second',
          ),
        ],
      );

      final decoded = TelegramMldManifest.decode(manifest.encode());

      expect(decoded.size, 8);
      expect(decoded.parts.map((part) => part.fileId), ['first', 'second']);
    });

    test('rejects gaps and overlaps', () {
      expect(
        () => TelegramMldManifest(
          size: 8,
          parts: const [
            TelegramMldPart(
              offset: 1,
              length: 4,
              messageId: 10,
              fileId: 'first',
            ),
            TelegramMldPart(
              offset: 5,
              length: 3,
              messageId: 11,
              fileId: 'second',
            ),
          ],
        ),
        throwsFormatException,
      );
    });
  });

  test('reads a requested range across Telegram parts', () async {
    final service = TelegramBotStorage(
      client: _TelegramClient(),
      apiBase: Uri(scheme: 'https', host: 'telegram.test'),
      partBytes: 4,
    );
    addTearDown(service.close);
    final manifest = TelegramMldManifest(
      size: 8,
      parts: const [
        TelegramMldPart(
          offset: 0,
          length: 4,
          messageId: 10,
          fileId: 'first',
        ),
        TelegramMldPart(
          offset: 4,
          length: 4,
          messageId: 11,
          fileId: 'second',
        ),
      ],
    );

    final bytes = await service.leerRango(
      token: '123:abc',
      manifest: manifest,
      start: 2,
      length: 4,
    );

    expect(bytes, [2, 3, 4, 5]);
  });
}

class _TelegramClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path.endsWith('/getFile')) {
      final fileId = (request as http.Request).bodyFields['file_id'];
      final path = switch (fileId) {
        'first' => 'first.part',
        'second' => 'second.part',
        _ => throw StateError('unexpected file id: $fileId'),
      };
      return _jsonResponse({
        'ok': true,
        'result': {'file_path': path, 'file_size': 4},
      });
    }

    if (request.url.path.endsWith('/first.part')) {
      return http.StreamedResponse(Stream.value([0, 1, 2, 3]), 200);
    }
    if (request.url.path.endsWith('/second.part')) {
      return http.StreamedResponse(Stream.value([4, 5, 6, 7]), 200);
    }
    throw StateError('unexpected request: ${request.method} ${request.url}');
  }

  http.StreamedResponse _jsonResponse(Map<String, Object> value) {
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(value))),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}
