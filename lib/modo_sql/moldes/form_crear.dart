import 'package:flutter/material.dart';

import '../comun/campos.dart';
import '../media_server/claves_molde_v3.dart';
import '../media_server/duro.dart';

/// Solo crear molde (carpeta → un solo .mld). La clave vive en Moldes.
class FormCrear extends StatelessWidget {
  final TextEditingController nombre;
  final TextEditingController carpeta;
  final TextEditingController clave;
  final TextEditingController tags;
  final String modoCifrado;

  /// Carpeta DESTINO en el índice (opcional, '' = raíz). El molde
  /// nace ya anidado ahí (solo índice, no toca archivos).
  final TextEditingController carpetaIndice;
  final bool creando;
  final String estado;
  final VoidCallback onElegir;
  final VoidCallback onCrear;
  final ValueChanged<String> onModoCifradoChanged;

  const FormCrear({
    super.key,
    required this.nombre,
    required this.carpeta,
    required this.clave,
    required this.tags,
    required this.modoCifrado,
    required this.carpetaIndice,
    required this.creando,
    required this.estado,
    required this.onElegir,
    required this.onCrear,
    required this.onModoCifradoChanged,
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
          FilledButton.tonal(onPressed: onElegir, child: const Text('Elegir…')),
        ]),
        const SizedBox(height: 6),
        campoTexto(clave, 'clave ÚNICA (tu SQL + molde)', oculto: true),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          initialValue: modoCifrado,
          decoration: InputDecoration(
            labelText: 'Modo de cifrado del molde',
            isDense: true,
            border: OutlineInputBorder(),
            helperText: modoCifrado == ClavesMoldeV3.marker
                ? 'Argon2id usa 128 MiB de RAM temporal al crear/abrir; no limita el tamaño del molde.'
                : 'Modo compatible: aplica PBKDF2 a cada archivo.',
          ),
          items: const [
            DropdownMenuItem(
              value: Duro.modoV2,
              child: Text('v2 · compatible (PBKDF2 por archivo)'),
            ),
            DropdownMenuItem(
              value: ClavesMoldeV3.marker,
              child: Text('v3 · Argon2id 128 MiB + claves rápidas por archivo'),
            ),
          ],
          onChanged: creando
              ? null
              : (value) {
                  if (value != null) onModoCifradoChanged(value);
                },
        ),
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
          SelectableText(estado, style: const TextStyle(fontSize: 12)),
        ],
      ],
    );
  }
}
