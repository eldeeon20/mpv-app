import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../media/media_player.dart';

String _fmt(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '${d.inHours > 0 ? '${d.inHours}:$m' : m}:$s';
}

/// Fecha corta de un ts en millis (o '' si no hay).
String _fmtFecha(String ts) {
  final ms = int.tryParse(ts);
  if (ms == null) return '';
  final f = DateTime.fromMillisecondsSinceEpoch(ms);
  final d = '${f.day.toString().padLeft(2, '0')}/${f.month.toString().padLeft(2, '0')}/${f.year}';
  final h = '${f.hour.toString().padLeft(2, '0')}:${f.minute.toString().padLeft(2, '0')}';
  return '$d $h';
}

String _titleOf(String path) =>
    path.split('/').last.split('\\').last.split('?').first;

/// Pantalla de Media con 4 vistas: Ahora / Listas / Historial / Favoritos.
///
/// - Ahora: player con video, progreso, controles y la cola actual
///   (los archivos elegidos se ven acá, con estrella al momento).
/// - Listas: playlists y grupos creados por el usuario.
/// - Historial: últimas reproducciones (cifrado en disco), con buscador;
///   tocar reproduce y salta a Ahora, la estrella marca favorito.
/// - Favoritos: solo los marcados, con buscador y reproducir-todo.
class MediaScreen extends StatefulWidget {
  final MediaPlayer mediaPlayer;
  const MediaScreen({super.key, required this.mediaPlayer});

  @override
  State<MediaScreen> createState() => _MediaScreenState();
}

class _MediaScreenState extends State<MediaScreen> {
  bool _hasVideo = false;
  bool _playing = false;
  double? _dragValue;
  final _subs = <StreamSubscription>[];
  final _searchHistCtrl = TextEditingController();
  final _searchFavCtrl = TextEditingController();
  String _queryHist = '';
  String _queryFav = '';

  @override
  void initState() {
    super.initState();
    widget.mediaPlayer.onChanged = () {
      if (mounted) setState(() {});
    };
    // Estado inicial REAL del player (el audio/video sigue en segundo plano).
    _hasVideo = widget.mediaPlayer.hasVideo;
    _playing = widget.mediaPlayer.isPlaying;
    _subs.add(widget.mediaPlayer.widthStream.listen((w) {
      if (mounted) setState(() => _hasVideo = (w ?? 0) > 0);
    }));
    _subs.add(widget.mediaPlayer.playingStream.listen((p) {
      if (mounted) setState(() => _playing = p);
    }));
    // Biblioteca (historial + favoritos + listas + grupos) desde disco cifrado.
    widget.mediaPlayer.library.load().then((_) {
      if (mounted) setState(() {});
    });
    _searchHistCtrl.addListener(() {
      if (mounted) setState(() => _queryHist = _searchHistCtrl.text.trim());
    });
    _searchFavCtrl.addListener(() {
      if (mounted) setState(() => _queryFav = _searchFavCtrl.text.trim());
    });
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _searchHistCtrl.dispose();
    _searchFavCtrl.dispose();
    super.dispose();
  }

  List<Map<String, String>> _filter(
      List<Map<String, String>> items, String q) {
    if (q.isEmpty) return items;
    final lq = q.toLowerCase();
    return items
        .where((e) =>
            (e['title'] ?? '').toLowerCase().contains(lq) ||
            (e['uri'] ?? '').toLowerCase().contains(lq))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final mp = widget.mediaPlayer;
    return DefaultTabController(
      length: 4,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.center,
            tabs: [
              const Tab(icon: Icon(Icons.play_circle), text: 'Ahora'),
              Tab(
                  icon: const Icon(Icons.queue_music),
                  text: 'Listas (${mp.library.playlists.length})'),
              Tab(
                  icon: const Icon(Icons.history),
                  text: 'Historial (${mp.library.history.length})'),
              Tab(
                  icon: const Icon(Icons.star),
                  text: 'Favoritos (${mp.library.favorites.length})'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                SingleChildScrollView(child: _buildNow()),
                _buildLists(),
                _buildHistory(),
                _buildFavorites(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // Vista AHORA (player + cola)
  // ===========================================================================

  Widget _buildNow() {
    final mp = widget.mediaPlayer;
    final fav = mp.isCurrentFavorite;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_hasVideo)
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Video(controller: mp.videoController),
            )
          else
            Container(
              height: 120,
              decoration: BoxDecoration(
                color: Colors.grey[900],
                borderRadius: BorderRadius.circular(12),
              ),
              child:
                  const Icon(Icons.music_note, size: 56, color: Colors.grey),
            ),
          const SizedBox(height: 8),
          Text(mp.status,
              style: const TextStyle(fontSize: 13, color: Colors.grey)),
          if (mp.current.isNotEmpty)
            Row(
              children: [
                Expanded(
                  child: Text(_titleOf(mp.current),
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.bold),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
                IconButton(
                  tooltip: fav ? 'Quitar de favoritos' : 'Marcar favorito',
                  onPressed: () async {
                    await mp.toggleCurrentFavorite();
                    if (mounted) setState(() {});
                  },
                  icon: Icon(fav ? Icons.star : Icons.star_border,
                      color: fav ? Colors.amber : Colors.grey),
                ),
                IconButton(
                  tooltip: 'Agregar a lista',
                  onPressed: () => _dialogoAgregarALista(context, mp.current),
                  icon: const Icon(Icons.playlist_add, color: Colors.grey),
                ),
              ],
            ),
          StreamBuilder<Duration>(
            stream: mp.durationStream,
            initialData: mp.duration,
            builder: (context, durSnap) {
              final dur = durSnap.data ?? Duration.zero;
              return StreamBuilder<Duration>(
                stream: mp.positionStream,
                initialData: mp.position,
                builder: (context, posSnap) {
                  final posMs = _dragValue ??
                      (posSnap.data ?? Duration.zero).inMilliseconds
                          .toDouble();
                  final durMs =
                      dur.inMilliseconds > 0 ? dur.inMilliseconds : 1;
                  return Column(
                    children: [
                      Slider(
                        min: 0,
                        max: durMs.toDouble(),
                        value: posMs.clamp(0, durMs.toDouble()),
                        onChanged: durMs <= 1
                            ? null
                            : (v) => setState(() => _dragValue = v),
                        onChangeEnd: (v) async {
                          await mp.seek(Duration(milliseconds: v.round()));
                          if (mounted) setState(() => _dragValue = null);
                        },
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(_fmt(Duration(milliseconds: posMs.round())),
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.grey)),
                          Text(_fmt(dur),
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.grey)),
                        ],
                      ),
                    ],
                  );
                },
              );
            },
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: () => mp.pickAndPlay(),
                icon: const Icon(Icons.folder_open),
                label: const Text('Abrir lista'),
              ),
              const SizedBox(width: 12),
              if (mp.queueLength > 1) ...[
                IconButton(
                  onPressed: () => mp.previous(),
                  icon: const Icon(Icons.skip_previous, size: 32),
                ),
                Text('${mp.queueIndex + 1}/${mp.queueLength}',
                    style:
                        const TextStyle(fontSize: 12, color: Colors.grey)),
                IconButton(
                  onPressed: () => mp.next(),
                  icon: const Icon(Icons.skip_next, size: 32),
                ),
                const SizedBox(width: 8),
              ],
              IconButton(
                onPressed: () => mp.playOrPause(),
                icon: Icon(_playing ? Icons.pause : Icons.play_arrow,
                    size: 32),
              ),
              IconButton(
                onPressed: () => mp.stop(),
                icon: const Icon(Icons.stop, size: 32),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _buildQueue(),
        ],
      ),
    );
  }

  /// Cola actual: los archivos elegidos, visibles y tocables.
  Widget _buildQueue() {
    final mp = widget.mediaPlayer;
    if (mp.cola.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text('Cola actual (${mp.queueLength})',
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.bold)),
        ),
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: mp.cola.length,
          itemBuilder: (context, i) {
            final uri = mp.cola[i];
            return _mediaTile(
              {'uri': uri, 'title': _titleOf(uri)},
              showDate: false,
              dismissible: false,
              leadingNumber: i + 1,
              onTap: () => mp.playAt(i),
            );
          },
        ),
      ],
    );
  }

  // ===========================================================================
  // Vista LISTAS (playlists + grupos)
  // ===========================================================================

  Widget _buildLists() {
    final mp = widget.mediaPlayer;
    final lib = mp.library;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: () => _dialogoTexto(
                  context,
                  titulo: 'Nueva lista',
                  ayuda: 'Nombre de la lista',
                  onOk: (v) => lib.createPlaylist(v),
                ),
                icon: const Icon(Icons.playlist_add),
                label: const Text('Nueva lista'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _dialogoTexto(
                  context,
                  titulo: 'Nuevo grupo',
                  ayuda: 'Nombre del grupo',
                  onOk: (v) => lib.createGroup(v),
                ),
                icon: const Icon(Icons.folder_open),
                label: const Text('Nuevo grupo'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        const Text('Grupos',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
        if (lib.groups.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Text('Sin grupos: agrupá tus listas por tema.',
                style: TextStyle(color: Colors.grey, fontSize: 12)),
          ),
        for (final g in lib.groups) _grupoTile(g),
        const SizedBox(height: 8),
        const Text('Listas',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
        if (lib.playlists.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Text(
                'Sin listas: creá una y agregale el tema actual o favoritos.',
                style: TextStyle(color: Colors.grey, fontSize: 12)),
          ),
        for (final p in lib.playlists) _listaTile(p),
      ],
    );
  }

  Widget _grupoTile(Map<String, dynamic> g) {
    final lib = widget.mediaPlayer.library;
    final id = '${g['id']}';
    final ids = lib.groupPlaylistIds(id);
    return Card(
      child: ExpansionTile(
        leading: const Icon(Icons.folder, color: Colors.orangeAccent),
        title: Text('${g['name']}'),
        subtitle: Text('${ids.length} listas'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Renombrar grupo',
              icon: const Icon(Icons.edit, size: 20),
              onPressed: () => _dialogoTexto(
                context,
                titulo: 'Renombrar grupo',
                inicial: '${g['name']}',
                onOk: (v) => lib.renameGroup(id, v),
              ),
            ),
            IconButton(
              tooltip: 'Borrar grupo',
              icon: const Icon(Icons.delete, size: 20),
              onPressed: () => lib.deleteGroup(id),
            ),
          ],
        ),
        children: [
          for (final pid in ids)
            if (lib.playlist(pid) != null)
              ListTile(
                leading: const Icon(Icons.queue_music, size: 20),
                title: Text('${lib.playlist(pid)!['name']}',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                    '${lib.playlistItems(pid).length} temas'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Reproducir lista',
                      icon: const Icon(Icons.play_arrow),
                      onPressed: () async {
                        final tab = DefaultTabController.of(context);
                        await widget.mediaPlayer
                            .playPlaylist(lib.playlistUris(pid));
                        if (mounted) tab.animateTo(0);
                      },
                    ),
                    IconButton(
                      tooltip: 'Sacar del grupo',
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: () => lib.groupRemove(id, pid),
                    ),
                  ],
                ),
              ),
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('Agregar lista al grupo'),
            onTap: () => _dialogoElegirLista(
              context,
              titulo: 'Agregar a ${g['name']}',
              excluir: ids.toSet(),
              onElegir: (pid) => lib.groupAdd(id, pid),
            ),
          ),
        ],
      ),
    );
  }

  Widget _listaTile(Map<String, dynamic> p) {
    final mp = widget.mediaPlayer;
    final lib = mp.library;
    final id = '${p['id']}';
    final items = lib.playlistItems(id);
    final uris = items
        .map((e) => e['uri'] ?? '')
        .where((u) => u.isNotEmpty)
        .toList();
    return Card(
      child: ExpansionTile(
        leading:
            const Icon(Icons.queue_music, color: Colors.lightBlueAccent),
        title: Text('${p['name']}'),
        subtitle: Text('${items.length} temas'),
        trailing: PopupMenuButton<String>(
          onSelected: (v) async {
            switch (v) {
              case 'play':
                final tab = DefaultTabController.of(context);
                await mp.playPlaylist(uris);
                if (mounted) tab.animateTo(0);
              case 'actual':
                if (mp.current.isNotEmpty) {
                  await lib.playlistAdd(id, mp.current);
                }
              case 'favs':
                for (final f in lib.favorites) {
                  await lib.playlistAdd(id, f['uri'] ?? '',
                      title: f['title']);
                }
              case 'renombrar':
                if (mounted) {
                  _dialogoTexto(
                    context,
                    titulo: 'Renombrar lista',
                    inicial: '${p['name']}',
                    onOk: (n) => lib.renamePlaylist(id, n),
                  );
                }
              case 'borrar':
                await lib.deletePlaylist(id);
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(
                value: 'play',
                child: Text('Reproducir todo')),
            PopupMenuItem(
                value: 'actual',
                child: Text('Agregar tema actual')),
            PopupMenuItem(
                value: 'favs',
                child: Text('Agregar favoritos')),
            PopupMenuItem(
                value: 'renombrar',
                child: Text('Renombrar')),
            PopupMenuItem(
                value: 'borrar',
                child: Text('Borrar lista')),
          ],
        ),
        children: [
          if (items.isEmpty)
            const ListTile(
              title: Text('Vacía: usá el menú (⋮) para agregar temas.',
                  style: TextStyle(color: Colors.grey, fontSize: 12)),
            ),
          for (var i = 0; i < items.length; i++)
            _mediaTile(
              items[i],
              showDate: false,
              dismissKey: 'lista-$id-${items[i]['uri']}',
              onTap: () async {
                final tab = DefaultTabController.of(context);
                await mp.playPlaylist(uris, startAt: i);
                if (mounted) tab.animateTo(0);
              },
              onRemove: () => lib.playlistRemove(
                  id, items[i]['uri'] ?? ''),
            ),
        ],
      ),
    );
  }

  // ===========================================================================
  // Vista HISTORIAL
  // ===========================================================================

  Widget _buildHistory() {
    final mp = widget.mediaPlayer;
    final items = _filter(mp.library.history, _queryHist);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            controller: _searchHistCtrl,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Buscar en historial...',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        if (mp.library.history.isNotEmpty)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => mp.library.clearHistory(),
              icon: const Icon(Icons.delete_sweep, size: 18),
              label: const Text('Borrar historial'),
            ),
          ),
        Expanded(
          child: items.isEmpty
              ? const Center(
                  child: Text('Sin reproducciones todavía',
                      style: TextStyle(color: Colors.grey)))
              : ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, i) => _mediaTile(
                    items[i],
                    showDate: true,
                    onTap: () async {
                      final tab = DefaultTabController.of(context);
                      await mp.openPath(items[i]['uri'] ?? '');
                      if (mounted) tab.animateTo(0);
                    },
                  ),
                ),
        ),
      ],
    );
  }

  // ===========================================================================
  // Vista FAVORITOS
  // ===========================================================================

  Widget _buildFavorites() {
    final mp = widget.mediaPlayer;
    final items = _filter(mp.library.favorites, _queryFav);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            controller: _searchFavCtrl,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Buscar en favoritos...',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        if (mp.library.favorites.isNotEmpty)
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                onPressed: () async {
                  final tab = DefaultTabController.of(context);
                  final uris = mp.library.favorites
                      .map((e) => e['uri'] ?? '')
                      .where((u) => u.isNotEmpty)
                      .toList();
                  await mp.playPlaylist(uris);
                  if (mounted) tab.animateTo(0);
                },
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('Reproducir todo'),
              ),
              TextButton.icon(
                onPressed: () => mp.library.clearFavorites(),
                icon: const Icon(Icons.delete_sweep, size: 18),
                label: const Text('Borrar favoritos'),
              ),
            ],
          ),
        Expanded(
          child: items.isEmpty
              ? const Center(
                  child: Text('Sin favoritos: marcá la estrella al reproducir',
                      style: TextStyle(color: Colors.grey)))
              : ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, i) => _mediaTile(
                    items[i],
                    showDate: false,
                    onTap: () async {
                      final tab = DefaultTabController.of(context);
                      await mp.openPath(items[i]['uri'] ?? '');
                      if (mounted) tab.animateTo(0);
                    },
                  ),
                ),
        ),
      ],
    );
  }

  // ===========================================================================
  // Fila de tema (estrella al momento en todas las vistas)
  // ===========================================================================

  /// Fila de historial/favorito/cola/lista: tocar reproduce, la estrella
  /// alterna favorito y se refleja AL MOMENTO en todas las vistas porque
  /// la biblioteca avisa al player ([MediaPlayer.onChanged]).
  Widget _mediaTile(
    Map<String, String> e, {
    required bool showDate,
    bool dismissible = true,
    String? dismissKey,
    int? leadingNumber,
    Future<void> Function()? onTap,
    Future<void> Function()? onRemove,
  }) {
    final mp = widget.mediaPlayer;
    final uri = e['uri'] ?? '';
    final title = e['title'] ?? uri;
    final fav = mp.library.isFavorite(uri);
    final isCurrent = mp.current == uri;
    final tile = ListTile(
      leading: leadingNumber != null && !isCurrent
          ? CircleAvatar(
              radius: 12,
              child: Text('$leadingNumber',
                  style: const TextStyle(fontSize: 11)),
            )
          : Icon(
              isCurrent ? Icons.play_circle_fill : Icons.music_note,
              color: isCurrent ? Colors.greenAccent : Colors.grey,
            ),
      title: Text(title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontWeight:
                  isCurrent ? FontWeight.bold : FontWeight.normal)),
      subtitle: Text(
          showDate && (e['ts'] ?? '').isNotEmpty
              ? '${_fmtFecha(e['ts'] ?? '')} · $uri'
              : uri,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: IconButton(
        tooltip: fav ? 'Quitar de favoritos' : 'Marcar favorito',
        onPressed: () => mp.library.toggleFavorite(uri, title: title),
        icon: Icon(fav ? Icons.star : Icons.star_border,
            color: fav ? Colors.amber : Colors.grey),
      ),
      onTap: onTap == null ? () => mp.openPath(uri) : () => onTap(),
    );
    if (!dismissible && onRemove == null) return tile;
    return Dismissible(
      key: ValueKey(dismissKey ?? 'media-$showDate-$uri'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Colors.red[900],
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      onDismissed: (_) {
        if (onRemove != null) {
          onRemove();
        } else if (showDate) {
          mp.library.removeHistory(uri);
        } else {
          mp.library.toggleFavorite(uri);
        }
      },
      child: tile,
    );
  }

  // ===========================================================================
  // Diálogos (crear/renombrar, elegir lista, agregar a lista)
  // ===========================================================================

  /// Pide un texto (crear/renombrar lista o grupo).
  Future<void> _dialogoTexto(
    BuildContext context, {
    required String titulo,
    String ayuda = '',
    String inicial = '',
    required Future<void> Function(String) onOk,
  }) async {
    final ctrl = TextEditingController(text: inicial);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(titulo),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(hintText: ayuda),
          onSubmitted: (_) => Navigator.of(context).pop(true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    final v = ctrl.text;
    ctrl.dispose();
    if (ok == true && v.trim().isNotEmpty && mounted) {
      await onOk(v);
    }
  }

  /// Elige una lista existente (para agregar un tema o meterla a un grupo).
  Future<void> _dialogoElegirLista(
    BuildContext context, {
    required String titulo,
    Set<String> excluir = const {},
    required Future<void> Function(String) onElegir,
  }) async {
    final lib = widget.mediaPlayer.library;
    final listas =
        lib.playlists.where((p) => !excluir.contains('${p['id']}')).toList();
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(titulo),
        content: SizedBox(
          width: double.maxFinite,
          child: listas.isEmpty
              ? const Text('No hay listas disponibles.',
                  style: TextStyle(color: Colors.grey))
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: listas.length,
                  itemBuilder: (_, i) => ListTile(
                    leading: const Icon(Icons.queue_music),
                    title: Text('${listas[i]['name']}',
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () async {
                      final pid = '${listas[i]['id']}';
                      Navigator.of(context).pop();
                      await onElegir(pid);
                    },
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  /// Agrega un tema a una lista (creándola si hace falta).
  Future<void> _dialogoAgregarALista(BuildContext context, String uri) async {
    final lib = widget.mediaPlayer.library;
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Agregar a lista'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('Nueva lista...'),
                onTap: () {
                  Navigator.of(context).pop();
                  _dialogoTexto(
                    context,
                    titulo: 'Nueva lista',
                    ayuda: 'Nombre de la lista',
                    onOk: (n) async {
                      final id = await lib.createPlaylist(n);
                      if (id.isNotEmpty) {
                        await lib.playlistAdd(id, uri);
                      }
                    },
                  );
                },
              ),
              for (final p in lib.playlists)
                ListTile(
                  leading: const Icon(Icons.queue_music),
                  title: Text('${p['name']}',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: lib.playlistHas('${p['id']}', uri)
                      ? const Icon(Icons.check,
                          color: Colors.greenAccent, size: 20)
                      : null,
                  onTap: () async {
                    Navigator.of(context).pop();
                    await lib.playlistAdd('${p['id']}', uri);
                  },
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }
}
