import 'package:flutter/material.dart';

import '../comun/campos.dart';

/// Solo crear molde (carpeta → un solo .mld). La clave vive en Moldes.
class FormCrear extends StatelessWidget {
  final TextEditingController nombre;
  final TextEditingController carpeta;
  final TextEditingController clave;
  final TextEditingController tags;

  /// Carpeta DESTINO en el índice (opcional, '' = raíz). El molde
  /// nace ya anidado ahí (solo índice, no toca archivos).
  final TextEditingController carpetaIndice;
  final bool creando;
  final String estado;
  final VoidCallback onElegir;
  final VoidCallback onCrear;

  const FormCrear({
    super.key,
    required this.nombre,
    required this.carpeta,
    required this.clave,
    required this.tags,
    required this.carpetaIndice,
    required this.creando,
    required this.estado,
    required this.onElegir,
    required this.onCrear,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        const Text('Crear molde (carpeta → un solo .mld)',
            style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        campoTexto(nombre, 'nombre molde (ej. molde_test)'),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(child: campoTexto(carpeta, 'carpeta origen…')),
          const SizedBox(width: 6),
          FilledButton.tonal(
              onPressed: onElegir, child: const Text('Elegir…')),
        ]),
        const SizedBox(height: 6),
        campoTexto(clave, 'clave ÚNICA (tu SQL + molde)',
            oculto: true),
        const SizedBox(height: 6),
        campoTexto(tags, 'tags separados por coma (8 máx, 16 letras)'),
        const SizedBox(height: 6),
        campoTexto(carpetaIndice,
            'carpeta en ÍNDICE (opcional, ej. a/b; vacío = raíz)'),
        const SizedBox(height: 6),
        FilledButton.icon(
          onPressed: creando ? null : onCrear,
          icon: const Icon(Icons.archive_rounded, size: 18),
          label: Text(creando ? 'cifrando…' : 'Crear molde'),
        ),
        if (estado.isNotEmpty) ...[
          const SizedBox(height: 6),
          SelectableText(estado,
              style: const TextStyle(fontSize: 12)),
        ],
      ],
    );
  }
}
