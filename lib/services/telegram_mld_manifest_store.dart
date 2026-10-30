import 'dart:io';

import 'package:pr_app/modo_sql/db/caja_sql.dart';
import 'package:pr_app/modo_sql/media_server/media_server.dart';
import 'package:pr_app/services/telegram_bot_storage.dart';

class TelegramMldManifestStore {
  static Future<File> _newEncryptedDb({
    required String nombre,
    required String clave,
    Directory? directory,
  }) async {
    MediaBase.exigirNombre('molde', nombre);
    if (clave.isEmpty) throw ArgumentError('La clave del molde es obligatoria');
    final folder = directory ?? await MediaBase.carpetaMoldes();
    final file = File('${folder.path}${Platform.pathSeparator}tg_$nombre.db');
    if (await file.exists()) await file.delete();
    await file.create(recursive: true);
    final box = CajaSql();
    await box.abrirRuta(file.path, clave: clave);
    try {
      box.db.execute(
        'CREATE TABLE manifest(size INTEGER NOT NULL);'
        'CREATE TABLE parts('
        'offset INTEGER PRIMARY KEY, length INTEGER NOT NULL, '
        'message_id INTEGER NOT NULL, file_id TEXT NOT NULL);',
      );
    } finally {
      box.cerrar();
    }
    return file;
  }

  static Future<File> crear({
    required String nombre,
    required String clave,
    required TelegramMldManifest manifest,
    Directory? directory,
  }) async {
    final file = await _newEncryptedDb(
      nombre: nombre,
      clave: clave,
      directory: directory,
    );
    final box = CajaSql();
    await box.abrirRuta(file.path, clave: clave);
    try {
      box.db.execute('BEGIN;');
      try {
        box.db
            .execute('INSERT INTO manifest(size) VALUES (?);', [manifest.size]);
        for (final part in manifest.parts) {
          box.db.execute(
            'INSERT INTO parts(offset, length, message_id, file_id) '
            'VALUES (?, ?, ?, ?);',
            [part.offset, part.length, part.messageId, part.fileId],
          );
        }
        box.db.execute('COMMIT;');
      } catch (_) {
        box.db.execute('ROLLBACK;');
        rethrow;
      }
    } finally {
      box.cerrar();
    }
    return file;
  }

  static Future<TelegramMldManifest> leer({
    required String ruta,
    required String clave,
  }) async {
    final file = File(ruta);
    if (!await file.exists())
      throw StateError('No existe el manifiesto Telegram');
    final box = CajaSql();
    await box.abrirRuta(file.path, clave: clave);
    try {
      final headers = box.db.select('SELECT size FROM manifest LIMIT 1;');
      if (headers.isEmpty || headers.first['size'] is! int) {
        throw const FormatException('Manifiesto Telegram sin tamaño');
      }
      final rows = box.db.select(
        'SELECT offset, length, message_id, file_id FROM parts ORDER BY offset;',
      );
      final parts = <TelegramMldPart>[
        for (final row in rows)
          TelegramMldPart(
            offset: row['offset'] as int,
            length: row['length'] as int,
            messageId: row['message_id'] as int,
            fileId: '${row['file_id']}',
          ),
      ];
      return TelegramMldManifest(
        size: headers.first['size'] as int,
        parts: parts,
      );
    } finally {
      box.cerrar();
    }
  }
}
