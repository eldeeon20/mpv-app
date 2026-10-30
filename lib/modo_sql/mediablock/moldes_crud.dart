part of '../mediablock_screen.dart';

/// Extensión de MediaBlockScreen (ver mediablock_screen.dart).
extension MoldesCrudExt on _MediaBlockScreenState {
  Future<void> _crear() async {
    if (_creando) return;
    if (!mounted) return;
    setState(() {
      _creando = true;
      _crearEstado = '· pidiendo permiso…';
    });
    if (!await accesoCarpeta()) {
      const m = '✗ sin permiso: dale acceso total en '
          'Ajustes → Apps → pr_app';
      _add(m);
      if (!mounted) return;
      setState(() {
        _creando = false;
        _crearEstado = m;
      });
      return;
    }
    if (!mounted) return;
    setState(() => _crearEstado = '· cifrando…');
    try {
      final tags = _tagsCtrl.text
          .split(',')
          .map((t) => t.trim())
          .where((t) => t.isNotEmpty)
          .toList();
      final nombre = _nombreCtrl.text.trim();
      final n = await CreateMoldeSql.crear(
        nombre: nombre,
        origenDir: _carpetaCtrl.text.trim(),
        clave: _clave,
        tags: tags,
        passIndice: await _passIndice(),
        captura: _captura,
        log: _add,
      );
      _add('✓ molde "$nombre.mld" con $n archivos '
          '(uno solo, primero en 0)');
      // Carpeta destino en índice (nace anidado; solo índice).
      final cpIni = _carpetaIndiceCtrl.text.trim();
      if (cpIni.isNotEmpty) {
        try {
          await Indice.mover(
            pass: await _passIndice(),
            nombre: nombre,
            carpeta: cpIni,
          );
          _add('✓ "$nombre" → $cpIni (solo índice)');
        } catch (e) {
          _add('⚠ no se anidó: $e');
        }
      }
      await _refrescarMoldes();
      if (_telegramUser.isReady) {
        await _telegramPreguntarRespaldoIndice();
      } else {
        _add('⚠ index.db se actualizó; conectá Telegram personal y '
            'respaldalo en Mensajes guardados');
      }
      if (!mounted) return;
      setState(() {
        _crearEstado = '✓ "$nombre" con $n archivos → mirá la pestaña Moldes';
      });
      _nombreCtrl.clear();
      _tabs.animateTo(3);
    } catch (e) {
      _add('✗ crear: $e');
      if (!mounted) return;
      setState(() => _crearEstado = '✗ crear: $e');
    }
    if (mounted) setState(() => _creando = false);
  }

  /// Al entrar SIEMPRE pide la pass del índice (no se guarda).
  /// Se puede saltear con "Ahora no" y ponerla en Moldes.
  Future<void> _preguntarIndice() async {
    if (!mounted) return;
    // Permiso de primera: sin "todos los archivos" no lista carpetas.
    if (!await accesoCarpeta()) {
      if (!mounted) return;
      final ir = await showDialog<bool>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) => AlertDialog(
          title:
              const Text('Permiso de archivos', style: TextStyle(fontSize: 14)),
          content: const Text(
            'Sin acceso total no se listan carpetas ni moldes. '
            'Dalo en Ajustes → Apps → pr_app.',
            style: TextStyle(fontSize: 12),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Seguir igual')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Abrir ajustes')),
          ],
        ),
      );
      if (ir == true) await abrirAjustes();
      if (!mounted) return;
    }
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        title: const Text('Clave del índice', style: TextStyle(fontSize: 14)),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          style: const TextStyle(fontSize: 12),
          decoration: const InputDecoration(
            hintText: 'propia del índice (no se guarda)',
            isDense: true,
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Ahora no')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Abrir')),
        ],
      ),
    );
    try {
      ctrl.dispose();
    } catch (_) {}
    if (!mounted) return;
    if (ok == true && ctrl.text.isNotEmpty) {
      setState(() => _indiceCtrl.text = ctrl.text);
    }
    await _refrescarMoldes(auto: true);
  }

  /// Carpetas desde el ÍNDICE cifrado (sin abrir las SQL de moldes).
  /// Con [auto] y un solo molde, lo abre solo.
  Future<void> _refrescarMoldes({bool auto = false}) async {
    if (!mounted) return;
    setState(() => _cargando = true);
    try {
      final p = await _passIndice();
      if (p.isEmpty) {
        _add('· poné la clave del ÍNDICE para ver el historial');
        if (mounted) setState(() {});
        return;
      }
      await Indice.asegurar(p);
      await _telegramActualizarEstadoIndice();
      final telegram = await Indice.credencialesTelegram(p);
      final bot = await Indice.botTelegram(p);
      if (_telegramApiIdCtrl.text.isEmpty) {
        _telegramApiIdCtrl.text = telegram.apiId;
      }

      if (_telegramApiHashCtrl.text.isEmpty) {
        _telegramApiHashCtrl.text = telegram.apiHash;
      }
      if (_telegramBotTokenCtrl.text.isEmpty) {
        _telegramBotTokenCtrl.text = bot.token;
      }
      if (_telegramBotChatCtrl.text.isEmpty) {
        _telegramBotChatCtrl.text = bot.chatId;
      }
      // La caché comparte la pass del índice: se desbloquea acá.
      try {
        await _sesionCache.abrir(p);
        _add('· caché desbloqueada (misma pass del índice)');
      } catch (e) {
        _add('✗ caché: $e');
      }
      final crudo = await Indice.listarRaw(p);
      final vistos = <String>{};
      _moldes = [];
      _passPorMolde.clear();
      _entradas.clear();
      _hfInfo.clear();
      _telegramBotMoldes
        ..clear()
        ..addAll(await Indice.moldesTelegram(p));
      _carpetaPorMolde.clear();
      for (final m in crudo) {
        final nombre = '${m['nombre'] ?? ''}';
        if (nombre.isEmpty || !vistos.add(nombre)) continue;
        _moldes.add(MoldeInfo(
          nombre: nombre,
          ruta: '${m['mld_ruta'] ?? ''}',
          fecha: (m['fecha'] as int?) ?? 0,
          total: (m['total'] as int?) ?? 0,
          sal: '${m['sal'] ?? ''}',
          cifrado: '${m['cifrado'] ?? ''}',
        ));
        // En local el índice ya sabe qué hay en HF (repo+versión):
        // se muestra en la lista (☁ repo v123).
        final repo = '${m['hf_repo'] ?? ''}';
        final ver = (m['version'] as int?) ?? 0;
        if (repo.isNotEmpty && ver > 0) {
          _hfInfo[nombre] = (repo: repo, version: ver);
        }
        final pm = '${m['pass'] ?? ''}';
        if (pm.isNotEmpty) _passPorMolde[nombre] = pm;
        _entradas[nombre] = m;
        // Carpeta del índice (anidadas solo-índice).
        // Sanea al leer: cura entradas viejas con `/` inicial.
        _carpetaPorMolde[nombre] =
            Indice.sanearCarpeta('${m['carpeta'] ?? ''}');
      }
      // Sin escaneo a la compartida legada (media_server.db): solo
      // demoraba con clave ajena. Solo índice.
      if (mounted) setState(() {});
      _add('· ${_moldes.length} molde(s) en el índice');
      // Un solo molde = se abre solo (sin tap).
      if (auto && _moldes.length == 1 && _infoAbierta == null && mounted) {
        await _abrirMolde(_moldes.first.nombre);
      }
    } catch (e) {
      _add('✗ índice: $e');
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  Future<void> _telegramActualizarEstadoIndice() async {
    try {
      final directory = await MediaBase.carpetaMoldes();
      final indexFile =
          File('${directory.path}${Platform.pathSeparator}${Indice.archivo}');
      if (!await indexFile.exists()) return;
      final hash = await HuggingFace.sha256Archivo(indexFile.path);
      final saved = await AppDb.leer('telegram_index_sha256');
      final savedHash = saved == null ? '' : String.fromCharCodes(saved);
      final pending = hash != savedHash;
      if (!mounted) return;
      setState(() => _telegramIndexPendiente = pending);
      if (pending) {
        _add('⚠ index.db tiene cambios sin confirmar en Mensajes guardados');
      }
    } catch (e) {
      _add('✗ verificar respaldo de index.db: $e');
    }
  }

  Future<void> _abrir(String nombre) async {
    try {
      final info =
          await CreateMoldeSql.moldeInfo(claveSql: _clave, molde: nombre);
      if (info == null) {
        _add('✗ abrir: "$nombre" no está en tu SQL');
        return;
      }
      final filas =
          await CreateMoldeSql.filasDe(claveSql: _clave, molde: nombre);
      // USER abre su SQL (info+filas); el server solo abre el .mld.
      // Sin tu SQL el server no sabe qué trae el molde.
      // Sin .mld local no se rompe: los trozos vienen de HF por
      // rangos (remoto) y quedan en caché (solo lo pedido).
      MoldeAbierto? m;
      try {
        m = await MediaServer.abrir(rutaMld: info.ruta);
      } catch (_) {
        m = null;
      }
      // Remoto del molde (repo+token del índice, o gemelo HF que
      // trae la propia SQL en `ruta` o columna `hf`): pedirRango
      // lo usa solo para los trozos que la caché no tiene.
      // Hay archivo local? manda ese; si no, el gemelo HF.
      try {
        var repo = '';
        var token = '';
        var archivo = '';
        for (final cand in [info.ruta, info.hf]) {
          if (!cand.startsWith('hf://')) continue;
          final resto = cand.substring(5);
          final i = resto.lastIndexOf('/');
          if (i > 0) {
            repo = resto.substring(0, i);
            // El nombre remoto sale de la propia URL (hash nuevo,
            // nombre legado): no depende del índice.
            archivo = resto.substring(i + 1);
            _add('· SQL apunta a HF ($repo/$archivo: sin .mld local)');
            break;
          }
        }
        final ent =
            await Indice.entrada(pass: await _passIndice(), nombre: nombre);
        if (repo.isEmpty) repo = '${ent?['hf_repo'] ?? ''}';
        token = '${ent?['hf_token'] ?? ''}';
        if (archivo.isEmpty) {
          final hm = '${ent?['hash_mld'] ?? ''}';
          if (hm.isNotEmpty) archivo = '$hm.mld';
        }
        if (repo.isNotEmpty && token.isNotEmpty) {
          CreateMoldeSql.remoto = (molde, absoluto, largo) => PuenteHf.rangoMld(
                repo: repo,
                nombre: molde,
                start: absoluto,
                // HTTP Range inclusivo: [absoluto, absoluto+largo).
                end: absoluto + largo - 1,
                token: token,
                archivo: archivo,
              );
          _add('· remoto HF listo ($repo: solo lo no cacheado)');
        } else {
          CreateMoldeSql.remoto = null;
        }
      } catch (_) {
        CreateMoldeSql.remoto = null;
      }
      try {
        final passIndice = await _passIndice();
        final teleMeta = await Indice.manifiestoTelegram(
          pass: passIndice,
          nombre: nombre,
        );
        if ('${teleMeta?['modo'] ?? ''}' == 'bot') {
          final config = await Indice.botTelegram(passIndice);
          if (config.token.isEmpty || config.chatId.isEmpty) {
            throw StateError('faltan token/destino del Bot API en index.db');
          }
          await _telegramBot.validarBot(config.token);
          await _telegramBot.validarDestino(
            token: config.token,
            chatId: '${teleMeta?['chat_id'] ?? config.chatId}',
          );
          final fileId = '${teleMeta?['manifest_file_id'] ?? ''}';
          if (fileId.isEmpty) {
            throw StateError('index.db no tiene file_id del hash.db');
          }
          final temporal = await Directory.systemTemp.createTemp('tg_mld_');
          try {
            final file = File(
                '${temporal.path}${Platform.pathSeparator}$nombre.hash.db');
            await _telegramBot.descargarArchivo(
              token: config.token,
              fileId: fileId,
              destination: file,
            );
            final manifest = await TelegramMldManifestStore.leer(
              ruta: file.path,
              clave: _clave,
            );
            final tamanoEsperado = (teleMeta?['mld_size'] as int?) ?? 0;
            if (manifest.size != tamanoEsperado) {
              throw StateError('hash.db no coincide con index.db');
            }
            CreateMoldeSql.remoto =
                (molde, absoluto, largo) => _telegramBot.leerRango(
                      token: config.token,
                      manifest: manifest,
                      start: absoluto,
                      length: largo,
                    );
            _add('· remoto Telegram Bot API validado; '
                'hash.db desencriptado en memoria para rangos');
          } finally {
            await temporal.delete(recursive: true);
          }
        }
      } catch (e) {
        CreateMoldeSql.remoto = null;
        _add('⚠ remoto Bot API no disponible: $e');
      }
      if (!mounted) return;
      // Caché en bruto sobre la sesión (misma pass del índice).
      final TrozoCache? cache = _sesionCache.abierta
          ? TrozoCache(
              sesion: _sesionCache,
              molde: nombre,
              limiteBytes: _limiteTrozosKb * 1024)
          : null;
      final PreviaCache? pcache = _sesionCache.abierta
          ? PreviaCache(
              sesion: _sesionCache,
              molde: nombre,
              limiteBytes: _limitePreviasMb * 1024 * 1024)
          : null;
      if (cache == null) {
        _add('· sin caché (índice bloqueado: solo server)');
      }
      if (!mounted) return;
      // La RAM de previas sobrevive: se guarda la del molde que se
      // deja y se restaura la del que se abre (volver = instantáneo).
      _previasStashGuardar();
      _previasStashRestaurar(nombre);
      setState(() {
        _infoAbierta = info;
        _filas = filas;
        _filasTag = null;
        _selArchivo = null;
        _rangoInfo = '';
        _minis.limpiar();
        // Misma referencia: el visor reusa lo que el grid descifró.
        _completos.minis = _minis.minis;
        _rutaExp = const [];
        _cache = cache;
        _previaCache = pcache;
      });
      _add('✓ abierto "$nombre": ${filas.length} filas de tu SQL, '
          '${m == null ? 'sin .mld local (HF por rangos)' : 'server solo ve ${fmtBytes(m.total)} crudos'}, '
          'caché local 512KB lista');
      // v1 o v2 en el log: v2 = trae previas guardadas (.prev/).
      // OJO: `filas` las excluye (filasDe filtra NOT LIKE .prev/%),
      // así que se cuentan aparte (antes daba siempre v1).
      var conPrevias = 0;
      try {
        conPrevias = await CreateMoldeSql.previasCuantas(
            claveSql: _clave, molde: nombre);
      } catch (_) {}
      _add(conPrevias == 0
          ? '· molde v1 (sin previas guardadas: el grid no toca '
              'originales, muestra icono hasta que pidas)'
          : '· molde v2 ($conPrevias archivo(s) con previa '
              'guardada: el grid sale de RAM/disco, jamás del original)');
      // Diagnóstico: nombres repetidos (ej. video 4 veces).
      final vistos = <String>{};
      var dups = 0;
      for (final f in filas) {
        if (!vistos.add(f.nombre)) dups++;
      }
      if (dups > 0) {
        _add('⚠ $dups fila(s) duplicadas en "$nombre" '
            '(botón Quitar duplicados en Lista)');
      }
      // Prefetch EN ORDEN del nivel actual (los carriles las sacan
      // en orden y el grid se llena sin saltar grillas).
      _preFetchMinis(nombre, info, hijosDe(filas, _rutaExp).directos);
      if (_recordar) {
        await ClavesApp().guardar(nombre, _clave);
        _add('· clave de "$nombre" recordada (cifrada, app local)');
      }
    } catch (e) {
      _add('✗ abrir: $e');
    }
  }
}
