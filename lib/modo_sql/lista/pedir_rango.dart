import 'package:flutter/material.dart';

import '../comun/campos.dart';

/// Pide un rango del archivo seleccionado (o el archivo entero).
class PedirRango extends StatelessWidget {
  final TextEditingController desde;
  final TextEditingController hasta;
  final String info;
  final VoidCallback onRango;
  final VoidCallback onEntero;

  const PedirRango({
    super.key,
    required this.desde,
    required this.hasta,
    required this.info,
    required this.onRango,
    required this.onEntero,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 6),
        Row(children: [
          Expanded(child: campoTexto(desde, 'desde')),
          const SizedBox(width: 6),
          Expanded(child: campoTexto(hasta, 'hasta')),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
            child: FilledButton.tonal(
                onPressed: onRango,
                child: const Text('Pedir rango')),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: FilledButton.tonal(
                onPressed: onEntero,
                child: const Text('Archivo entero')),
          ),
        ]),
        if (info.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SelectableText(info,
                style: const TextStyle(fontSize: 11)),
          ),
      ],
    );
  }
}
