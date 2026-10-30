part of '../mediablock_screen.dart';

/// Extensión de MediaBlockScreen (ver mediablock_screen.dart).
extension HfFlujosExt on _MediaBlockScreenState {
  /// Sube los seleccionados (cada uno a SU repo; por hash salta
  /// lo que ya está arriba). Log por molde + resumen.
  Future<void> _subirSeleccionados() async {
    if (_hfOcupado || _selSubir.isEmpty) return;
    setState(() => _hfOcupado = true);
    try {
      final r = await _puenteHf.subirSeleccionados(
        passIndice: await _passIndice(),
        claveSql: _clave,
        nombres: _selSubir.toList(),
        conIndice: _hfConIndice,
        log: _add,
      );
      _add('✓ subida selección: ${r.subidos} subido(s), '
          '${r.saltados} ya estaban');
      if (mounted) setState(() => _selSubir.clear());
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

  /// HF: sube .mld + SQL del molde abierto (+ índice solo si el
  /// check "Subir índice junto" está puesto).
  Future<void> _hfSubir() async {
    if (_hfOcupado) return;
    final m = _infoAbierta?.nombre;
    if (m == null) {
      _add('· HF: abrí un molde primero');
      return;
    }
    setState(() => _hfOcupado = true);
    try {
      await _puenteHf.subirMolde(
        passIndice: await _passIndice(),
        claveSql: _clave,
        nombre: m,
        conIndice: _hfConIndice,
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
    final m = _infoAbierta?.nombre ?? _hfRepoCtrl.text.trim();
    if (m.isEmpty) {
      _add('· HF: abrí un molde o poné su nombre en repo');
      return;
    }
    setState(() => _hfOcupado = true);
    try {
      final ruta = await _puenteHf.bajarSql(
        passIndice: await _passIndice(),
        nombre: _infoAbierta?.nombre ?? m,
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

  Future<void> _telegramBotGuardar() async {
    final token = _telegramBotTokenCtrl.text.trim();
    final chatId = _telegramBotChatCtrl.text.trim();
    if (token.isEmpty || chatId.isEmpty) {
      _add('· completá token del bot y chat destino');
      return;
    }
    if (_telegramBotOcupado) return;
    setState(() => _telegramBotOcupado = true);
    try {
      final username = await _telegramBot.validarBot(token);
      await _telegramBot.validarDestino(token: token, chatId: chatId);
      await Indice.guardarBotTelegram(
        pass: await _passIndice(),
        token: token,
        chatId: chatId,
      );
      await _telegramActualizarEstadoIndice();
      _add('✓ bot @$username y destino validados; configuración guardada '
          'en index.db cifrado');
    } catch (e) {
      _add('✗ validar/guardar Bot API: $e');
    } finally {
      if (mounted) setState(() => _telegramBotOcupado = false);
    }
  }

  Future<void> _telegramBotSubirMolde() async {
    final nombre = _infoAbierta?.nombre;
    if (nombre == null) {
      _add('· abrí el molde que querés subir por Bot API');
      return;
    }
    if (_telegramBotOcupado) return;
    setState(() => _telegramBotOcupado = true);
    try {
      final passIndice = await _passIndice();
      final config = await Indice.botTelegram(passIndice);
      final ent = await Indice.entrada(pass: passIndice, nombre: nombre);
      if (ent == null) throw StateError('"$nombre" no está en index.db');
      final rutaMld = '${ent['mld_ruta'] ?? ''}';
      final archivo = File(rutaMld);
      if (!await archivo.exists()) {
        throw StateError('No hay .mld local para subir: $rutaMld');
      }
      if (config.token.isEmpty || config.chatId.isEmpty) {
        throw StateError('configurá y validá el Bot API primero');
      }

      _add('· subiendo "$nombre.mld" en partes de 17 MB; '
          'el archivo ya está cifrado y no se vuelve a cifrar');
      var ultimoProgreso = -1;
      final manifest = await _telegramBot.subirMolde(
        token: config.token,
        chatId: config.chatId,
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
        clave: _clave,
        manifest: manifest,
      );
      final subidaManifiesto = await _telegramBot.subirArchivo(
        token: config.token,
        chatId: config.chatId,
        ruta: rutaManifiesto.path,
        nombre: '$nombre.hash.db',
      );
      final rutaSql = '${ent['db_ruta'] ?? ''}';
      final archivoSql = File(rutaSql);
      if (!await archivoSql.exists()) {
        throw StateError('No existe la SQL cifrada del molde: $rutaSql');
      }
      if (await archivoSql.length() >= 20 * 1000 * 1000) {
        throw StateError(
          'La SQL del molde supera el límite de descarga Bot API de 20 MB; '
          'usá Hugging Face para este molde.',
        );
      }
      final cajaSql = CajaSql();
      await cajaSql.abrirRuta(rutaSql, clave: _clave);
      cajaSql.cerrar();
      final subidaSql = await _telegramBot.subirArchivo(
        token: config.token,
        chatId: config.chatId,
        ruta: rutaSql,
        nombre: '$nombre.sql.db',
      );
      await Indice.guardarManifiestoTelegram(
        pass: passIndice,
        nombre: nombre,
        chatId: config.chatId,
        fileId: subidaManifiesto.fileId,
        messageId: subidaManifiesto.messageId,
        size: manifest.size,
        sqlFileId: subidaSql.fileId,
        sqlMessageId: subidaSql.messageId,
        sqlSize: subidaSql.size,
      );
      _add('✓ "$nombre.mld" subido en ${manifest.parts.length} partes; '
          'SQL cifrada y hash.db cifrado enlazados desde index.db');
      await _refrescarMoldes();
      if (_telegramUser.isReady) {
        await _telegramPreguntarRespaldoIndice();
      } else {
        _add('⚠ index.db cambió. Conectá la cuenta Telegram personal para '
            'respaldarlo en Mensajes guardados.');
      }
    } catch (e) {
      _add('✗ subir molde por Bot API: $e');
    } finally {
      if (mounted) setState(() => _telegramBotOcupado = false);
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

  Future<void> _telegramPreguntarRespaldoIndice() async {
    if (!mounted) return;
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Respaldar index.db'),
        content: const Text(
          'El catálogo cambió. ¿Subir ahora index.db ya cifrado a '
          'Mensajes guardados de tu cuenta Telegram personal? '
          'No se vuelve a cifrar.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Después'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Respaldar ahora'),
          ),
        ],
      ),
    );
    if (confirmar == true) {
      await _telegramSubirIndice();
    } else {
      _add(
          '⚠ index.db quedó actualizado localmente; respaldo de Telegram pendiente');
    }
  }
}
