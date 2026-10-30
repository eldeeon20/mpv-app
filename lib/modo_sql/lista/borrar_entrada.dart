import 'package:flutter/material.dart';

import '../media_server/media_server.dart';
import '../tool/create_molde_sql.dart';

/// Borra UNA entrada del índice con aviso (popup): solo la fila SQL,
/// los bytes quedan huérfanos en el .mld.
Future<void> borrarEntrada({
  required BuildContext context,
  required FichaArchivo f,
  required String claveSql,
  required String molde,
  required Future<void> Function() onListo,
  required void Function(String s) log,
  required void Function() alBorrar,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title:
          const Text('Borrar entrada', style: TextStyle(fontSize: 13)),
      content: Text(
        '"${f.nombre}" sale del índice SQL.\n'
        'AVISO: sus bytes quedan en el .mld (huérfanos); '
        'los demás archivos no se mueven.\n¿Seguir?',
        style: const TextStyle(fontSize: 12),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Borrar')),
      ],
    ),
  );
  if (ok != true) return;
  try {
    await CreateMoldeSql.quitarEntrada(
      claveSql: claveSql,
      molde: molde,
      archivo: f.nombre,
    );
    alBorrar();
    log('✓ entrada "${f.nombre}" borrada del índice');
    await onListo();
  } catch (e) {
    log('✗ borrar entrada: $e');
  }
}
