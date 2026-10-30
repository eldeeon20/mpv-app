import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Reproductor local de video con surface propia (Player + Video
/// dedicados: el singleton de Media no tiene surface en este contexto
/// y por eso solo salía audio).
/// Al cerrar se libera el player y se borra el temporal.
class DialogoVideo extends StatefulWidget {
  final String ruta;
  final String titulo;
  const DialogoVideo(
      {super.key, required this.ruta, required this.titulo});

  @override
  State<DialogoVideo> createState() => _DialogoVideoEstado();
}

class _DialogoVideoEstado extends State<DialogoVideo> {
  late final Player _player;
  late final VideoController _ctrl;
  String? _error;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _ctrl = VideoController(_player);
    _abrir();
  }

  Future<void> _abrir() async {
    try {
      await _player.open(Media(widget.ruta));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    try {
      _player.dispose();
    } catch (_) {}
    try {
      File(widget.ruta).deleteSync();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: EdgeInsets.zero,
      backgroundColor: Colors.black,
      child: Column(
        children: [
          AppBar(
            backgroundColor: Colors.black,
            title: Text(widget.titulo,
                style: const TextStyle(fontSize: 13)),
            leading: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          Expanded(
            child: _error != null
                ? Center(
                    child: Text(_error!,
                        style: const TextStyle(color: Colors.redAccent)))
                : Video(controller: _ctrl),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: StreamBuilder<bool>(
              stream: _player.stream.playing,
              builder: (_, snap) {
                final sonando = snap.data ?? false;
                return FilledButton.tonalIcon(
                  onPressed: () => _player.playOrPause(),
                  icon: Icon(sonando
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded),
                  label:
                      Text(sonando ? 'Pausar' : 'Reproducir'),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
