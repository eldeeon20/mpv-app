import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:pr_app/services/hf.dart';

import 'indice/indice.dart';
import 'db/caja_sql.dart';
import 'media_server/media_server.dart';
import 'tool/create_molde_sql.dart';

/// Puente HF de moldes: el índice guarda por molde su repo
/// (dir/user = `repo_id`), su pass y su token de acceso.
///
/// Convención de paths dentro del repo:
///
///   `<nombre>.mld`   el molde (blob grande, NUNCA se baja entero)
///   `<nombre>.sql`   su SQL con ruta `hf://repo/<nombre>.mld`
///                     (se baja entera; apunta al molde de HF)
///
/// El `.mld` remoto solo se lee por RANGOS (`rangoMld`), con el
/// token del molde para repos privados. La SQL sí se descarga
/// completa la primera vez que se toca el molde como carpeta.
class PuenteHf {
  final HuggingFace _hf = HuggingFace();

  bool get listo => _hf.ready;

  Future<void> init(String token) => _hf.init(token);

  void cerrar() => _hf.dispose();

  /// ¿El token valida en HF? (whoami-v2, 15s).
  /// true = HF lo acepta. false = token malo O sin red (no distingue).
  static Future<bool> tokenValido(String token) async {
    if (token.isEmpty) return false;
    try {
      final r = await http.get(
        Uri.parse('https://huggingface.co/api/whoami-v2'),
        headers: {'authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 15));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> tokenValidoConBearer(String token) async {
    if (token.isEmpty) return false;
    try {
      final response = await http.get(
        Uri.parse('https://huggingface.co/api/whoami-v2'),
        headers: {'authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 15));
      return response.statusCode == 200;
    } on http.ClientException {
      return false;
    } on TimeoutException {
      return false;
    }
  }

  /// Config HF de un molde desde el índice.
  static Future<({String repo, String token, int version})> configDe({
    required String passIndice,
    required String nombre,
  }) async {
    final ent = await Indice.entrada(pass: passIndice, nombre: nombre);
    if (ent == null) {
      throw StateError('puente_hf: "$nombre" no está en el índice');
    }
    return (
      repo: '${ent['hf_repo'] ?? ''}',
      token: '${ent['hf_token'] ?? ''}',
      version: (ent['version'] as int?) ?? 0,
    );
  }

  /// Crea el repo privado si falta (exist_ok, no falla si ya está).
  Future<void> asegurarRepo({
    required String repoId,
    required String token,
    String repoType = 'dataset',
  }) async {
    await init(token);
    final existe = await _hf.repoExists(repoId: repoId, repoType: repoType);
    if (!existe) {
      await _hf.createRepository(
        repoId: repoId,
        repoType: repoType,
        private: true,
      );
    }
  }

  /// Sube el molde (.mld + su SQL + respaldo del índice) y marca
  /// la versión.
  /// En HF viven SOLO con su hash256 (`<sha>.mld`, `<sha>.sql`): el
  /// alias queda en el índice junto al hash (así se comprueba que es
  /// ese). Local no cambia de nombre.
  /// El SQL que sube apunta al molde de HF (`hf://repo/<sha>.mld`,
  /// editado en una COPIA: tu SQL local sigue al .mld local).
  /// El índice viaja como respaldo cifrado (lleva repos+tokens).
  /// Retorna la versión subida (ms actual).
  Future<int> subirMolde({
    required String passIndice,
    required String claveSql,
    required String nombre,
    String repoType = 'dataset',
    bool conIndice = true,
    void Function(String s)? log,
  }) async {
    final ent = await Indice.entrada(pass: passIndice, nombre: nombre);
    if (ent == null) {
      throw StateError('puente_hf: "$nombre" no está en el índice');
    }
    final repo = '${ent['hf_repo'] ?? ''}';
    final token = '${ent['hf_token'] ?? ''}';
    if (repo.isEmpty || token.isEmpty) {
      throw StateError('puente_hf: "$nombre" sin repo/token '
          '(guardalos primero con Indice.guardarHf)');
    }
    await asegurarRepo(repoId: repo, token: token, repoType: repoType);
    final version = DateTime.now().millisecondsSinceEpoch;
    var hashMld = '';
    var hashSql = '';

    final mldRuta = '${ent['mld_ruta'] ?? ''}';
    if (mldRuta.isNotEmpty && await File(mldRuta).exists()) {
      hashMld = await HuggingFace.sha256Archivo(mldRuta);
      log?.call('· subiendo $nombre.mld como $hashMld.mld…');
      await _hf.uploadFile(
        repoId: repo,
        localFilePath: mldRuta,
        pathInRepo: '$hashMld.mld',
        // El comment ES el hash (se comprueba que es ese).
        commitMessage: 'sha256:$hashMld',
        repoType: repoType,
      );
    }
    final dbRuta = '${ent['db_ruta'] ?? ''}';
    if (dbRuta.isNotEmpty && await File(dbRuta).exists()) {
      log?.call('· subiendo $nombre.sql (apuntando a HF)…');
      final hfMldLocal = hashMld.isNotEmpty ? 'hf://$repo/$hashMld.mld' : '';
      // LOCAL también se actualiza: anota su gemelo en HF (la ruta
      // local queda; `hf` dice dónde está subido).
      try {
        final cajaL = CajaSql();
        try {
          await cajaL.abrirRuta(dbRuta, clave: claveSql);
          cajaL.db.execute(
            'UPDATE "${MediaBase.tablaMoldes}" SET hf = ? '
            'WHERE nombre = ?;',
            [hfMldLocal, nombre],
          );
        } finally {
          cajaL.cerrar();
        }
      } catch (e) {
        log?.call('⚠ sql local no anotado: $e');
      }
      // Copia con ruta HF: el que baja este SQL ve el molde de HF,
      // no tu disco. Nombre remoto = hash256 de la copia ya apuntada.
      final tmp = await Directory.systemTemp.createTemp('hf_sql_up');
      try {
        final dbBase = dbRuta.split('/').last;
        final copia = File('${tmp.path}/$dbBase');
        await File(dbRuta).copy(copia.path);
        final sinDb = dbBase.endsWith('.db')
            ? dbBase.substring(0, dbBase.length - 3)
            : dbBase;
        final caja = CajaSql();
        try {
          await caja.abrir(sinDb, carpeta: tmp.path, clave: claveSql);
          caja.db.execute(
            'UPDATE "${MediaBase.tablaMoldes}" SET ruta = ?, hf = ? '
            'WHERE nombre = ?;',
            [hfMldLocal, hfMldLocal, nombre],
          );
        } finally {
          caja.cerrar();
        }
        hashSql = await HuggingFace.sha256Archivo(copia.path);
        log?.call('· subiendo $nombre.sql como $hashSql.sql…');
        await _hf.uploadFile(
          repoId: repo,
          localFilePath: copia.path,
          pathInRepo: '$hashSql.sql',
          // El comment ES el hash (se comprueba que es ese).
          commitMessage: 'sha256:$hashSql',
          repoType: repoType,
        );
      } finally {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      }
    }
    if (hashMld.isNotEmpty || hashSql.isNotEmpty) {
      await Indice.guardarHash(
        pass: passIndice,
        nombre: nombre,
        hashMld: hashMld,
        hashSql: hashSql,
      );
      log?.call('· alias "$nombre" → mld $hashMld sql $hashSql');
    }
    await Indice.marcarVersion(
        pass: passIndice, nombre: nombre, version: version);
    // Respaldo del índice (cifrado con tu clave: repos+tokens).
    // En la copia que sube, este molde apunta al repo:
    // sql → `$nombre.sql`, mld → `hf://repo/nombre.mld`.
    // El índice local no se toca. Con conIndice=false no sube.
    if (!conIndice) {
      log?.call('· índice aparte: este molde sube SIN índice');
    } else
      try {
        final carpeta = await MediaBase.carpetaMoldes();
        final idx = File('${carpeta.path}/${Indice.archivo}');
        if (await idx.exists()) {
          log?.call('· subiendo ${Indice.archivo} (apuntando a HF)…');
          final tmpI = await Directory.systemTemp.createTemp('hf_idx_up');
          try {
            final copiaI = File('${tmpI.path}/${Indice.archivo}');
            await idx.copy(copiaI.path);
            final cajaI = CajaSql();
            try {
              await cajaI.abrir('indice',
                  carpeta: tmpI.path, clave: passIndice);
              cajaI.db.execute(
                'UPDATE indice SET sql = ?, mld = ? WHERE nombre = ?;',
                ['hf://$repo/$nombre.sql', 'hf://$repo/$nombre.mld', nombre],
              );
            } finally {
              cajaI.cerrar();
            }
            await _hf.uploadFile(
              repoId: repo,
              localFilePath: copiaI.path,
              pathInRepo: Indice.archivo,
              commitMessage: 'indice $nombre v$version',
              repoType: repoType,
            );
          } finally {
            try {
              await tmpI.delete(recursive: true);
            } catch (_) {}
          }
        }
      } catch (e) {
        log?.call('⚠ índice no subido: $e');
      }
    log?.call('✓ $nombre en $repo v$version');
    return version;
  }

  /// Baja la SQL entera del molde si no está local, directo a su
  /// ruta propia (`m_<nombre>.db`, la que `_cajaMolde` sabe abrir),
  /// y deja apuntado el índice (el índice sabe dónde está cada SQL).
  /// En HF vive por hash (`<sha>.sql`): se verifica al bajar (si no
  /// coincide, no es ese → error). Sin hash (legado) usa el nombre.
  /// Retorna su path. El .mld NO se baja: se consulta por rangos.
  Future<String> bajarSql({
    required String passIndice,
    required String nombre,
    String repoType = 'dataset',
  }) async {
    // Tolera alias, "alias.sql" o "<hash>.sql": el índice vive por alias.
    var alias = nombre.trim();
    if (alias.toLowerCase().endsWith('.sql')) {
      alias = alias.substring(0, alias.length - 4);
    }
    if (alias.toLowerCase().endsWith('.mld')) {
      alias = alias.substring(0, alias.length - 4);
    }
    if (alias.contains('/')) {
      alias = alias.split('/').last;
    }
    var ent0 = await Indice.entrada(pass: passIndice, nombre: alias);
    ent0 ??= await _entradaPorRemoto(passIndice, alias);
    if (ent0 == null) {
      throw StateError('puente_hf: "$nombre" no está en el índice '
          '(probá con el alias, ej. v2222)');
    }
    final nombreIx = '${ent0['nombre'] ?? alias}';
    final destino = await CreateMoldeSql.rutaDbPropia(nombreIx);
    // ¿La local TRAE el molde? (un .db vacío/rancio no vale: se baja).
    final passMolde = '${ent0['pass'] ?? ''}';
    var trae = false;
    if (await File(destino).exists() && passMolde.isNotEmpty) {
      try {
        final caja = CajaSql();
        await caja.abrirRuta(destino, clave: passMolde);
        try {
          trae =
              caja.uno(MediaBase.tablaMoldes, 'nombre = ?', [nombreIx]) != null;
        } finally {
          caja.cerrar();
        }
      } catch (_) {}
    }
    if (trae) {
      await Indice.actualizarRutas(
        pass: passIndice,
        nombre: nombreIx,
        dbRuta: destino,
        mldRuta: '',
      );
      return destino;
    }
    final ent = ent0;
    final repo = '${ent['hf_repo'] ?? ''}';
    final token = '${ent['hf_token'] ?? ''}';
    if (repo.isEmpty || token.isEmpty) {
      throw StateError('puente_hf: "$nombreIx" sin repo/token');
    }
    final hashSql = '${ent['hash_sql'] ?? ''}';
    final remoto = hashSql.isNotEmpty ? '$hashSql.sql' : '$nombreIx.sql';
    await init(token);
    final tmp = await Directory.systemTemp.createTemp('hf_sql');
    try {
      final bajado = await _hf.downloadFile(
        repoId: repo,
        filename: remoto,
        localDir: tmp.path,
        repoType: repoType,
      );
      if (hashSql.isNotEmpty) {
        final got = await HuggingFace.sha256Archivo(bajado);
        if (got != hashSql) {
          throw StateError(
              'puente_hf: "$remoto" no autentica (hash $got ≠ $hashSql)');
        }
      }
      await File(bajado).copy(destino);
    } finally {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
    await Indice.actualizarRutas(
      pass: passIndice,
      nombre: nombreIx,
      dbRuta: destino,
      mldRuta: '',
    );
    return destino;
  }

  /// Busca entrada por nombre remoto (`<hash>.sql`/`<hash>.mld`).
  /// null = no hay.
  static Future<Map<String, Object?>?> _entradaPorRemoto(
      String passIndice, String remoto) async {
    final r = remoto.toLowerCase();
    final lista = await Indice.listarRaw(passIndice);
    for (final m in lista) {
      final hm = '${m['hash_mld'] ?? ''}'.toLowerCase();
      final hs = '${m['hash_sql'] ?? ''}'.toLowerCase();
      if ((hm.isNotEmpty && (r == '$hm.mld' || r == hm)) ||
          (hs.isNotEmpty && (r == '$hs.sql' || r == hs))) {
        return m;
      }
    }
    return null;
  }

  /// Un RANGO de bytes del .mld remoto (el molde se consulta,
  /// no se descarga). Token del molde para repos privados.
  /// [archivo]: nombre remoto exacto (`<sha>.mld` por hash; vacío =
  /// legado `$nombre.mld`). El que llama resuelve el hash en el índice.
  static Future<Uint8List> rangoMld({
    required String repo,
    required String nombre,
    required int start,
    required int end,
    String token = '',
    String repoType = 'dataset',
    String archivo = '',
  }) {
    return HuggingFace.downloadFileRange(
      repoId: repo,
      filename: archivo.isNotEmpty ? archivo : '$nombre.mld',
      start: start,
      end: end,
      token: token,
      repoType: repoType,
    );
  }

  /// Archivos del repo (control de versiones: qué hay subido).
  Future<List<String>> archivos({
    required String repoId,
    required String token,
    String repoType = 'dataset',
  }) async {
    await init(token);
    return _hf.listRepoFiles(
        repoId: repoId, recursive: true, repoType: repoType);
  }

  /// Sube varios moldes (cada uno a SU repo del índice). Por hash: si
  /// `<sha>.mld` y `<sha>.sql` ya están arriba, se salta (ya está).
  /// Retorna (subidos, saltados).
  Future<({int subidos, int saltados})> subirSeleccionados({
    required String passIndice,
    required String claveSql,
    required List<String> nombres,
    String repoType = 'dataset',
    bool conIndice = true,
    void Function(String s)? log,
  }) async {
    var subidos = 0;
    var saltados = 0;
    final repoCache = <String, Set<String>>{};
    for (final nombre in nombres) {
      try {
        final ent = await Indice.entrada(pass: passIndice, nombre: nombre);
        if (ent == null) {
          log?.call('✗ "$nombre": no está en el índice');
          continue;
        }
        final repo = '${ent['hf_repo'] ?? ''}';
        final token = '${ent['hf_token'] ?? ''}';
        if (repo.isEmpty || token.isEmpty) {
          log?.call('✗ "$nombre": sin repo/token');
          continue;
        }
        final mldRuta = '${ent['mld_ruta'] ?? ''}';
        var hashMld = '';
        if (mldRuta.isNotEmpty && await File(mldRuta).exists()) {
          hashMld = await HuggingFace.sha256Archivo(mldRuta);
        }
        final hashSql = '${ent['hash_sql'] ?? ''}';
        final hashMldIx = '${ent['hash_mld'] ?? ''}';
        final arriba = repoCache.putIfAbsent('$repoType/$repo', () => {});
        if (arriba.isEmpty) {
          try {
            arriba.addAll(
                await archivos(repoId: repo, token: token, repoType: repoType));
          } catch (e) {
            log?.call('⚠ no se listó $repo: $e');
          }
        }
        // Mismo contenido ya arriba (verificado por nombre=hash).
        if (hashMld.isNotEmpty &&
            hashMld == hashMldIx &&
            arriba.contains('$hashMld.mld') &&
            (hashSql.isEmpty || arriba.contains('$hashSql.sql'))) {
          log?.call('· "$nombre": ya está arriba ($hashMld), se salta');
          saltados++;
          continue;
        }
        await subirMolde(
          passIndice: passIndice,
          claveSql: claveSql,
          nombre: nombre,
          repoType: repoType,
          conIndice: conIndice,
          log: log,
        );
        subidos++;
      } catch (e) {
        log?.call('✗ "$nombre": $e');
      }
    }
    return (subidos: subidos, saltados: saltados);
  }

  /// Sube SOLO el índice (`indice.db`, cifrado con tu clave) al repo
  /// que digas (repo+token propios del índice, guardados con
  /// `Indice.guardarHfIndice`). No toca ningún molde.
  Future<void> subirIndice({
    required String passIndice,
    required String repo,
    required String token,
    String repoType = 'dataset',
    void Function(String s)? log,
  }) async {
    if (repo.isEmpty || token.isEmpty) {
      throw StateError('puente_hf: el índice no tiene repo/token '
          '(guardalos primero con "Guardar HF índice")');
    }
    // La pass tiene que abrir el índice: si no, no hay qué subir.
    await Indice.hfIndice(passIndice);
    final carpeta = await MediaBase.carpetaMoldes();
    final idx = File('${carpeta.path}/${Indice.archivo}');
    if (!await idx.exists()) {
      throw StateError('puente_hf: no hay ${Indice.archivo} local');
    }
    await asegurarRepo(repoId: repo, token: token, repoType: repoType);
    log?.call('· subiendo ${Indice.archivo} a $repo…');
    await _hf.uploadFile(
      repoId: repo,
      localFilePath: idx.path,
      pathInRepo: Indice.archivo,
      commitMessage: 'indice solo v${DateTime.now().millisecondsSinceEpoch}',
      repoType: repoType,
    );
    log?.call('✓ índice en $repo');
  }

  /// Baja SOLO el índice (`indice.db`) del repo que digas y lo pone
  /// como local. El anterior se respalda (`indice.db.bak_<ms>`).
  /// OJO: el bajado abre con SU clave, no con la tuya.
  /// Retorna el path final. Token vacío = repo público.
  Future<String> bajarIndice({
    required String repo,
    required String token,
    String repoType = 'dataset',
    void Function(String s)? log,
  }) async {
    if (repo.isEmpty) {
      throw StateError('puente_hf: decí el repo del índice');
    }
    await init(token);
    final tmp = await Directory.systemTemp.createTemp('hf_idx');
    try {
      final bajado = await _hf.downloadFile(
        repoId: repo,
        filename: Indice.archivo,
        localDir: tmp.path,
        repoType: repoType,
      );
      final carpeta = await MediaBase.carpetaMoldes();
      final destino = File('${carpeta.path}/${Indice.archivo}');
      if (await destino.exists()) {
        final bak = File('${carpeta.path}/${Indice.archivo}'
            '.bak_${DateTime.now().millisecondsSinceEpoch}');
        await destino.copy(bak.path);
        log?.call('· local respaldado en ${bak.path.split('/').last}');
      }
      await File(bajado).copy(destino.path);
      log?.call('✓ índice bajado de $repo (abre con SU clave)');
      return destino.path;
    } finally {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }
}
