import 'package:flutter/material.dart';

import '../media_server/media_server.dart';
import 'lista_archivos.dart';

/// Hijos de una ruta: subcarpetas inmediatas + archivos directos.
/// Ordenados. Lo usan grid y lista.
({List<String> subdirs, List<FichaArchivo> directos}) hijosDe(
    List<FichaArchivo> archivos, List<String> ruta) {
  final subdirs = <String>[];
  final directos = <FichaArchivo>[];
  for (final f in archivos) {
    final segs = f.nombre.split('/');
    final padre =
        segs.length <= 1 ? const <String>[] : segs.sublist(0, segs.length - 1);
    if (padre.length < ruta.length) continue;
    var ok = true;
    for (var i = 0; i < ruta.length; i++) {
      if (padre[i] != ruta[i]) {
        ok = false;
        break;
      }
    }
    if (!ok) continue;
    if (padre.length == ruta.length) {
      directos.add(f);
    } else if (!subdirs.contains(padre[ruta.length])) {
      subdirs.add(padre[ruta.length]);
    }
  }
  subdirs.sort();
  directos.sort((a, b) => a.nombre.compareTo(b.nombre));
  return (subdirs: subdirs, directos: directos);
}

/// Migas: 📁 / molde / sub / dir (tap = ir). La usan grid y lista.
/// [onSalir] cierra el molde y vuelve a los moldes (sin esto no se
/// sale más una vez adentro).
Widget migasRuta({
  required String molde,
  required List<String> ruta,
  required void Function(List<String> nueva) onRuta,
  VoidCallback? onSalir,
}) {
  return Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      if (onSalir != null)
        ActionChip(
          label: const Text('📁 Moldes',
              style: TextStyle(fontSize: 11)),
          onPressed: onSalir,
        ),
      ActionChip(
        label: Text(molde, style: const TextStyle(fontSize: 11)),
        onPressed: () => onRuta(const []),
      ),
      for (var i = 0; i < ruta.length; i++) ...[
        const Text(' / ', style: TextStyle(color: Colors.grey)),
        ActionChip(
          label: Text(ruta[i], style: const TextStyle(fontSize: 11)),
          onPressed: () => onRuta(ruta.sublist(0, i + 1)),
        ),
      ],
    ],
  );
}

/// Explorador del molde: sus carpetas nativas, se entra y se sale.
/// Devuelve slivers para el scroll libre de la pestaña.
List<Widget> sliversExplorador({
  required String molde,
  required List<FichaArchivo> archivos,
  required List<String> ruta,
  required void Function(List<String> nueva) onRuta,
  required String? sel,
  required void Function(FichaArchivo f) onSel,
  required void Function(FichaArchivo f) onTags,
  required void Function(FichaArchivo f) onRecuperar,
  required void Function(FichaArchivo f) onBorrar,
  VoidCallback? onSalir,
}) {
  final hijos = hijosDe(archivos, ruta);
  final subdirs = hijos.subdirs;
  final directos = hijos.directos;
  return [
    // Migas: molde / sub / dir (tap = ir).
    SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: migasRuta(
            molde: molde, ruta: ruta, onRuta: onRuta, onSalir: onSalir),
      ),
    ),
    // Carpetas para entrar.
    SliverList.builder(
      itemCount: subdirs.length,
      itemBuilder: (_, i) => Card(
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: ListTile(
          dense: true,
          leading: const Icon(Icons.folder_rounded,
              size: 26, color: Colors.amber),
          title: Text(subdirs[i],
              style: const TextStyle(fontSize: 13)),
          trailing: const Icon(Icons.chevron_right_rounded,
              color: Colors.grey),
          onTap: () => onRuta([...ruta, subdirs[i]]),
        ),
      ),
    ),
    // Archivos de esta carpeta (tap = preview).
    SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 0),
      sliver: ListaArchivosSliver(
        archivos: directos,
        sel: sel,
        cabeceras: false,
        onSel: onSel,
        onTags: onTags,
        onRecuperar: onRecuperar,
        onBorrar: onBorrar,
      ),
    ),
  ];
}
