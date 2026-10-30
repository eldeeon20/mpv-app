import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../media_server/media_server.dart';

/// Diálogo preview de un archivo ya descifrado: imagen → vista,
/// texto → texto, resto → hex. Botones Tags + Guardar copia + Cerrar.
/// El preview sigue abierto tras guardar tags (título vivo).
Future<void> mostrarVistaArchivo({
  required BuildContext context,
  required FichaArchivo f,
  required Uint8List datos,
  required Set<String> imgs,
  required Set<String> textos,
  required Future<void> Function() onTags,
  required String Function() tagsFrescos,
  required Future<void> Function() onGuardarCopia,
}) async {
  final fmt = f.formato.toLowerCase();
  late final Widget cuerpo;
  if (imgs.contains(fmt)) {
    cuerpo = Image.memory(
      datos,
      errorBuilder: (_, __, ___) =>
          const Text('bytes descifrados pero no es imagen válida'),
    );
  } else if (textos.contains(fmt)) {
    cuerpo = SingleChildScrollView(
      child: SelectableText(
        utf8.decode(datos, allowMalformed: true),
        style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
      ),
    );
  } else {
    final hex = datos
        .take(128)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(' ');
    cuerpo = SelectableText(
      'formato ".$fmt" sin vista previa (${datos.length} bytes):\n$hex'
      '${datos.length > 128 ? '…' : ''}',
      style: const TextStyle(fontSize: 11),
    );
  }
  var tagsAhora = tagsFrescos();
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDlg) => AlertDialog(
        title: Text(
          tagsAhora.isEmpty ? f.nombre : '${f.nombre}\n[$tagsAhora]',
          style: const TextStyle(fontSize: 13),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: cuerpo,
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await onTags();
              setDlg(() => tagsAhora = tagsFrescos());
            },
            child: const Text('Tags'),
          ),
          TextButton(
            onPressed: onGuardarCopia,
            child: const Text('Guardar copia'),
          ),
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cerrar')),
        ],
      ),
    ),
  );
}
