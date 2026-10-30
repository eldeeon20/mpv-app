import 'package:flutter/material.dart';

/// Comunes chicos: formato de bytes, campo de texto y vacío con +.

String fmtBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

Widget campoTexto(TextEditingController c, String hint,
    {bool oculto = false, void Function(String)? onChanged}) {
  return TextField(
    controller: c,
    obscureText: oculto,
    onChanged: onChanged,
    style: const TextStyle(fontSize: 12),
    decoration: InputDecoration(
        hintText: hint, isDense: true, border: const OutlineInputBorder()),
  );
}

/// Estado vacío con botón + (ir a crear/abrir).
class VacioConMas extends StatelessWidget {
  final String texto;
  final String boton;
  final VoidCallback onMas;

  const VacioConMas({
    super.key,
    required this.texto,
    required this.boton,
    required this.onMas,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        const SizedBox(height: 48),
        const Icon(Icons.photo_library_outlined,
            size: 64, color: Colors.grey),
        const SizedBox(height: 12),
        Center(
          child: Text(
            texto,
            style:
                const TextStyle(fontSize: 14, color: Colors.grey),
          ),
        ),
        const SizedBox(height: 12),
        Center(
          child: FilledButton.icon(
            onPressed: onMas,
            icon: const Icon(Icons.add_rounded),
            label: Text(boton),
          ),
        ),
      ],
    );
  }
}
