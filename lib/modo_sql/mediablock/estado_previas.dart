part of '../mediablock_screen.dart';

/// Extensión de MediaBlockScreen (ver mediablock_screen.dart).
extension EstadoPreviasExt on _MediaBlockScreenState {
  /// Mitad del tope RAM para previas+stash (la otra mitad es minis).
  int get _previasTope => _topeRamBytes ~/ 2;

  /// Bytes guardados en el stash de otros moldes (previas+unos).
  int _stashBytes() {
    var t = 0;
    for (final v in _previasBytesStash.values) {
      t += v;
    }
    for (final v in _unoBytesStash.values) {
      t += v;
    }
    return t;
  }

  void _unoGuardar(String nombre, Uint8List bytes) {
    final anterior = _uno.remove(nombre);
    if (anterior != null) _unoBytes -= anterior.length;
    _uno[nombre] = bytes;
    _unoBytes += bytes.length;
    _previasEvictar();
  }

  void _unoTocar(String nombre) {
    final bytes = _uno.remove(nombre);
    if (bytes != null) _uno[nombre] = bytes;
  }

  void _futurosQuitar(String nombre) {
    for (final k in _previasFut.keys.toList()) {
      if (k.endsWith('\n$nombre')) _previasFut.remove(k);
    }
    for (final k in _unoFut.keys.toList()) {
      if (k.endsWith('\n$nombre')) _unoFut.remove(k);
    }
  }

  /// Saca el molde más viejo del stash (orden de uso, no cantidad).
  void _evictarStashViejo() {
    if (_previasStash.isEmpty && _unoStash.isEmpty) return;
    final vieja = _previasStash.keys.isNotEmpty
        ? _previasStash.keys.first
        : _unoStash.keys.first;
    _previasStash.remove(vieja);
    _previasBytesStash.remove(vieja);
    _unoStash.remove(vieja);
    _unoBytesStash.remove(vieja);
    for (final k in _previasFut.keys.toList()) {
      if (k.startsWith('$vieja\n')) _previasFut.remove(k);
    }
    for (final k in _unoFut.keys.toList()) {
      if (k.startsWith('$vieja\n')) _unoFut.remove(k);
    }
  }

  void _previasGuardar(String nombre, List<Uint8List> p) {
    final vieja = _previas[nombre];
    if (vieja != null) {
      _previasBytes -= vieja.fold(0, (a, b) => a + b.length);
      _previas.remove(nombre);
    }
    _previas[nombre] = p;
    _previasBytes += p.fold(0, (a, b) => a + b.length);
    _previasEvictar();
  }

  void _previasEvictar() {
    // Primero sale el stash de otros moldes (por bytes, sin tope de
    // cantidad); el mapa abierto sale último (es lo que se ve).
    while (_previasBytes + _unoBytes + _stashBytes() > _previasTope &&
        (_previasStash.isNotEmpty || _unoStash.isNotEmpty)) {
      _evictarStashViejo();
    }
    while (_previasBytes + _unoBytes > _previasTope && _uno.length > 1) {
      final vieja = _uno.keys.first;
      _unoBytes -= _uno.remove(vieja)!.length;
      _futurosQuitar(vieja);
    }
    while (_previasBytes > _previasTope && _previas.length > 1) {
      final vieja = _previas.keys.first;
      final b = _previas.remove(vieja)!;
      _previasBytes -= b.fold(0, (a, x) => a + x.length);
      _futurosQuitar(vieja);
    }
  }

  /// Guarda el mapa RAM actual en el stash del molde que se deja.
  /// Sin límite de cantidad de moldes: manda el presupuesto en bytes.
  void _previasStashGuardar() {
    final m = _infoAbierta?.nombre;
    if (m == null || m.isEmpty) return;
    // Reinsertar = marcar como recién usado (orden = antigüedad).
    _previasStash.remove(m);
    _previasBytesStash.remove(m);
    _unoStash.remove(m);
    _unoBytesStash.remove(m);
    _previasStash[m] = Map.of(_previas);
    _previasBytesStash[m] = _previasBytes;
    _unoStash[m] = Map.of(_uno);
    _unoBytesStash[m] = _uno.values.fold(0, (a, b) => a + b.length);
    _previas.clear();
    _previasBytes = 0;
    _uno.clear();
    _unoBytes = 0;
    _previasEvictar();
  }

  /// Restaura el mapa RAM del molde que se abre ([] = primera vez).
  /// El molde activo deja de ocupar espacio duplicado en el stash.
  void _previasStashRestaurar(String molde) {
    final previasGuardadas = _previasStash.remove(molde);
    _previasBytes = _previasBytesStash.remove(molde) ?? 0;
    _previas
      ..clear()
      ..addAll(previasGuardadas ?? const {});
    final unoGuardado = _unoStash.remove(molde);
    _unoBytesStash.remove(molde);
    _uno
      ..clear()
      ..addAll(unoGuardado ?? const {});
    _unoBytes = _uno.values.fold(0, (a, b) => a + b.length);
    for (final k in _previasFut.keys.toList()) {
      if (!k.startsWith('$molde\n')) _previasFut.remove(k);
    }
    for (final k in _unoFut.keys.toList()) {
      if (!k.startsWith('$molde\n')) _unoFut.remove(k);
    }
  }

  /// LRU: la usada vuelve al fondo.
  void _previasTocar(String nombre) {
    final p = _previas[nombre];
    if (p == null) return;
    _previas.remove(nombre);
    _previas[nombre] = p;
  }

  /// Lee UN frame para el grid (disco primero, SQL después).
  /// Los videos JAMÁS tocan el original para mostrarse.
  /// Igual que las previas: 3 intentos y los fallos no se memoizan.
  Future<Uint8List?> _previaUnoDe(FichaArchivo f) {
    final m = _infoAbierta?.nombre;
    if (m == null) return Future.value(null);
    final ya = _uno[f.nombre];
    if (ya != null) {
      _unoTocar(f.nombre);
      return Future.value(ya);
    }
    final k = '$m\n${f.nombre}';
    final fut = _unoFut.putIfAbsent(k, () => _cargarUno(m, f));
    return fut.then((v) {
      if (v == null) _unoFut.remove(k);
      return v;
    });
  }

  Future<Uint8List?> _cargarUno(String m, FichaArchivo f) async {
    final ya = _uno[f.nombre];
    if (ya != null) {
      _unoTocar(f.nombre);
      return ya;
    }
    Object? ultimoError;
    for (var intento = 1; intento <= 3; intento++) {
      try {
        return await _leerUno(m, f);
      } catch (e) {
        ultimoError = e;
        if (intento == 3) {
          _add('✗ previa video "${f.nombre}": $ultimoError');
          return null;
        }
        await Future.delayed(Duration(milliseconds: 250 * intento));
      }
    }
    return null;
  }

  /// Una lectura de 1 frame. null sin lanzar = no hay previa.
  Future<Uint8List?> _leerUno(String m, FichaArchivo f) async {
    // Disco primero (1 frame, misma fila que los 17).
    final disco = await _previaCache?.leerUno(archivo: f.nombre);
    if (disco != null && disco.isNotEmpty) {
      final vis = await PreviewMolde.mostrable(disco);
      _unoGuardar(f.nombre, vis);
      return vis;
    }
    final b = await CreateMoldeSql.previaUno(
      claveSql: _clave,
      molde: m,
      archivo: f.nombre,
      cache: _cache,
      info: _infoAbierta,
      log: _add,
    );
    if (b != null && b.isNotEmpty) {
      final vis = await PreviewMolde.mostrable(b);
      _unoGuardar(f.nombre, vis);
      try {
        await _previaCache?.guardarUno(archivo: f.nombre, frame: b);
      } catch (e) {
        _add('⚠ no se pudo guardar la previa en caché: $e');
      }
      return vis;
    }
    return null;
  }

  /// Lee las previas guardadas de un archivo ([] = sin previas,
  /// moldes viejos: el grid usa mini al vuelo).
  /// Los fallos NO se memoizan: si el future da vacío se saca del
  /// mapa para que el próximo build reintente (antes quedaba el []
  /// pegado y la celda no se actualizaba jamás).
  Future<List<Uint8List>> _previasDe(FichaArchivo f) {
    final m = _infoAbierta?.nombre;
    if (m == null) return Future.value(const <Uint8List>[]);
    final k = '$m\n${f.nombre}';
    final fut = _previasFut.putIfAbsent(k, () => _cargarPrevias(m, f));
    return fut.then((v) {
      if (v.isEmpty) _previasFut.remove(k);
      return v;
    });
  }

  /// Hasta 3 intentos con espera creciente. Vacía SIN error = no hay
  /// previas (no se reintenta); error = se reintenta.
  Future<List<Uint8List>> _cargarPrevias(String m, FichaArchivo f) async {
    final ya = _previas[f.nombre];
    if (ya != null) {
      _previasTocar(f.nombre);
      return ya;
    }
    Object? ultimoError;
    for (var intento = 1; intento <= 3; intento++) {
      try {
        final vis = await _leerPrevia(m, f);
        if (vis.isEmpty) return const [];
        _previasGuardar(f.nombre, vis);
        return vis;
      } catch (e) {
        ultimoError = e;
        if (intento == 3) {
          _add('✗ previa "${f.nombre}": $ultimoError');
          return const [];
        }
        await Future.delayed(Duration(milliseconds: 250 * intento));
      }
    }
    return const [];
  }

  /// Una lectura de previa (disco primero, SQL después). Lanza si
  /// falla para que el llamador reintente; vacía sin lanzar = no hay.
  Future<List<Uint8List>> _leerPrevia(String m, FichaArchivo f) async {
    // Disco primero (TODOS los frames: la transición sobrevive).
    final disco = await _previaCache?.leerTodos(archivo: f.nombre);
    if (disco != null && disco.isNotEmpty) {
      // AVIF → mostrable (una vez; RAM memoiza).
      final vis = <Uint8List>[];
      for (final b in disco) {
        vis.add(await PreviewMolde.mostrable(b));
      }
      return vis;
    }
    final p = await CreateMoldeSql.previasDe(
      claveSql: _clave,
      molde: m,
      archivo: f.nombre,
      cache: _cache,
      info: _infoAbierta,
      log: _add,
    );
    final vis = <Uint8List>[];
    for (final b in p) {
      vis.add(await PreviewMolde.mostrable(b));
    }
    if (p.isNotEmpty) {
      try {
        // En disco se guarda el ORIGINAL (AVIF chico); en RAM el
        // mostrable. La próxima sale de disco sin tocar el molde.
        await _previaCache?.guardarTodos(archivo: f.nombre, frames: p);
      } catch (_) {}
    }
    return vis;
  }
}
