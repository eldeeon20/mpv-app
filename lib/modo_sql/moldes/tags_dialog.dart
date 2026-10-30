import 'package:flutter/material.dart';

import '../media_server/media_server.dart';
import '../tool/create_molde_sql.dart';

/// Popup de tags de UNA entrada (update en tu SQL, no duplica).
/// Al guardar llama [onListo] (la pantalla reabre y refresca).
Future<void> editarTagsMolde({
  required BuildContext context,
  required FichaArchivo f,
  required String claveSql,
  required String molde,
  required Future<void> Function() onListo,
  required void Function(String s) log,
}) async {
  final ctrl = TextEditingController(text: f.tags.join(', '));
  final guardar = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Tags de ${f.nombre}',
          style: const TextStyle(fontSize: 13)),
      content: TextField(
        controller: ctrl,
        style: const TextStyle(fontSize: 12),
        decoration: const InputDecoration(
          hintText: 'coma, separados (8 máx, 16 letras)',
          isDense: true,
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Guardar')),
      ],
    ),
  );
  final tags = ctrl.text
      .split(',')
      .map((t) => t.trim())
      .where((t) => t.isNotEmpty)
      .toList();
  try {
    ctrl.dispose();
  } catch (_) {}
  if (guardar != true) return;
  try {
    await CreateMoldeSql.actualizarTags(
      claveSql: claveSql,
      molde: molde,
      archivo: f.nombre,
      tags: tags,
    );
    log('✓ tags de "${f.nombre}": ${tags.join(', ')}');
    await onListo();
  } catch (e) {
    log('✗ tags: $e');
  }
}
