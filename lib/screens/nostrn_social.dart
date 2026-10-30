/// Nostrn+ · sección social: publicar/responder/citar/reaccionar/repost
/// (escritura vía sesión viva), artículo largo, contactos y notificaciones.
///
/// Widget separado del principal a propósito: recibe la sesión [gestion]
/// y devuelve logs por [onLog]; sin estado compartido oculto.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../src/rust/api/nostr_busca.dart' as rustb;
import '../src/rust/api/nostrn_gestion.dart' as rust;
import '../services/nostr_busca.dart';

class NostrnSocial extends StatefulWidget {
  final rust.GestionViva? gestion;
  final void Function(String linea) onLog;

  const NostrnSocial({super.key, required this.gestion, required this.onLog});

  @override
  State<NostrnSocial> createState() => _NostrnSocialState();
}

class _NostrnSocialState extends State<NostrnSocial> {
  final _buscaLectura = NostrBusca();

  final _postCtrl = TextEditingController();
  final _respIdCtrl = TextEditingController();
  final _respAutorCtrl = TextEditingController();
  final _citaCtrl = TextEditingController();
  final _artTituloCtrl = TextEditingController();
  final _artResumenCtrl = TextEditingController();
  final _artImagenCtrl = TextEditingController();
  final _artCuerpoCtrl = TextEditingController();
  final _seguirCtrl = TextEditingController();

  List<rustb.PostItem> _notificaciones = [];
  List<String> _seguidos = [];
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [
      _postCtrl,
      _respIdCtrl,
      _respAutorCtrl,
      _citaCtrl,
      _artTituloCtrl,
      _artResumenCtrl,
      _artImagenCtrl,
      _artCuerpoCtrl,
      _seguirCtrl,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _guard(Future<void> Function() f) async {
    if (_busy || widget.gestion == null) return;
    setState(() => _busy = true);
    try {
      await f();
    } catch (e) {
      widget.onLog('ERROR: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  TextField _tf(TextEditingController c, String hint,
          {int maxLines = 1, bool monospace = false}) =>
      TextField(
        controller: c,
        maxLines: maxLines,
        style: TextStyle(
            fontSize: 12, fontFamily: monospace ? 'monospace' : null),
        decoration: InputDecoration(
            hintText: hint, isDense: true, border: const OutlineInputBorder()),
      );

  Card _card(String title, Color color, List<Widget> children) => Card(
        color: color.withValues(alpha: .06),
        shape: Border(left: BorderSide(color: color, width: 3)),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: color)),
                const SizedBox(height: 8),
                ...children,
              ]),
        ),
      );

  // ------------------------------------------------------------- acciones

  Future<void> _publicar() => _guard(() async {
        final t = _postCtrl.text.trim();
        if (t.isEmpty) throw 'texto vacío';
        final idResp = _respIdCtrl.text.trim();
        final autor = _respAutorCtrl.text.trim();
        if (idResp.isNotEmpty != autor.isNotEmpty) {
          throw 'para responder necesito id Y autor: usá "copiar ID" '
              'en un post del muro (precarga ambos)';
        }
        String id;
        if (idResp.isNotEmpty && autor.isNotEmpty) {
          final cita = _citaCtrl.text.trim();
          id = cita.isNotEmpty
              ? await widget.gestion!
                  .citar(texto: t, idEvento: idResp, autor: autor, textoCitado: cita)
              : await widget.gestion!
                  .responder(texto: t, idEvento: idResp, autor: autor);
        } else {
          id = await widget.gestion!.postear(texto: t);
        }
        _postCtrl.clear();
        widget.onLog('✓ publicado $id');
      });

  Future<void> _reaccionar(rustb.PostItem p) => _guard(() async {
        await widget.gestion!.reaccionar(idEvento: p.idHex, autor: p.autorNpub);
        widget.onLog('+ enviado');
      });

  Future<void> _repost(rustb.PostItem p) => _guard(() async {
        await widget.gestion!.repost(idEvento: p.idHex, autor: p.autorNpub);
        widget.onLog('repost enviado');
      });

  Future<void> _responderDesde(rustb.PostItem p) => _guard(() async {
        _respIdCtrl.text = p.idHex;
        _respAutorCtrl.text = p.autorNpub;
        _citaCtrl.text =
            p.contenido.length > 200 ? p.contenido.substring(0, 200) : p.contenido;
        widget.onLog('respuesta precargada: completá tu texto arriba');
      });

  Future<void> _publicarArticulo() => _guard(() async {
        final id = await widget.gestion!.articuloPublicar(
          titulo: _artTituloCtrl.text.trim(),
          resumen: _artResumenCtrl.text.trim(),
          imagenUrl: _artImagenCtrl.text.trim(),
          cuerpo: _artCuerpoCtrl.text,
        );
        widget.onLog('✓ artículo $id');
      });

  Future<void> _refrescarSeguidos() => _guard(() async {
        final l = await widget.gestion!.seguidos();
        setState(() => _seguidos = l);
        widget.onLog('${l.length} seguidos');
      });

  Future<void> _toggleSeguir(bool seguir) => _guard(() async {
        final npub = _seguirCtrl.text.trim();
        if (npub.isEmpty) throw 'pegá un npub';
        final l = await widget.gestion!.seguir(npub: npub, seguir: seguir);
        setState(() => _seguidos = l);
        widget.onLog(seguir ? 'siguiendo ✓' : 'dejado de seguir ✓');
      });

  Future<void> _notifis() => _guard(() async {
        final me = await widget.gestion!.publicKey();
        final r = await _buscaLectura.notificaciones(miNpub: me, relays: const []);
        setState(() => _notificaciones = r);
        widget.onLog('${r.length} notificación(es)');
      });

  // ---------------------------------------------------------------- build

  String _fechaCorta(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.day}/${d.month}/${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final conectado = widget.gestion != null;
    return Column(children: [
      _card('6 · Publicar post', Colors.deepOrangeAccent, [
        _tf(_postCtrl, '¿qué estás pensando?', maxLines: 4),
        const SizedBox(height: 6),
        FilledButton.icon(
          onPressed: conectado && !_busy ? _publicar : null,
          icon: const Icon(Icons.send_rounded, size: 18),
          label: const Text('Publicar'),
        ),
        const SizedBox(height: 8),
        // opcionales SIEMPRE visibles: solo se usan si los llenás
        Row(children: [
          Expanded(child: _tf(_respIdCtrl,
              'id evento a responder (opcional)', monospace: true)),
          const SizedBox(width: 6),
          Expanded(child:
              _tf(_respAutorCtrl, 'npub del autor (opcional)',
                  monospace: true)),
        ]),
        const SizedBox(height: 6),
        _tf(_citaCtrl, 'fragmento a citar (opcional, vacío = responder)',
            maxLines: 2),
        const Text(
            'con solo texto = post normal · id+npub = responder/citar',
            style: TextStyle(fontSize: 9, color: Colors.white24)),
      ]),
      _card('7 · Artículo largo (kind 30023)', Colors.pinkAccent, [
        _tf(_artTituloCtrl, 'título *'),
        const SizedBox(height: 6),
        _tf(_artResumenCtrl, 'resumen'),
        const SizedBox(height: 6),
        _tf(_artImagenCtrl, 'imagen URL (https://…)', monospace: true),
        const SizedBox(height: 6),
        _tf(_artCuerpoCtrl, 'cuerpo markdown', maxLines: 8, monospace: true),
        const SizedBox(height: 6),
        FilledButton.icon(
          onPressed: conectado && !_busy ? _publicarArticulo : null,
          icon: const Icon(Icons.article_rounded, size: 18),
          label: const Text('Publicar artículo'),
        ),
      ]),
      _card('8 · Contactos (seguir)', Colors.limeAccent, [
        _tf(_seguirCtrl, 'npub a seguir / dejar de seguir', monospace: true),
        const SizedBox(height: 6),
        Wrap(spacing: 8, children: [
          FilledButton.tonalIcon(
              onPressed: conectado && !_busy ? () => _toggleSeguir(true) : null,
              icon: const Icon(Icons.person_add_rounded, size: 18),
              label: const Text('Seguir')),
          FilledButton.tonalIcon(
              onPressed:
                  conectado && !_busy ? () => _toggleSeguir(false) : null,
              icon: const Icon(Icons.person_remove_rounded, size: 18),
              label: const Text('Dejar')),
          FilledButton.tonalIcon(
              onPressed: conectado && !_busy ? _refrescarSeguidos : null,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: Text('Lista (${_seguidos.length})')),
        ]),
        for (final n in _seguidos.take(20))
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(n,
                style: const TextStyle(
                    fontSize: 9, fontFamily: 'monospace', color: Colors.white38)),
          ),
      ]),
      _card('9 · Notificaciones (quién te respondió/mencionó)',
          Colors.amberAccent, [
        FilledButton.icon(
          onPressed: conectado && !_busy ? _notifis : null,
          icon: const Icon(Icons.notifications_rounded, size: 18),
          label: const Text('Revisar'),
        ),
        for (final n in _notificaciones.take(20))
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(n.contenido,
                maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text(
                '${_fechaCorta(n.fechaMs)} · ${n.autorNpub}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 9, fontFamily: 'monospace')),
            trailing: IconButton(
              tooltip: 'copiar ID',
              icon: const Icon(Icons.copy_rounded, size: 16),
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: n.idHex)),
            ),
          ),
      ]),
    ]);
  }
}
