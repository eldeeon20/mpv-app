import 'package:flutter/material.dart';

import '../comun/campos.dart';
import '../media_server/media_server.dart';

/// Lista por directorios PEREZOSA (sliver): solo dibuja las filas
/// visibles, nunca construye todo de una (por eso no se detiene).
/// Sin preview (eso es Cuadrícula): al tocar visualiza.
class ListaArchivosSliver extends StatelessWidget {
  final List<FichaArchivo> archivos;
  final String? sel;
  final void Function(FichaArchivo f) onSel;
  final void Function(FichaArchivo f) onTags;
  final void Function(FichaArchivo f) onRecuperar;
  final void Function(FichaArchivo f) onBorrar;

  /// Cabeceras 📁 (en el explorador las apaga: ya están las migas).
  final bool cabeceras;

  const ListaArchivosSliver({
    super.key,
    required this.archivos,
    required this.sel,
    required this.onSel,
    required this.onTags,
    required this.onRecuperar,
    required this.onBorrar,
    this.cabeceras = true,
  });

  static String _corto(String nombre) {
    final i = nombre.lastIndexOf('/');
    return i < 0 ? nombre : nombre.substring(i + 1);
  }

  /// Aplana a items: cabecera de dir o ficha (barato, sin widgets).
  static List<Object> _aplanar(List<FichaArchivo> archivos) {
    final items = <Object>[];
    String? dirActual;
    for (final f in archivos) {
      final i = f.nombre.lastIndexOf('/');
      final dir = i <= 0 ? '/' : f.nombre.substring(0, i);
      if (dir != dirActual) {
        dirActual = dir;
        items.add(_Cabeza(dir));
      }
      items.add(f);
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final items =
        _aplanar(archivos).where((it) => cabeceras || it is! _Cabeza).toList();
    return SliverList.builder(
      itemCount: items.length,
      itemBuilder: (_, i) {
        final it = items[i];
        if (it is _Cabeza) {
          return Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text('📁 ${it.dir}',
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.bold)),
          );
        }
        final f = it as FichaArchivo;
        return ListTile(
          dense: true,
          contentPadding:
              const EdgeInsets.only(left: 24, right: 8),
          selected: sel == f.nombre,
          title: Text(_corto(f.nombre),
              style: const TextStyle(fontSize: 12)),
          subtitle: Text(
              '${f.formato} · ${fmtBytes(f.tamano)} · '
              '[${f.inicio}-${f.fin}]'
              '${f.tags.isEmpty ? '' : ' · ${f.tags.join(', ')}'}',
              style: const TextStyle(fontSize: 10)),
          onTap: () => onSel(f),
          trailing:
              Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              icon:
                  const Icon(Icons.label_outline_rounded, size: 18),
              tooltip: 'Editar tags (esta entrada SQL)',
              onPressed: () => onTags(f),
            ),
            Tooltip(
              message: 'Baja el archivo a Download',
              child: TextButton(
                onPressed: () => onRecuperar(f),
                child: const Text('Descargar',
                    style: TextStyle(fontSize: 11)),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded,
                  size: 18, color: Colors.redAccent),
              tooltip: 'Borrar entrada (popup)',
              onPressed: () => onBorrar(f),
            ),
          ]),
        );
      },
    );
  }
}

/// Cabecera de directorio en la lista aplanada.
class _Cabeza {
  final String dir;
  _Cabeza(this.dir);
}
