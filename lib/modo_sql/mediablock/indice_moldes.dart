part of '../mediablock_screen.dart';

/// Extensión de MediaBlockScreen (ver mediablock_screen.dart).
extension IndiceMoldesExt on _MediaBlockScreenState {
  /// Cierra el molde y vuelve a la RAÍZ (la lista de moldes
  /// en la misma pestaña: el grid/lista la muestran solos).
  void _cerrarMolde() {
    _previasStashGuardar();
    setState(() {
      _infoAbierta = null;
      _filas = [];
      _filasTag = null;
      _previas.clear();
      _previasFut.clear();
      _selArchivo = null;
      _rangoInfo = '';
      _rutaExp = const [];
      _minis.limpiar();
      _completos.limpiar();
    });
    _add('· molde cerrado (de vuelta a los moldes)');
  }

  /// Mueve un molde a otro directorio (admin): .db + .mld juntos,
  /// actualiza la SQL y el índice. Si era el abierto, lo reabre.
  Future<void> _moverMolde(String nombre) async {
    final dir = await elegirCarpeta();
    if (dir == null || dir.isEmpty) return;
    if (!mounted) return;
    try {
      _add('· moviendo "$nombre" a "$dir"…');
      await CreateMoldeSql.moverMolde(
        claveSql: _passPorMolde[nombre] ?? _clave,
        molde: nombre,
        passIndice: await _passIndice(),
        nuevoDir: dir,
      );
      _add('✓ "$nombre" movido a "$dir"');
      if (_infoAbierta?.nombre == nombre) {
        await _abrirMolde(nombre);
      } else {
        await _refrescarMoldes();
      }
    } catch (e) {
      _add('✗ mover: $e');
    }
  }

  /// Edita a mano las rutas de un molde (URL, IP, no físico).
  /// No valida: si no abre, el error sale al abrir el molde.
  Future<void> _editarRutas(String nombre) async {
    final ent = _entradas[nombre];
    final dbCtrl = TextEditingController(text: '${ent?['db_ruta'] ?? ''}');
    final mldCtrl = TextEditingController(text: '${ent?['mld_ruta'] ?? ''}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Rutas de $nombre', style: const TextStyle(fontSize: 13)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: dbCtrl,
                style: const TextStyle(fontSize: 11),
                decoration: const InputDecoration(
                  labelText: 'SQL (ruta, URL o IP)',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: mldCtrl,
                style: const TextStyle(fontSize: 11),
                decoration: const InputDecoration(
                  labelText: 'MLD (ruta, URL o IP)',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Guardar')),
        ],
      ),
    );
    final dbRuta = dbCtrl.text.trim();
    final mldRuta = mldCtrl.text.trim();
    try {
      dbCtrl.dispose();
      mldCtrl.dispose();
    } catch (_) {}
    if (ok != true) return;
    try {
      await Indice.actualizarRutas(
        pass: await _passIndice(),
        nombre: nombre,
        dbRuta: dbRuta,
        mldRuta: mldRuta,
      );
      _add('✓ rutas de "$nombre" editadas a mano');
      if (_infoAbierta?.nombre == nombre) {
        await _abrirMolde(nombre);
      } else {
        await _refrescarMoldes();
      }
    } catch (e) {
      _add('✗ editar rutas: $e');
    }
  }

  /// Indexa por carpeta: rastrea .mld y añade al índice con su pass.
  /// (molde = carpeta: 30 moldes = 30 lugares, se indexan al elegir).
  Future<void> _indexarCarpeta() async {
    final dir = await elegirCarpeta();
    if (dir == null || dir.isEmpty) return;
    if (!mounted) return;
    try {
      _add('· rastreando "$dir"…');
      final hallados = await CreateMoldeSql.rastrearCarpeta(
        dir,
        claveSql: _clave,
      );
      if (hallados.isEmpty) {
        _add('· sin .mld con SQL en "$dir"');
        return;
      }
      _add('· ${hallados.length} molde(s) en "$dir"');
      if (!mounted) return;
      await mostrarParaIndexar(
        context: context,
        hallados: hallados,
        onAnadir: (nombre, passMolde) async {
          try {
            final h = hallados.firstWhere((e) => '${e['nombre']}' == nombre);
            await Indice.registrar(
              pass: await _passIndice(),
              nombre: nombre,
              dbRuta: '${h['db_ruta'] ?? ''}',
              mldRuta: '${h['mld_ruta'] ?? ''}',
              n: (h['n'] as int?) ?? 0,
              total: (h['total'] as int?) ?? 0,
              sal: '${h['sal'] ?? ''}',
              passMolde: passMolde,
            );
            if (_recordar && passMolde.isNotEmpty) {
              await ClavesApp().guardar(nombre, passMolde);
            }
            _add('✓ "$nombre" al índice');
            await _refrescarMoldes();
          } catch (e) {
            _add('✗ indexar "$nombre": $e');
          }
        },
      );
    } catch (e) {
      _add('✗ rastrear: $e');
    }
  }

  /// Abre un molde: pass del ÍNDICE → recordada → escrita.
  /// Si vive en la SQL vieja, lo migra a su propia SQL al abrir.
  Future<void> _abrirMolde(String nombre) async {
    if (_infoAbierta?.nombre == nombre) {
      // Ya está abierto: solo ir al grid si estamos en Moldes.
      if (mounted && _tabs.index == 3) _tabs.animateTo(0);
      return;
    }
    var pass = _passPorMolde[nombre] ?? '';
    if (pass.isEmpty) {
      pass = await ClavesApp().leer(nombre) ?? '';
    }
    if (pass.isEmpty) pass = _clave;
    if (pass.isEmpty) {
      _add('· poné la clave de "$nombre" para abrir');
      return;
    }
    if (mounted && _clave != pass) {
      setState(() => _claveCtrl.text = pass);
    }
    // Sin SQL local pero con HF: se baja SOLA (por hash, verificada).
    // Por CONTENIDO (¿trae el molde?), no por archivo: aperturas
    // viejas dejan .db locales vacíos que hay que ignorar.
    try {
      final pi = await _passIndice();
      final info =
          await CreateMoldeSql.moldeInfo(claveSql: pass, molde: nombre);
      if (info == null) {
        final ent = await Indice.entrada(pass: pi, nombre: nombre);
        final teleMeta = await Indice.manifiestoTelegram(
          pass: pi,
          nombre: nombre,
        );
        if ('${teleMeta?['modo'] ?? ''}' == 'bot' &&
            '${teleMeta?['sql_file_id'] ?? ''}'.isNotEmpty) {
          final config = await Indice.botTelegram(pi);
          await _telegramBot.validarBot(config.token);
          final tempDir =
              await Directory.systemTemp.createTemp('tg_sql_restore_');
          try {
            final downloaded =
                File('${tempDir.path}${Platform.pathSeparator}$nombre.sql.db');
            await _telegramBot.descargarArchivo(
              token: config.token,
              fileId: '${teleMeta?['sql_file_id']}',
              destination: downloaded,
            );
            final remoteSql = CajaSql();
            await remoteSql.abrirRuta(downloaded.path, clave: pass);
            remoteSql.cerrar();
            final rutaAnterior = '${ent?['db_ruta'] ?? ''}';
            final destino = rutaAnterior.isNotEmpty
                ? rutaAnterior
                : await CreateMoldeSql.rutaDbPropia(nombre);
            final target = File(destino);
            await target.parent.create(recursive: true);
            if (await target.exists()) {
              await target.copy(
                '${target.path}.bak_${DateTime.now().millisecondsSinceEpoch}',
              );
            }
            await downloaded.copy(target.path);
            await Indice.actualizarRutas(
              pass: pi,
              nombre: nombre,
              dbRuta: target.path,
              mldRuta: '',
            );
            _add('✓ SQL cifrada de "$nombre" restaurada desde Bot API');
          } finally {
            await tempDir.delete(recursive: true);
          }
        }
        if (ent != null && '${ent['hf_repo'] ?? ''}'.isNotEmpty) {
          _add('· "$nombre" solo en HF: bajando su SQL…');
          await _puenteHf.bajarSql(passIndice: pi, nombre: nombre);
          _add('✓ SQL de "$nombre" bajada (hash verificado)');
          await _refrescarMoldes();
        }
      }
    } catch (e) {
      _add('✗ bajar SQL: $e');
    }
    try {
      final migro = await CreateMoldeSql.migrarSiHaceFalta(
        claveSql: pass,
        molde: nombre,
        passIndice: await _passIndice(),
      );
      if (migro) {
        _add('✓ "$nombre" migrado a su propia SQL');
        await _refrescarMoldes();
      }
    } catch (e) {
      _add('✗ migrar: $e');
    }
    await _abrir(nombre);
    // Si se abrió desde la pestaña Moldes, llevar al grid a verlo.
    if (mounted && _infoAbierta != null && _tabs.index == 3) {
      _tabs.animateTo(0);
    }
  }

  Future<void> _borrarMolde(String nombre) async {
    try {
      await CreateMoldeSql.borrar(
        nombre: nombre,
        claveSql: _clave.isEmpty ? 'x' : _clave,
        passIndice: await _passIndice(),
      );
      await ClavesApp().borrar(nombre);
      // Sin caché vieja: los offsets del .mld borrado envenenan.
      if (_sesionCache.abierta) {
        await TrozoCache.limpiarMoldeDe(_sesionCache, nombre);
        await PreviaCache.limpiarMoldeDe(_sesionCache, nombre);
        _add('· caché invalidada de "$nombre"');
      }
      if (!mounted) return;
      setState(() {
        if (_infoAbierta?.nombre == nombre) {
          _infoAbierta = null;
          _filas = [];
          _filasTag = null;
          _previas.clear();
          _previasFut.clear();
          _selArchivo = null;
          _rangoInfo = '';
        }
      });
      _add('✓ borrado "$nombre" (.mld + filas SQL)');
      await _refrescarMoldes();
    } catch (e) {
      _add('✗ borrar: $e');
    }
  }

  /// Mover molde a otra carpeta DEL ÍNDICE (anidar, solo índice: ni
  /// SQL ni .mld se tocan). '' = raíz. (El mover FÍSICO es _moverMolde.)
  Future<void> _moverMoldeCarpeta(String nombre) async {
    final actual = _carpetaPorMolde[nombre] ?? '';
    final exist = <String>{};
    for (final c in _carpetaPorMolde.values) {
      final v = c.trim();
      if (v.isNotEmpty) exist.add(v);
    }
    final ctrl = TextEditingController(text: actual);
    final elegida = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Mover "$nombre" (solo índice)'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Carpeta actual:',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
              Text(actual.isEmpty ? '(raíz)' : actual,
                  style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 8),
              TextField(
                controller: ctrl,
                decoration: const InputDecoration(
                    labelText: 'Nueva carpeta (vacío = raíz, ej. a/b)',
                    border: OutlineInputBorder()),
                onSubmitted: (_) => Navigator.pop(ctx, ctrl.text.trim()),
              ),
              if (exist.isNotEmpty) ...[
                const SizedBox(height: 8),
                const Text('Existentes:',
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
                for (final e in exist.toList()..sort())
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.folder_open_rounded, size: 18),
                    title: Text(e, style: const TextStyle(fontSize: 12)),
                    onTap: () => Navigator.pop(ctx, e),
                  ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Mover')),
        ],
      ),
    );
    ctrl.dispose();
    if (elegida == null || !mounted) return;
    try {
      await Indice.mover(
        pass: await _passIndice(),
        nombre: nombre,
        carpeta: elegida,
      );
      _add('✓ "$nombre" → ${elegida.isEmpty ? "(raíz)" : elegida} '
          '(solo índice)');
      await _refrescarMoldes();
    } catch (e) {
      _add('✗ mover: $e');
    }
  }
}
