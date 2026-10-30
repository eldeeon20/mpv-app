import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

const int telegramMldPartBytes = 17 * 1000 * 1000;

class TelegramMldPart {
  final int offset;
  final int length;
  final int messageId;
  final String fileId;

  const TelegramMldPart({
    required this.offset,
    required this.length,
    required this.messageId,
    required this.fileId,
  });

  Map<String, Object> toJson() => {
        'offset': offset,
        'length': length,
        'message_id': messageId,
        'file_id': fileId,
      };

  factory TelegramMldPart.fromJson(Map<String, Object?> json) {
    final offset = json['offset'];
    final length = json['length'];
    final messageId = json['message_id'];
    final fileId = json['file_id'];
    if (offset is! int ||
        length is! int ||
        messageId is! int ||
        fileId is! String ||
        offset < 0 ||
        length <= 0 ||
        fileId.isEmpty) {
      throw const FormatException('Parte Telegram inválida');
    }
    return TelegramMldPart(
      offset: offset,
      length: length,
      messageId: messageId,
      fileId: fileId,
    );
  }
}

class TelegramMldManifest {
  final int size;
  final List<TelegramMldPart> parts;

  TelegramMldManifest(
      {required this.size, required List<TelegramMldPart> parts})
      : parts = List.unmodifiable(parts) {
    if (size <= 0 || parts.isEmpty) {
      throw const FormatException('Manifiesto Telegram vacío');
    }
    var cursor = 0;
    for (final part in parts) {
      if (part.offset != cursor || part.offset + part.length > size) {
        throw const FormatException('Partes Telegram incompletas o solapadas');
      }
      cursor += part.length;
    }
    if (cursor != size) {
      throw const FormatException('Manifiesto Telegram truncado');
    }
  }

  Map<String, Object> toJson() => {
        'version': 1,
        'size': size,
        'parts': parts.map((part) => part.toJson()).toList(),
      };

  String encode() => jsonEncode(toJson());

  factory TelegramMldManifest.decode(String value) {
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, dynamic> ||
        decoded['version'] != 1 ||
        decoded['size'] is! int ||
        decoded['parts'] is! List) {
      throw const FormatException('Manifiesto Telegram no reconocido');
    }
    final parts = <TelegramMldPart>[];
    for (final item in decoded['parts'] as List) {
      if (item is! Map<String, dynamic>) {
        throw const FormatException('Parte Telegram inválida');
      }
      parts.add(TelegramMldPart.fromJson(item));
    }
    return TelegramMldManifest(size: decoded['size'] as int, parts: parts);
  }
}

class TelegramUploadedFile {
  final String fileId;
  final int messageId;
  final int size;

  const TelegramUploadedFile({
    required this.fileId,
    required this.messageId,
    required this.size,
  });
}

/// Transporte Bot API para moldes ya cifrados. Cada parte queda por debajo
/// del límite de descarga de la Bot API y se lee/escribe temporalmente en disco.
class TelegramBotStorage {
  final http.Client _client;
  final Uri _apiBase;
  final int _partBytes;
  final Duration _timeout;

  TelegramBotStorage({
    http.Client? client,
    Uri? apiBase,
    int partBytes = telegramMldPartBytes,
    Duration timeout = const Duration(minutes: 5),
  })  : _client = client ?? http.Client(),
        _apiBase = apiBase ?? Uri(scheme: 'https', host: 'api.telegram.org'),
        _partBytes = partBytes,
        _timeout = timeout {
    if (partBytes <= 0 || partBytes >= 20 * 1000 * 1000) {
      throw ArgumentError.value(partBytes, 'partBytes',
          'debe ser menor al límite de descarga de 20 MB');
    }
  }

  Future<String> validarBot(String token) async {
    final result = await _call(token, 'getMe');
    final username = result['username'];
    if (username is! String || username.isEmpty) {
      throw const FormatException('Telegram no devolvió el usuario del bot');
    }
    return username;
  }

  Future<void> validarDestino({
    required String token,
    required String chatId,
  }) async {
    if (chatId.trim().isEmpty) {
      throw ArgumentError.value(chatId, 'chatId', 'no puede estar vacío');
    }
    await _call(token, 'getChat', {'chat_id': chatId.trim()});
  }

  Future<TelegramMldManifest> subirMolde({
    required String token,
    required String chatId,
    required String ruta,
    void Function(int subidos, int total)? progreso,
  }) async {
    if (chatId.trim().isEmpty) {
      throw ArgumentError.value(chatId, 'chatId', 'no puede estar vacío');
    }
    final file = File(ruta);
    final size = await file.length();
    if (size <= 0) throw StateError('El .mld está vacío');

    final parts = <TelegramMldPart>[];
    for (var offset = 0; offset < size; offset += _partBytes) {
      final length = (size - offset).clamp(0, _partBytes).toInt();
      final request = http.MultipartRequest(
        'POST',
        _apiUri(token, 'sendDocument'),
      )
        ..fields['chat_id'] = chatId.trim()
        ..files.add(http.MultipartFile(
          'document',
          file.openRead(offset, offset + length),
          length,
          filename: 'mediablock_${offset ~/ _partBytes}.mldpart',
        ));
      final response = await _client.send(request).timeout(_timeout);
      final result = await _readResult(response);
      final document = result['document'];
      final messageId = result['message_id'];
      if (document is! Map<String, dynamic> ||
          document['file_id'] is! String ||
          messageId is! int) {
        throw const FormatException('Telegram no confirmó el archivo subido');
      }
      final remoteSize = document['file_size'];
      if (remoteSize is int && remoteSize != length) {
        throw StateError(
            'Telegram guardó una parte incompleta ($remoteSize/$length)');
      }
      parts.add(TelegramMldPart(
        offset: offset,
        length: length,
        messageId: messageId,
        fileId: document['file_id'] as String,
      ));
      progreso?.call((offset + length).clamp(0, size).toInt(), size);
    }
    return TelegramMldManifest(size: size, parts: parts);
  }

  Future<TelegramUploadedFile> subirArchivo({
    required String token,
    required String chatId,
    required String ruta,
    required String nombre,
  }) async {
    final file = File(ruta);
    final size = await file.length();
    if (size <= 0 || size >= 20 * 1000 * 1000) {
      throw StateError(
          'El manifiesto debe pesar entre 1 byte y menos de 20 MB');
    }
    final request = http.MultipartRequest(
      'POST',
      _apiUri(token, 'sendDocument'),
    )
      ..fields['chat_id'] = chatId.trim()
      ..files.add(http.MultipartFile(
        'document',
        file.openRead(),
        size,
        filename: nombre,
      ));
    final response = await _client.send(request).timeout(_timeout);
    final result = await _readResult(response);
    final document = result['document'];
    final messageId = result['message_id'];
    if (document is! Map<String, dynamic> ||
        document['file_id'] is! String ||
        messageId is! int) {
      throw const FormatException('Telegram no confirmó el manifiesto');
    }
    final remoteSize = document['file_size'];
    if (remoteSize is int && remoteSize != size) {
      throw StateError('Telegram guardó un manifiesto incompleto');
    }
    return TelegramUploadedFile(
      fileId: document['file_id'] as String,
      messageId: messageId,
      size: size,
    );
  }

  Future<void> descargarArchivo({
    required String token,
    required String fileId,
    required File destination,
    int maxBytes = 20 * 1000 * 1000 - 1,
  }) async {
    final part = TelegramMldPart(
      offset: 0,
      length: 1,
      messageId: 0,
      fileId: fileId,
    );
    final result = await _call(token, 'getFile', {'file_id': part.fileId});
    final filePath = result['file_path'];
    final fileSize = result['file_size'];
    if (filePath is! String || filePath.isEmpty || fileSize is! int) {
      throw const FormatException(
          'Telegram no devolvió los datos del manifiesto');
    }
    if (fileSize <= 0 || fileSize > maxBytes) {
      throw StateError('Manifiesto remoto excede el tamaño permitido');
    }
    await _descargarEnDisco(token, filePath, destination, fileSize);
  }

  Future<Uint8List> leerRango({
    required String token,
    required TelegramMldManifest manifest,
    required int start,
    required int length,
  }) async {
    if (start < 0 || length <= 0 || start + length > manifest.size) {
      throw RangeError('Rango Telegram fuera del molde');
    }
    final output = BytesBuilder(copy: false);
    final end = start + length;
    for (final part in manifest.parts) {
      final partEnd = part.offset + part.length;
      if (part.offset >= end || partEnd <= start) continue;

      final tempDir = await Directory.systemTemp.createTemp('mpv_tg_range_');
      final temp =
          File('${tempDir.path}${Platform.pathSeparator}${part.offset}.part');
      try {
        await _descargarParte(token, part, temp);
        final localStart = (start - part.offset).clamp(0, part.length).toInt();
        final localEnd = (end - part.offset).clamp(0, part.length).toInt();
        final handle = await temp.open(mode: FileMode.read);
        try {
          await handle.setPosition(localStart);
          final bytes = await handle.read(localEnd - localStart);
          if (bytes.length != localEnd - localStart) {
            throw StateError('Parte Telegram incompleta en disco');
          }
          output.add(bytes);
        } finally {
          await handle.close();
        }
      } finally {
        await tempDir.delete(recursive: true);
      }
    }
    final bytes = output.takeBytes();
    if (bytes.length != length) {
      throw StateError('Telegram devolvió un rango incompleto '
          '(${bytes.length}/$length bytes)');
    }
    return bytes;
  }

  Future<void> borrarMensajes({
    required String token,
    required String chatId,
    required Iterable<int> messageIds,
  }) async {
    final ids = messageIds.toList(growable: false);
    if (ids.isEmpty) return;
    await _call(token, 'deleteMessages', {
      'chat_id': chatId,
      'message_ids': jsonEncode(ids),
    });
  }

  Future<void> _descargarParte(
      String token, TelegramMldPart part, File destination) async {
    final result = await _call(token, 'getFile', {'file_id': part.fileId});
    final filePath = result['file_path'];
    final fileSize = result['file_size'];
    if (filePath is! String || filePath.isEmpty) {
      throw const FormatException('Telegram no devolvió la ruta de descarga');
    }
    if (fileSize is int && fileSize != part.length) {
      throw StateError('Tamaño remoto inesperado ($fileSize/${part.length})');
    }
    await _descargarEnDisco(token, filePath, destination, part.length);
  }

  Future<void> _descargarEnDisco(
      String token, String filePath, File destination, int expectedSize) async {
    final uri = _fileUri(token, filePath);
    final response =
        await _client.send(http.Request('GET', uri)).timeout(_timeout);
    if (response.statusCode != 200) {
      throw HttpException(
          'Telegram falló al descargar una parte (${response.statusCode})');
    }
    final sink = destination.openWrite();
    try {
      await response.stream.pipe(sink).timeout(_timeout);
    } finally {
      await sink.close();
    }
    final downloaded = await destination.length();
    if (downloaded != expectedSize) {
      throw StateError('Descarga Telegram truncada '
          '($downloaded/$expectedSize)');
    }
  }

  Future<Map<String, dynamic>> _call(String token, String method,
      [Map<String, String> fields = const {}]) async {
    final request = http.Request('POST', _apiUri(token, method))
      ..bodyFields = fields;
    final response = await _client.send(request).timeout(_timeout);
    return _readResult(response);
  }

  Future<Map<String, dynamic>> _readResult(
      http.StreamedResponse response) async {
    final body = await response.stream.bytesToString();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('Telegram respondió HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic> || decoded['ok'] != true) {
      final description = decoded is Map ? decoded['description'] : null;
      throw HttpException('Telegram rechazó la operación'
          '${description is String ? ': $description' : ''}');
    }
    final result = decoded['result'];
    if (result is! Map<String, dynamic>) {
      throw const FormatException('Respuesta Telegram sin resultado');
    }
    return result;
  }

  Uri _apiUri(String token, String method) => _apiBase.replace(
      path: '${_apiBase.path}/bot${_validarToken(token)}/$method');

  Uri _fileUri(String token, String filePath) => _apiBase.replace(
        path: '${_apiBase.path}/file/bot${_validarToken(token)}/$filePath',
      );

  String _validarToken(String token) {
    final value = token.trim();
    if (!RegExp(r'^\d+:[A-Za-z0-9_-]+$').hasMatch(value)) {
      throw ArgumentError.value(token, 'token', 'token de Bot API inválido');
    }
    return value;
  }

  void close() => _client.close();
}
