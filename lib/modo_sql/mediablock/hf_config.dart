part of '../mediablock_screen.dart';

/// Extensión de MediaBlockScreen (ver mediablock_screen.dart).
extension HfConfigExt on _MediaBlockScreenState {
  /// HF: repo+token que vale para EL ABIERTO (si no hay checks) o para los
  /// chequeados. Siempre pregunta cuando puede: qué querés usar, el abierto
  /// o los checks, para guardar / descargar / subir.
  Future<List<String>?> _destinosHf() async {
    final m = _infoAbierta?.nombre;
    final checks = _selSubir.toList()..sort();
    if (m == null && checks.isEmpty) {
      _add('· HF: abrí un molde primero');
      return null;
    }
    if (m != null && checks.isNotEmpty) {
      final eleccion = await _preguntarDestinoHf(m, checks);
      if (eleccion == null || !mounted) return null;
      return eleccion;
    }
    return checks.isNotEmpty ? checks : [m!];
  }

  /// HF: guarda repo (dir/user) + token en los destinos elegidos
  /// (el abierto o los checks, preguntando si hay de los dos).
  Future<void> _hfGuardar() async {
    final destinos = await _destinosHf();
    if (destinos == null || destinos.isEmpty || !mounted) return;

    final repo = _hfRepoCtrl.text.trim();
    final tok = _hfTokenCtrl.text.trim();
    if (tok.isNotEmpty) {
      _add('· verificando token en HF…');
      if (!await PuenteHf.tokenValidoConBearer(tok)) {
        _add('✗ el token NO valida en HF (¿mal copiado? ¿sin internet?). '
            'No se guardó.');
        return;
      }
      _add('✓ token válido');
    }
    try {
      final pass = await _passIndice();
      for (final n in destinos) {
        await Indice.guardarHf(
          pass: pass,
          nombre: n,
          hfRepo: repo,
          hfToken: tok,
        );
      }
      if (destinos.length == 1) {
        _add('✓ HF de "${destinos.first}" guardado');
      } else {
        _add(
            '✓ HF guardado en ${destinos.length} moldes (${destinos.join(', ')})');
      }
      await _refrescarMoldes();
      if (mounted) setState(() {});
    } catch (e) {
      _add('✗ HF guardar: $e');
    }
  }

  /// Diálogo: "oye, tenés 1 molde abierto pero tenés N checks, ¿qué querés
  /// guardar: el abierto o todos los chequeados?". Devuelve los nombres
  /// elegidos, o null si se cancela.
  Future<List<String>?> _preguntarDestinoHf(
      String abierto, List<String> checks) {
    return showDialog<List<String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title:
            Text('Tenés "$abierto" abierto pero tenés ${checks.length} check'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('¿Qué querés guardar?'),
              const SizedBox(height: 8),
              for (final n in checks)
                Text('· $n', style: const TextStyle(fontSize: 13)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, [abierto]),
            child: Text('En "$abierto"'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, checks),
            child: Text('En los ${checks.length} checks'),
          ),
        ],
      ),
    );
  }

  /// Índice: guarda SU repo+token propios (aparte de los moldes)
  /// con lo que dicen los campos repo/token. Ese es "el repo que
  /// digo yo" para subir/bajar el índice solo.
  Future<void> _hfGuardarIndice() async {
    final repo = _hfIndiceRepoCtrl.text.trim();
    final tok = _hfIndiceTokenCtrl.text.trim();
    if (repo.isEmpty || tok.isEmpty) {
      _add('· poné repo y token primero');
      return;
    }
    _add('· verificando token en HF…');
    if (!await PuenteHf.tokenValidoConBearer(tok)) {
      _add('✗ el token NO valida en HF (¿mal copiado? ¿sin internet?). '
          'No se guardó.');
      return;
    }
    _add('✓ token válido');
    try {
      await Indice.guardarHfIndice(
        pass: await _passIndice(),
        hfRepo: repo,
        hfToken: tok,
      );
      _add('✓ HF del ÍNDICE guardado ($repo)');
    } catch (e) {
      _add('✗ HF índice guardar: $e');
    }
  }
}
