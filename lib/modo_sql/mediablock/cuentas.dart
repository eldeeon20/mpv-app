part of '../mediablock_screen.dart';

extension CuentasExt on _MediaBlockScreenState {
  Future<void> _refrescarCuentasNube() async {
    try {
      final pass = await _passIndice();
      if (pass.isEmpty) {
        _add('· ingresá la clave del índice para gestionar cuentas');
        return;
      }
      final accounts = await Indice.cuentasNube(pass);
      if (!mounted) return;
      setState(() => _cuentasNube = accounts);
    } catch (e) {
      _add('✗ leer cuentas: $e');
    }
  }

  Future<void> _crearCuentaNube() async {
    final name = TextEditingController();
    final destination = TextEditingController();
    final secret = TextEditingController();
    var provider = 'telegram_bot';
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, refresh) => AlertDialog(
          title: const Text('Agregar cuenta o destino'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: provider,
                    decoration: const InputDecoration(labelText: 'Servicio'),
                    items: const [
                      DropdownMenuItem(
                        value: 'telegram_bot',
                        child: Text('Telegram Bot API'),
                      ),
                      DropdownMenuItem(
                        value: 'huggingface',
                        child: Text('Hugging Face'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) refresh(() => provider = value);
                    },
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: name,
                    decoration: const InputDecoration(
                      labelText: 'Nombre para reconocerla',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: destination,
                    decoration: InputDecoration(
                      labelText: provider == 'telegram_bot'
                          ? 'Chat ID de destino'
                          : 'Repo HF (usuario/repositorio)',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: secret,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: provider == 'telegram_bot'
                          ? 'Token del bot'
                          : 'Token HF (write)',
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'La credencial se guarda dentro de index.db cifrado.',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Validar y guardar'),
            ),
          ],
        ),
      ),
    );
    final accountName = name.text.trim();
    final target = destination.text.trim();
    final token = secret.text.trim();
    name.dispose();
    destination.dispose();
    secret.dispose();
    if (result != true || !mounted) return;
    try {
      if (provider == 'telegram_bot') {
        await _telegramBot.validarBot(token);
        await _telegramBot.validarDestino(token: token, chatId: target);
      } else {
        if (!await PuenteHf.tokenValidoConBearer(token)) {
          throw StateError('El token HF no fue validado');
        }
      }
      await Indice.guardarCuentaNube(
        pass: await _passIndice(),
        provider: provider,
        name: accountName,
        destination: target,
        secret: token,
      );
      await _telegramActualizarEstadoIndice();
      await _refrescarCuentasNube();
      _add('✓ cuenta "$accountName" validada y guardada');
    } catch (e) {
      _add('✗ guardar cuenta: $e');
    }
  }

  Future<void> _eliminarCuentaNube(CuentaNube account) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar cuenta'),
        content: Text('¿Quitar "${account.nombre}" de este índice?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await Indice.quitarCuentaNube(
        pass: await _passIndice(),
        id: account.id,
      );
      await _telegramActualizarEstadoIndice();
      await _refrescarCuentasNube();
      _add('✓ cuenta "${account.nombre}" quitada del índice');
    } catch (e) {
      _add('✗ quitar cuenta: $e');
    }
  }

  Future<CuentaNube?> _elegirCuentaNube(String provider) async {
    await _refrescarCuentasNube();
    if (!mounted) return null;
    final accounts =
        _cuentasNube.where((account) => account.proveedor == provider).toList();
    final selected = await showDialog<CuentaNube>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(provider == 'telegram_bot'
            ? 'Elegir cuenta Telegram Bot (${accounts.length})'
            : 'Elegir cuenta Hugging Face (${accounts.length})'),
        content: SizedBox(
          width: 420,
          child: accounts.isEmpty
              ? const Text('Todavía no hay cuentas de este servicio.')
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final account in accounts)
                      ListTile(
                        leading: Icon(provider == 'telegram_bot'
                            ? Icons.send_rounded
                            : Icons.cloud_rounded),
                        title: Text(account.nombre),
                        subtitle: Text(account.destino),
                        onTap: () => Navigator.pop(ctx, account),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _tabs.animateTo(5);
            },
            child: const Text('Agregar cuenta'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
        ],
      ),
    );
    return selected;
  }

  Widget _tabCuentas() {
    final bots =
        _cuentasNube.where((account) => account.proveedor == 'telegram_bot');
    final hf =
        _cuentasNube.where((account) => account.proveedor == 'huggingface');
    return Scrollbar(
      thumbVisibility: true,
      interactive: true,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Cuentas y servidores',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          const Text(
            'Agregá varios destinos. Al subir un molde vas a poder elegir '
            'cuál usar. Las credenciales se guardan en el índice cifrado.',
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: _crearCuentaNube,
            icon: const Icon(Icons.add_rounded),
            label: const Text('Agregar cuenta de nube'),
          ),
          const SizedBox(height: 8),
          const Text('Telegram Bot API',
              style: TextStyle(fontWeight: FontWeight.bold)),
          for (final account in bots)
            Card(
              child: ListTile(
                leading: const Icon(Icons.send_rounded),
                title: Text(account.nombre),
                subtitle: Text(account.destino),
                trailing: IconButton(
                  tooltip: 'Eliminar cuenta',
                  onPressed: () => _eliminarCuentaNube(account),
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
              ),
            ),
          const SizedBox(height: 8),
          const Text('Hugging Face',
              style: TextStyle(fontWeight: FontWeight.bold)),
          for (final account in hf)
            Card(
              child: ListTile(
                leading: const Icon(Icons.cloud_rounded),
                title: Text(account.nombre),
                subtitle: Text(account.destino),
                trailing: IconButton(
                  tooltip: 'Eliminar cuenta',
                  onPressed: () => _eliminarCuentaNube(account),
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
              ),
            ),
          const Divider(height: 28),
          const Text(
            'Cuenta personal de Telegram (TDLib)',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const Text(
            'Se usa para guardar y restaurar index.db en Mensajes guardados. '
            'No es un destino de subida de moldes. '
            'La autorización TDLib está disponible solo en Android.',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 8),
          campoTexto(_telegramApiIdCtrl, 'API ID de my.telegram.org'),
          const SizedBox(height: 6),
          campoTexto(_telegramApiHashCtrl, 'API Hash', oculto: true),
          FilledButton.tonalIcon(
            onPressed: Platform.isAndroid ? _telegramCuentaGuardar : null,
            icon: const Icon(Icons.login_rounded, size: 18),
            label: Text(Platform.isAndroid
                ? 'Guardar credenciales e iniciar TDLib'
                : 'TDLib personal no disponible en Windows'),
          ),
          if (_telegramUserStep == TelegramUserAuthStep.waitingPhone) ...[
            campoTexto(_telegramPhoneCtrl, 'teléfono internacional (+...)'),
            FilledButton.tonal(
              onPressed: _telegramEnviarPasoAuth,
              child: const Text('Enviar teléfono'),
            ),
          ],
          if (_telegramUserStep == TelegramUserAuthStep.waitingCode) ...[
            campoTexto(_telegramCodeCtrl, 'código recibido de Telegram'),
            FilledButton.tonal(
              onPressed: _telegramEnviarPasoAuth,
              child: const Text('Enviar código'),
            ),
          ],
          if (_telegramUserStep == TelegramUserAuthStep.waitingPassword) ...[
            campoTexto(_telegramPasswordCtrl, 'contraseña 2FA', oculto: true),
            FilledButton.tonal(
              onPressed: _telegramEnviarPasoAuth,
              child: const Text('Enviar contraseña'),
            ),
          ],
          if (_telegramUserError != null)
            Text(_telegramUserError!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
          if (_telegramUserStep == TelegramUserAuthStep.ready)
            const ListTile(
              dense: true,
              leading: Icon(Icons.verified_rounded, color: Colors.greenAccent),
              title: Text('Cuenta personal Telegram autorizada'),
            ),
          ListTile(
            dense: true,
            leading: Icon(
              _telegramIndexPendiente
                  ? Icons.cloud_off_rounded
                  : Icons.cloud_done_rounded,
              color: _telegramIndexPendiente
                  ? Colors.amberAccent
                  : Colors.greenAccent,
            ),
            title: Text(_telegramIndexPendiente
                ? 'index.db: respaldo pendiente'
                : 'index.db: respaldado'),
          ),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: _telegramUser.isReady ? _telegramSubirIndice : null,
                icon: const Icon(Icons.backup_rounded, size: 18),
                label: const Text('Respaldar index.db'),
              ),
              FilledButton.tonalIcon(
                onPressed: _telegramUser.isReady ? _telegramBajarIndice : null,
                icon: const Icon(Icons.restore_rounded, size: 18),
                label: const Text('Restaurar index.db'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
