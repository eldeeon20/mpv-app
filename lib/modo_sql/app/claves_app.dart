import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../services/app_db.dart';

/// Claves recordadas de la APP (no del molde): una SQL local privada
/// (soporte, NO Download) con la clave de cada molde cifrada (AES-GCM)
/// con una maestra aleatoria guardada en archivo privado.
///
/// Ojo honesto: sin keystore/biometría es ofuscación fuerte, no
/// secreto contra root. Sirve para no tipear la clave cada vez.
class ClavesApp {
  /// Una sola apertura de app.db: la cifrada de AppDb (migra el plano
  /// una vez). Abrirla acá en plano rompía con "file is not a database"
  /// en cuanto AppDb la cifraba.
  Future<Database> _abrir() async {
    final db = await AppDb.abrirDb();
    db.execute('CREATE TABLE IF NOT EXISTS recuerdo_claves('
        'molde TEXT PRIMARY KEY, nonce BLOB, datos BLOB);');
    return db;
  }

  Future<Uint8List> _maestra() async {
    final dir = await getApplicationSupportDirectory();
    final f = File('${dir.path}/app_master.key');
    try {
      if (await f.exists()) {
        final b = await f.readAsBytes();
        if (b.length == 32) return Uint8List.fromList(b);
      }
    } catch (_) {}
    final r = Random.secure();
    final k = Uint8List.fromList(
        List<int>.generate(32, (_) => r.nextInt(256)));
    try {
      await f.writeAsBytes(k, flush: true);
    } catch (_) {}
    return k;
  }

  static Uint8List _nonceAzar() {
    final r = Random.secure();
    return Uint8List.fromList(
        List<int>.generate(12, (_) => r.nextInt(256)));
  }

  /// Guarda (o pisa) la clave recordada de un molde.
  Future<void> guardar(String molde, String clave) async {
    if (molde.isEmpty || clave.isEmpty) return;
    final m = await _maestra();
    final nonce = _nonceAzar();
    final box = await AesGcm.with256bits().encrypt(
      utf8.encode(clave),
      secretKey: SecretKey(m),
      nonce: nonce,
    );
    final db = await _abrir();
    try {
      db.execute(
        'INSERT OR REPLACE INTO recuerdo_claves(molde, nonce, datos) '
        'VALUES (?, ?, ?);',
        [molde, nonce, Uint8List.fromList(box.concatenation())],
      );
    } finally {
      db.dispose();
    }
  }

  static Uint8List _bytes(Object? v) {
    if (v is Uint8List) return v;
    if (v is List) return Uint8List.fromList(v.cast<int>());
    throw StateError('recuerdo: blob inválido');
  }

  /// Clave recordada o null (no hay o no descifra).
  Future<String?> leer(String molde) async {
    try {
      final db = await _abrir();
      try {
        final rs = db.select(
          'SELECT datos FROM recuerdo_claves WHERE molde = ?;',
          [molde],
        );
        if (rs.isEmpty) return null;
        // El nonce va embebido en la concatenación (nonce+ct+mac).
        final datos = _bytes(rs.first['datos']);
        final m = await _maestra();
        final claro = await AesGcm.with256bits().decrypt(
          SecretBox.fromConcatenation(
            datos,
            nonceLength: 12,
            macLength: 16,
          ),
          secretKey: SecretKey(m),
        );
        return utf8.decode(claro);
      } finally {
        db.dispose();
      }
    } catch (_) {
      return null;
    }
  }

  /// Olvida la clave de un molde.
  Future<void> borrar(String molde) async {
    try {
      final db = await _abrir();
      try {
        db.execute(
            'DELETE FROM recuerdo_claves WHERE molde = ?;', [molde]);
      } finally {
        db.dispose();
      }
    } catch (_) {}
  }
}
