import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_avif/flutter_avif.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Previas al CREAR el molde: se generan en el momento, se guardan
/// cifradas DENTRO del `.mld` (entradas `.prev/<archivo>#<i>`,
/// formato `prev`, misma clave del archivo) y el grid/list las
/// muestran sin abrir jamás el original.
///
/// Imágenes: 1 AVIF de 320px (el original no se toca). Videos:
/// frames JPEG con el media de mimapp (seek + screenshot sobre
/// surface oculta). Vacío = sin previa (el grid muestra icono).
/// Moldes viejos (previas PNG): se muestran igual (passthrough).
class PreviewMolde {
  /// Prefijo de las entradas de previa dentro del molde.
  static const prefijo = '.prev/';

  static String entrada(String nombreRel, int i) => '$prefijo$nombreRel#$i';

  static bool esPrevia(String nombre) => nombre.startsWith(prefijo);

  static const formatosVideo = {
    'mp4',
    'mkv',
    'webm',
    'avi',
    'mov',
    '3gp',
    'm4v',
    'ts',
    'flv',
    'wmv',
    'mpg',
    'mpeg',
  };

  static bool esVideo(String formato) =>
      formatosVideo.contains(formato.toLowerCase());

  /// Genera las previas de un archivo local. Imágenes en hilo
  /// aparte; videos con [captura] (surface oculta del que crea).
  /// Sin captura, los videos quedan sin previa (icono+formato).
  /// OJO: las fotos se generan en el hilo principal (el decoder
  /// `dart:ui` NO anda en `Isolate.run`: fallaba silencioso y los
  /// moldes salían sin previas). El codec es async nativo, no traba.
  static Future<List<Uint8List>> generar({
    required String ruta,
    required String formato,
    CapturaVideo? captura,
  }) async {
    if (esVideo(formato)) {
      if (captura == null) return [];
      return captura.frames(ruta);
    }
    return _previaImagen(ruta);
  }

  /// Lee las previas guardadas de un archivo (del .mld, descifradas).
  /// El lector real lo hace `CreateMoldeSql.previasDe`.
  static String patronDe(String nombreRel) => '$prefijo$nombreRel#%';

  /// ¿Es AVIF? (magic `....ftypavif` en offset 4).
  static bool esAvif(Uint8List b) {
    if (b.length < 12) return false;
    if (b[4] != 0x66 || b[5] != 0x74 || b[6] != 0x79 || b[7] != 0x70) {
      return false;
    }
    if (b.length < 12) return false;
    final marca = String.fromCharCodes(b.sublist(8, 12));
    return marca == 'avif';
  }

  /// Previa lista para mostrar: AVIF → PNG en memoria, el resto pasa
  /// igual (JPEG de video, PNG de moldes viejos). Una vez por previa
  /// (el modo memoiza en RAM).
  static Future<Uint8List> mostrable(Uint8List b) async {
    if (!esAvif(b)) return b;
    try {
      final frames = await decodeAvif(b);
      if (frames.isEmpty) return b;
      final img = frames.first.image;
      try {
        final data =
            await img.toByteData(format: ui.ImageByteFormat.png);
        final out = data?.buffer.asUint8List();
        if (out == null || out.isEmpty) return b;
        return Uint8List.fromList(out);
      } finally {
        try {
          img.dispose();
        } catch (_) {}
      }
    } catch (_) {
      return b;
    }
  }

  /// PNG → AVIF para guardar (solo previas). Si falla, PNG original.
  static Future<Uint8List> aAvif(Uint8List png) async {
    try {
      final a = await encodeAvif(png);
      if (a.isEmpty) return png;
      return a;
    } catch (_) {
      return png;
    }
  }
}

/// Achica un ui.Image a [ancho] px dibujando directo (sin PNG
/// intermedio: el codec nativo no abre AVIF y era un rodeo).
Future<Uint8List?> _achicarUi(ui.Image src, int ancho) async {
  try {
    if (src.width <= 0 || src.height <= 0) return null;
    final alto = (src.height * ancho / src.width).round();
    if (alto <= 0) return null;
    final rec = ui.PictureRecorder();
    final c = ui.Canvas(rec);
    c.drawImageRect(
      src,
      ui.Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
      ui.Rect.fromLTWH(0, 0, ancho.toDouble(), alto.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    final pic = rec.endRecording();
    final out = await pic.toImage(ancho, alto);
    try {
      final data =
          await out.toByteData(format: ui.ImageByteFormat.png);
      final b = data?.buffer.asUint8List();
      if (b == null || b.isEmpty) return null;
      return Uint8List.fromList(b);
    } finally {
      out.dispose();
    }
  } catch (_) {
    return null;
  }
}

/// Una previa de imagen: AVIF de 320px (corre en el hilo principal:
/// `dart:ui` no anda en isolates). Si el AVIF falla, PNG.
/// Si el ORIGINAL es AVIF (el codec nativo no lo abre): libavif →
/// achicado directo → AVIF. Sin PNG en el medio.
/// El original nunca se modifica.
/// (Sin encoder jpeg a mano: `ImageByteFormat` no tiene jpeg.)
Future<List<Uint8List>> _previaImagen(String ruta) async {
  try {
    final bytes = await File(ruta).readAsBytes();
    if (bytes.isEmpty) return [];
    // Origen AVIF: libavif + achique directo (sin rodeos).
    if (PreviewMolde.esAvif(bytes)) {
      try {
        final fs = await decodeAvif(bytes);
        if (fs.isEmpty) return [];
        final chica = await _achicarUi(fs.first.image, 320);
        try {
          fs.first.image.dispose();
        } catch (_) {}
        if (chica == null || chica.isEmpty) return [];
        return [await PreviewMolde.aAvif(chica)];
      } catch (_) {
        return [];
      }
    }
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: 320,
    );
    final frame = await codec.getNextFrame();
    try {
      final data = await frame.image
          .toByteData(format: ui.ImageByteFormat.png);
      final b = data?.buffer.asUint8List();
      if (b == null || b.isEmpty) return [];
      // Solo la previa va en AVIF; el original no se toca.
      return [await PreviewMolde.aAvif(Uint8List.fromList(b))];
    } finally {
      frame.image.dispose();
      codec.dispose();
    }
  } catch (_) {
    return [];
  }
}

/// Frames de video con el media de mimapp: seek al fotograma X y
/// captura de la surface. La surface existe pero oculta (el que
/// crea monta [vista] en Offstage mientras genera).
///
/// Tiempos según duración (17 repartidos, 1 cada ~1/18 del total).
/// Si sale corto, se rellena repitiendo el último hasta 17.
/// Sin video válido → [].
class CapturaVideo {
  final Player player = Player();
  late final VideoController controller = VideoController(player);

  /// Surface oculta: el creador la monta en Offstage mientras
  /// genera (sin surface el mpv no renderiza y no hay captura).
  Widget vista() => Video(controller: controller);

  Future<List<Uint8List>> frames(String ruta, {int tope = 17}) async {
    final fuera = <Uint8List>[];
    try {
      await player.setVolume(0);
      // Reproduciendo muteado: en play:false el mpv no renderiza
      // y no hay frames ni duración.
      await player.open(Media(ruta));
      final dur = await player.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 15),
              onTimeout: () => Duration.zero);
      if (dur <= Duration.zero) return fuera;
      final ancho = await player.stream.width
          .firstWhere((w) => (w ?? 0) > 0)
          .timeout(const Duration(seconds: 15),
              onTimeout: () => 0);
      if ((ancho ?? 0) <= 0) return fuera;
      for (var i = 0; i < tope; i++) {
        final t = dur * (i + 1) ~/ (tope + 1);
        final shot = await _fotoEn(t);
        if (shot == null) break;
        fuera.add(shot);
      }
      // Relleno: si salió corto, se repite el último hasta el tope.
      while (fuera.isNotEmpty && fuera.length < tope) {
        fuera.add(fuera.last);
      }
    } catch (_) {
    } finally {
      try {
        await player.stop();
      } catch (_) {}
    }
    return fuera;
  }

  /// Seek a [t], espera el fotograma y lo captura.
  Future<Uint8List?> _fotoEn(Duration t) async {
    try {
      await player.seek(t);
      final ok = await player.stream.position
          .firstWhere((p) => p >= t - const Duration(milliseconds: 400))
          .timeout(const Duration(seconds: 4), onTimeout: () => t);
      if (ok < Duration.zero) return null;
      await Future<void>.delayed(const Duration(milliseconds: 250));
      return await player.screenshot(format: 'image/jpeg');
    } catch (_) {
      return null;
    }
  }

  Future<void> cerrar() async {
    try {
      await player.dispose();
    } catch (_) {}
  }
}

/// Frames de video: ver [CapturaVideo] (requiere surface oculta del
/// creador). Sin captura no hay frames.
Future<List<Uint8List>> _framesVideo(String ruta) async => [];
