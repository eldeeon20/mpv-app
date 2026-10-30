part of '../mediablock_screen.dart';

/// Extensión de MediaBlockScreen (ver mediablock_screen.dart).
extension AjustesMbExt on _MediaBlockScreenState {
  static const _kAjustesModo = 'ajustes_modo';

  /// Memoria libre (MB) para topar sliders. /proc en Android.
  Future<int> _memLibre() async {
    try {
      final txt = await File('/proc/meminfo').readAsString();
      for (final l in txt.split('\n')) {
        if (l.startsWith('MemAvailable:')) {
          final kb = int.parse(l.split(RegExp(r'\s+'))[1]);
          return (kb ~/ 1024).clamp(256, 32768);
        }
      }
    } catch (_) {}
    return 2048;
  }

  Future<void> _cargarAjustes() async {
    _memLibreMb = await _memLibre();
    // El json viejo no importa: se borra, app.db manda con defaults.
    await AppDb.tachar('ajustes_modo.json');
    try {
      final raw = await AppDb.leer(_kAjustesModo);
      if (raw != null) {
        final m =
            jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
        final sr = m['sqlRutas'];
        if (sr is List) {
          _sqlRutas = [
            for (final e in sr)
              if ('$e'.trim().isNotEmpty) '$e'.trim()
          ];
        }
        _limiteTrozosKb =
            ((m['trozosKb'] as num?)?.toInt() ?? 512).clamp(1024, 1 << 30);
        _limitePreviasMb =
            ((m['previasMb'] as num?)?.toInt() ?? 256).clamp(50, 8192);
        _limiteGlobalMb =
            ((m['globalMb'] as num?)?.toInt() ?? 1024).clamp(100, 16384);
      }
    } catch (_) {}
    // Trozos con tope de memoria libre (no prometer lo que no hay).
    final topeKb = _memLibreMb * 1024;
    if (_limiteTrozosKb > topeKb) _limiteTrozosKb = topeKb;
    final c = _cache;
    if (c != null) c.limiteBytes = _limiteTrozosKb * 1024;
    final p = _previaCache;
    if (p != null) p.limiteBytes = _limitePreviasMb * 1024 * 1024;
    // El global manda en disco (trozos+previas, entre moldes).
    _sesionCache.limiteGlobalBytes = _limiteGlobalMb * 1024 * 1024;
    _aplicarTopeRam();
    if (mounted) setState(() {});
  }

  /// Tope RAM total según memoria libre (previas+stash+minis):
  /// libre ≥4GB → 2GB; ≥2GB → 1GB; ≥1GB → 512MB; menos → 256MB.
  /// Suave recorta a 512MB como máximo. Sin límite por molde.
  void _aplicarTopeRam() {
    final libre = _memLibreMb;
    var tope = libre >= 4096
        ? 2 * 1024 * 1024 * 1024
        : libre >= 2048
            ? 1024 * 1024 * 1024
            : libre >= 1024
                ? 512 * 1024 * 1024
                : 256 * 1024 * 1024;
    if (_suave && tope > 512 * 1024 * 1024) {
      tope = 512 * 1024 * 1024;
    }
    _topeRamBytes = tope;
    // Mitad para minis, mitad para previas+stash (cada uno con su LRU).
    _minis.topeBytes = tope ~/ 2;
    _previasEvictar();
  }
  Future<void> _guardarAjustes() async {
    try {
      await AppDb.guardar(
        _kAjustesModo,
        Uint8List.fromList(utf8.encode(jsonEncode({
          'trozosKb': _limiteTrozosKb,
          'previasMb': _limitePreviasMb,
          'globalMb': _limiteGlobalMb,
          'sqlRutas': _sqlRutas,
        }))),
      );
    } catch (_) {}
  }

  /// Total de cachés (trozos + previas, todos los moldes).
  Future<int> _cacheTotal() async {
    if (!_sesionCache.abierta) return 0;
    try {
      final t = await TrozoCache.bytesTotales(_sesionCache);
      final p = await PreviaCache.bytesTotales(_sesionCache);
      return t + p;
    } catch (_) {
      return 0;
    }
  }

  /// El global evicta (LRU entre moldes) y avisa si sigue pasado.
  Future<void> _chequearGlobal() async {
    _sesionCache.limiteGlobalBytes = _limiteGlobalMb * 1024 * 1024;
    await _sesionCache.evictarGlobal();
    final total = await _cacheTotal();
    if (!mounted) return;
    final limite = _limiteGlobalMb * 1024 * 1024;
    if (total >= limite) {
      _add('⚠ caché total ${fmtBytes(total)} ≥ límite '
          'global ${fmtBytes(limite)} (vaciá en Ajustes)');
      if (mounted) setState(() {});
    }
  }
}
