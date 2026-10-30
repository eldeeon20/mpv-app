import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../media_server/media_server.dart';
import '../preview_molde.dart';

/// Visor pantalla completa: deslizá a los costados para la
/// preview siguiente/anterior, pellizcá para zoom (InteractiveViewer).
/// Cada página carga sus bytes perezoso (memoizado afuera).
class VisorPreview extends StatefulWidget {
  final List<FichaArchivo> imagenes;
  final int indiceInicial;

  /// Bytes completos descifrados (null = no se pudo).
  final Future<Uint8List?> Function(FichaArchivo f) cargar;

  /// Tags actuales (frescos) de un archivo.
  final String Function(FichaArchivo f) tagsDe;

  /// Abre el editor de tags (el visor sigue abierto).
  final Future<void> Function(FichaArchivo f) onTags;

  /// Guarda copia con los bytes ya cargados.
  final Future<void> Function(FichaArchivo f, Uint8List b) onGuardar;

  const VisorPreview({
    super.key,
    required this.imagenes,
    required this.indiceInicial,
    required this.cargar,
    required this.tagsDe,
    required this.onTags,
    required this.onGuardar,
  });

  @override
  State<VisorPreview> createState() => _VisorPreviewState();
}

class _VisorPreviewState extends State<VisorPreview> {
  late final PageController _paginas;
  late final TransformationController _zoom;
  late int _i;
  bool _ampliado = false;

  /// Bytes ya cargados por índice (para Guardar sin re-pedir).
  final Map<int, Uint8List> _listos = {};

  /// Decodificados AVIF por índice (mostrar; Guardar usa el original).
  final Map<int, Future<Uint8List>> _vis = {};

  @override
  void initState() {
    super.initState();
    _i = widget.indiceInicial
        .clamp(0, widget.imagenes.length - 1);
    _paginas = PageController(initialPage: _i);
    _zoom = TransformationController();
    _zoom.addListener(_alZoom);
  }

  /// El zoom robaba el gesto lateral: pan solo si está ampliado,
  /// si no el desliz va al PageView (siguiente/anterior).
  void _alZoom() {
    final a = _zoom.value.getMaxScaleOnAxis() > 1.01;
    if (a != _ampliado && mounted) setState(() => _ampliado = a);
  }

  @override
  void dispose() {
    _zoom.removeListener(_alZoom);
    _zoom.dispose();
    _paginas.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.imagenes[_i];
    final tags = widget.tagsDe(f);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          '${_i + 1}/${widget.imagenes.length} · '
          '${f.nombre.split('/').last}'
          '${tags.isEmpty ? '' : '\n[$tags]'}',
          style: const TextStyle(fontSize: 12),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.label_outline_rounded),
            tooltip: 'Tags',
            onPressed: () async {
              await widget.onTags(f);
              if (mounted) setState(() {});
            },
          ),
          IconButton(
            icon: const Icon(Icons.save_alt_rounded),
            tooltip: 'Guardar copia',
            onPressed: () {
              final b = _listos[_i];
              if (b == null) return;
              widget.onGuardar(f, b);
            },
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded),
            tooltip: 'Cerrar',
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
      body: PageView.builder(
        controller: _paginas,
        itemCount: widget.imagenes.length,
        onPageChanged: (n) {
          // Página nueva = zoom reiniciado (el swipe manda).
          _zoom.value = Matrix4.identity();
          setState(() => _i = n);
        },
        itemBuilder: (_, n) {
          final a = widget.imagenes[n];
          return FutureBuilder<Uint8List?>(
            future: widget.cargar(a),
            builder: (_, snap) {
              if (snap.connectionState != ConnectionState.done) {
                // Tap = original o nada (sin previa de relleno).
                return const Center(
                  child: Icon(Icons.image_outlined,
                      size: 64, color: Colors.grey),
                );
              }
              final b = snap.data;
              if (b == null) {
                return const Center(
                  child: Icon(Icons.broken_image_outlined,
                      size: 64, color: Colors.redAccent),
                );
              }
              _listos[n] = b;
              // Original AVIF: se muestra decodificado (Guardar sigue
              // con el original intacto).
              final Widget vista = PreviewMolde.esAvif(b)
                  ? FutureBuilder<Uint8List>(
                      future: _vis.putIfAbsent(
                          n, () => PreviewMolde.mostrable(b)),
                      builder: (_, vsnap) {
                        final vb = vsnap.data;
                        if (vb == null) {
                          return const Center(
                            child: Icon(Icons.image_outlined,
                                size: 64, color: Colors.grey),
                          );
                        }
                        return InteractiveViewer(
                          transformationController: _zoom,
                          // Sin ampliar el pan va al PageView (deslizar cambia).
                          panEnabled: _ampliado,
                          scaleEnabled: true,
                          minScale: 1,
                          maxScale: 6,
                          child: Center(
                            child: Image.memory(vb,
                                fit: BoxFit.contain,
                                gaplessPlayback: true),
                          ),
                        );
                      },
                    )
                  : InteractiveViewer(
                      transformationController: _zoom,
                      // Sin ampliar el pan va al PageView (deslizar cambia).
                      panEnabled: _ampliado,
                      scaleEnabled: true,
                      minScale: 1,
                      maxScale: 6,
                      child: Center(
                        child: Image.memory(b,
                            fit: BoxFit.contain,
                            gaplessPlayback: true),
                      ),
                    );
              return vista;
            },
          );
        },
      ),
    );
  }
}
