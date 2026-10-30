import 'package:flutter/material.dart';

import '../comun/campos.dart';
import '../media_server/media_server.dart';

/// Moldes como DIRECTORIOS navegables (no lista plana): se entra a
/// las carpetas y adentro están sus moldes. Las carpetas son SOLO del
/// índice (ni SQL ni .mld se tocan). Tap en molde = abrir solo ese.
class ListaMoldes extends StatefulWidget {
  final List<MoldeInfo> moldes;
  final String? abierta;
  final bool cargando;
  final VoidCallback onRecargar;
  final void Function(String nombre) onAbrir;
  final void Function(String nombre) onBorrar;

  /// Sin borrar (grid/lista): borrar es gestión de la pestaña Moldes.
  final bool conBorrar;

  /// En HF por molde (repo+versión): lo que ya está subido.
  final Map<String, ({String repo, int version})> hfInfo;
  final Set<String> telegramBotMoldes;

  /// Carpeta del índice por molde ('' = raíz). Sin esto, todo a raíz.
  final Map<String, String> carpetas;

  /// Mover a otra carpeta (null = sin botón: grid/lista).
  final void Function(String nombre)? onMover;

  /// Repo+token HF del molde (null = sin botón: grid/lista).
  /// Sin esto no se puede bajar lo subido (círculo: sin abrir no
  /// había dónde poner el token).
  final void Function(String nombre)? onHf;

  /// Selección múltiple para subir (vacío = sin modo selección).
  /// null = sin selección (grid/lista).
  final Set<String>? seleccion;
  final void Function(String nombre)? onToggleSel;

  /// Marcar/desmarcar todo lo de una carpeta (null = sin checks en carpetas).
  /// Le pasan los moldes de adentro (con todo lo anidado) y decide qué hacer.
  final void Function(List<String> dentro)? onToggleCarpeta;

  const ListaMoldes({
    super.key,
    required this.moldes,
    required this.abierta,
    required this.cargando,
    required this.onRecargar,
    required this.onAbrir,
    required this.onBorrar,
    this.conBorrar = true,
    this.hfInfo = const {},
    this.telegramBotMoldes = const {},
    this.carpetas = const {},
    this.onMover,
    this.onHf,
    this.seleccion,
    this.onToggleSel,
    this.onToggleCarpeta,
  });

  @override
  State<ListaMoldes> createState() => _ListaMoldesState();
}

class _ListaMoldesState extends State<ListaMoldes> {
  /// Carpeta vista ('' = raíz). Navegación interna del árbol.
  String _vista = '';

  String _carpetaDe(String nombre) =>
      (widget.carpetas[nombre] ?? '').replaceAll('\\', '/');

  @override
  Widget build(BuildContext context) {
    // Si la vista actual ya no existe (movieron todo afuera), a raíz.
    final hay = widget.moldes
        .any((m) => _carpetaDe(m.nombre) == _vista || _carpetaDe(m.nombre).startsWith('$_vista/'));
    final vista = (widget.moldes.isEmpty || hay || _subcarpetas(_vista).isNotEmpty) ? _vista : '';
    if (vista != _vista) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _vista = vista);
      });
    }
    final subs = _subcarpetas(vista);
    final mios = [
      for (final m in widget.moldes)
        if (_carpetaDe(m.nombre) == vista) m
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          if (vista.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.arrow_back_rounded, size: 18),
              tooltip: 'Subir',
              onPressed: () => setState(() => _vista = _padre(vista)),
            ),
          Expanded(
            child: Text(vista.isEmpty ? 'Moldes (carpetas)' : vista,
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded, size: 18),
            tooltip: 'Recargar',
            onPressed: widget.cargando ? null : widget.onRecargar,
          ),
        ]),
        if (widget.moldes.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('No hay moldes (tocá + para crear o indexá)',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ),
        for (final s in subs)
          _tileCarpeta(vista, s),
        for (final m in mios) _tile(context, m),
      ],
    );
  }

  /// Hijos directos (un nivel) de [vista].
  List<String> _subcarpetas(String vista) {
    final fuera = <String>{};
    for (final m in widget.moldes) {
      var c = _carpetaDe(m.nombre);
      if (vista.isEmpty) {
        final i = c.indexOf('/');
        fuera.add(i < 0 ? (c.isEmpty ? '' : c) : c.substring(0, i));
      } else {
        if (!c.startsWith('$vista/')) continue;
        final resto = c.substring(vista.length + 1);
        final i = resto.indexOf('/');
        fuera.add(i < 0 ? resto : resto.substring(0, i));
      }
    }
    fuera.remove('');
    final l = fuera.toList()..sort();
    return l;
  }

  String _padre(String vista) {
    final i = vista.lastIndexOf('/');
    return i < 0 ? '' : vista.substring(0, i);
  }

  /// Nombres de los moldes dentro de una subcarpeta (con todo lo anidado).
  List<String> _dentro(String sub) {
    final base = _vista.isEmpty ? sub : '$_vista/$sub';
    return [
      for (final m in widget.moldes)
        if (_carpetaDe(m.nombre) == base ||
            _carpetaDe(m.nombre).startsWith('$base/'))
          m.nombre
    ];
  }

  int _cuantos(String sub) {
    final base = _vista.isEmpty ? sub : '$_vista/$sub';
    var n = 0;
    for (final m in widget.moldes) {
      final c = _carpetaDe(m.nombre);
      if (c == base || c.startsWith('$base/')) n++;
    }
    return n;
  }

  /// Fila de carpeta: tap entra, y con checks activos el check marca o
  /// desmarca todo lo de adentro (con lo anidado). Long-press también
  /// marca/desmarca, igual que en los moldes.
  Widget _tileCarpeta(String vista, String s) {
    final conChecks =
        widget.seleccion != null && widget.onToggleCarpeta != null;
    final dentro = conChecks ? _dentro(s) : const <String>[];
    final marcados =
        conChecks ? dentro.where(widget.seleccion!.contains).length : 0;
    final todos = dentro.isNotEmpty && marcados == dentro.length;
    final algunos = marcados > 0 && !todos;

    void alternar() {
      if (dentro.isEmpty) return;
      widget.onToggleCarpeta!(dentro);
    }

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 0),
      child: ListTile(
        dense: true,
        leading: conChecks
            ? IconButton(
                icon: Icon(
                  todos
                      ? Icons.check_box_rounded
                      : (algunos
                          ? Icons.indeterminate_check_box_rounded
                          : Icons.check_box_outline_blank_rounded),
                  size: 28,
                  color: todos || algunos
                      ? Colors.lightBlueAccent
                      : Colors.grey,
                ),
                tooltip: todos ? 'Desmarcar todo' : 'Marcar todo',
                onPressed: alternar,
              )
            : const Icon(Icons.folder_rounded,
                size: 28, color: Colors.amber),
        title: Text(s,
            style:
                const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
        subtitle: Text(
            '${_cuantos(s)} molde(s)'
            '${conChecks && marcados > 0 ? ' · $marcados check' : ''}',
            style: const TextStyle(fontSize: 10)),
        trailing: const Icon(Icons.chevron_right_rounded, size: 20),
        selected: todos || algunos,
        onTap: () => setState(() => _vista =
            vista.isEmpty ? s : '$vista/$s'),
        onLongPress: conChecks ? alternar : null,
      ),
    );
  }

  Widget _tile(BuildContext context, MoldeInfo m) {
    final sel = widget.seleccion?.contains(m.nombre) ?? false;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        dense: true,
        leading: widget.seleccion == null
            ? const Icon(Icons.folder_rounded,
                size: 28, color: Colors.amber)
            : Icon(
                sel
                    ? Icons.check_box_rounded
                    : Icons.check_box_outline_blank_rounded,
                size: 28,
                color: sel ? Colors.lightBlueAccent : Colors.grey),
        selected: widget.abierta == m.nombre || sel,
        title: Row(children: [
          Expanded(
            child:
                Text(m.nombre, style: const TextStyle(fontSize: 13)),
          ),
          if (widget.hfInfo.containsKey(m.nombre))
            const Icon(Icons.cloud_done_rounded,
                size: 16, color: Colors.lightBlueAccent),
          if (widget.telegramBotMoldes.contains(m.nombre))
            const Padding(
              padding: EdgeInsets.only(left: 5),
              child: Icon(Icons.smart_toy_outlined,
                  size: 16, color: Colors.greenAccent),
            ),
        ]),
        subtitle: Text(
            fmtBytes(m.total) +
                (widget.hfInfo[m.nombre] == null
                    ? ''
                    : ' · ☁ ${widget.hfInfo[m.nombre]!.repo} '
                        'v${widget.hfInfo[m.nombre]!.version}') +
                (widget.telegramBotMoldes.contains(m.nombre)
                    ? ' · Telegram Bot'
                    : ''),
            style: const TextStyle(fontSize: 10)),
        // Tap = abrir SOLO este molde (no todos los del SQL).
        // En selección: tap marca/desmarca. Long-press inicia selección.
        onTap: () {
          if (widget.seleccion != null &&
              widget.seleccion!.isNotEmpty &&
              widget.onToggleSel != null) {
            widget.onToggleSel!(m.nombre);
          } else {
            widget.onAbrir(m.nombre);
          }
        },
        onLongPress: widget.onToggleSel == null
            ? null
            : () => widget.onToggleSel!(m.nombre),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (widget.onHf != null)
            IconButton(
              icon: const Icon(Icons.cloud_rounded,
                  size: 18, color: Colors.lightBlueAccent),
              tooltip: 'Repo+token HF (sin abrir)',
              onPressed: () => widget.onHf!(m.nombre),
            ),
          if (widget.onMover != null)
            IconButton(
              icon: const Icon(Icons.folder_shared,
                  size: 18, color: Colors.lightBlueAccent),
              tooltip: 'Mover de carpeta (solo índice)',
              onPressed: () => widget.onMover!(m.nombre),
            ),
          if (widget.conBorrar)
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded,
                  size: 18, color: Colors.redAccent),
              tooltip: 'Borrar molde',
              onPressed: () => widget.onBorrar(m.nombre),
            ),
        ]),
      ),
    );
  }
}
