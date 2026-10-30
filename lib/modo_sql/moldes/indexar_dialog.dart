import 'package:flutter/material.dart';

import '../comun/campos.dart';

/// Indexar por carpeta: lista lo rastreado (.mld + su SQL) y por cada
/// uno pide su pass y lo añade al índice.
Future<void> mostrarParaIndexar({
  required BuildContext context,
  required List<Map<String, Object?>> hallados,
  required Future<void> Function(String nombre, String passMolde)
      onAnadir,
}) async {
  final ctrls = <String, TextEditingController>{};
  final hechos = <String>{};
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDlg) => AlertDialog(
        title: Text('Indexar carpeta (${hallados.length})',
            style: const TextStyle(fontSize: 13)),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final h in hallados)
                () {
                  final nombre = '${h['nombre'] ?? ''}';
                  final ctrl = ctrls.putIfAbsent(
                      nombre, () => TextEditingController());
                  final hecho = hechos.contains(nombre);
                  return Padding(
                    padding:
                        const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        Text(
                          '$nombre.mld '
                          '(${fmtBytes((h['total'] as int?) ?? 0)}, '
                          '${h['n'] ?? 0} archivos)',
                          style: const TextStyle(fontSize: 12),
                        ),
                        const SizedBox(height: 4),
                        Row(children: [
                          Expanded(
                            child: TextField(
                              controller: ctrl,
                              obscureText: true,
                              enabled: !hecho,
                              style: const TextStyle(fontSize: 11),
                              decoration: const InputDecoration(
                                hintText: 'pass del molde',
                                isDense: true,
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          hecho
                              ? const Text('✓',
                                  style: TextStyle(
                                      color: Colors.tealAccent))
                              : TextButton(
                                  onPressed: () async {
                                    await onAnadir(
                                        nombre, ctrl.text);
                                    setDlg(() =>
                                        hechos.add(nombre));
                                  },
                                  child: const Text('Añadir',
                                      style: TextStyle(
                                          fontSize: 11)),
                                ),
                        ]),
                      ],
                    ),
                  );
                }(),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cerrar')),
        ],
      ),
    ),
  );
  for (final c in ctrls.values) {
    try {
      c.dispose();
    } catch (_) {}
  }
}
