import 'dart:convert';
import 'dart:typed_data';

import '../toolsec/toolsec.dart';
import 'app_db.dart';
import 'crypto_vault.dart';

/// Estado persistente del usuario, guardado en `app.db`
/// (tabla `kv`, clave `ajustes`, JSON directo).
///
/// El archivo completo ya va cifrado con ChaCha20 en AppDb; por eso
/// Settings no usa AES por valor. Solo se conserva AES/XOR para leer
/// y migrar blobs viejos.
class Settings {
  static final Settings instance = Settings._();
  Settings._();

  /// Toggle funcional del menú: mostrar la ruta/URI completa en media.
  bool mediaShowUri = false;

  /// Claves guardadas de Pkarr y Nostr (secretos en hex, cifrados junto
  /// con el resto en app.db).
  List<Map<String, dynamic>> pkarrKeys = [];
  List<Map<String, dynamic>> nostrKeys = [];

  /// Clave del archivo `app.db`. Ya no cifra valores nuevos de Settings;
  /// solo sirve para migrar blobs viejos.
  String get masterKey => AppDb.claveDb;

  bool _loaded = false;

  /// El load en curso (bootstrap lo dispara al arrancar). Los save()
  /// lo ESPERAN: guardar antes de cargar pisaba el archivo bueno con
  /// la memoria en defaults (vacía) → al reabrir, todo borrado.
  Future<void>? _cargando;

  /// Cola de guardados: los save() se EJECUTAN DE A UNO.
  static Future<void> _cola = Future.value();

  Future<void> save() {
    final t = _cola.then((_) async {
      try {
        await _cargando;
      } catch (_) {}
      await _guardarAhora();
    });
    _cola = t.catchError((_) {});
    return t;
  }

  Future<void> load() async {
    if (_loaded) return;
    _cargando ??= _cargar();
    try {
      await _cargando;
    } finally {
      _loaded = true;
    }
  }

  Future<void> _cargar() async {
    try {
      final kv = await AppDb.leer('ajustes');
      if (kv != null) await _cargarBytes(kv);
    } catch (e) {
      print('Settings.load error: $e');
    }
    await AppDb.tachar('config.pr');
    await AppDb.tachar('config.pr.bak');
    await AppDb.tachar('config.pr.tmp');
  }

  /// Vuelca los bytes guardados en memoria. true = ok.
  /// Acepta JSON directo (formato actual), envelope AES viejo y
  /// legado XOR. Los dos últimos se migran a JSON directo al guardar.
  Future<bool> _cargarBytes(Uint8List enc) async {
    try {
      Uint8List? plain;
      bool needsMigration = false;
      if (CryptoVault.isEnvelope(enc)) {
        plain = await CryptoVault.decrypt(enc, masterKey);
        needsMigration = true;
      } else {
        try {
          jsonDecode(utf8.decode(enc));
          plain = enc;
        } catch (_) {
          plain = ToolSec(masterKey).processBytes(enc);
          needsMigration = true;
        }
      }
      if (plain == null) {
        print('Settings.load: blob viejo no autenticado, defaults');
        return false;
      }
      final map = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
      mediaShowUri = map['mediaShowUri'] as bool? ?? false;
      if (map['pkarrKeys'] is List) {
        pkarrKeys = map['pkarrKeys']
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
      if (map['nostrKeys'] is List) {
        nostrKeys = map['nostrKeys']
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
      if (needsMigration) save();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _guardarAhora() async {
    try {
      final map = {
        'mediaShowUri': mediaShowUri,
        'pkarrKeys': pkarrKeys,
        'nostrKeys': nostrKeys,
      };
      final plain = utf8.encode(jsonEncode(map));
      await AppDb.guardar('ajustes', Uint8List.fromList(plain));
    } catch (e) {
      print('Settings.save error: $e');
    }
  }
}
