part of '../mediablock_screen.dart';

/// Extensión de MediaBlockScreen (ver mediablock_screen.dart).
extension HfConfigExt on _MediaBlockScreenState {
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
