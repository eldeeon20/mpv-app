part of '../mediablock_screen.dart';

/// Extensión de MediaBlockScreen (ver mediablock_screen.dart).
extension HfFlujosExt on _MediaBlockScreenState {
  /// Sube los seleccionados (cada uno a SU repo; por hash salta
  /// lo que ya está arriba). Log por molde + resumen.
  Future<void> _subirSeleccionados() async {
    if (_hfOcupado || _selSubir.isEmpty) return;
    final nombres = _selSubir.toList()..sort();
    final cuenta = await _elegirCuentaNube('huggingface');
    if (cuenta == null || !mounted) return;
    setState(() => _hfOcupado = true);
    try {
      for (final nombre in nombres) {
        await Indice.guardarHf(
          pass: await _passIndice(),
          nombre: nombre,
          hfRepo: cuenta.destino,
          hfToken: cuenta.token,
        );
      }
      final r = await _puenteHf.subirSeleccionados(
        passIndice: await _passIndice(),
        claveSql: _clave,
        nombres: nombres,
        conIndice: false,
        log: _add,
      );
      _add('✓ subida selección: ${r.subidos} subido(s), '
          '${r.saltados} ya estaban');
      if (mounted && r.completados.isNotEmpty) {
        setState(() => _selSubir.removeAll(r.completados));
      }
      await _refrescarMoldes();
    } catch (e) {
      _add('✗ subir selección: $e');
    } finally {
      if (mounted) setState(() => _hfOcupado = false);
    }
  }

  /// HF de un molde SIN abrirlo (repo+token para poder bajarlo).
  /// Rompe el círculo: sin token no baja, sin abrir no había dónde
  /// ponerlo.
  Future<void> _hfDeMolde(String nombre) async {
    final ent = await Indice.entrada(pass: await _passIndice(), nombre: nombre);
    if (ent == null || !mounted) return;
    final repoCtrl = TextEditingController(text: '${ent['hf_repo'] ?? ''}');
    final tokCtrl = TextEditingController(text: '${ent['hf_token'] ?? ''}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('HF de "$nombre"'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: repoCtrl,
                decoration: const InputDecoration(
                    labelText: 'repo dir/user', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: tokCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                    labelText: 'token (write para subir)',
                    border: OutlineInputBorder()),
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
    final repo = repoCtrl.text.trim();
    final tok = tokCtrl.text.trim();
    repoCtrl.dispose();
    tokCtrl.dispose();
    if (ok != true || !mounted) return;
    try {
      await Indice.guardarHf(
        pass: await _passIndice(),
        nombre: nombre,
        hfRepo: repo,
        hfToken: tok,
      );
      _add('✓ HF de "$nombre" guardado (sin abrir)');
      await _refrescarMoldes();
    } catch (e) {
      _add('✗ HF guardar: $e');
    }
  }

  /// HF: sube .mld + SQL del molde abierto. El índice se respalda
  /// por separado y solo cuando el usuario lo pide.
  Future<void> _hfSubir() async {
    if (_hfOcupado) return;
    final m = _infoAbierta?.nombre;
    if (m == null) {
      _add('· HF: abrí un molde primero');
      return;
    }
    final cuenta = await _elegirCuentaNube('huggingface');
    if (cuenta == null || !mounted) return;
    setState(() => _hfOcupado = true);
    try {
      await Indice.guardarHf(
        pass: await _passIndice(),
        nombre: m,
        hfRepo: cuenta.destino,
        hfToken: cuenta.token,
      );
      await _puenteHf.subirMolde(
        passIndice: await _passIndice(),
        claveSql: _clave,
        nombre: m,
        conIndice: false,
        log: _add,
      );
      if (mounted) setState(() {});
    } catch (e) {
      _add('✗ HF subir: $e');
    } finally {
      if (mounted) setState(() => _hfOcupado = false);
    }
  }

  /// HF: baja la SQL entera si falta y abre el molde.
  /// El .mld nunca se baja: se consulta por rangos.
  Future<void> _hfBajarSql() async {
    if (_hfOcupado) return;
    final m = _infoAbierta?.nombre;
    if (m == null) {
      _add('· abrí el molde que querés recuperar desde Hugging Face');
      return;
    }
    setState(() => _hfOcupado = true);
    try {
      final ruta = await _puenteHf.bajarSql(
        passIndice: await _passIndice(),
        nombre: m,
      );
      _add('✓ SQL en $ruta');
      if (_infoAbierta == null && mounted) {
        await _abrirMolde(m);
      }
    } catch (e) {
      _add('✗ HF bajar SQL: $e');
    } finally {
      if (mounted) setState(() => _hfOcupado = false);
    }
  }

  /// (a) Sube SOLO el índice al repo guardado con "Guardar HF índice".
  /// Usa únicamente el destino propio guardado del índice (nunca el
  /// del molde): primero Guardar, después Subir.
  Future<void> _hfSubirIndice() async {
    if (_hfOcupado) return;
    setState(() => _hfOcupado = true);
    try {
      final pass = await _passIndice();
      final propio = await Indice.hfIndice(pass);
      await _puenteHf.subirIndice(
        passIndice: pass,
        repo: propio.repo,
        token: propio.token,
        log: _add,
      );
      if (mounted) setState(() {});
    } catch (e) {
      _add('✗ HF subir índice: $e');
    } finally {
      if (mounted) setState(() => _hfOcupado = false);
    }
  }

  /// (b) Baja SOLO el índice del repo que digas (diálogo, prellena
  /// con el guardado; token vacío = público). Reemplaza el local con
  /// respaldo; el bajado abre con SU clave, no con la tuya.
  Future<void> _hfBajarIndice() async {
    if (_hfOcupado) return;
    var propio = (repo: '', token: '');
    try {
      propio = await Indice.hfIndice(await _passIndice());
    } catch (_) {}
    // Los campos propios del índice mandan; lo guardado es respaldo.
    final repoCtrl = TextEditingController(
        text: _hfIndiceRepoCtrl.text.trim().isNotEmpty
            ? _hfIndiceRepoCtrl.text.trim()
            : propio.repo);
    final tokCtrl = TextEditingController(
        text: _hfIndiceTokenCtrl.text.trim().isNotEmpty
            ? _hfIndiceTokenCtrl.text.trim()
            : propio.token);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Bajar índice'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: repoCtrl,
                decoration: const InputDecoration(
                    labelText: 'repo dir/user del ÍNDICE',
                    border: OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: tokCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                    labelText: 'token (vacío = público)',
                    border: OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              const Text(
                  'Reemplaza tu índice local (se respalda como .bak). '
                  'El bajado abre con SU clave, no con la tuya.',
                  style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Bajar')),
        ],
      ),
    );
    final repo = repoCtrl.text.trim();
    final tok = tokCtrl.text.trim();
    repoCtrl.dispose();
    tokCtrl.dispose();
    if (ok != true || !mounted) return;
    setState(() => _hfOcupado = true);
    try {
      await _puenteHf.bajarIndice(repo: repo, token: tok, log: _add);
      // Los campos propios reflejan de dónde vino este índice.
      if (mounted) {
        setState(() {
          _hfIndiceRepoCtrl.text = repo;
          _hfIndiceTokenCtrl.text = tok;
        });
      }
      try {
        await _refrescarMoldes();
      } catch (e) {
        _add('· el índice nuevo pide SU clave: $e');
      }
      if (mounted) setState(() {});
    } catch (e) {
      _add('✗ HF bajar índice: $e');
    } finally {
      if (mounted) setState(() => _hfOcupado = false);
    }
  }

  Future<void> _telegramBotSubirMolde() async {
    final nombres = _selSubir.toList()..sort();
    if (nombres.isEmpty) {
      _add('· seleccioná los moldes que querés subir');
      return;
    }
    final seleccionados = _selSubir.toSet();
    final cuenta = await _elegirCuentaNube('telegram_bot');
    if (cuenta == null || !mounted) return;
    if (_telegramBotOcupado) return;
    setState(() => _telegramBotOcupado = true);
    try {
      final passIndice = await _passIndice();
      var exitos = 0;
      final subidos = <String>{};
      for (final nombre in nombres) {
        try {
          await _telegramBotSubirUnMolde(
            nombre: nombre,
            passIndice: passIndice,
            accountId: cuenta.id,
            token: cuenta.token,
            chatId: cuenta.destino,
          );
          exitos++;
          subidos.add(nombre);
        } catch (e) {
          _add('✗ Telegram "$nombre": $e');
        }
      }
      _add('· Telegram: $exitos/${nombres.length} molde(s) subido(s)');
      if (seleccionados.isNotEmpty && subidos.isNotEmpty && mounted) {
        setState(() => _selSubir.removeAll(subidos));
      }
      if (exitos > 0) {
        await _refrescarMoldes();
        _add('· index.db local actualizado; sus respaldos en HF y Telegram '
            'siguen siendo manuales e independientes');
      }
    } catch (e) {
      _add('✗ subir molde por Bot API: $e');
    } finally {
      if (mounted) setState(() => _telegramBotOcupado = false);
    }
  }

  Future<void> _telegramBotSubirUnMolde({
    required String nombre,
    required String passIndice,
    required String accountId,
    required String token,
    required String chatId,
  }) async {
    final ent = await Indice.entrada(pass: passIndice, nombre: nombre);
    if (ent == null) throw StateError('"$nombre" no está en indice.db');
    final claveMolde = _passPorMolde[nombre]?.isNotEmpty == true
        ? _passPorMolde[nombre]!
        : (nombre == _infoAbierta?.nombre ? _clave : '');
    if (claveMolde.isEmpty) {
      throw StateError('falta la clave de "$nombre" guardada en indice.db');
    }

    final rutaMld = '${ent['mld_ruta'] ?? ''}';
    final archivoMld = File(rutaMld);
    if (!await archivoMld.exists()) {
      throw StateError('no hay .mld local para subir: $rutaMld');
    }
    final rutaSql = '${ent['db_ruta'] ?? ''}';
    final archivoSql = File(rutaSql);
    if (!await archivoSql.exists()) {
      throw StateError('no existe la SQL cifrada: $rutaSql');
    }
    final sqlSize = await archivoSql.length();
    if (sqlSize <= 0 || sqlSize >= 20 * 1000 * 1000) {
      throw StateError(
        'la SQL cifrada debe pesar menos de 20 MB para descargarla con Bot API',
      );
    }
    final cajaSql = CajaSql();
    try {
      await cajaSql.abrirRuta(rutaSql, clave: claveMolde);
    } finally {
      cajaSql.cerrar();
    }

    _add('· subiendo "$nombre.mld" en partes de 19 MB; '
        'el archivo ya está cifrado');
    var ultimoProgreso = -1;
    final manifest = await _telegramBot.subirMolde(
      token: token,
      chatId: chatId,
      ruta: rutaMld,
      progreso: (subidos, total) {
        final porcentaje = (100 * subidos / total).floor();
        if (porcentaje ~/ 10 != ultimoProgreso ~/ 10) {
          ultimoProgreso = porcentaje;
          _add('· Bot API "$nombre": $porcentaje%');
        }
      },
    );
    final rutaManifiesto = await TelegramMldManifestStore.crear(
      nombre: nombre,
      clave: claveMolde,
      manifest: manifest,
    );
    final subidaManifiesto = await _telegramBot.subirArchivo(
      token: token,
      chatId: chatId,
      ruta: rutaManifiesto.path,
      nombre: '$nombre.hash.db',
    );
    final subidaSql = await _telegramBot.subirArchivo(
      token: token,
      chatId: chatId,
      ruta: rutaSql,
      nombre: '$nombre.sql.db',
    );
    await Indice.guardarManifiestoTelegram(
      pass: passIndice,
      nombre: nombre,
      accountId: accountId,
      chatId: chatId,
      fileId: subidaManifiesto.fileId,
      messageId: subidaManifiesto.messageId,
      size: manifest.size,
      sqlFileId: subidaSql.fileId,
      sqlMessageId: subidaSql.messageId,
      sqlSize: subidaSql.size,
    );
    _add('✓ "$nombre": .mld en ${manifest.parts.length} partes, '
        'hash.db y SQL cifrada enlazados en indice.db');
  }

  Future<void> _telegramBotRestaurarSeleccion() async {
    final nombres = _selSubir.toList()..sort();
    if (nombres.isEmpty) {
      _add('· seleccioná los moldes que querés recuperar');
      return;
    }
    if (!mounted || _telegramBotOcupado) return;
    setState(() => _telegramBotOcupado = true);
    try {
      final passIndice = await _passIndice();
      var recuperados = 0;
      for (final nombre in nombres) {
        try {
          await _telegramBotRestaurarUno(
            nombre: nombre,
            passIndice: passIndice,
          );
          recuperados++;
        } catch (e) {
          _add('✗ recuperar "$nombre" de Telegram: $e');
        }
      }
      _add('· Telegram: $recuperados/${nombres.length} molde(s) recuperado(s)');
      if (recuperados > 0) await _refrescarMoldes();
    } catch (e) {
      _add('✗ recuperar selección de Telegram: $e');
    } finally {
      if (mounted) setState(() => _telegramBotOcupado = false);
    }
  }

  Future<void> _telegramBotRestaurarUno({
    required String nombre,
    required String passIndice,
  }) async {
    final ent = await Indice.entrada(pass: passIndice, nombre: nombre);
    if (ent == null) throw StateError('"$nombre" no está en indice.db');
    final meta = await Indice.manifiestoTelegram(
      pass: passIndice,
      nombre: nombre,
    );
    if ('${meta?['modo'] ?? ''}' != 'bot') {
      throw StateError('indice.db no tiene un respaldo Bot API de "$nombre"');
    }
    final accountId = '${meta?['account_id'] ?? ''}';
    final account = accountId.isEmpty
        ? null
        : await Indice.cuentaNube(pass: passIndice, id: accountId);
    final config = account == null
        ? await Indice.botTelegram(passIndice)
        : (token: account.token, chatId: account.destino);
    if (config.token.isEmpty) {
      throw StateError(
        'no está la cuenta Telegram que subió "$nombre"; '
        'restaurá el indice.db correcto o volvé a registrar esa cuenta',
      );
    }
    final claveMolde = _passPorMolde[nombre]?.isNotEmpty == true
        ? _passPorMolde[nombre]!
        : (nombre == _infoAbierta?.nombre ? _clave : '');
    if (claveMolde.isEmpty) {
      throw StateError('falta la clave de "$nombre" guardada en indice.db');
    }
    final mldSize = (meta?['mld_size'] as int?) ?? 0;
    if (mldSize <= 0) {
      throw StateError(
          'indice.db no tiene el tamaño del respaldo de "$nombre"');
    }

    final tempDir = await Directory.systemTemp.createTemp('tg_mld_restore_');
    try {
      final rutaSqlIndice = '${ent['db_ruta'] ?? ''}';
      final sqlDestino = rutaSqlIndice.isNotEmpty
          ? File(rutaSqlIndice)
          : File(await CreateMoldeSql.rutaDbPropia(nombre));
      if (await sqlDestino.exists()) {
        final sqlLocal = CajaSql();
        try {
          await sqlLocal.abrirRuta(sqlDestino.path, clave: claveMolde);
        } finally {
          sqlLocal.cerrar();
        }
      } else {
        final sqlFileId = '${meta?['sql_file_id'] ?? ''}';
        if (sqlFileId.isEmpty) {
          throw StateError(
            'indice.db no tiene el file_id de la SQL de "$nombre"',
          );
        }
        final sqlTemporal = File(
          '${tempDir.path}${Platform.pathSeparator}$nombre.sql.db',
        );
        await _telegramBot.descargarArchivo(
          token: config.token,
          fileId: sqlFileId,
          destination: sqlTemporal,
        );
        final sqlSize = (meta?['sql_size'] as int?) ?? 0;
        if (sqlSize > 0 && await sqlTemporal.length() != sqlSize) {
          throw StateError('SQL descargada incompleta para "$nombre"');
        }
        final sqlRemota = CajaSql();
        try {
          await sqlRemota.abrirRuta(sqlTemporal.path, clave: claveMolde);
        } finally {
          sqlRemota.cerrar();
        }
        await sqlDestino.parent.create(recursive: true);
        await sqlTemporal.copy(sqlDestino.path);
        await Indice.actualizarRutas(
          pass: passIndice,
          nombre: nombre,
          dbRuta: sqlDestino.path,
          mldRuta: '${ent['mld_ruta'] ?? ''}',
        );
        _add('✓ SQL de "$nombre" recuperada y validada; ahora se descarga '
            'el molde');
      }

      final fileId = '${meta?['manifest_file_id'] ?? ''}';
      if (fileId.isEmpty) {
        throw StateError('indice.db no tiene el file_id de "$nombre.hash.db"');
      }
      final hashDb = File(
        '${tempDir.path}${Platform.pathSeparator}$nombre.hash.db',
      );
      await _telegramBot.descargarArchivo(
        token: config.token,
        fileId: fileId,
        destination: hashDb,
      );
      final manifest = await TelegramMldManifestStore.leer(
        ruta: hashDb.path,
        clave: claveMolde,
      );
      if (manifest.size != mldSize) {
        throw StateError('hash.db no coincide con indice.db');
      }

      final rutaIndice = '${ent['mld_ruta'] ?? ''}';
      final destino = rutaIndice.isNotEmpty
          ? File(rutaIndice)
          : await MediaBase.archivoMolde(nombre);
      if (!await destino.exists()) {
        await _telegramBot.restaurarMolde(
          token: config.token,
          manifest: manifest,
          destination: destino,
        );
      } else if (await destino.length() != manifest.size) {
        throw StateError(
          'ya existe un .mld distinto en ${destino.path}; no se sobrescribió',
        );
      }
      await Indice.actualizarRutas(
        pass: passIndice,
        nombre: nombre,
        dbRuta: sqlDestino.path,
        mldRuta: destino.path,
      );
      _add('✓ "$nombre" recuperado desde Telegram (SQL + '
          '${fmtBytes(manifest.size)} de .mld)');
    } finally {
      await tempDir.delete(recursive: true);
    }
  }

  Future<void> _telegramCuentaGuardar() async {
    try {
      final pass = await _passIndice();
      await Indice.guardarCredencialesTelegram(
        pass: pass,
        apiId: _telegramApiIdCtrl.text,
        apiHash: _telegramApiHashCtrl.text,
      );
      await _telegramActualizarEstadoIndice();
      final credentials = await Indice.credencialesTelegram(pass);
      await _telegramUser.iniciar(
        apiId: credentials.apiId,
        apiHash: credentials.apiHash,
        databaseKey: credentials.databaseKey,
      );
      _add('✓ TDLib inicializado; seguí el paso de autorización '
          '(teléfono, código y contraseña 2FA si corresponde)');
    } catch (e) {
      _add('✗ iniciar cuenta Telegram: $e');
      if (mounted) {
        setState(() {
          _telegramUserStep = TelegramUserAuthStep.error;
          _telegramUserError = '$e';
        });
      }
    }
  }

  void _telegramEnviarPasoAuth() {
    try {
      switch (_telegramUserStep) {
        case TelegramUserAuthStep.waitingPhone:
          _telegramUser.enviarTelefono(_telegramPhoneCtrl.text);
        case TelegramUserAuthStep.waitingCode:
          _telegramUser.enviarCodigo(_telegramCodeCtrl.text);
        case TelegramUserAuthStep.waitingPassword:
          _telegramUser.enviarContrasena(_telegramPasswordCtrl.text);
        default:
          _add('· TDLib no está pidiendo un dato de autorización ahora');
          return;
      }
      _add('· dato de autorización enviado a TDLib');
    } catch (e) {
      _add('✗ autorización Telegram: $e');
    }
  }

  Future<void> _telegramSubirIndice() async {
    if (!_telegramUser.isReady) {
      _add('✗ iniciá y autorizá la cuenta personal Telegram primero');
      return;
    }
    try {
      final directory = await MediaBase.carpetaMoldes();
      final indexFile =
          File('${directory.path}${Platform.pathSeparator}${Indice.archivo}');
      if (!await indexFile.exists()) {
        throw StateError('No existe ${Indice.archivo}');
      }
      final hash = await HuggingFace.sha256Archivo(indexFile.path);
      final messageId = await _telegramUser.subirIndice(
        indexFile.path,
        hash: hash,
      );
      final hashActual = await HuggingFace.sha256Archivo(indexFile.path);
      if (hashActual != hash) {
        setState(() => _telegramIndexPendiente = true);
        _add('⚠ se subió una versión de index.db (mensaje $messageId), '
            'pero el índice cambió durante el envío; volvé a respaldarlo');
        return;
      }
      await AppDb.guardar(
        'telegram_index_sha256',
        Uint8List.fromList(hash.codeUnits),
      );
      if (mounted) setState(() => _telegramIndexPendiente = false);
      _add('✓ ${Indice.archivo} cifrado respaldado en Mensajes guardados '
          '(mensaje $messageId; SHA-256 $hash)');
    } catch (e) {
      _add('✗ respaldo Telegram de index.db: $e');
    }
  }

  Future<void> _telegramBajarIndice() async {
    if (!_telegramUser.isReady) {
      _add('✗ iniciá y autorizá la cuenta personal Telegram primero');
      return;
    }
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restaurar index.db'),
        content: const Text(
          'Se descargará el último respaldo cifrado desde Mensajes guardados. '
          'El index.db local actual se conservará como .bak.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Restaurar'),
          ),
        ],
      ),
    );
    if (confirmar != true || !mounted) return;
    try {
      final directory = await MediaBase.carpetaMoldes();
      final target =
          File('${directory.path}${Platform.pathSeparator}${Indice.archivo}');
      final path = await _telegramUser.bajarUltimoIndice(target.path);
      final restoredHash = await HuggingFace.sha256Archivo(target.path);
      await AppDb.guardar(
        'telegram_index_sha256',
        Uint8List.fromList(restoredHash.codeUnits),
      );
      if (mounted) setState(() => _telegramIndexPendiente = false);
      _add('✓ index.db restaurado desde Mensajes guardados: $path');
      await _refrescarMoldes();
    } catch (e) {
      _add('✗ restaurar index.db desde Telegram: $e');
    }
  }
}
