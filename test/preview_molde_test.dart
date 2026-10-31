import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:pr_app/modo_sql/preview_molde.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('generates an image preview without disposing the buffer twice',
      () async {
    final directory = await Directory.systemTemp.createTemp('preview_molde_');
    addTearDown(() => directory.delete(recursive: true));

    final image = File('${directory.path}/image.png');
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      const ui.Rect.fromLTWH(0, 0, 2, 2),
      ui.Paint()..color = const ui.Color(0xFFFF0000),
    );
    final picture = recorder.endRecording();
    final source = await picture.toImage(2, 2);
    final png = await source.toByteData(format: ui.ImageByteFormat.png);
    source.dispose();
    picture.dispose();
    expect(png, isNotNull);
    await image.writeAsBytes(
      png!.buffer.asUint8List(),
      flush: true,
    );

    final previews = await PreviewMolde.generar(
      ruta: image.path,
      formato: 'png',
    );

    expect(previews, hasLength(1));
    expect(previews.single, isNotEmpty);
  });
}
