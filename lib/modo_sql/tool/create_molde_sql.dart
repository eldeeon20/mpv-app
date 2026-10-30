import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../cache/trozo_cache.dart';
import '../indice/indice.dart';
import '../db/caja_sql.dart';
import '../media_server/media_server.dart';
import '../preview_molde.dart';

/// HERRAMIENTA (una vez): crea `.mld` + índice en TU sql.
/// Clave ÚNICA: abre tu SQL y deriva el molde.
class CreateMoldeSql {
  CreateMoldeSql._();

  static const baseDatos = 'media_server';

  /// Ruta del archivo SQL propio de un molde (para el índice).
  static Future<String> rutaDbPropia(String molde) async {
    final db = 'm_${molde.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.db';
    final dir = await dirSql();
    if (dir != null) return '$dir/$db';
    final sup = await getApplicationSupportDirectory();
    return '${sup.path}/db/$db';
  }

  /// SQL por defecto en Download/mediablock (visible); si no se puede,
  /// soporte. Migra la vieja copiándola una vez (no se borra).
  static Future<String?> dirSql() async {
    try {
      final down = await MediaBase.carpetaDescargas();
      if (down == null) return null;
      final dest = File('${down.path}/$baseDatos.db');
      if (!await dest.exists()) {
        final sup = await getApplicationSupportDirectory();
        final vieja = File('${sup.path}/db/$baseDatos.db');
        if (await vieja.exists()) await vieja.copy(dest.path);
      }
      return down.path;
    } catch (_) {
      return null;
    }
  }

  /// Memos RAM de sesión (el PBKDF2 + re-leer la SQL en cada pedido
  /// trancaba el scroll: todo corría en el hilo UI sin caché).
  static final Map<String, MoldeInfo> _memoInfo = {};
  static final Map<String, List<FichaArchivo>> _memoFilas = {};
  static final Map<String, Uint8List> _memoClaves = {};

  static String _k(String claveSql, String molde) => '$claveSql\x00$molde';

  /// Olvida un molde (llamar tras editar tags/borrar, para no servir
  /// filas viejas desde el memo).
  static void olvidarMolde(String molde) {
    _memoInfo.removeWhere((k, _) => k.endsWith('\x00$molde'));
    _memoFilas.removeWhere((k, _) => k.endsWith('\x00$molde'));
    _memoClaves.removeWhere((k, _) => k.contains('\x00$molde\x00'));
  }

  /// Clave de archivo memoizada (un solo PBKDF2 por archivo/sesión).
  static Future<Uint8List> claveDe({
    required String claveSql,
    required String molde,
    required String archivo,
    required String salHex,
  }) async {
    final k = '${_k(claveSql, molde)}\x00$archivo\x00$salHex';
    final ya = _memoClaves[k];
    if (ya != null) return ya;
    final c = await Duro.claveArchivoHilo(
      clave: claveSql,
      molde: molde,
      nombre: archivo,
      salHex: salHex,
    );
    if (_memoClaves.length > 100) _memoClaves.clear();
    _memoClaves[k] = c;
    return c;
  }

  /// Índice de UN molde: cada molde arma su propia SQL (`m_<molde>`).
  /// Sin [molde] = la SQL vieja compartida (`media_server`, legacy).
  static Future<CajaSql> abrirIndice(
      {required String claveSql, String? molde}) async {
    if (claveSql.isEmpty) {
      throw ArgumentError('mediablock: la clave no puede vacía');
    }
    final db = molde == null
        ? baseDatos
        : 'm_${molde.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}';
    final caja = CajaSql();
    // La SQL va cifrada entera (sqlite3mc ChaCha20) con su propia
    // clave; adentro nombres+tags van en bruto (sin cifrado manual).
    await caja.abrir(db, carpeta: await dirSql(), clave: claveSql);
    caja.crearTabla(MediaBase.tablaMoldes, {
      'nombre': 'TEXT UNIQUE',
      'ruta': 'TEXT',
      'semilla': 'TEXT',
      'fecha': 'INTEGER',
      'total': 'INTEGER',
      'sal': 'TEXT',
      'cifrado': 'TEXT',
      // Gemelo en HF (ruta `hf://repo/molde.mld`): la ruta local
      // queda, esto dice dónde está subido. Vacío = no subido.
      'hf': 'TEXT',
    });
    if (!caja.campos(MediaBase.tablaMoldes).contains('sal')) {
      caja.agregarCampo(MediaBase.tablaMoldes, 'sal', 'TEXT');
    }
    if (!caja.campos(MediaBase.tablaMoldes).contains('cifrado')) {
      caja.agregarCampo(MediaBase.tablaMoldes, 'cifrado', 'TEXT');
    }
    if (!caja.campos(MediaBase.tablaMoldes).contains('hf')) {
      caja.agregarCampo(MediaBase.tablaMoldes, 'hf', 'TEXT');
    }
    caja.crearTabla(MediaBase.tablaArchivos, {
      'molde': 'TEXT',
      'nombre': 'TEXT',
      'formato': 'TEXT',
      'tamano': 'INTEGER',
      'inicio': 'INTEGER',
      'fin': 'INTEGER',
      'fecha': 'INTEGER',
      'tag1': 'TEXT',
      'tag2': 'TEXT',
      'tag3': 'TEXT',
      'tag4': 'TEXT',
      'tag5': 'TEXT',
      'tag6': 'TEXT',
      'tag7': 'TEXT',
      'tag8': 'TEXT',
      'trozo': 'INTEGER',
    });
    if (!caja.campos(MediaBase.tablaArchivos).contains('trozo')) {
      caja.agregarCampo(MediaBase.tablaArchivos, 'trozo', 'INTEGER');
    }
    // La SQL va cifrada entera (sqlite3mc); adentro nombres+tags
    // van en bruto. `*_c` solo se lee (moldes viejos), no se escribe.
    if (!caja.campos(MediaBase.tablaArchivos).contains('nombre_c')) {
      caja.agregarCampo(MediaBase.tablaArchivos, 'nombre_c', 'TEXT');
    }
    if (!caja.campos(MediaBase.tablaArchivos).contains('tags_c')) {
      caja.agregarCampo(MediaBase.tablaArchivos, 'tags_c', 'TEXT');
    }
    caja.crearTabla('papelera', {
      'molde': 'TEXT',
      'nombre': 'TEXT',
      'fila': 'TEXT',
      'borrado': 'INTEGER',
    });
    caja.crearIndice(MediaBase.tablaArchivos, 'molde');
    return caja;
  }

  /// Clave del molde (para su índice) desde su fila `moldes`.
  static Future<Uint8List> _claveMoldeDe(
      CajaSql caja, String claveSql, String molde) async {
    final m = caja.uno(MediaBase.tablaMoldes, 'nombre = ?', [molde]);
    return Duro.claveMoldeHilo(
      clave: claveSql,
      molde: molde,
      salHex: '${m?['sal'] ?? ''}',
    );
  }

  /// Fila con nombre+tags reales (descifra en hilo si hay `*_c`).
  static Future<Map<String, Object?>> _filaReal(
      Uint8List moldeKey, Map<String, Object?> r) async {
    final nc = '${r['nombre_c'] ?? ''}';
    if (nc.isEmpty) return r; // legacy en plano
    final m = Map<String, Object?>.from(r);
    final nombre = await Duro.descifrarTexto(claveMolde: moldeKey, dato: nc);
    m['nombre'] = nombre;
    m['formato'] = _formato(nombre);
    final tc = '${r['tags_c'] ?? ''}';
    final tags = tc.isEmpty
        ? <String>[]
        : (await Duro.descifrarTexto(claveMolde: moldeKey, dato: tc))
            .split('\n')
            .where((t) => t.isNotEmpty)
            .toList();
    for (var i = 0; i < MediaBase.maxTags; i++) {
      m['tag${i + 1}'] = i < tags.length ? tags[i] : '';
    }
    return m;
  }

  /// Crea `<nombre>.mld` desde [origenDir] (recursivo) + índice.
  /// [passIndice]: si viene, registra el molde en el catálogo cifrado.
  static Future<int> crear({
    required String nombre,
    required String origenDir,
    required String clave,
    List<String> tags = const [],
    Map<String, List<String>>? tagsPorArchivo,
    int trozoClaro = Duro.trozoClaro,
    String? passIndice,
    // Captura de video (surface oculta del creador). Sin captura,
    // los videos quedan sin previas (icono+formato).
    CapturaVideo? captura,
    void Function(String s)? log,
  }) async {
    MediaBase.exigirNombre('molde', nombre);
    if (clave.isEmpty) {
      throw ArgumentError('mediablock: la clave no puede vacía');
    }
    if (trozoClaro <= 0) {
      throw ArgumentError('mediablock: trozoClaro debe ser > 0');
    }
    final origen = Directory(origenDir);
    if (!await origen.exists()) {
      throw ArgumentError('mediablock: no existe la carpeta "$origenDir"');
    }
    final comunes = MediaBase.sanearTags(tags);
    final porArchivo = <String, List<String>>{};
    tagsPorArchivo?.forEach((k, v) {
      porArchivo[k] = MediaBase.sanearTags(v);
    });

    final base = origen.uri.toFilePath();
    final fuentes = <File>[];
    await for (final e in origen.list(recursive: true, followLinks: false)) {
      if (e is File) fuentes.add(e);
    }
    String rel(File f) {
      var r = f.uri.toFilePath();
      if (r.startsWith(base)) r = r.substring(base.length);
      return r.replaceAll('\\', '/');
    }

    fuentes.sort((a, b) => rel(a).compareTo(rel(b)));
    if (fuentes.isEmpty) {
      throw StateError('mediablock: "$origenDir" no trae archivos');
    }

    final destino = await MediaBase.archivoMolde(nombre);
    if (await destino.exists()) {
      throw StateError(
        'mediablock: ya existe el archivo del molde "${destino.path}"',
      );
    }
    final cajaInicial = await abrirIndice(claveSql: clave, molde: nombre);
    try {
      if (cajaInicial.uno(MediaBase.tablaMoldes, 'nombre = ?', [nombre]) !=
          null) {
        throw StateError(
          'mediablock: el molde "$nombre" ya existe (borralo)',
        );
      }
    } finally {
      cajaInicial.cerrar();
    }
    final temporal = File(
      '${destino.path}.building_${DateTime.now().microsecondsSinceEpoch}',
    );
    final sal = Duro.nuevaSal();
    var offset = 0;
    final filas = <Map<String, Object?>>[];
    var conPrevias = 0;
    await temporal.create(recursive: true);
    try {
      var idx = 0;
      for (final f in fuentes) {
        final nombreRel = rel(f);
        idx++;
        if (nombreRel.isEmpty) continue;
        final tam = await f.length();
        // Progreso real: el cifrado por trozos no avisa solo.
        // Sin esto la bitácora se queda en "cifrando…" horas.
        log?.call('· [$idx/${fuentes.length}] $nombreRel '
            '(${(tam / 1048576).toStringAsFixed(1)}MB)');
        final fecha = (await f.lastModified()).millisecondsSinceEpoch;
        final claveArchivo = await Duro.claveArchivoHilo(
          clave: clave,
          molde: nombre,
          nombre: nombreRel,
          salHex: sal,
        );
        await Duro.cifrarArchivoADiscoHilo(
          claveArchivo: claveArchivo,
          trozoClaro: trozoClaro,
          origen: f.path,
          destino: temporal.path,
          tamanoEsperado: tam,
        );
        final guardado = _largoGuardado(tam, trozoClaro);
        final tagsF = porArchivo[nombreRel] ?? comunes;
        filas.add(MediaBase.filaArchivo(
          molde: nombre,
          nombre: nombreRel,
          formato: _formato(nombreRel),
          tamano: tam,
          inicio: offset,
          fin: offset + guardado,
          fecha: fecha,
          tags: tagsF,
          trozo: trozoClaro,
        ));
        offset += guardado;
        try {
          final previas = await PreviewMolde.generar(
            ruta: f.path,
            formato: _formato(nombreRel),
            captura: captura,
          );
          for (var i = 0; i < previas.length; i++) {
            final bytes = previas[i];
            final nombrePrevia = PreviewMolde.entrada(nombreRel, i);
            final clavePrevia = await Duro.claveEntrada(
              claveArchivo: claveArchivo,
              nombreEntrada: nombrePrevia,
            );
            final tmpP = File(
              '${Directory.systemTemp.path}/prev_'
              '${DateTime.now().microsecondsSinceEpoch}_$i.tmp',
            );
            try {
              await tmpP.writeAsBytes(bytes, flush: true);
              await Duro.cifrarArchivoADiscoHilo(
                claveArchivo: clavePrevia,
                trozoClaro: trozoClaro,
                origen: tmpP.path,
                destino: temporal.path,
                tamanoEsperado: bytes.length,
              );
              final guardadoP = _largoGuardado(bytes.length, trozoClaro);
              filas.add(MediaBase.filaArchivo(
                molde: nombre,
                nombre: nombrePrevia,
                formato: 'prev',
                tamano: bytes.length,
                inicio: offset,
                fin: offset + guardadoP,
                fecha: fecha,
                tags: const [],
                trozo: trozoClaro,
              ));
              offset += guardadoP;
              conPrevias++;
            } finally {
              if (await tmpP.exists()) await tmpP.delete();
            }
          }
          if (previas.isEmpty && PreviewMolde.esVideo(_formato(nombreRel))) {
            log?.call('⚠ sin previas de video: $nombreRel');
          }
        } catch (e) {
          log?.call('✗ previa "$nombreRel": $e');
        }
      }
      final caja = await abrirIndice(claveSql: clave, molde: nombre);
      var movido = false;
      try {
        caja.db.execute('BEGIN IMMEDIATE;');
        try {
          if (caja.uno(MediaBase.tablaMoldes, 'nombre = ?', [nombre]) != null) {
            throw StateError(
              'mediablock: el molde "$nombre" ya existe (borralo)',
            );
          }
          for (final fila in filas) {
            caja.agregar(MediaBase.tablaArchivos, fila);
          }
          caja.agregar(MediaBase.tablaMoldes, {
            'nombre': nombre,
            'ruta': destino.path,
            'semilla': '',
            'fecha': DateTime.now().millisecondsSinceEpoch,
            'total': offset,
            'sal': sal,
            'cifrado': 'gcm-c-entry-v2',
          });
          await temporal.rename(destino.path);
          movido = true;
          caja.db.execute('COMMIT;');
        } catch (_) {
          caja.db.execute('ROLLBACK;');
          rethrow;
        }
      } catch (_) {
        if (movido && await destino.exists()) await destino.delete();
        rethrow;
      } finally {
        caja.cerrar();
      }
      final hechoN = filas.length;
      final hechoTotal = offset;
      log?.call('· previas guardadas en $conPrevias archivo(s)');
      if (passIndice != null && passIndice.isNotEmpty) {
        await Indice.registrar(
          pass: passIndice,
          nombre: nombre,
          dbRuta: await rutaDbPropia(nombre),
          mldRuta: destino.path,
          n: hechoN,
          total: hechoTotal,
          sal: sal,
          passMolde: clave,
        );
      }
      return hechoN;
    } finally {
      if (await temporal.exists()) await temporal.delete();
    }
  }

  static int _largoGuardado(int tam, int trozo) {
    if (tam <= 0) return 0;
    final n = (tam + trozo - 1) ~/ trozo;
    return tam + n * Duro.overhead;
  }

  static Future<void> borrar({
    required String nombre,
    required String claveSql,
    String? passIndice,
  }) async {
    MediaBase.exigirNombre('molde', nombre);
    // Borra de la propia y de la vieja (por si nunca migró).
    for (final soloPropia in [true, false]) {
      CajaSql? caja;
      try {
        caja = soloPropia
            ? await abrirIndice(claveSql: claveSql, molde: nombre)
            : await abrirIndice(claveSql: claveSql);
        caja.quitarDonde(MediaBase.tablaArchivos, 'molde = ?', [nombre]);
        caja.quitarDonde(MediaBase.tablaMoldes, 'nombre = ?', [nombre]);
      } catch (_) {
      } finally {
        caja?.cerrar();
      }
    }
    try {
      final f = await MediaBase.archivoMolde(nombre);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    olvidarMolde(nombre);
    if (passIndice != null && passIndice.isNotEmpty) {
      try {
        await Indice.quitar(pass: passIndice, nombre: nombre);
      } catch (_) {}
    }
  }

  /// Caja donde vive el molde: la propia primero, la vieja si no.
  static Future<CajaSql> _cajaMolde(String claveSql, String molde) async {
    final propia = await abrirIndice(claveSql: claveSql, molde: molde);
    final hay = propia.uno(MediaBase.tablaMoldes, 'nombre = ?', [molde]);
    if (hay != null) return propia;
    propia.cerrar();
    return abrirIndice(claveSql: claveSql);
  }

  static Future<MoldeInfo?> moldeInfo({
    required String claveSql,
    required String molde,
  }) async {
    final caja = await _cajaMolde(claveSql, molde);
    try {
      final m = caja.uno(MediaBase.tablaMoldes, 'nombre = ?', [molde]);
      if (m == null) return null;
      return MoldeInfo.deMapa(m);
    } finally {
      caja.cerrar();
    }
  }

  static Future<List<FichaArchivo>> filasDe({
    required String claveSql,
    required String molde,
  }) async {
    final caja = await _cajaMolde(claveSql, molde);
    try {
      final crudas = caja.listarDonde(
        MediaBase.tablaArchivos,
        // Las previas (.prev/) no listan: van por previasDe.
        'molde = ? AND nombre NOT LIKE \'.prev/%\'',
        [molde],
        por: 'inicio',
      );
      if (crudas.isEmpty) return [];
      return await _mapearFilas(
          claveSql: claveSql, molde: molde, caja: caja, crudas: crudas);
    } finally {
      caja.cerrar();
    }
  }

  /// Filtro por tag EN SQL (LIKE sobre columnas en bruto: la SQL ya
  /// va cifrada entera, no hay cifrado manual que impida matchear).
  static Future<List<FichaArchivo>> filasPorTag({
    required String claveSql,
    required String molde,
    required String tag,
  }) async {
    final t = tag.trim().replaceAll("'", "''");
    if (t.isEmpty) return filasDe(claveSql: claveSql, molde: molde);
    final like = '%$t%';
    final cond = 'molde = ? AND nombre NOT LIKE \'.prev/%\' '
        'AND (nombre LIKE ? '
        'OR tag1 LIKE ? OR tag2 LIKE ? OR tag3 LIKE ? OR tag4 LIKE ? '
        'OR tag5 LIKE ? OR tag6 LIKE ? OR tag7 LIKE ? OR tag8 LIKE ?)';
    final caja = await _cajaMolde(claveSql, molde);
    try {
      final crudas = caja.listarDonde(
        MediaBase.tablaArchivos,
        cond,
        [molde, like, like, like, like, like, like, like, like, like],
        por: 'inicio',
      );
      if (crudas.isEmpty) return [];
      return await _mapearFilas(
          claveSql: claveSql, molde: molde, caja: caja, crudas: crudas);
    } finally {
      caja.cerrar();
    }
  }

  /// Cuántos archivos del molde traen previa guardada (entradas
  /// `.prev/<arch>#<i>`). El log v1/v2 sale de acá porque filasDe()
  /// excluye `.prev/` a propósito (y escanear `filas` daba siempre v1).
  static Future<int> previasCuantas({
    required String claveSql,
    required String molde,
  }) async {
    final caja = await _cajaMolde(claveSql, molde);
    try {
      final crudas = caja.listarDonde(
        MediaBase.tablaArchivos,
        'molde = ? AND nombre LIKE \'.prev/%\'',
        [molde],
      );
      final bases = <String>{};
      for (final c in crudas) {
        final n = '${c['nombre'] ?? ''}';
        if (!PreviewMolde.esPrevia(n)) continue;
        final h = n.lastIndexOf('#');
        bases.add(h < 0 ? n : n.substring(0, h));
      }
      return bases.length;
    } finally {
      caja.cerrar();
    }
  }

  /// Previas guardadas de un archivo (del .mld, descifradas con la
  /// clave del ORIGINAL, no de la entrada previa). Vacío = sin
  /// previas (moldes viejos: previa al vuelo).
  static Future<List<Uint8List>> previasDe({
    required String claveSql,
    required String molde,
    required String archivo,
    TrozoCache? cache,
    MoldeInfo? info,
    bool soloPrimero = false,
    void Function(String s)? log,
  }) async {
    final esc = archivo
        .replaceAll('\\', '\\\\')
        .replaceAll('%', '\\%')
        .replaceAll('_', '\\_');
    final caja = await _cajaMolde(claveSql, molde);
    List<FichaArchivo> fichas;
    try {
      final crudas = caja.listarDonde(
        MediaBase.tablaArchivos,
        'molde = ? AND nombre LIKE ? ESCAPE \'\\\'',
        [molde, '${PreviewMolde.prefijo}$esc#%'],
        por: 'nombre',
      );
      if (crudas.isEmpty) return [];
      fichas = await _mapearFilas(
          claveSql: claveSql, molde: molde, caja: caja, crudas: crudas);
    } finally {
      caja.cerrar();
    }
    final infoOk = info ?? await moldeInfo(claveSql: claveSql, molde: molde);
    if (infoOk == null) return [];
    final claveOk = await claveDe(
      claveSql: claveSql,
      molde: molde,
      archivo: archivo,
      salHex: infoOk.sal,
    );
    final fuera = <Uint8List>[];
    Object? primerError;
    for (final p in fichas) {
      if (p.tamano <= 0) continue;
      try {
        fuera.add(await pedirRango(
          claveSql: claveSql,
          molde: molde,
          archivo: p.nombre,
          desde: 0,
          hasta: p.tamano,
          cache: cache,
          info: infoOk,
          filas: fichas,
          claveArchivo: infoOk.cifrado == 'gcm-c-entry-v2'
              ? await Duro.claveEntrada(
                  claveArchivo: claveOk,
                  nombreEntrada: p.nombre,
                )
              : claveOk,
          log: log,
        ));
      } catch (e) {
        primerError ??= e;
      }
      // Grid de video: 1 solo frame (los 17 solo en el visor).
      if (soloPrimero && fuera.isNotEmpty) break;
    }
    // Todo falló: que el motivo salga (antes volvía [] en silencio y
    // el grid mostraba nada sin decir por qué).
    if (fuera.isEmpty && fichas.isNotEmpty && primerError != null) {
      throw primerError;
    }
    return fuera;
  }

  /// UN solo frame (el primero) para el grid de videos.
  /// El grid jamás pide los 17: esos solo los trae el visor.
  static Future<Uint8List?> previaUno({
    required String claveSql,
    required String molde,
    required String archivo,
    TrozoCache? cache,
    MoldeInfo? info,
    void Function(String s)? log,
  }) async {
    final l = await previasDe(
      claveSql: claveSql,
      molde: molde,
      archivo: archivo,
      cache: cache,
      info: info,
      soloPrimero: true,
      log: log,
    );
    return l.isEmpty ? null : l.first;
  }

  /// Fuente remota de trozos crudos (por si no hay .mld local).
  /// La pone la pantalla al abrir (repo+token del índice).
  /// null = sin remoto (como antes: error si falta el archivo).
  static Future<Uint8List?> Function(String molde, int absoluto, int largo)?
      remoto;

  /// Mapea filas crudas a FichaArchivo (descifra en batch solo las
  /// legacy con `*_c`; las nuevas ya vienen en bruto y no tocan
  /// el hilo de descifrado).
  static Future<List<FichaArchivo>> _mapearFilas({
    required String claveSql,
    required String molde,
    required CajaSql caja,
    required List<Map<String, Object?>> crudas,
  }) async {
    final moldeKey = await _claveMoldeDe(caja, claveSql, molde);
    // Junta todo lo cifrado y lo descifra en UN solo hilo.
    final idxN = <int>[];
    final datosN = <String>[];
    final idxT = <int>[];
    final datosT = <String>[];
    for (var i = 0; i < crudas.length; i++) {
      final nc = '${crudas[i]['nombre_c'] ?? ''}';
      if (nc.isNotEmpty) {
        idxN.add(i);
        datosN.add(nc);
      }
      final tc = '${crudas[i]['tags_c'] ?? ''}';
      if (tc.isNotEmpty) {
        idxT.add(i);
        datosT.add(tc);
      }
    }
    final nomDec = <int, String>{};
    final tagDec = <int, String>{};
    if (datosN.isNotEmpty) {
      final r =
          await Duro.descifrarTextosHilo(claveMolde: moldeKey, datos: datosN);
      for (var j = 0; j < idxN.length; j++) {
        nomDec[idxN[j]] = r[j];
      }
    }
    if (datosT.isNotEmpty) {
      final r =
          await Duro.descifrarTextosHilo(claveMolde: moldeKey, datos: datosT);
      for (var j = 0; j < idxT.length; j++) {
        tagDec[idxT[j]] = r[j];
      }
    }
    final fuera = <FichaArchivo>[];
    for (var i = 0; i < crudas.length; i++) {
      final m = Map<String, Object?>.from(crudas[i]);
      if (nomDec.containsKey(i)) {
        final nombre = nomDec[i]!;
        m['nombre'] = nombre;
        m['formato'] = _formato(nombre);
        final tags =
            tagDec[i]?.split('\n').where((t) => t.isNotEmpty).toList() ??
                <String>[];
        for (var k = 0; k < MediaBase.maxTags; k++) {
          m['tag${k + 1}'] = k < tags.length ? tags[k] : '';
        }
      }
      fuera.add(FichaArchivo.deMapa(m));
    }
    return fuera;
  }

  /// Mueve un molde de la SQL vieja a su propia SQL (una vez).
  /// Devuelve true si migró. Registra en el índice si hay pass.
  static Future<bool> migrarSiHaceFalta({
    required String claveSql,
    required String molde,
    String passIndice = '',
  }) async {
    final propia = await abrirIndice(claveSql: claveSql, molde: molde);
    try {
      if (propia.uno(MediaBase.tablaMoldes, 'nombre = ?', [molde]) != null) {
        return false;
      }
      // Legado desactivado: la compartida media_server.db solo
      // demoraba (intentos con clave ajena) y ya no se usa.
      return false;
    } finally {
      propia.cerrar();
    }
  }

  /// Tu SQL → trozos → server crudo → vos descifrás. `[desde, hasta)`.
  ///
  /// [cache]: si viene, los trozos salen de la caché local cifrada
  /// (LRU) y solo los miss tocan el .mld. [info]/[filas]/[claveArchivo]
  /// evitan re-abrir la SQL y re-derivar PBKDF2 por pedido.
  static Future<Uint8List> pedirRango({
    required String claveSql,
    required String molde,
    required String archivo,
    required int desde,
    required int hasta,
    TrozoCache? cache,
    MoldeInfo? info,
    List<FichaArchivo>? filas,
    Uint8List? claveArchivo,
    void Function(String s)? log,
  }) async {
    final k = _k(claveSql, molde);
    var infoOk = info ?? _memoInfo[k];
    infoOk ??= await moldeInfo(claveSql: claveSql, molde: molde);
    if (infoOk == null) {
      throw StateError('mediablock: no existe el molde "$molde"');
    }
    _memoInfo[k] = infoOk;
    var filasOk = filas ?? _memoFilas[k];
    filasOk ??= await filasDe(claveSql: claveSql, molde: molde);
    _memoFilas[k] = filasOk;
    FichaArchivo? ficha;
    for (final x in filasOk) {
      if (x.nombre == archivo) {
        ficha = x;
        break;
      }
    }
    if (ficha == null) {
      throw StateError('mediablock: "$archivo" no está en "$molde"');
    }
    final f = ficha;
    if (f.tamano == 0) return Uint8List(0);
    if (desde < 0 || hasta < 0 || desde >= hasta || hasta > f.tamano) {
      throw ArgumentError('mediablock: rango [$desde, $hasta) '
          'fuera de "$archivo" (0..${f.tamano})');
    }
    // Server local si hay .mld; si no, nulo (lo trae `remoto`).
    MoldeAbierto? server;
    try {
      server = await MediaServer.abrir(rutaMld: infoOk.ruta);
    } catch (_) {
      server = null;
    }
    final claveOk = claveArchivo ??
        await claveDe(
          claveSql: claveSql,
          molde: molde,
          archivo: archivo,
          salHex: infoOk.sal,
        );
    final primero = desde ~/ f.trozo;
    final ultimo = (hasta - 1) ~/ f.trozo;
    // 1) caché primero, en UN solo SELECT (el scroll no espera nada:
    // el grid ya se armó con formato+nombre de la SQL).
    final crudos = <int, Uint8List>{};
    if (cache != null) {
      crudos.addAll(await cache.leerLote(
        archivo: archivo,
        indices: [for (var i = primero; i <= ultimo; i++) i],
      ));
    }
    final faltan = <int>[
      for (var i = primero; i <= ultimo; i++)
        if (!crudos.containsKey(i)) i
    ];
    // 2) lo que falta: UNA lectura del server (o remoto HF por
    // rangos si no hay .mld local) + UN guardado en lote.
    // A la caché solo se le pide una vez; al molde solo lo que
    // la caché no tenía (local o remoto, igual).
    if (faltan.isNotEmpty) {
      final leidos = <Uint8List>[];
      if (server != null) {
        leidos.addAll(await server.leerVarios([
          for (final i in faltan)
            [
              Duro.offsetDe(f.inicio, i, f.trozo),
              Duro.largoDe(i, f.tamano, f.trozo)
            ]
        ]));
      } else {
        final rem = remoto;
        if (rem == null) {
          throw StateError('mediablock: no existe el bloque '
              '"${infoOk.ruta}" ni hay remoto para "$molde"');
        }
        // UNA llamada por tramo contiguo (500MB no son 300 GETs:
        // se calcula el span y se parte en casa).
        var i = 0;
        while (i < faltan.length) {
          final ini = faltan[i];
          var fin = ini;
          var iniOff = Duro.offsetDe(f.inicio, ini, f.trozo);
          var span = Duro.largoDe(ini, f.tamano, f.trozo);
          while (i + 1 < faltan.length && faltan[i + 1] == fin + 1) {
            fin++;
            i++;
            span += Duro.largoDe(fin, f.tamano, f.trozo);
          }
          final b = await rem(molde, iniOff, span);
          if (b == null || b.length != span) {
            throw StateError('mediablock: remoto incompleto '
                '(trozos $ini..$fin de "$archivo")');
          }
          var o = 0;
          for (var k = ini; k <= fin; k++) {
            final len = Duro.largoDe(k, f.tamano, f.trozo);
            leidos.add(Uint8List.sublistView(b, o, o + len));
            o += len;
          }
          i++;
        }
      }
      final lote = <int, Uint8List>{};
      for (var j = 0; j < faltan.length; j++) {
        crudos[faltan[j]] = leidos[j];
        lote[faltan[j]] = leidos[j];
      }
      if (cache != null) {
        await cache.guardarLote(archivo: archivo, paquetes: lote);
      }
    }
    final packs = <PaqueteCrudo>[
      for (var i = primero; i <= ultimo; i++) PaqueteCrudo(i, crudos[i]!)
    ];
    try {
      return await Duro.descifrarRangoHilo(
        claveArchivo: claveOk,
        rango: RangoCrudo(
          modo: 'gcm-c',
          archivo: archivo,
          desde: desde,
          hasta: hasta,
          trozo: f.trozo,
          tamano: f.tamano,
          paquetes: packs,
        ),
      );
    } catch (e) {
      // MAC falló: la caché puede tener paquetes de otro .mld
      // (borrar/recrear con mismos nombres). Se purga el archivo
      // y se avisa; el próximo intento relee del server.
      if ('$e'.contains('no autentica') && cache != null) {
        await cache.limpiarArchivo(archivo);
        log?.call('⚠ caché envenenada de "$archivo" '
            '(molde "$molde"): purgada, reintentá');
      }
      rethrow;
    }
  }

  static Future<List<MoldeInfo>> listarMoldes({
    required String claveSql,
  }) async {
    final caja = await abrirIndice(claveSql: claveSql);
    try {
      final filas = caja.listar(MediaBase.tablaMoldes, por: 'nombre');
      return [for (final f in filas) MoldeInfo.deMapa(f)];
    } finally {
      caja.cerrar();
    }
  }

  static Future<void> actualizarTags({
    required String claveSql,
    required String molde,
    required String archivo,
    required List<String> tags,
  }) async {
    final saneados = MediaBase.sanearTags(tags);
    final caja = await _cajaMolde(claveSql, molde);
    try {
      final moldeKey = await _claveMoldeDe(caja, claveSql, molde);
      final todas = caja.listarDonde(
        MediaBase.tablaArchivos,
        'molde = ?',
        [molde],
      );
      Map<String, Object?>? f;
      for (final r in todas) {
        final real = await _filaReal(moldeKey, r);
        if ('${real['nombre']}' == archivo) {
          f = r;
          break;
        }
      }
      if (f == null) {
        throw StateError('mediablock: "$archivo" no está en "$molde"');
      }
      // OJO: si la fila es legacy (_c), hay que bajar el nombre real
      // a bruto; si no queda '§enc' para siempre (el _c se limpia abajo).
      final real = await _filaReal(moldeKey, f);
      final mapa = <String, Object?>{
        'nombre': real['nombre'],
        'formato': real['formato'],
        'nombre_c': '',
        'tags_c': '',
      };
      for (var i = 0; i < MediaBase.maxTags; i++) {
        mapa['tag${i + 1}'] = i < saneados.length ? saneados[i] : '';
      }
      caja.actualizar(MediaBase.tablaArchivos, (f['id'] as int?) ?? 0, mapa);
      olvidarMolde(molde);
    } finally {
      caja.cerrar();
    }
  }

  static Future<void> quitarEntrada({
    required String claveSql,
    required String molde,
    required String archivo,
  }) async {
    final caja = await _cajaMolde(claveSql, molde);
    try {
      final moldeKey = await _claveMoldeDe(caja, claveSql, molde);
      final todas = caja.listarDonde(
        MediaBase.tablaArchivos,
        'molde = ?',
        [molde],
      );
      Map<String, Object?>? f;
      for (final r in todas) {
        final real = await _filaReal(moldeKey, r);
        if ('${real['nombre']}' == archivo) {
          f = r;
          break;
        }
      }
      if (f == null) {
        throw StateError('mediablock: "$archivo" no está en "$molde"');
      }
      final id = (f['id'] as int?) ?? 0;
      caja.db.execute('BEGIN;');
      try {
        caja.agregar('papelera', {
          'molde': molde,
          'nombre': archivo,
          'fila': jsonEncode(f),
          'borrado': DateTime.now().millisecondsSinceEpoch,
        });
        caja.quitar(MediaBase.tablaArchivos, id);
        caja.db.execute('COMMIT;');
      } catch (_) {
        caja.db.execute('ROLLBACK;');
        rethrow;
      }
      olvidarMolde(molde);
    } finally {
      caja.cerrar();
    }
  }

  static Future<List<Map<String, Object?>>> papeleraDe({
    required String claveSql,
    required String molde,
  }) async {
    final caja = await _cajaMolde(claveSql, molde);
    try {
      final filas = caja.db.select(
        'SELECT id, nombre, borrado, fila FROM papelera '
        'WHERE molde = ? ORDER BY borrado DESC;',
        [molde],
      );
      return [
        for (final fila in filas)
          {
            'id': fila['id'] as int,
            'nombre': '${fila['nombre'] ?? ''}',
            'borrado': (fila['borrado'] as int?) ?? 0,
            'archivo': jsonDecode('${fila['fila']}') as Map<String, dynamic>,
          }
      ];
    } finally {
      caja.cerrar();
    }
  }

  static Future<void> restaurarPapelera({
    required String claveSql,
    required String molde,
    required int papeleraId,
  }) async {
    final caja = await _cajaMolde(claveSql, molde);
    try {
      final filas = caja.db.select(
        'SELECT fila FROM papelera WHERE id = ? AND molde = ?;',
        [papeleraId, molde],
      );
      if (filas.isEmpty) {
        throw StateError('mediablock: la entrada ya no está en la papelera');
      }
      final decoded = jsonDecode('${filas.first['fila']}');
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException(
            'mediablock: respaldo de papelera inválido');
      }
      final columnas = caja.campos(MediaBase.tablaArchivos).toSet();
      final archivo = <String, Object?>{
        for (final entry in decoded.entries)
          if (entry.key != 'id' && columnas.contains(entry.key))
            entry.key: entry.value,
      };
      if ('${archivo['molde'] ?? ''}' != molde ||
          '${archivo['nombre'] ?? ''}'.isEmpty) {
        throw const FormatException('mediablock: fila de respaldo incompleta');
      }
      final nombres = archivo.keys.map((k) => '"$k"').join(', ');
      final marcas = List.filled(archivo.length, '?').join(', ');
      caja.db.execute('BEGIN;');
      try {
        caja.db.execute(
          'INSERT INTO "${MediaBase.tablaArchivos}" ($nombres) '
          'VALUES ($marcas);',
          archivo.values.toList(),
        );
        caja.db.execute(
          'DELETE FROM papelera WHERE id = ? AND molde = ?;',
          [papeleraId, molde],
        );
        caja.db.execute('COMMIT;');
      } catch (_) {
        caja.db.execute('ROLLBACK;');
        rethrow;
      }
      olvidarMolde(molde);
    } finally {
      caja.cerrar();
    }
  }

  static Future<void> vaciarPapelera({
    required String claveSql,
    required String molde,
    int? papeleraId,
  }) async {
    final caja = await _cajaMolde(claveSql, molde);
    try {
      if (papeleraId == null) {
        caja.db.execute('DELETE FROM papelera WHERE molde = ?;', [molde]);
      } else {
        caja.db.execute(
          'DELETE FROM papelera WHERE id = ? AND molde = ?;',
          [papeleraId, molde],
        );
      }
    } finally {
      caja.cerrar();
    }
  }

  static Future<int> quitarDuplicados({
    required String claveSql,
    required String molde,
  }) async {
    // Duplicados por nombre REAL (descifrado), borra por id.
    final filas = await filasDe(claveSql: claveSql, molde: molde);
    final caja = await _cajaMolde(claveSql, molde);
    try {
      final vistos = <String>{};
      var borradas = 0;
      for (final f in filas) {
        if (!vistos.add(f.nombre)) {
          caja.quitar(MediaBase.tablaArchivos, f.id);
          borradas++;
        }
      }
      // Previas huérfanas (.prev/x#i sin archivo x): se van también.
      final previas = caja.listarDonde(
        MediaBase.tablaArchivos,
        'molde = ? AND nombre LIKE \'.prev/%\'',
        [molde],
      );
      for (final p in previas) {
        final n = '${p['nombre'] ?? ''}';
        // Base = entre el prefijo y el ÚLTIMO '#' (el nombre
        // puede traer '#' adentro; el índice va al final).
        var base = '';
        if (n.startsWith(PreviewMolde.prefijo)) {
          final resto = n.substring(PreviewMolde.prefijo.length);
          final h = resto.lastIndexOf('#');
          base = h < 0 ? resto : resto.substring(0, h);
        }
        if (base.isEmpty || !vistos.contains(base)) {
          caja.quitar(MediaBase.tablaArchivos, (p['id'] as int?) ?? 0);
          borradas++;
        }
      }
      olvidarMolde(molde);
      return borradas;
    } finally {
      caja.cerrar();
    }
  }

  /// Mueve los archivos de un molde a otro directorio (admin):
  /// .mld + su SQL, actualiza `moldes.ruta` y la entrada del índice.
  /// OJO: mueve (copia+borra), no duplica; olvida memos.
  static Future<void> moverMolde({
    required String claveSql,
    required String molde,
    required String passIndice,
    required String nuevoDir,
  }) async {
    MediaBase.exigirNombre('molde', molde);
    if (passIndice.isEmpty) {
      throw ArgumentError('mover: falta la pass del índice');
    }
    final ent = await Indice.entrada(pass: passIndice, nombre: molde);
    if (ent == null) {
      throw StateError('mover: "$molde" no está en el índice');
    }
    final dir = Directory(nuevoDir);
    await dir.create(recursive: true);
    final dbVieja = File('${ent['db_ruta'] ?? ''}');
    final mldViejo = File('${ent['mld_ruta'] ?? ''}');
    if (!await mldViejo.exists()) {
      throw StateError('mover: no existe ${ent['mld_ruta']}');
    }
    final baseDb = '${ent['db_ruta'] ?? ''}'.split('/').last;
    final dbNueva = File('${dir.path}/$baseDb');
    final mldNuevo = File('${dir.path}/$molde.mld');
    await mldViejo.copy(mldNuevo.path);
    if (await dbVieja.exists()) {
      await dbVieja.copy(dbNueva.path);
    } else {
      throw StateError('mover: no existe ${ent['db_ruta']}');
    }
    // Actualiza la ruta dentro de la SQL nueva.
    final caja = CajaSql();
    await caja.abrir(baseDb.replaceAll(RegExp(r'\.db$'), ''),
        carpeta: dir.path);
    try {
      final filas =
          caja.listarDonde(MediaBase.tablaMoldes, 'nombre = ?', [molde]);
      for (final r in filas) {
        caja.actualizar(MediaBase.tablaMoldes, (r['id'] as int?) ?? 0,
            {'ruta': mldNuevo.path});
      }
    } finally {
      caja.cerrar();
    }
    // Borra los viejos solo si los nuevos quedaron.
    await mldViejo.delete();
    await dbVieja.delete();
    await Indice.registrar(
      pass: passIndice,
      nombre: molde,
      dbRuta: dbNueva.path,
      mldRuta: mldNuevo.path,
      n: (ent['n'] as int?) ?? 0,
      total: (ent['total'] as int?) ?? 0,
      sal: '${ent['sal'] ?? ''}',
      passMolde: '${ent['pass'] ?? claveSql}',
    );
    olvidarMolde(molde);
  }

  /// Rastrea una carpeta: por cada `.mld` busca su SQL (`m_<n>.db`
  /// al lado o en Download, si no la vieja compartida) y lee sal,
  /// total y cantidad. Las SQL cifradas se abren con [claveSql];
  /// las legacy en plano se leen igual.
  static Future<List<Map<String, Object?>>> rastrearCarpeta(String dir,
      {String claveSql = ''}) async {
    final origen = Directory(dir);
    if (!await origen.exists()) {
      throw ArgumentError('rastrear: no existe "$dir"');
    }
    final moldes = <File>[];
    await for (final e in origen.list(recursive: true, followLinks: false)) {
      if (e is File && e.path.endsWith('.mld')) moldes.add(e);
    }
    moldes.sort((a, b) => a.path.compareTo(b.path));
    final fuera = <Map<String, Object?>>[];
    for (final mld in moldes) {
      final base = mld.uri.pathSegments.last;
      final nombre = base.replaceAll(RegExp(r'\.mld$'), '');
      try {
        MediaBase.exigirNombre('molde', nombre);
      } catch (_) {
        continue;
      }
      // Candidatas: m_<n>.db al lado, en Download, o vieja compartida.
      final candidatas = <String>[
        '${mld.parent.path}/m_$nombre.db',
        await rutaDbPropia(nombre),
      ];
      try {
        final sup = await getApplicationSupportDirectory();
        candidatas.add('${sup.path}/db/$baseDatos.db');
      } catch (_) {}
      final dl = await dirSql();
      if (dl != null) candidatas.add('$dl/$baseDatos.db');
      String? dbOk;
      Map<String, Object?>? fila;
      for (final c in candidatas) {
        try {
          final caja = CajaSql();
          await caja.abrirRuta(c, clave: claveSql);
          try {
            fila = caja.uno(MediaBase.tablaMoldes, 'nombre = ?', [nombre]);
            if (fila != null) {
              dbOk = c;
              break;
            }
          } finally {
            caja.cerrar();
          }
        } catch (_) {}
      }
      if (fila == null || dbOk == null) continue;
      var n = 0;
      try {
        final caja = CajaSql();
        await caja.abrirRuta(dbOk, clave: claveSql);
        try {
          n = caja.listarDonde(
              MediaBase.tablaArchivos, 'molde = ?', [nombre]).length;
        } finally {
          caja.cerrar();
        }
      } catch (_) {}
      fuera.add({
        'nombre': nombre,
        'mld_ruta': mld.path,
        'db_ruta': dbOk,
        'sal': '${fila['sal'] ?? ''}',
        'total': (fila['total'] as int?) ?? 0,
        'n': n,
      });
    }
    return fuera;
  }

  static String _formato(String nombreRel) {
    final base = nombreRel.split('/').last;
    final p = base.lastIndexOf('.');
    if (p <= 0 || p == base.length - 1) return 'sinformato';
    return base.substring(p + 1).toLowerCase();
  }
}
