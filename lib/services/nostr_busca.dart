import '../src/rust/api/nostr_busca.dart' as rust;

/// Nostr Busca: perfiles y búsqueda de usuarios.
/// Clase fina reutilizable desde cualquier pantalla o página Lua caliente.
class NostrBusca {
  /// B1: perfil de un npub concreto (bech32 o hex).
  Future<rust.PerfilItem> perfil({
    required String npub,
    required List<String> relays,
    int timeoutSecs = 8,
  }) =>
      rust.nostrPerfilFetch(
        npub: npub,
        relays: relays,
        timeoutSecs: timeoutSecs,
      );

  /// B2: búsqueda por texto (NIP-50 — solo relays que la soportan).
  Future<List<rust.PerfilItem>> buscar({
    required String query,
    required List<String> relays,
    int limite = 25,
    int timeoutSecs = 8,
  }) =>
      rust.nostrBuscarUsuarios(
        query: query,
        relays: relays,
        limite: limite,
        timeoutSecs: timeoutSecs,
      );

  /// Muro: publicaciones kind 1 de un npub, ordenadas fecha ↓.
  /// [desdeMs] 0 = sin límite de tiempo.
  Future<List<rust.PostItem>> posts({
    required String npub,
    required List<String> relays,
    int limite = 20,
    int desdeMs = 0,
    int timeoutSecs = 8,
  }) =>
      rust.nostrPostsFetch(
        npub: npub,
        relays: relays,
        limite: limite,
        desdeMs: desdeMs,
        timeoutSecs: timeoutSecs,
      );

  /// Búsqueda de posts en TODA la red (NIP-50 sobre kind 1).
  Future<List<rust.PostItem>> buscarPosts({
    required String query,
    required List<String> relays,
    int limite = 25,
    int timeoutSecs = 8,
  }) =>
      rust.nostrBuscarPosts(
        query: query,
        relays: relays,
        limite: limite,
        timeoutSecs: timeoutSecs,
      );

  /// Relés del usuario (NIP-65 kind 10002 + fallback kind 3).
  Future<List<rust.RelayItem>> relays({
    required String npub,
    required List<String> relays,
    int timeoutSecs = 8,
  }) =>
      rust.nostrRelaysFetch(
        npub: npub,
        relays: relays,
        timeoutSecs: timeoutSecs,
      );

  /// Notificaciones: kind 1 dirigidos a mi npub (respuestas/menciones).
  Future<List<rust.PostItem>> notificaciones({
    required String miNpub,
    required List<String> relays,
    int limite = 30,
    int timeoutSecs = 8,
  }) =>
      rust.nostrNotificaciones(
        miNpub: miNpub,
        relays: relays,
        limite: limite,
        timeoutSecs: timeoutSecs,
      );
}
