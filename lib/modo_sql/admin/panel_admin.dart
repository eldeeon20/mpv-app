import 'package:flutter/material.dart';

/// Panel admin: por molde muestra su SQL y su .mld, y permite MOVERLOS
/// a otro directorio (actualiza la SQL y el índice, OJO: mueve todo
/// junto o nada).
class PanelAdmin extends StatelessWidget {
  /// Entradas crudas del índice (nombre, db_ruta, mld_ruta, n, total).
  final List<Map<String, Object?>> entradas;

  /// Mueve un molde (pide carpeta y actualiza rutas).
  final void Function(String nombre) onMover;

  /// Edita rutas a mano (URL, IP o lugar no físico).
  final void Function(String nombre) onEditarRutas;

  /// Modo suave: 1 hilo de descifrado (vs 6 libres).
  final bool suave;
  final void Function(bool v) onSuave;

  /// Hilos actuales en uso (para ver si satura).
  final int hilosEnUso;
  final int maxHilos;

  /// Caché visible: bytes por molde, resumen hits/miss, límite.
  final Map<String, int> cacheBytes;
  final String cacheResumen;
  final int cacheLimiteKb;
  final VoidCallback onVaciarCache;
  final bool scrollable;

  const PanelAdmin({
    super.key,
    required this.entradas,
    required this.onMover,
    required this.onEditarRutas,
    required this.suave,
    required this.onSuave,
    required this.hilosEnUso,
    required this.maxHilos,
    required this.cacheBytes,
    required this.cacheResumen,
    required this.cacheLimiteKb,
    required this.onVaciarCache,
    this.scrollable = true,
  });

  @override
  Widget build(BuildContext context) {
    final children = [
      const Text('Admin (rutas de cada molde)',
          style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 4),
      const Text(
        'El índice guarda la relación: qué SQL + su pass + dónde. '
        'Mover cambia .db + .mld juntos y actualiza todo.',
        style: TextStyle(fontSize: 11, color: Colors.grey),
      ),
      const SizedBox(height: 6),
      const Text('Índice: Download/mediablock/indice.db (cifrado)',
          style: TextStyle(fontSize: 11)),
      const Text('Caché: privada en la app (misma pass del índice)',
          style: TextStyle(fontSize: 11)),
      const SizedBox(height: 4),
      Row(children: [
        Expanded(
          child: Text(
            cacheResumen.isEmpty
                ? 'Caché vacía (límite $cacheLimiteKb KB por molde)'
                : '$cacheResumen · límite $cacheLimiteKb KB por molde',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ),
        TextButton(
          onPressed: onVaciarCache,
          child: const Text('Vaciar', style: TextStyle(fontSize: 11)),
        ),
      ]),
      if (cacheBytes.isNotEmpty)
        for (final e in cacheBytes.entries)
          Text('· ${e.key}: ${e.value} bytes',
              style: const TextStyle(fontSize: 11)),
      const Divider(height: 12),
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title:
            const Text('Modo suave (2 hilos)', style: TextStyle(fontSize: 12)),
        subtitle: Text(
          suave
              ? '2 hilos: scroll libre, previews en orden'
              : 'libre ($maxHilos hilos, en uso: $hilosEnUso)',
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
        value: suave,
        onChanged: onSuave,
      ),
      const Divider(height: 12),
      if (entradas.isEmpty)
        const Text('Sin entradas en el índice',
            style: TextStyle(fontSize: 12, color: Colors.grey)),
      for (final e in entradas)
        Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: ListTile(
            dense: true,
            title: Text('${e['nombre'] ?? ''}',
                style: const TextStyle(fontSize: 13)),
            subtitle: Text(
              'sql: ${e['db_ruta'] ?? ''}\n'
              'mld: ${e['mld_ruta'] ?? ''}',
              style: const TextStyle(fontSize: 10),
            ),
            isThreeLine: true,
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              TextButton(
                onPressed: () => onEditarRutas('${e['nombre'] ?? ''}'),
                child: const Text('Editar…', style: TextStyle(fontSize: 11)),
              ),
              TextButton(
                onPressed: () => onMover('${e['nombre'] ?? ''}'),
                child: const Text('Mover…', style: TextStyle(fontSize: 11)),
              ),
            ]),
          ),
        ),
    ];
    if (!scrollable) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      );
    }
    return ListView(padding: const EdgeInsets.all(12), children: children);
  }
}
