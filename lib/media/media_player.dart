import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:media_kit/media_kit.dart';

import '../services/settings.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'media_library.dart';

/// Reproductor de audio/video con playlist y notificación del sistema
/// (botones play/pausa/anterior/siguiente/stop en la notificación).
///
/// Singleton: se inicializa vía [AudioService.init] en main().
class MediaPlayer extends BaseAudioHandler with SeekHandler {
  static MediaPlayer? _instance;
  static MediaPlayer get instance => _instance ??= MediaPlayer._internal();

  factory MediaPlayer() => instance;

  /// AudioService se inicializa LAZY (solo al entrar a Media).
  /// Si se hace en bootstrap, Android muestra la notificación
  /// multimedia sin haber reproducido nada.
  static bool audioListo = false;
  static Future<void> ensureService() async {
    if (audioListo) return;
    try {
      await AudioService.init(
        builder: () => MediaPlayer.instance,
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'pr_app_media',
          androidNotificationChannelName: 'Reproducción de medios',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: true,
        ),
      );
      audioListo = true;
    } catch (e) {
      // Sin servicio igual se puede usar el player local sin notificación.
    }
  }

  MediaPlayer._internal() : super() {
    _player = Player();
    _videoController = VideoController(_player);
    _subscribe();
    // Lo que cambie en la biblioteca (estrella, listas, grupos) avisa
    // a la UI al momento.
    library.onChanged = () => onChanged?.call();
  }

  late final Player _player;
  late final VideoController _videoController;

  String _status = 'Sin archivo';
  String _current = '';

  /// Playlist de rutas locales.
  final List<String> _queue = [];
  int _queueIndex = -1;

  /// Empuja un (id, valor) a la GUI cuando algo cambia (config, status...).
  void Function(String id, String value)? onPush;

  /// Notifica a la UI que hubo un cambio de estado.
  void Function()? onChanged;

  VideoController get videoController => _videoController;
  String get status => _status;
  String get current => _current;
  int get queueLength => _queue.length;
  int get queueIndex => _queueIndex;

  /// Cola actual (rutas). La vista Ahora la muestra como lista.
  /// Se llama `cola` porque `queue` ya existe en BaseAudioHandler.
  List<String> get cola => List.unmodifiable(_queue);

  /// Biblioteca (historial + favoritos) del reproductor.
  MediaLibraryStore get library => MediaLibraryStore.instance;

  /// ¿El archivo actual está en favoritos?
  bool get isCurrentFavorite =>
      _current.isNotEmpty && library.isFavorite(_current);

  /// Marca/desmarca el archivo actual como favorito.
  Future<bool> toggleCurrentFavorite() async {
    if (_current.isEmpty) return false;
    final fav =
        await library.toggleFavorite(_current, title: _titleOf(_current));
    onChanged?.call();
    return fav;
  }

  Stream<Duration> get positionStream => _player.stream.position;
  Stream<Duration> get durationStream => _player.stream.duration;
  Stream<bool> get playingStream => _player.stream.playing;
  Stream<int?> get widthStream => _player.stream.width;

  /// Estado actual sincrónico (para restaurar la UI al volver a la pantalla).
  Duration get position => _player.state.position;
  Duration get duration => _player.state.duration;
  bool get isPlaying => _player.state.playing;
  bool get hasVideo => (_player.state.width ?? 0) > 0;
  Stream<int?> get heightStream => _player.stream.height;

  // ===========================================================================
  // Suscripción a streams de libmpv → sincroniza estado + notificación
  // ===========================================================================

  void _subscribe() {
    _player.stream.error.listen((e) {
      _status = 'Error: $e';
      _push('player_status', _status);
    });

    _player.stream.playing.listen((playing) {
      if (playing) _status = 'Reproduciendo: ${_titleOf(_current)}';
      _broadcastState(playing);
      _push('player_status', _status);
    });

    _player.stream.duration.listen((d) {
      if (_current.isNotEmpty) {
        mediaItem.add(_mediaItemFor(_current).copyWith(duration: d));
      }
    });

    _player.stream.completed.listen((done) async {
      if (!done) return;
      if (_queueIndex >= 0 && _queueIndex < _queue.length - 1) {
        await playAt(_queueIndex + 1);
      } else {
        _status = 'Terminado: ${_titleOf(_current)}';
        _broadcastState(false);
        _push('player_status', _status);
      }
    });
  }

  // ===========================================================================
  // Playlist
  // ===========================================================================

  /// Abre el selector con selección múltiple y arma la lista.
  Future<void> pickAndPlay() async {
    try {
      _status = 'Abriendo selector...';
      _push('player_status', _status);
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: true,
      );
      if (result == null || result.files.isEmpty) {
        _status = 'Selección cancelada';
        _push('player_status', _status);
        return;
      }
      final paths =
          result.files.where((f) => f.path != null).map((f) => f.path!).toList();
      if (paths.isEmpty) {
        _status = 'Archivos sin ruta accesible';
        _push('player_status', _status);
        return;
      }
      await setQueue(paths);
    } catch (e) {
      _status = 'Error al abrir: $e';
      _push('player_status', _status);
    }
  }

  /// Reemplaza la playlist y reproduce desde [startAt].
  /// Todos los elegidos quedan en el historial para verlos en listas.
  Future<void> setQueue(List<String> paths, {int startAt = 0}) async {
    _queue
      ..clear()
      ..addAll(paths);
    unawaited(library.addHistoryMany(paths).then((_) => onChanged?.call()));
    await playAt(startAt.clamp(0, _queue.length - 1));
  }

  /// Reproduce una lista de la biblioteca (o favoritos) como cola nueva.
  Future<void> playPlaylist(List<String> paths, {int startAt = 0}) =>
      setQueue(paths, startAt: startAt);

  /// Reproduce la pista [i] de la lista.
  Future<void> playAt(int i) async {
    if (_queue.isEmpty) return;
    _queueIndex = i.clamp(0, _queue.length - 1);
    await openPath(_queue[_queueIndex]);
  }

  Future<void> next() async {
    if (_queue.isEmpty) return;
    await playAt((_queueIndex + 1) % _queue.length);
  }

  Future<void> previous() async {
    if (_queue.isEmpty) return;
    await playAt((_queueIndex - 1 + _queue.length) % _queue.length);
  }

  // ===========================================================================
  // Reproducción
  // ===========================================================================

  /// Reproduce un archivo por ruta (y lo registra en el historial).
  Future<void> openPath(String path) async {
    try {
      await _player.open(Media(path));
      _current = path;
      _status = 'Reproduciendo: ${_titleOf(path)}';
      mediaItem.add(_mediaItemFor(path));
      _broadcastState(true);
      // Historial: no bloquea la reproducción si falla el disco.
      unawaited(library.addHistory(path).then((_) => onChanged?.call()));
    } catch (e) {
      _status = 'Error al reproducir: $e';
    }
    _push('player_status', _status);
  }

  @override
  Future<void> play() async {
    await _player.play();
    _broadcastState(true);
  }

  @override
  Future<void> pause() async {
    await _player.pause();
    _broadcastState(false);
  }

  Future<void> playOrPause() => _player.playOrPause();

  @override
  Future<void> stop() async {
    await _player.stop();
    _status = 'Detenido';
    _broadcastState(false);
    _push('player_status', _status);
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() => next();

  @override
  Future<void> skipToPrevious() => previous();

  // ===========================================================================
  // Estado para la notificación del sistema
  // ===========================================================================

  void _broadcastState(bool playing) {
    final controls = <MediaControl>[
      if (_queue.length > 1) MediaControl.skipToPrevious,
      playing ? MediaControl.pause : MediaControl.play,
      if (_queue.length > 1) MediaControl.skipToNext,
      MediaControl.stop,
    ];
    playbackState.add(PlaybackState(
      controls: controls,
      systemActions: const {MediaAction.seek, MediaAction.seekForward, MediaAction.seekBackward},
      processingState: AudioProcessingState.ready,
      playing: playing,
      updatePosition: _player.state.position,
      bufferedPosition: _player.state.buffer,
      speed: _player.state.rate,
      queueIndex: _queueIndex < 0 ? null : _queueIndex,
    ));
  }

  MediaItem _mediaItemFor(String path) {
    return MediaItem(
      id: path,
      title: _titleOf(path),
    );
  }

  String _titleOf(String path) {
    if (Settings.instance.mediaShowUri) return path;
    return path.split('/').last.split('\\').last.split('?').first;
  }

  // ===========================================================================
  // Utilidades internas
  // ===========================================================================

  void _push(String id, String value) {
    onPush?.call(id, value);
    onChanged?.call();
  }

  void dispose() {
    _player.dispose();
  }
}
