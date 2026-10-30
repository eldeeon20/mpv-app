part of '../mediablock_screen.dart';

/// Extensión de MediaBlockScreen (ver mediablock_screen.dart).
extension ArchivosMbExt on _MediaBlockScreenState {
  Future<void> _pedirRango() async {
    final molde = _infoAbierta?.nombre;
    final a = _selArchivo;
    if (molde == null || a == null) return;
    final desde = int.tryParse(_desdeCtrl.text.trim()) ?? -1;
    final hasta = int.tryParse(_hastaCtrl.text.trim()) ?? -1;
    final texto = await pedirRangoTexto(
      claveSql: _clave,
      molde: molde,
      archivo: a,
      desde: desde,
      hasta: hasta,
      cache: _cache,
      info: _infoAbierta,
      filas: _filas,
    );
    if (!mounted) return;
    setState(() => _rangoInfo = texto);
  }

  Future<void> _pedirArchivo() async {
    final molde = _infoAbierta?.nombre;
    final a = _selArchivo;
    if (molde == null || a == null) return;
    FichaArchivo? ficha;
    for (final f in _filas) {
      if (f.nombre == a) {
        ficha = f;
        break;
      }
    }
    if (ficha == null) return;
    final texto = await pedirArchivoTexto(
      claveSql: _clave,
      molde: molde,
      ficha: ficha,
      cache: _cache,
      info: _infoAbierta,
      filas: _filas,
    );
    if (!mounted) return;
    setState(() => _rangoInfo = texto);
  }

  static const _imgs = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'avif'};
  static const _textos = {
    'txt',
    'md',
    'json',
    'log',
    'csv',
    'xml',
    'html',
    'css',
    'js',
    'srt',
    'vtt',
    'ini',
    'cfg',
    'yaml',
    'yml',
    'py',
    'dart',
    'sh',
    'java',
    'kt',
    'c',
    'h',
    'cpp',
    'rs',
    'go',
    'rb',
    'php',
    'sql',
    'toml',
    'lua'
  };

  /// Recupera un archivo en RAM (descifrado desde su rango SQL) y lo
  /// abre en diálogo: imagen → vista, texto → texto, resto → aviso.
  Future<void> _recuperar(FichaArchivo f) async {
    final molde = _infoAbierta?.nombre;
    if (molde == null) return;
    if (f.tamano == 0) {
      _add('· "${f.nombre}" vacío (0 bytes, nada que recuperar)');
      return;
    }
    if (f.tamano > 15 * 1024 * 1024) {
      _add('✗ recuperar "${f.nombre}": ${fmtBytes(f.tamano)}, muy grande '
          'para RAM (pedí por rangos)');
      return;
    }
    // Imágenes → visor pantalla completa con swipe (principal).
    if (_imgs.contains(f.formato.toLowerCase())) {
      final lista = _soloImgs(_filtrados());
      final vista = lista.isEmpty ? [f] : lista;
      var idx = vista.indexWhere((x) => x.nombre == f.nombre);
      if (idx < 0) idx = 0;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => Dialog(
          insetPadding: EdgeInsets.zero,
          backgroundColor: Colors.black,
          child: VisorPreview(
            imagenes: vista,
            indiceInicial: idx,
            cargar: _bytesCompletos,
            tagsDe: _tagsFrescos,
            onTags: (a) => _editarTags(a),
            onGuardar: (a, b) => _guardarCopia(a.nombre, b),
          ),
        ),
      );
      return;
    }
    late final List<int> datos;
    try {
      // Tu SQL dice el rango, la caché/server da crudo, vos descifrás.
      datos = await CreateMoldeSql.pedirRango(
        claveSql: _clave,
        molde: molde,
        archivo: f.nombre,
        desde: 0,
        hasta: f.tamano,
        cache: _cache,
        info: _infoAbierta,
        filas: _filas,
      );
      if (_cache != null) _add('· ${_cache!.resumen()}');
    } catch (e) {
      _add('✗ recuperar: $e');
      return;
    }
    if (!mounted) return;
    final copia = Uint8List.fromList(datos);
    await mostrarVistaArchivo(
      context: context,
      f: f,
      datos: copia,
      imgs: _imgs,
      textos: _textos,
      onTags: () => _editarTags(f),
      tagsFrescos: () {
        for (final x in _filas) {
          if (x.nombre == f.nombre) return x.tags.join(', ');
        }
        return f.tags.join(', ');
      },
      onGuardarCopia: () => _guardarCopia(f.nombre, copia),
    );
  }

  /// Visor de video: sus 17 previas en transición + tags,
  /// reproducir (copia local a la app + reproductor) o guardar
  /// en Descargas (como las fotos).
  /// Tap = contenido o nada: abre con los frames listos.
  Future<void> _verVideo(FichaArchivo f) async {
    final molde = _infoAbierta?.nombre;
    if (molde == null || !mounted) return;
    final frames = await _previasDe(f);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: EdgeInsets.zero,
        backgroundColor: Colors.black,
        child: Column(
          children: [
            AppBar(
              backgroundColor: Colors.black,
              title: Text(f.nombre, style: const TextStyle(fontSize: 13)),
              leading: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(ctx),
              ),
            ),
            Expanded(
              child: frames.isNotEmpty
                  ? CiclaPrevia(frames: frames)
                  : const Icon(Icons.movie_rounded,
                      size: 64, color: Colors.grey),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                spacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _editarTags(f);
                    },
                    icon: const Icon(Icons.label_rounded, size: 18),
                    label: const Text('Tags'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _reproducirVideo(f);
                    },
                    icon: const Icon(Icons.play_arrow_rounded, size: 18),
                    label: const Text('Reproducir'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _recuperar(f);
                    },
                    icon: const Icon(Icons.download_rounded, size: 18),
                    label: const Text('Guardar'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Reproduce un video: copia descifrada local en la app +
  /// diálogo con player propio (con surface: se VE, no solo audio).
  Future<void> _reproducirVideo(FichaArchivo f) async {
    final molde = _infoAbierta?.nombre;
    if (molde == null) return;
    if (f.tamano > 500 * 1024 * 1024) {
      _add('✗ reproducir "${f.nombre}": ${fmtBytes(f.tamano)}, '
          'muy grande para RAM (bajalo por rangos)');
      return;
    }
    _add('· preparando video "${f.nombre}"…');
    try {
      final datos = await CreateMoldeSql.pedirRango(
        claveSql: _clave,
        molde: molde,
        archivo: f.nombre,
        desde: 0,
        hasta: f.tamano,
        cache: _cache,
        info: _infoAbierta,
        filas: _filas,
      );
      final dir = await getApplicationSupportDirectory();
      final tmp =
          File('${dir.path}/video_${DateTime.now().millisecondsSinceEpoch}'
              '.${f.formato.isEmpty ? 'mp4' : f.formato}');
      await tmp.writeAsBytes(datos, flush: true);
      _add('▶ reproduciendo "${f.nombre}"');
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => DialogoVideo(ruta: tmp.path, titulo: f.nombre),
      );
    } catch (e) {
      _add('✗ reproducir: $e');
    }
  }

  /// Guarda copia en Descargas (bytes ya descifrados).
  Future<void> _guardarCopia(String nombre, Uint8List datos) =>
      guardarCopia(nombre: nombre, datos: datos, log: _add);

  /// Edita los tags de UNA entrada (popup en su archivo).
  /// Sin reabrir el molde: recarga solo las filas (rápido, sin
  /// prefetch ni server de nuevo). Antes reabría todo y trancaba.
  Future<void> _editarTags(FichaArchivo f) async {
    final molde = _infoAbierta?.nombre;
    if (molde == null) return;
    await editarTagsMolde(
      context: context,
      f: f,
      claveSql: _clave,
      molde: molde,
      onListo: () async {
        try {
          final filas =
              await CreateMoldeSql.filasDe(claveSql: _clave, molde: molde);
          if (!mounted) return;
          setState(() {
            _filas = filas;
            _filasTag = null;
          });
        } catch (e) {
          _add('✗ refrescar tags: $e');
        }
      },
      log: _add,
    );
  }

  /// Descarga un archivo a Download (por partes, sin tope RAM).
  /// El tap abre preview; el botón Descargar baja el archivo.
  Future<void> _descargarArchivo(FichaArchivo f) async {
    final molde = _infoAbierta?.nombre;
    if (molde == null) return;
    await descargarArchivo(
      claveSql: _clave,
      molde: molde,
      ficha: f,
      cache: _cache,
      info: _infoAbierta,
      filas: _filas,
      log: _add,
    );
    if (_cache != null) _add('· ${_cache!.resumen()}');
  }

  /// Borra UNA entrada del índice con aviso (popup).
  Future<void> _borrarEntrada(FichaArchivo f) async {
    final molde = _infoAbierta?.nombre;
    if (molde == null) return;
    await borrarEntrada(
      context: context,
      f: f,
      claveSql: _clave,
      molde: molde,
      onListo: () => _abrir(molde),
      log: _add,
      alBorrar: () {
        if (!mounted) return;
        setState(() {
          if (_selArchivo == f.nombre) {
            _selArchivo = null;
            _rangoInfo = '';
          }
        });
      },
    );
  }

  Future<void> _mostrarPapelera() async {
    final molde = _infoAbierta?.nombre;
    if (molde == null) return;
    var elementos = CreateMoldeSql.papeleraDe(
      claveSql: _clave,
      molde: molde,
    );
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('Papelera de "$molde"'),
          content: SizedBox(
            width: 460,
            height: 360,
            child: FutureBuilder<List<Map<String, Object?>>>(
              future: elementos,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Text('No se pudo leer la papelera: ${snapshot.error}');
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final filas = snapshot.data!;
                if (filas.isEmpty) {
                  return const Center(child: Text('La papelera está vacía'));
                }
                return ListView.builder(
                  itemCount: filas.length,
                  itemBuilder: (context, index) {
                    final fila = filas[index];
                    final archivo = fila['archivo'] as Map<String, dynamic>;
                    final id = fila['id'] as int;
                    final nombre = '${fila['nombre'] ?? ''}';
                    final tamano = (archivo['tamano'] as int?) ?? 0;
                    return ListTile(
                      dense: true,
                      title: Text(nombre,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        '${fmtBytes(tamano)} · respaldo local de la fila',
                        style: const TextStyle(fontSize: 11),
                      ),
                      trailing: IconButton(
                        tooltip: 'Restaurar entrada',
                        icon: const Icon(Icons.restore_rounded),
                        onPressed: () async {
                          try {
                            await CreateMoldeSql.restaurarPapelera(
                              claveSql: _clave,
                              molde: molde,
                              papeleraId: id,
                            );
                            _add('✓ "$nombre" restaurado desde la papelera');
                            setDialogState(() {
                              elementos = CreateMoldeSql.papeleraDe(
                                claveSql: _clave,
                                molde: molde,
                              );
                            });
                            await _abrir(molde);
                          } catch (e) {
                            _add('✗ restaurar "$nombre": $e');
                          }
                        },
                      ),
                    );
                  },
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                final vaciar = await showDialog<bool>(
                  context: dialogContext,
                  builder: (confirmContext) => AlertDialog(
                    title: const Text('Vaciar papelera'),
                    content: const Text(
                      'Se eliminarán los respaldos de metadatos de la papelera. '
                      'Los bytes cifrados que ya están en el .mld no se modifican.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(confirmContext, false),
                        child: const Text('Cancelar'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(confirmContext, true),
                        child: const Text('Vaciar'),
                      ),
                    ],
                  ),
                );
                if (vaciar != true) return;
                try {
                  await CreateMoldeSql.vaciarPapelera(
                    claveSql: _clave,
                    molde: molde,
                  );
                  _add('✓ papelera de "$molde" vaciada');
                  setDialogState(() {
                    elementos = CreateMoldeSql.papeleraDe(
                      claveSql: _clave,
                      molde: molde,
                    );
                  });
                } catch (e) {
                  _add('✗ vaciar papelera: $e');
                }
              },
              child: const Text('Vaciar papelera'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cerrar'),
            ),
          ],
        ),
      ),
    );
  }

  /// Quita duplicados del molde abierto (mismo nombre → deja el primero).
  Future<void> _quitarDuplicados() async {
    final molde = _infoAbierta?.nombre;
    if (molde == null) return;
    try {
      final n = await CreateMoldeSql.quitarDuplicados(
        claveSql: _clave,
        molde: molde,
      );
      _add(n == 0
          ? '· sin duplicados en "$molde"'
          : '✓ $n duplicado(s) quitados de "$molde"');
      await _abrir(molde);
    } catch (e) {
      _add('✗ duplicados: $e');
    }
  }

  /// Solo imágenes, en orden alfabético (respeta carpetas/orden).
  static List<FichaArchivo> _soloImgs(List<FichaArchivo> archivos) {
    final imgs = [
      for (final f in archivos)
        if (_imgs.contains(f.formato.toLowerCase())) f
    ];
    imgs.sort((a, b) => a.nombre.compareTo(b.nombre));
    return imgs;
  }

  /// Filas del abierto con búsqueda por nombre o tags aplicada.
  List<FichaArchivo> _filtrados() {
    final ft = _filasTag;
    if (ft != null) return ft;
    final t = _tagFiltroCtrl.text.trim();
    if (t.isEmpty) return _filas;
    final q = t.toLowerCase();
    return [
      for (final f in _filas)
        if (f.nombre.toLowerCase().contains(q) ||
            f.tags.any((tag) => tag.toLowerCase().contains(q)))
          f
    ];
  }

  /// Encola previas en orden (sin await: la cola manda).
  /// El molde v2 ya trae la previa calculada: se calientan previas,
  /// NO minis (la mini descifra el archivo entero, derroche).
  /// Moldes viejos: cada cuadro pide su mini perezoso al verse.
  /// Entra/sale de subcarpeta + prefetch de ese nivel (de a una,
  /// sin congelar). Antes solo había prefetch al abrir el molde y
  /// entrar a una carpeta con videos largaba todo junto.
  void _entrarDir(List<String> nueva) {
    setState(() => _rutaExp = nueva);
    final info = _infoAbierta;
    if (info == null) return;
    _preFetchMinis(info.nombre, info, hijosDe(_filas, nueva).directos);
  }

  void _preFetchMinis(
      String molde, MoldeInfo info, List<FichaArchivo> filas) async {
    var n = 0;
    for (final f in filas) {
      final formato = f.formato.toLowerCase();
      final esVid = PreviewMolde.esVideo(formato);
      if (!_imgs.contains(formato) && !esVid) {
        continue;
      }
      if (n >= 60) break;
      n++;
      // DE A UNA y cediendo el turno: 60 descifrados juntos
      // congelaban la pantalla al abrir la carpeta.
      // Videos: 1 frame (los 17 solo los trae el visor).
      try {
        if (esVid) {
          await _previaUnoDe(f);
        } else {
          await _previasDe(f);
        }
      } catch (_) {}
      await Future<void>.delayed(Duration.zero);
    }
    // Prefetch listo = Admin con números reales.
    _medirCache();
  }

  /// Tags frescos de un archivo (tras editar tags + reabrir).
  String _tagsFrescos(FichaArchivo f) {
    for (final x in _filas) {
      if (x.nombre == f.nombre) return x.tags.join(', ');
    }
    return f.tags.join(', ');
  }

  /// Bytes completos para el visor (clase, memoizados, con caché).
  Future<Uint8List?> _bytesCompletos(FichaArchivo f) {
    final molde = _infoAbierta?.nombre;
    if (molde == null) return Future.value(null);
    return _completos.de(
      claveSql: _clave,
      molde: molde,
      f: f,
      cache: _cache,
      info: _infoAbierta,
      filas: _filas,
    );
  }
}
