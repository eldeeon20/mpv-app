import 'dart:typed_data';

import '../cache/trozo_cache.dart';
import '../media_server/media_server.dart';
import '../tool/create_molde_sql.dart';

/// Caché RAM de minis: bytes por nombre + futuros memoizados +
/// tope de descifrados en vuelo + presupuesto de RAM.
///
/// Cada cuadro visible pide la suya perezoso; lo que no se ve no se
/// construye ni descifra. Sin esto cada rebuild re-derivaba PBKDF2 y
/// re-descifraba todo en el hilo UI (el scroll se trancaba).
class MiniCache {
  /// Bytes descifrados por nombre de archivo.
  final Map<String, Uint8List> minis = {};

  /// Trabajos en curso por molde+archivo; los resultados viven solo en [minis].
  final Map<String, Future<Uint8List?>> _pendientes = {};

  /// Tamaño en bytes por entrada (para evictar por RAM, no por n).
  final Map<String, int> _bytesPorMini = {};

  /// Descifrados simultáneos (tope para no saturar al deslizar).
  int enVuelo = 0;

  /// Hilos a la vez (6 libre, 1 modo suave). Ajustable en Admin.
  int maxEnVuelo = 6;

  /// Bytes totales en RAM.
  int bytesEnRam = 0;

  /// Presupuesto RAM de minis (lo viejo sale primero).
  /// Guarda bytes completos (el 256px lo hace el Image al pintar).
  /// Mitad del tope RAM adaptativo (lo pone la pantalla).
  int topeBytes = 512 * 1024 * 1024;
  int _generacion = 0;

  int get cuantas => minis.length;

  void limpiar() {
    _generacion++;
    minis.clear();
    _pendientes.clear();
    _bytesPorMini.clear();
    bytesEnRam = 0;
  }

  void _evictar() {
    while (bytesEnRam > topeBytes && minis.isNotEmpty) {
      final vieja = minis.keys.first;
      bytesEnRam -= _bytesPorMini[vieja] ?? 0;
      _bytesPorMini.remove(vieja);
      minis.remove(vieja);
    }
  }

  /// Mini de un archivo (null si no es imagen, es grande o falla).
  /// Usa la caché de trozos si viene (no toca el .mld de nuevo).
  Future<Uint8List?> de({
    required String claveSql,
    required String molde,
    required FichaArchivo f,
    required Set<String> imgs,
    TrozoCache? cache,
    MoldeInfo? info,
    List<FichaArchivo>? filas,
    void Function(String)? log,
  }) {
    final k = '$molde\n${f.nombre}';
    // LRU: lo ya descifrado vuelve al fondo (no se evicta por scrollear).
    final m0 = minis[f.nombre];
    if (m0 != null) {
      minis.remove(f.nombre);
      minis[f.nombre] = m0;
      return Future.value(m0);
    }
    final ya = _pendientes[k];
    if (ya != null) return ya;
    final generacion = _generacion;
    final fut = () async {
      try {
        if (!imgs.contains(f.formato.toLowerCase())) return null;
        // Tope 15MB como el visor (las fotos pasan los 3MB y el grid
        // las pintaba rotas sin intentar). La RAM se cuida sola por
        // presupuesto + decodificado a 256px.
        if (f.tamano <= 0 || f.tamano > 15 * 1024 * 1024) return null;
        while (enVuelo >= maxEnVuelo) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
        enVuelo++;
        try {
          final datos = await CreateMoldeSql.pedirRango(
            claveSql: claveSql,
            molde: molde,
            archivo: f.nombre,
            desde: 0,
            hasta: f.tamano,
            cache: cache,
            info: info,
            filas: filas,
            log: log,
          );
          final b = Uint8List.fromList(datos);
          if (generacion != _generacion) return b;
          minis[f.nombre] = b;
          bytesEnRam += b.length - (_bytesPorMini[f.nombre] ?? 0);
          _bytesPorMini[f.nombre] = b.length;
          _evictar();
          return b;
        } finally {
          enVuelo--;
        }
      } catch (e) {
        // Rojo con motivo: el error real va a la bitácora.
        try {
          log?.call('✗ mini "${f.nombre}": $e');
        } catch (_) {}
        return null;
      }
    }();
    _pendientes[k] = fut;
    return fut.whenComplete(() {
      if (identical(_pendientes[k], fut)) _pendientes.remove(k);
    });
  }
}
