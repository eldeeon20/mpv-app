part of '../mediablock_screen.dart';

/// Extensión de MediaBlockScreen (ver mediablock_screen.dart).
extension EscanerSqlExt on _MediaBlockScreenState {

  /// Cadena de intentos para abrir una SQL en el escáner:
  /// 1) la misma pass de moldes (+ plano, lo prueba abrirRuta);
  /// 2) passes ya conocidas en la sesión (por molde o por ruta);
  /// 3) null = hay que pedirla a mano.
  Future<List<String>?> _intentarEscanear(
      String ruta, String passIndice, String pass) async {
    try {
      return await Indice.escanearSql(
          pass: passIndice, sqlPath: ruta, claveSql: pass);
    } catch (_) {}
    final probadas = <String>{pass, ''};
    for (final p in [..._passPorMolde.values, ..._passPorRuta.values]) {
      if (!probadas.add(p)) continue;
      try {
        return await Indice.escanearSql(
            pass: passIndice, sqlPath: ruta, claveSql: p);
      } catch (_) {}
    }
    final pr = _passPorRuta[ruta];
    if (pr != null && probadas.add(pr)) {
      try {
        return await Indice.escanearSql(
            pass: passIndice, sqlPath: ruta, claveSql: pr);
      } catch (_) {}
    }
    return null;
  }

  /// Pide a mano la pass de una SQL que no abrió. null = saltear.
  Future<String?> _pedirPassRuta(String ruta) async {
    final ctrl = TextEditingController();
    final corto = ruta.split('/').last;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Pass de $corto'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                'No abrió con la pass de moldes ni en plano. '
                'Escribí SU pass (solo esta sesión, no se guarda):',
                style: TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            TextField(
              controller: ctrl,
              obscureText: true,
              decoration: const InputDecoration(
                  labelText: 'pass de esta SQL', border: OutlineInputBorder()),
              onSubmitted: (_) => Navigator.pop(ctx, true),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Saltear')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Probar')),
        ],
      ),
    );
    final v = ctrl.text;
    ctrl.dispose();
    if (ok != true || v.isEmpty) return null;
    return v;
  }

  /// Edita las rutas SQL extra (una por línea). Sin pass por ruta:
  /// el escáner las intenta todas con la misma pass de moldes.
  Future<void> _editarSqlRutas() async {
    final ctrl =
        TextEditingController(text: _sqlRutas.join('\n'));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rutas SQL a escanear'),
        content: SizedBox(
          width: 360,
          child: TextField(
            controller: ctrl,
            maxLines: 6,
            decoration: const InputDecoration(
                hintText: 'una ruta .db por línea',
                border: OutlineInputBorder()),
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
    final lineas = [
      for (final l in ctrl.text.split('\n'))
        if (l.trim().isNotEmpty) l.trim()
    ];
    ctrl.dispose();
    if (ok != true || !mounted) return;
    setState(() => _sqlRutas = lineas);
    await _guardarAjustes();
    _add('✓ ${lineas.length} ruta(s) SQL guardada(s)');
  }
  /// Índice: "esta SQL, ¿tiene algún molde?" La SQL dice qué
  /// moldes trae y dónde está cada .mld; el índice los registra.
  Future<void> _hfEscanearSql() async {
    final ruta = _hfSqlCtrl.text.trim();
    // Todas las SQL se intentan con LA MISMA pass (la de moldes):
    // no hay pass por ruta. Sin pass escrita, solo abren las .db
    // en plano.
    final pass = _clave;
    if (pass.isEmpty) {
      _add('· sin pass de moldes: solo abren las .db en plano '
          '(escribí la pass arriba para las cifradas)');
    }
    final rutas = <String>[];
    if (ruta.isNotEmpty) {
      rutas.add(ruta);
    }
    // Rutas fijas de Ajustes (sin pass por ruta).
    rutas.addAll(_sqlRutas);
    try {
      final tmp = Directory.systemTemp;
      await for (final e in tmp.list()) {
        if (e is File && e.path.endsWith('.db')) rutas.add(e.path);
      }
    } catch (_) {}
    try {
      final carp = await MediaBase.carpetaMoldes();
      await for (final e in carp.list()) {
        if (e is File && e.path.endsWith('.db')) rutas.add(e.path);
      }
    } catch (_) {}
    // Legado: si la carpeta vieja sigue existiendo (el rename no
    // pudo), también se escanea.
    try {
      final vieja = Directory('/storage/emulated/0/Download/test_sql');
      if (await vieja.exists()) {
        await for (final e in vieja.list()) {
          if (e is File && e.path.endsWith('.db')) rutas.add(e.path);
        }
      }
    } catch (_) {}
    // La propia del índice no se escanea (no es de moldes).
    rutas.removeWhere((r) => r.endsWith('/${Indice.archivo}'));
    if (rutas.isEmpty) {
      _add('· poné la ruta de la .db a escanear (o baja una primero)');
      return;
    }
    try {
      var total = 0;
      final vistos = <String>{};
      final passIndice = await _passIndice();
      for (final r in rutas) {
        if (!vistos.add(r)) continue;
        var nombres = await _intentarEscanear(r, passIndice, pass);
        if (nombres == null) {
          // No abrió con nada conocido: SE PIDE la pass de este archivo.
          final pedida = await _pedirPassRuta(r);
          if (pedida == null || !mounted) {
            _add('· "$r": salteada (sin pass)');
            continue;
          }
          _passPorRuta[r] = pedida;
          nombres = await _intentarEscanear(r, passIndice, pedida);
          if (nombres == null) {
            _add('✗ "$r": tampoco abre con esa pass');
            continue;
          }
        }
        if (nombres.isEmpty) {
          _add('· sin moldes en "$r"');
        } else {
          total += nombres.length;
          _add('✓ ${nombres.length} molde(s) desde "$r": '
              '${nombres.join(', ')}');
        }
      }
      if (total > 0) await _refrescarMoldes();
      if (mounted) setState(() {});
    } catch (e) {
      _add('✗ escanear SQL: $e');
    }
  }
}
