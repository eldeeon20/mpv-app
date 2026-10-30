import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../db/caja_sql.dart';
import '../media_server/media_server.dart';

class CuentaNube {
  final String id;
  final String proveedor;
  final String nombre;
  final String destino;
  final String token;

  const CuentaNube({
    required this.id,
    required this.proveedor,
    required this.nombre,
    required this.destino,
    required this.token,
  });

  factory CuentaNube.fromRow(Map<String, Object?> row) => CuentaNube(
        id: '${row['account_id'] ?? ''}',
        proveedor: '${row['provider'] ?? ''}',
        nombre: '${row['name'] ?? ''}',
        destino: '${row['destination'] ?? ''}',
        token: '${row['secret'] ?? ''}',
      );
}

/// ÍNDICE en SQL de verdad (`indice.db` en Download) con SU PROPIA
/// CLAVE: el archivo va cifrado entero con sqlite3mc ChaCha20 y el
/// cifrado es transparente por página — jamás hay nada descifrado
/// en disco, sin temporales. Clave mala = no abre.
/// (El formato viejo de GCM entero se migra solo, una vez.)
///
/// Liviana: por molde solo QUÉ sql + SU pass + dónde está el .mld.
class Indice {
  static const archivo = 'indice.db';
  static const _viejoDb = 'catalogo.db';
  static const _viejoMlc = 'catalogo.mlc';

  /// Sumidero de avisos (lo viejo y lo automático se loguea siempre).
  static void Function(String s)? log;

  static Future<File> _file() async {
    final carpeta = await MediaBase.carpetaMoldes();
    return File('${carpeta.path}/$archivo');
  }

  /// Si existe la vieja `catalogo.db` y la nueva no, se adopta
  /// (se lee de ahí; el primer guardado ya escribe `indice.db`).
  static Future<File> _origen() async {
    final nuevo = await _file();
    if (await nuevo.exists()) return nuevo;
    final carpeta = await MediaBase.carpetaMoldes();
    final viejo = File('${carpeta.path}/$_viejoDb');
    if (await viejo.exists()) return viejo;
    return nuevo;
  }

  static Future<File> _tmp() async {
    final t = await getTemporaryDirectory();
    return File('${t.path}/catalogo_tmp.db');
  }

  static String _salHex(Uint8List sal) {
    return sal.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
  }

  static Future<Uint8List> _clave(String pass, String salHex) {
    return Duro.claveArchivoHilo(
      clave: pass,
      molde: 'catalogo',
      nombre: 'indice',
      salHex: salHex,
    );
  }

  static void _tabla(Database db) {
    db.execute('CREATE TABLE IF NOT EXISTS indice('
        'nombre TEXT PRIMARY KEY, sql TEXT, pass TEXT, mld TEXT, '
        'n INTEGER, total INTEGER, fecha INTEGER, sal TEXT, '
        'hf_repo TEXT, hf_token TEXT, version INTEGER, '
        'hash_mld TEXT, hash_sql TEXT, carpeta TEXT);');
    // Repo+token PROPIOS del índice (aparte de los moldes). Una sola fila.
    db.execute('CREATE TABLE IF NOT EXISTS indice_hf(repo TEXT, token TEXT);');
    db.execute(
        'CREATE TABLE IF NOT EXISTS telegram_bot_config(token TEXT, chat_id TEXT);');
    db.execute('CREATE TABLE IF NOT EXISTS cloud_accounts('
        'account_id TEXT PRIMARY KEY, provider TEXT NOT NULL, name TEXT NOT NULL, '
        'destination TEXT NOT NULL, secret TEXT NOT NULL);');
    db.execute('CREATE TABLE IF NOT EXISTS config_migrations('
        'migration TEXT PRIMARY KEY);');
    db.execute('CREATE TABLE IF NOT EXISTS telegram_user_config('
        'api_id TEXT, api_hash TEXT, database_key TEXT);');
    db.execute('CREATE TABLE IF NOT EXISTS indice_telegram('
        'nombre TEXT PRIMARY KEY, modo TEXT NOT NULL, chat_id TEXT, '
        'manifest_file_id TEXT, manifest_message_id INTEGER, '
        'mld_size INTEGER, sql_file_id TEXT, sql_message_id INTEGER, '
        'sql_size INTEGER, updated_at INTEGER);');
    final telegramCols = {
      for (final row in db.select('PRAGMA table_info(indice_telegram);'))
        '${row['name']}': true,
    };
    for (final col in {
      'account_id': 'TEXT',
      'sql_file_id': 'TEXT',
      'sql_message_id': 'INTEGER',
      'sql_size': 'INTEGER',
    }.entries) {
      if (!telegramCols.containsKey(col.key)) {
        db.execute(
          'ALTER TABLE indice_telegram ADD COLUMN ${col.key} ${col.value};',
        );
      }
    }
    // Migración: índices viejos sin columnas nuevas.
    final cols = {
      for (final r in db.select('PRAGMA table_info(indice);'))
        '${r['name']}': true
    };
    for (final c in [
      'hf_repo',
      'hf_token',
      'version',
      'hash_mld',
      'hash_sql',
      'carpeta'
    ]) {
      if (!cols.containsKey(c)) {
        db.execute(
            'ALTER TABLE indice ADD COLUMN $c ${c == 'version' ? 'INTEGER' : 'TEXT'};');
      }
    }
  }

  /// Descifra el índice a un temporal privado (lo crea vacío si no hay).
  static Future<File> _materializar(String pass) async {
    if (pass.isEmpty) {
      throw ArgumentError('índice: poné su propia clave');
    }
    final f = await _origen();
    final tmp = await _tmp();
    try {
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {}
    if (!await f.exists()) {
      final db = sqlite3.open(tmp.path);
      try {
        _tabla(db);
      } finally {
        db.dispose();
      }
      return tmp;
    }
    final raw = await f.readAsBytes();
    if (raw.length < 16 + 12 + 16) {
      throw StateError('índice: archivo corrupto o truncado');
    }
    final sal = raw.sublist(0, 16);
    final nonce = raw.sublist(16, 28);
    final resto = raw.sublist(28);
    final key = await _clave(pass, _salHex(sal));
    try {
      final mac = Mac(resto.sublist(resto.length - 16));
      final cipher = resto.sublist(12, resto.length - 16);
      final claro = await AesGcm.with256bits().decrypt(
        SecretBox(cipher, nonce: nonce, mac: mac),
        secretKey: SecretKey(key),
      );
      await tmp.writeAsBytes(claro, flush: true);
      return tmp;
    } catch (_) {
      throw StateError('índice: clave mal (no autentica)');
    }
  }

  /// Abre el índice: SQLite cifrado con sqlite3mc (clave = pass).
  /// Sin temporales descifrados en disco: el cifrado es transparente
  /// por página, nunca hay nada en claro fuera del proceso.
  /// Crea o migra del formato viejo (GCM entero) una sola vez.
  static Future<CajaSql> _caja(String pass) async {
    if (pass.isEmpty) {
      throw ArgumentError('índice: poné su propia clave');
    }
    final f = await _file();
    final carpeta = await MediaBase.carpetaMoldes();
    final caja = CajaSql();
    if (await f.exists()) {
      try {
        await caja.abrirRuta(f.path, clave: pass);
        _tabla(caja.db);
        return caja;
      } catch (_) {
        caja.cerrar();
      }
      // No abrió con clave: formato viejo GCM → se migra una vez.
      await _migrarLegacy(pass, f);
    }
    await caja.abrir('indice', carpeta: carpeta.path, clave: pass);
    _tabla(caja.db);
    return caja;
  }

  static Object? _col(Row r, String c) {
    try {
      return r[c];
    } catch (_) {
      return null;
    }
  }

  /// Migra el índice viejo (AES-GCM entero) al SQLite cifrado.
  /// Lee todo en memoria, pisa el archivo y escribe el nuevo.
  static Future<void> _migrarLegacy(String pass, File f) async {
    log?.call('⚠ índice viejo (GCM entero) → migrando a SQL cifrada…');
    // _materializar lanza si la clave es mala: no se toca nada.
    final tmp = await _materializar(pass);
    final leidas = <Map<String, Object?>>[];
    final origen = sqlite3.open(tmp.path);
    try {
      for (final r in origen.select('SELECT * FROM indice;')) {
        leidas.add({
          'nombre': '${_col(r, 'nombre') ?? ''}',
          'sql': '${_col(r, 'sql') ?? ''}',
          'pass': '${_col(r, 'pass') ?? ''}',
          'mld': '${_col(r, 'mld') ?? ''}',
          'n': (_col(r, 'n') as int?) ?? 0,
          'total': (_col(r, 'total') as int?) ?? 0,
          'fecha': (_col(r, 'fecha') as int?) ?? 0,
          'sal': '${_col(r, 'sal') ?? ''}',
          'hf_repo': '${_col(r, 'hf_repo') ?? ''}',
          'hf_token': '${_col(r, 'hf_token') ?? ''}',
          'version': (_col(r, 'version') as int?) ?? 0,
        });
      }
    } finally {
      origen.dispose();
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
    final carpeta = await MediaBase.carpetaMoldes();
    final caja = CajaSql();
    await caja.abrir('indice', carpeta: carpeta.path, clave: pass);
    try {
      _tabla(caja.db);
      for (final m in leidas) {
        caja.db.execute(
          'INSERT OR REPLACE INTO indice(nombre, sql, pass, mld, n, '
          'total, fecha, sal, hf_repo, hf_token, version, hash_mld, '
          'hash_sql, carpeta) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
          [
            m['nombre'],
            m['sql'],
            m['pass'],
            m['mld'],
            m['n'],
            m['total'],
            m['fecha'],
            m['sal'],
            m['hf_repo'],
            m['hf_token'],
            m['version'],
            '',
            '',
            '',
          ],
        );
      }
    } finally {
      caja.cerrar();
    }
    log?.call('✓ índice migrado a SQL cifrada (${leidas.length} molde(s))');
  }

  /// Asegura que el índice propio existe (vacío cifrado si es nuevo).
  /// Borra el `.mlc` viejo si quedó (la `catalogo.db` vieja se adopta
  /// en `_origen`, no se borra: el primer guardado ya escribe nuevo).
  static Future<void> asegurar(String pass) async {
    if (pass.isEmpty) return;
    try {
      final carpeta = await MediaBase.carpetaMoldes();
      final mlc = File('${carpeta.path}/$_viejoMlc');
      if (await mlc.exists()) await mlc.delete();
    } catch (_) {}
    final caja = await _caja(pass);
    caja.cerrar();
  }

  /// Índice liviano: solo QUÉ sql + SU pass (+ .mld y números).
  static Future<List<Map<String, Object?>>> listarRaw(String pass) async {
    final caja = await _caja(pass);
    try {
      final rs = caja.db.select('SELECT * FROM indice ORDER BY nombre;');
      return [
        for (final r in rs)
          {
            'nombre': '${r['nombre'] ?? ''}',
            'db': '${r['sql'] ?? ''}',
            'db_ruta': '${r['sql'] ?? ''}',
            'pass': '${r['pass'] ?? ''}',
            'mld_ruta': '${r['mld'] ?? ''}',
            'n': (r['n'] as int?) ?? 0,
            'total': (r['total'] as int?) ?? 0,
            'fecha': (r['fecha'] as int?) ?? 0,
            'sal': '${r['sal'] ?? ''}',
            'cifrado': 'sql-chacha20',
            // HF: dónde vive remoto (repo_id = dir/user), con qué
            // token entrar y qué versión se subió por última vez.
            // hash_*: con QUÉ nombre (hash256) vive cada archivo en HF.
            // carpeta: anidado SOLO del índice ('' = raíz).
            'hf_repo': '${r['hf_repo'] ?? ''}',
            'hf_token': '${r['hf_token'] ?? ''}',
            'version': (r['version'] as int?) ?? 0,
            'hash_mld': '${r['hash_mld'] ?? ''}',
            'hash_sql': '${r['hash_sql'] ?? ''}',
            'carpeta': '${r['carpeta'] ?? ''}',
          }
      ];
    } finally {
      caja.cerrar();
    }
  }

  /// Una entrada del índice (relación: qué sql + su pass + rutas).
  static Future<Map<String, Object?>?> entrada({
    required String pass,
    required String nombre,
  }) async {
    final lista = await listarRaw(pass);
    for (final m in lista) {
      if ('${m['nombre']}' == nombre) return m;
    }
    return null;
  }

  /// Historial rápido (MoldeInfo listos para abrir).
  static Future<List<MoldeInfo>> listar(String pass) async {
    final lista = await listarRaw(pass);
    return [
      for (final m in lista)
        MoldeInfo(
          nombre: '${m['nombre'] ?? ''}',
          ruta: '${m['mld_ruta'] ?? ''}',
          fecha: (m['fecha'] as int?) ?? 0,
          total: (m['total'] as int?) ?? 0,
          sal: '${m['sal'] ?? ''}',
          cifrado: '${m['cifrado'] ?? ''}',
        )
    ];
  }

  static Future<void> registrar({
    required String pass,
    required String nombre,
    required String dbRuta,
    required String mldRuta,
    required int n,
    required int total,
    required String sal,
    String passMolde = '',
    String hfRepo = '',
    String hfToken = '',
    int version = 0,
    // null = conserva lo que había (igual que HF con vacío).
    String? hashMld,
    String? hashSql,
    String? carpeta,
  }) async {
    final caja = await _caja(pass);
    try {
      // Preserva HF si esta llamada no trae (registros viejos).
      var repo = hfRepo;
      var tok = hfToken;
      var ver = version;
      String? hm = hashMld;
      String? hs = hashSql;
      String? cp = carpeta;
      try {
        final prev = caja.db.select(
            'SELECT hf_repo, hf_token, version, hash_mld, hash_sql, '
            'carpeta FROM indice WHERE nombre = ?;',
            [nombre]);
        if (prev.isNotEmpty) {
          final p = prev.first;
          if (hfRepo.isEmpty && hfToken.isEmpty) {
            repo = '${p['hf_repo'] ?? ''}';
            tok = '${p['hf_token'] ?? ''}';
            ver = (p['version'] as int?) ?? 0;
          }
          hm ??= '${p['hash_mld'] ?? ''}';
          hs ??= '${p['hash_sql'] ?? ''}';
          cp ??= '${p['carpeta'] ?? ''}';
        }
      } catch (_) {}
      caja.db.execute(
        'INSERT OR REPLACE INTO indice'
        '(nombre, sql, pass, mld, n, total, fecha, sal, '
        'hf_repo, hf_token, version, hash_mld, hash_sql, carpeta) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
        [
          nombre,
          dbRuta,
          passMolde,
          mldRuta,
          n,
          total,
          DateTime.now().millisecondsSinceEpoch,
          sal,
          repo,
          tok,
          ver,
          hm ?? '',
          hs ?? '',
          cp ?? '',
        ],
      );
    } finally {
      caja.cerrar();
    }
  }

  /// Guarda/actualiza los datos HF de un molde (dir/user = repo_id,
  /// pass del molde y token de acceso). No toca lo demás.
  static Future<void> guardarHf({
    required String pass,
    required String nombre,
    required String hfRepo,
    required String hfToken,
  }) async {
    final ent = await entrada(pass: pass, nombre: nombre);
    if (ent == null) {
      throw StateError('índice: "$nombre" no existe');
    }
    await registrar(
      pass: pass,
      nombre: nombre,
      dbRuta: '${ent['db_ruta'] ?? ''}',
      mldRuta: '${ent['mld_ruta'] ?? ''}',
      n: (ent['n'] as int?) ?? 0,
      total: (ent['total'] as int?) ?? 0,
      sal: '${ent['sal'] ?? ''}',
      passMolde: '${ent['pass'] ?? ''}',
      hfRepo: hfRepo,
      hfToken: hfToken,
      version: (ent['version'] as int?) ?? 0,
      hashMld: '${ent['hash_mld'] ?? ''}',
      hashSql: '${ent['hash_sql'] ?? ''}',
      carpeta: '${ent['carpeta'] ?? ''}',
    );
  }

  /// Guarda el repo+token PROPIOS del índice (aparte de los moldes).
  /// No toca ningún molde: es para subir el índice solo, sin mezclar.
  static Future<void> guardarHfIndice({
    required String pass,
    required String hfRepo,
    required String hfToken,
  }) async {
    final caja = await _caja(pass);
    try {
      _tabla(caja.db);
      caja.db.execute('DELETE FROM indice_hf;');
      caja.db.execute('INSERT INTO indice_hf(repo, token) VALUES (?, ?);',
          [hfRepo, hfToken]);
    } finally {
      caja.cerrar();
    }
  }

  /// Repo+token propios del índice ('' si no se guardaron).
  static Future<({String repo, String token})> hfIndice(String pass) async {
    final caja = await _caja(pass);
    try {
      _tabla(caja.db);
      final r = caja.db.select('SELECT repo, token FROM indice_hf LIMIT 1;');
      if (r.isEmpty) return (repo: '', token: '');
      return (
        repo: '${r.first['repo'] ?? ''}',
        token: '${r.first['token'] ?? ''}'
      );
    } finally {
      caja.cerrar();
    }
  }

  static Future<void> guardarBotTelegram({
    required String pass,
    required String token,
    required String chatId,
  }) async {
    final caja = await _caja(pass);
    try {
      caja.db.execute('DELETE FROM telegram_bot_config;');
      caja.db.execute(
        'INSERT INTO telegram_bot_config(token, chat_id) VALUES (?, ?);',
        [token.trim(), chatId.trim()],
      );
    } finally {
      caja.cerrar();
    }
  }

  static Future<List<CuentaNube>> cuentasNube(String pass) async {
    final caja = await _caja(pass);
    try {
      _tabla(caja.db);
      final migrated = caja.db.select(
        'SELECT migration FROM config_migrations WHERE migration = ?;',
        ['cloud_accounts_v1'],
      );
      if (migrated.isEmpty) {
        final bot = caja.db.select(
          'SELECT token, chat_id FROM telegram_bot_config LIMIT 1;',
        );
        if (bot.isNotEmpty &&
            '${bot.first['token'] ?? ''}'.isNotEmpty &&
            '${bot.first['chat_id'] ?? ''}'.isNotEmpty) {
          caja.db.execute(
            'INSERT OR IGNORE INTO cloud_accounts'
            '(account_id, provider, name, destination, secret) '
            'VALUES (?, ?, ?, ?, ?);',
            [
              'telegram_bot_legacy',
              'telegram_bot',
              'Bot Telegram anterior',
              '${bot.first['chat_id']}',
              '${bot.first['token']}',
            ],
          );
        }
        final hf = caja.db.select(
          'SELECT DISTINCT hf_repo, hf_token FROM indice '
          "WHERE COALESCE(hf_repo, '') != '' "
          "AND COALESCE(hf_token, '') != '';",
        );
        for (final row in hf) {
          final repo = '${row['hf_repo']}';
          final token = '${row['hf_token']}';
          final id = 'hf_legacy_${base64Url.encode(utf8.encode(repo))}';
          caja.db.execute(
            'INSERT OR IGNORE INTO cloud_accounts'
            '(account_id, provider, name, destination, secret) '
            'VALUES (?, ?, ?, ?, ?);',
            [id, 'huggingface', repo, repo, token],
          );
        }
        caja.db.execute(
          'INSERT INTO config_migrations(migration) VALUES (?);',
          ['cloud_accounts_v1'],
        );
      }
      return [
        for (final row in caja.db.select(
          'SELECT account_id, provider, name, destination, secret '
          'FROM cloud_accounts ORDER BY provider, name;',
        ))
          CuentaNube.fromRow(row)
      ];
    } finally {
      caja.cerrar();
    }
  }

  static Future<String> guardarCuentaNube({
    required String pass,
    required String provider,
    required String name,
    required String destination,
    required String secret,
    String? id,
  }) async {
    if (!{'telegram_bot', 'huggingface'}.contains(provider)) {
      throw ArgumentError.value(provider, 'provider', 'Proveedor inválido');
    }
    if (name.trim().isEmpty ||
        destination.trim().isEmpty ||
        secret.trim().isEmpty) {
      throw ArgumentError('Nombre, destino y credencial son obligatorios');
    }
    final accountId = id ??
        '${provider}_${DateTime.now().microsecondsSinceEpoch}_'
            '${Random.secure().nextInt(1 << 32).toRadixString(16)}';
    final caja = await _caja(pass);
    try {
      _tabla(caja.db);
      caja.db.execute(
        'INSERT OR REPLACE INTO cloud_accounts'
        '(account_id, provider, name, destination, secret) VALUES (?, ?, ?, ?, ?);',
        [
          accountId,
          provider,
          name.trim(),
          destination.trim(),
          secret.trim(),
        ],
      );
    } finally {
      caja.cerrar();
    }
    return accountId;
  }

  static Future<void> quitarCuentaNube({
    required String pass,
    required String id,
  }) async {
    final caja = await _caja(pass);
    try {
      _tabla(caja.db);
      final referencias = caja.db.select(
        'SELECT nombre FROM indice_telegram WHERE account_id = ? LIMIT 1;',
        [id],
      );
      if (referencias.isNotEmpty) {
        throw StateError(
          'La cuenta está asociada al molde "${referencias.first['nombre']}". '
          'No se puede quitar mientras ese respaldo dependa de ella.',
        );
      }
      caja.db.execute(
        'DELETE FROM cloud_accounts WHERE account_id = ?;',
        [id],
      );
    } finally {
      caja.cerrar();
    }
  }

  static Future<CuentaNube?> cuentaNube({
    required String pass,
    required String id,
  }) async {
    final cuentas = await cuentasNube(pass);
    for (final cuenta in cuentas) {
      if (cuenta.id == id) return cuenta;
    }
    return null;
  }

  static Future<({String token, String chatId})> botTelegram(
      String pass) async {
    final caja = await _caja(pass);
    try {
      final rows = caja.db.select(
        'SELECT token, chat_id FROM telegram_bot_config LIMIT 1;',
      );
      if (rows.isEmpty) return (token: '', chatId: '');
      return (
        token: '${rows.first['token'] ?? ''}',
        chatId: '${rows.first['chat_id'] ?? ''}',
      );
    } finally {
      caja.cerrar();
    }
  }

  static Future<void> guardarManifiestoTelegram({
    required String pass,
    required String nombre,
    String accountId = '',
    required String chatId,
    required String fileId,
    required int messageId,
    required int size,
    required String sqlFileId,
    required int sqlMessageId,
    required int sqlSize,
  }) async {
    final caja = await _caja(pass);
    try {
      caja.db.execute(
        'INSERT OR REPLACE INTO indice_telegram('
        'nombre, modo, account_id, chat_id, manifest_file_id, manifest_message_id, '
        'mld_size, sql_file_id, sql_message_id, sql_size, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
        [
          nombre,
          'bot',
          accountId,
          chatId,
          fileId,
          messageId,
          size,
          sqlFileId,
          sqlMessageId,
          sqlSize,
          DateTime.now().millisecondsSinceEpoch,
        ],
      );
    } finally {
      caja.cerrar();
    }
  }

  static Future<Map<String, Object?>?> manifiestoTelegram({
    required String pass,
    required String nombre,
  }) async {
    final caja = await _caja(pass);
    try {
      final rows = caja.db.select(
        'SELECT modo, account_id, chat_id, manifest_file_id, manifest_message_id, '
        'mld_size, sql_file_id, sql_message_id, sql_size, updated_at '
        'FROM indice_telegram WHERE nombre = ?;',
        [nombre],
      );
      if (rows.isEmpty) return null;
      final row = rows.first;
      return {
        'modo': '${row['modo'] ?? ''}',
        'account_id': '${row['account_id'] ?? ''}',
        'chat_id': '${row['chat_id'] ?? ''}',
        'manifest_file_id': '${row['manifest_file_id'] ?? ''}',
        'manifest_message_id': (row['manifest_message_id'] as int?) ?? 0,
        'mld_size': (row['mld_size'] as int?) ?? 0,
        'sql_file_id': '${row['sql_file_id'] ?? ''}',
        'sql_message_id': (row['sql_message_id'] as int?) ?? 0,
        'sql_size': (row['sql_size'] as int?) ?? 0,
        'updated_at': (row['updated_at'] as int?) ?? 0,
      };
    } finally {
      caja.cerrar();
    }
  }

  static Future<Set<String>> moldesTelegram(String pass) async {
    final caja = await _caja(pass);
    try {
      final rows = caja.db.select(
        'SELECT nombre FROM indice_telegram WHERE modo = ?;',
        ['bot'],
      );
      return {
        for (final row in rows)
          if ('${row['nombre'] ?? ''}'.isNotEmpty) '${row['nombre']}',
      };
    } finally {
      caja.cerrar();
    }
  }

  static Future<void> guardarCredencialesTelegram({
    required String pass,
    required String apiId,
    required String apiHash,
  }) async {
    final id = int.tryParse(apiId.trim());
    if (id == null || id <= 0 || apiHash.trim().isEmpty) {
      throw ArgumentError('API ID y API Hash de Telegram son obligatorios');
    }
    final caja = await _caja(pass);
    try {
      final previous = caja.db.select(
        'SELECT database_key FROM telegram_user_config LIMIT 1;',
      );
      final databaseKey = previous.isEmpty
          ? base64Encode(
              List<int>.generate(32, (_) => Random.secure().nextInt(256)))
          : '${previous.first['database_key'] ?? ''}';
      caja.db.execute('DELETE FROM telegram_user_config;');
      caja.db.execute(
        'INSERT INTO telegram_user_config(api_id, api_hash, database_key) '
        'VALUES (?, ?, ?);',
        [id.toString(), apiHash.trim(), databaseKey],
      );
    } finally {
      caja.cerrar();
    }
  }

  static Future<({String apiId, String apiHash, String databaseKey})>
      credencialesTelegram(String pass) async {
    final caja = await _caja(pass);
    try {
      final rows = caja.db.select(
        'SELECT api_id, api_hash, database_key '
        'FROM telegram_user_config LIMIT 1;',
      );
      if (rows.isEmpty) {
        return (apiId: '', apiHash: '', databaseKey: '');
      }
      return (
        apiId: '${rows.first['api_id'] ?? ''}',
        apiHash: '${rows.first['api_hash'] ?? ''}',
        databaseKey: '${rows.first['database_key'] ?? ''}',
      );
    } finally {
      caja.cerrar();
    }
  }

  /// Guarda los hash256 con que viven .mld/.sql en HF. No toca lo demás.
  static Future<void> guardarHash({
    required String pass,
    required String nombre,
    required String hashMld,
    required String hashSql,
  }) async {
    final ent = await entrada(pass: pass, nombre: nombre);
    if (ent == null) {
      throw StateError('índice: "$nombre" no existe');
    }
    await registrar(
      pass: pass,
      nombre: nombre,
      dbRuta: '${ent['db_ruta'] ?? ''}',
      mldRuta: '${ent['mld_ruta'] ?? ''}',
      n: (ent['n'] as int?) ?? 0,
      total: (ent['total'] as int?) ?? 0,
      sal: '${ent['sal'] ?? ''}',
      passMolde: '${ent['pass'] ?? ''}',
      hfRepo: '${ent['hf_repo'] ?? ''}',
      hfToken: '${ent['hf_token'] ?? ''}',
      version: (ent['version'] as int?) ?? 0,
      hashMld: hashMld,
      hashSql: hashSql,
    );
  }

  /// Mueve un molde a otra carpeta DEL ÍNDICE (anidar, solo índice:
  /// ni SQL ni .mld se tocan). '' = raíz.
  /// Normaliza una carpeta del índice: sin `/` inicial ni final,
  /// sin dobles, `\` → `/`. Un `/` suelto o vacío = raíz ('').
  /// Sin esto, `/a` y `a` son grupos distintos y el molde "desaparece".
  static String sanearCarpeta(String carpeta) {
    var cp = carpeta.trim().replaceAll('\\', '/');
    cp = cp.replaceAll(RegExp(r'/+'), '/');
    cp = cp.replaceAll(RegExp(r'^/|/$'), '');
    return cp;
  }

  static Future<void> mover({
    required String pass,
    required String nombre,
    required String carpeta,
  }) async {
    final ent = await entrada(pass: pass, nombre: nombre);
    if (ent == null) {
      throw StateError('índice: "$nombre" no existe');
    }
    final cp = sanearCarpeta(carpeta);
    if (cp.contains('..')) {
      throw ArgumentError('índice: carpeta inválida "$carpeta"');
    }
    await registrar(
      pass: pass,
      nombre: nombre,
      dbRuta: '${ent['db_ruta'] ?? ''}',
      mldRuta: '${ent['mld_ruta'] ?? ''}',
      n: (ent['n'] as int?) ?? 0,
      total: (ent['total'] as int?) ?? 0,
      sal: '${ent['sal'] ?? ''}',
      passMolde: '${ent['pass'] ?? ''}',
      hfRepo: '${ent['hf_repo'] ?? ''}',
      hfToken: '${ent['hf_token'] ?? ''}',
      version: (ent['version'] as int?) ?? 0,
      hashMld: '${ent['hash_mld'] ?? ''}',
      hashSql: '${ent['hash_sql'] ?? ''}',
      carpeta: cp,
    );
  }

  /// Marca la versión remota recién subida de un molde.
  static Future<void> marcarVersion({
    required String pass,
    required String nombre,
    required int version,
  }) async {
    final ent = await entrada(pass: pass, nombre: nombre);
    if (ent == null) return;
    await registrar(
      pass: pass,
      nombre: nombre,
      dbRuta: '${ent['db_ruta'] ?? ''}',
      mldRuta: '${ent['mld_ruta'] ?? ''}',
      n: (ent['n'] as int?) ?? 0,
      total: (ent['total'] as int?) ?? 0,
      sal: '${ent['sal'] ?? ''}',
      passMolde: '${ent['pass'] ?? ''}',
      hfRepo: '${ent['hf_repo'] ?? ''}',
      hfToken: '${ent['hf_token'] ?? ''}',
      version: version,
    );
  }

  /// Edita a mano las rutas de una entrada (por si el archivo está
  /// en un lugar no físico: URL, IP, etc.). No valida nada: si la
  /// ruta no abre, el error sale al abrir el molde.
  static Future<void> actualizarRutas({
    required String pass,
    required String nombre,
    required String dbRuta,
    required String mldRuta,
  }) async {
    final ent = await entrada(pass: pass, nombre: nombre);
    if (ent == null) {
      throw StateError('índice: "$nombre" no existe');
    }
    await registrar(
      pass: pass,
      nombre: nombre,
      dbRuta: dbRuta.isEmpty ? '${ent['db_ruta'] ?? ''}' : dbRuta,
      mldRuta: mldRuta.isEmpty ? '${ent['mld_ruta'] ?? ''}' : mldRuta,
      n: (ent['n'] as int?) ?? 0,
      total: (ent['total'] as int?) ?? 0,
      sal: '${ent['sal'] ?? ''}',
      passMolde: '${ent['pass'] ?? ''}',
      hfRepo: '${ent['hf_repo'] ?? ''}',
      hfToken: '${ent['hf_token'] ?? ''}',
      version: (ent['version'] as int?) ?? 0,
    );
  }

  static Future<void> quitar({
    required String pass,
    required String nombre,
  }) async {
    final caja = await _caja(pass);
    try {
      caja.db.execute('DELETE FROM indice WHERE nombre = ?;', [nombre]);
      caja.db
          .execute('DELETE FROM indice_telegram WHERE nombre = ?;', [nombre]);
    } finally {
      caja.cerrar();
    }
  }

  /// Escaneo inverso: "esta SQL, ¿tiene algún molde?"
  /// Abre la SQL, lee su tabla de moldes (la SQL sabe dónde está
  /// cada .mld) y registra cada hallazgo con dbRuta = esta SQL.
  /// El índice aprende dónde está cada SQL. Retorna los nombres.
  static Future<List<String>> escanearSql({
    required String pass,
    required String sqlPath,
    String claveSql = '',
  }) async {
    final caja = CajaSql();
    await caja.abrirRuta(sqlPath, clave: claveSql);
    try {
      late final List<Map<String, Object?>> filas;
      try {
        filas = caja.listar(MediaBase.tablaMoldes, por: 'nombre');
      } catch (_) {
        return [];
      }
      final nombres = <String>[];
      for (final f in filas) {
        final nombre = '${f['nombre'] ?? ''}';
        if (nombre.isEmpty || nombres.contains(nombre)) continue;
        final legacy = '${f['nombre_c'] ?? ''}'.isNotEmpty;
        await registrar(
          pass: pass,
          nombre: nombre,
          dbRuta: sqlPath,
          mldRuta: '${f['ruta'] ?? ''}',
          n: 0,
          total: (f['total'] as int?) ?? 0,
          sal: '${f['sal'] ?? ''}',
        );
        nombres.add(nombre);
        if (legacy) {
          log?.call('⚠ "$nombre": SQL legacy (nombres/tags cifrados '
              'a mano) en $sqlPath');
        } else {
          log?.call('· "$nombre": SQL nueva (bruto) en $sqlPath');
        }
      }
      return nombres;
    } finally {
      caja.cerrar();
    }
  }
}
