import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:handy_tdlib/handy_tdlib.dart' as td;
import 'package:path_provider/path_provider.dart';
import 'package:cryptography/cryptography.dart';

enum TelegramUserAuthStep {
  disconnected,
  waitingPhone,
  waitingCode,
  waitingPassword,
  ready,
  error,
}

class TelegramUserAuth {
  final TelegramUserAuthStep step;
  final String? error;

  const TelegramUserAuth(this.step, {this.error});
}

class _TelegramTdlibInit {
  final SendPort mainPort;
  final String libraryPath;

  const _TelegramTdlibInit(this.mainPort, this.libraryPath);
}

void _telegramTdlibReceiveLoop(_TelegramTdlibInit init) async {
  final commands = ReceivePort();
  var running = true;
  commands.listen((message) {
    if (message == 'stop') {
      running = false;
    } else if (message is Map<String, Object?>) {
      final clientId = message['client_id'];
      final request = message['request'];
      if (clientId is int && request is String) {
        td.TdPlugin.instance.tdSend(clientId, request);
      }
    }
  });
  try {
    await td.TdPlugin.initialize(init.libraryPath);
    final clientId = td.TdPlugin.instance.tdCreateClientId();
    init.mainPort.send({'ready': clientId, 'commands': commands.sendPort});
    while (running) {
      final result = td.TdPlugin.instance.tdReceive(0.5);
      if (result != null) init.mainPort.send(result);
      await Future<void>.delayed(Duration.zero);
    }
  } catch (e) {
    init.mainPort.send({'error': '$e'});
  } finally {
    commands.close();
  }
}

/// TDLib account bridge based on NovaDrive's TDLib flow. Supported by the
/// handy_tdlib package on Android; file content is sent without re-encryption.
class TelegramUserAccount {
  final StreamController<TelegramUserAuth> _auth =
      StreamController<TelegramUserAuth>.broadcast();
  final Map<String, Completer<Map<String, dynamic>>> _requests = {};
  final Map<int, Completer<void>> _messageAcks = {};
  final Set<int> _completedMessages = {};
  final ReceivePort _receivePort = ReceivePort();
  Isolate? _isolate;
  SendPort? _commandPort;
  int? _clientId;
  int _requestId = 0;
  String _apiId = '';
  String _apiHash = '';
  String _databaseKey = '';
  String? _savedMessagesChatId;
  bool _parametersSent = false;
  bool _resolvingSavedMessages = false;

  Stream<TelegramUserAuth> get authChanges => _auth.stream;
  bool get isReady => _savedMessagesChatId != null;

  Future<void> iniciar({
    required String apiId,
    required String apiHash,
    required String databaseKey,
  }) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError(
        'TDLib personal está disponible en Android en esta compilación.',
      );
    }
    final id = int.tryParse(apiId);
    if (id == null || id <= 0 || apiHash.trim().isEmpty) {
      throw ArgumentError('API ID / API Hash de Telegram inválidos');
    }
    if (databaseKey.isEmpty) {
      throw ArgumentError('Falta la llave cifrada de la base TDLib');
    }
    if (_clientId != null) return;
    _apiId = '$id';
    _apiHash = apiHash.trim();
    _databaseKey = databaseKey;

    await td.TdPlugin.initialize('libtdjson.so');
    final ready = Completer<void>();
    _receivePort.listen((message) {
      if (message is Map && message['ready'] is int) {
        _clientId = message['ready'] as int;
        _commandPort = message['commands'] as SendPort;
        if (!ready.isCompleted) ready.complete();
      } else if (message is Map && message['error'] is String) {
        if (!ready.isCompleted) {
          ready.completeError(StateError('${message['error']}'));
        }
      } else if (message is String) {
        _onUpdate(message);
      }
    });
    final support = await getApplicationSupportDirectory();
    final libraryPath = 'libtdjson.so';
    _isolate = await Isolate.spawn(
      _telegramTdlibReceiveLoop,
      _TelegramTdlibInit(_receivePort.sendPort, libraryPath),
      debugName: 'mpv-tdlib-receive',
    );
    await ready.future.timeout(const Duration(seconds: 30));
    final separator = Platform.pathSeparator;
    final databaseDir =
        Directory('${support.path}${separator}telegram${separator}database');
    final filesDir =
        Directory('${support.path}${separator}telegram${separator}files');
    await databaseDir.create(recursive: true);
    await filesDir.create(recursive: true);
    _send({
      '@type': 'getAuthorizationState',
      '@extra': _nextRequestId(),
    });
    _auth.add(const TelegramUserAuth(TelegramUserAuthStep.disconnected));
  }

  void enviarTelefono(String phoneNumber) {
    final value = phoneNumber.trim();
    if (!value.startsWith('+') || value.length < 8) {
      throw ArgumentError('Ingresá el teléfono con prefijo internacional');
    }
    _send({
      '@type': 'setAuthenticationPhoneNumber',
      'phone_number': value,
    });
  }

  void enviarCodigo(String code) {
    if (code.trim().isEmpty) throw ArgumentError('El código está vacío');
    _send({
      '@type': 'checkAuthenticationCode',
      'code': code.trim(),
    });
  }

  void enviarContrasena(String password) {
    if (password.isEmpty) throw ArgumentError('La contraseña está vacía');
    _send({
      '@type': 'checkAuthenticationPassword',
      'password': password,
    });
  }

  Future<int> subirIndice(String ruta, {String? hash}) async {
    final chatId = _savedMessagesChatId;
    if (chatId == null) {
      throw StateError('La cuenta Telegram no está autorizada');
    }
    final file = File(ruta);
    if (!await file.exists()) throw StateError('No existe index.db');
    final localMessage = await _request({
      '@type': 'sendMessage',
      'chat_id': chatId,
      'message_thread_id': 0,
      'input_message_content': {
        '@type': 'inputMessageDocument',
        'document': {'@type': 'inputFileLocal', 'path': file.absolute.path},
        'thumbnail': null,
        'disable_content_type_detection': true,
        'caption': {
          '@type': 'formattedText',
          'text': '#mediablock_index\n'
              '${jsonEncode({
                'version': 1,
                'size': await file.length(),
                'hash': hash ?? '',
                'created_at': DateTime.now().toUtc().toIso8601String(),
              })}',
          'entities': <Object>[],
        },
      },
    }, timeout: const Duration(minutes: 2));
    final message = localMessage['result'];
    if (message is! Map<String, dynamic> || message['id'] is! int) {
      throw const FormatException('TDLib no confirmó el envío de index.db');
    }
    final messageId = message['id'] as int;
    if (message['sending_state'] == null ||
        _completedMessages.contains(messageId)) {
      return messageId;
    }
    final ack = Completer<void>();
    _messageAcks[messageId] = ack;
    await ack.future.timeout(const Duration(minutes: 15));
    _messageAcks.remove(messageId);
    return messageId;
  }

  Future<String> bajarUltimoIndice(String destino) async {
    final chatId = _savedMessagesChatId;
    if (chatId == null) {
      throw StateError('La cuenta Telegram no está autorizada');
    }
    final result = await _request({
      '@type': 'searchChatMessages',
      'chat_id': chatId,
      'query': '#mediablock_index',
      'from_message_id': 0,
      'offset': 0,
      'limit': 100,
      'filter': {'@type': 'searchMessagesFilterDocument'},
    });
    final response = result['result'];
    final messages = response is Map ? response['messages'] : null;
    if (messages is! List) {
      throw const FormatException('Telegram no devolvió mensajes del índice');
    }
    Map<String, dynamic>? backup;
    for (final item in messages) {
      if (item is! Map<String, dynamic>) continue;
      final content = item['content'];
      final document = content is Map ? content['document'] : null;
      final caption = document is Map ? document['caption'] : null;
      final text = caption is Map ? caption['text'] : null;
      if (text is String && text.startsWith('#mediablock_index\n')) {
        backup = item;
        break;
      }
    }
    if (backup == null)
      throw StateError('No hay respaldo index.db en Guardados');

    final content = backup['content'] as Map<String, dynamic>;
    final document = content['document'] as Map<String, dynamic>;
    final remoteFile = document['document'] as Map<String, dynamic>;
    final fileId = remoteFile['id'];
    if (fileId is! int) throw const FormatException('Respaldo sin file_id');
    final downloaded = await _request({
      '@type': 'downloadFile',
      'file_id': fileId,
      'priority': 32,
      'offset': 0,
      'limit': 0,
      'synchronous': true,
    }, timeout: const Duration(minutes: 15));
    final remote = downloaded['result'];
    final local = remote is Map ? remote['local'] : null;
    final path = local is Map ? local['path'] : null;
    final complete = local is Map ? local['is_downloading_completed'] : null;
    if (path is! String || path.isEmpty || complete != true) {
      throw StateError('Telegram no completó la descarga de index.db');
    }
    final source = File(path);
    if (!await source.exists())
      throw StateError('No se encontró el archivo descargado');
    final caption = document['caption'];
    final captionText = caption is Map ? caption['text'] : null;
    if (captionText is! String) {
      throw const FormatException('Respaldo sin metadatos verificables');
    }
    final metadataStart = captionText.indexOf('\n');
    if (metadataStart < 0)
      throw const FormatException('Metadatos del respaldo inválidos');
    final metadata = jsonDecode(captionText.substring(metadataStart + 1));
    if (metadata is! Map<String, dynamic> ||
        metadata['version'] != 1 ||
        metadata['hash'] is! String ||
        metadata['size'] is! int) {
      throw const FormatException('Versión de respaldo no reconocida');
    }
    if (await source.length() != metadata['size']) {
      throw StateError('index.db descargado tiene tamaño incorrecto');
    }
    final actualHash =
        _hex((await Sha256().hash(await source.readAsBytes())).bytes);
    if (actualHash != metadata['hash']) {
      throw StateError('El SHA-256 del respaldo Telegram no coincide');
    }

    final target = File(destino);
    await target.parent.create(recursive: true);
    final temporary = File(
        '${target.path}.incoming_${DateTime.now().millisecondsSinceEpoch}');
    try {
      await source.copy(temporary.path);
      if (await target.exists()) {
        final backupPath =
            '${target.path}.bak_${DateTime.now().millisecondsSinceEpoch}';
        await target.copy(backupPath);
      }
      if (await target.exists()) await target.delete();
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
    return target.path;
  }

  Future<void> cerrar() async {
    _commandPort?.send('stop');
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _clientId = null;
    _commandPort = null;
    _savedMessagesChatId = null;
    _receivePort.close();
    await _auth.close();
  }

  String _nextRequestId() => 'mpv_${++_requestId}';

  void _send(Map<String, Object?> request) {
    final id = _clientId;
    if (id == null) throw StateError('TDLib todavía no está conectado');
    final port = _commandPort;
    if (port == null) throw StateError('TDLib no recibe solicitudes');
    port.send({
      'client_id': id,
      'request': jsonEncode(request),
    });
  }

  Future<Map<String, dynamic>> _request(
    Map<String, Object?> request, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    final extra = _nextRequestId();
    final completer = Completer<Map<String, dynamic>>();
    _requests[extra] = completer;
    request['@extra'] = extra;
    _send(request);
    return completer.future.timeout(timeout).whenComplete(() {
      _requests.remove(extra);
    });
  }

  void _onUpdate(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      final extra = decoded['@extra'];
      if (extra is String) {
        final completer = _requests.remove(extra);
        if (completer != null && !completer.isCompleted) {
          if (decoded['@type'] == 'error') {
            completer.completeError(StateError(
              'TDLib ${decoded['code']}: ${decoded['message']}',
            ));
          } else {
            completer.complete(decoded);
          }
        }
      }
      final type = decoded['@type'];
      if (type == 'updateAuthorizationState') {
        final state = decoded['authorization_state'];
        if (state is Map<String, dynamic>) {
          _handleAuthState('${state['@type'] ?? ''}');
        }
      } else if (type == 'updateMessageSendSucceeded') {
        final message = decoded['message'];
        if (message is Map<String, dynamic> && message['id'] is int) {
          _completeMessage(message['id'] as int);
        }
        final oldId = decoded['old_message_id'];
        if (oldId is int) _completeMessage(oldId);
      } else if (type == 'updateMessageSendFailed') {
        final message = decoded['message'];
        final id = message is Map ? message['id'] : null;
        final failure = decoded['error'];
        if (id is int) {
          _messageAcks.remove(id)?.completeError(StateError(
                'No se pudo subir index.db: '
                '${failure is Map ? failure['message'] : 'error TDLib'}',
              ));
        }
      }
    } catch (e) {
      _auth.add(TelegramUserAuth(
        TelegramUserAuthStep.error,
        error: 'Respuesta TDLib inválida: $e',
      ));
    }
  }

  void _handleAuthState(String state) {
    switch (state) {
      case 'authorizationStateWaitTdlibParameters':
        if (_parametersSent) return;
        _parametersSent = true;
        unawaited(_configureDatabase());
      case 'authorizationStateWaitPhoneNumber':
        _auth.add(const TelegramUserAuth(TelegramUserAuthStep.waitingPhone));
      case 'authorizationStateWaitCode':
        _auth.add(const TelegramUserAuth(TelegramUserAuthStep.waitingCode));
      case 'authorizationStateWaitPassword':
        _auth.add(const TelegramUserAuth(TelegramUserAuthStep.waitingPassword));
      case 'authorizationStateReady':
        _auth.add(const TelegramUserAuth(TelegramUserAuthStep.ready));
        unawaited(_resolveSavedMessages());
      case 'authorizationStateClosed':
        _auth.add(const TelegramUserAuth(TelegramUserAuthStep.disconnected));
      default:
        break;
    }
  }

  Future<void> _configureDatabase() async {
    final support = await getApplicationSupportDirectory();
    _send({
      '@type': 'setTdlibParameters',
      'use_test_dc': false,
      'database_directory':
          '${support.path}${Platform.pathSeparator}telegram${Platform.pathSeparator}database',
      'files_directory':
          '${support.path}${Platform.pathSeparator}telegram${Platform.pathSeparator}files',
      'use_file_database': true,
      'use_chat_info_database': true,
      'use_message_database': true,
      'use_secret_chats': false,
      'api_id': int.parse(_apiId),
      'api_hash': _apiHash,
      'system_language_code': Platform.localeName.split('_').first,
      'device_model': Platform.operatingSystem,
      'system_version': Platform.operatingSystemVersion,
      'application_version': '1.0.0',
      'database_encryption_key': _databaseKey,
    });
  }

  Future<void> _resolveSavedMessages() async {
    if (_resolvingSavedMessages || _savedMessagesChatId != null) return;
    _resolvingSavedMessages = true;
    try {
      final me = await _request({'@type': 'getMe'});
      final user = me['result'];
      if (user is! Map<String, dynamic> || user['id'] is! int) {
        throw const FormatException('TDLib no devolvió el usuario');
      }
      final chatResult = await _request({
        '@type': 'createPrivateChat',
        'user_id': user['id'],
        'force': false,
      });
      final chat = chatResult['result'];
      if (chat is! Map<String, dynamic> || chat['id'] is! int) {
        throw const FormatException('No se pudo resolver Mensajes guardados');
      }
      _savedMessagesChatId = '${chat['id']}';
      _auth.add(const TelegramUserAuth(TelegramUserAuthStep.ready));
    } catch (e) {
      _auth.add(TelegramUserAuth(
        TelegramUserAuthStep.error,
        error:
            'Telegram inició sesión, pero no se resolvió Mensajes guardados: $e',
      ));
    } finally {
      _resolvingSavedMessages = false;
    }
  }

  void _completeMessage(int id) {
    _completedMessages.add(id);
    _messageAcks.remove(id)?.complete();
  }

  static String _hex(List<int> bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
