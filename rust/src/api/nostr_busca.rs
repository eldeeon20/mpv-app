/// Nostr Busca: perfiles y búsqueda de usuarios (B1 npub→kind 0,
/// B2 NIP-50 por texto). Wrapper FRB fino sobre `gt::nostrbusca`.
use crate::gt::nostrbusca::{
    buscar_posts, buscar_usuarios, notificaciones_fetch, perfil_fetch, posts_fetch, relays_fetch,
    Perfil,
};

/// Perfil de usuario Nostr serializable a Dart.
#[flutter_rust_bridge::frb]
#[derive(Clone)]
pub struct PerfilItem {
    pub npub: String,
    pub name: String,
    pub display_name: String,
    pub about: String,
    pub picture: String,
    pub nip05: String,
}

fn mapear(p: Perfil) -> PerfilItem {
    PerfilItem {
        npub: p.npub,
        name: p.name,
        display_name: p.display_name,
        about: p.about,
        picture: p.picture,
        nip05: p.nip05,
    }
}

fn a_relays(relays: Vec<String>) -> Vec<String> {
    if relays.is_empty() {
        vec![
            "wss://relay.damus.io".to_string(),
            "wss://nos.social".to_string(),
            "wss://relay.nostr.band".to_string(),
            "wss://search.nos.today".to_string(),
        ]
    } else {
        relays
    }
}

/// B1: perfil completo de un npub (bech32 o hex).
#[flutter_rust_bridge::frb]
pub fn nostr_perfil_fetch(
    npub: String,
    relays: Vec<String>,
    timeout_secs: i64,
) -> Result<PerfilItem, String> {
    perfil_fetch(
        &npub,
        &a_relays(relays),
        timeout_secs.max(1) as u64,
    )
    .map(mapear)
    .map_err(|e| format!("{e:#}"))
}

/// B2: búsqueda por texto (NIP-50; requiere relay que lo soporte).
/// Sin resultados = lista vacía.
#[flutter_rust_bridge::frb]
pub fn nostr_buscar_usuarios(
    query: String,
    relays: Vec<String>,
    limite: i64,
    timeout_secs: i64,
) -> Result<Vec<PerfilItem>, String> {
    buscar_usuarios(
        &query,
        &a_relays(relays),
        limite.max(1) as usize,
        timeout_secs.max(1) as u64,
    )
    .map(|v| v.into_iter().map(mapear).collect())
    .map_err(|e| format!("{e:#}"))
}

/// Publicación (nota kind 1) del muro de un npub.
#[flutter_rust_bridge::frb]
#[derive(Clone)]
pub struct PostItem {
    pub id_hex: String,
    pub autor_npub: String,
    pub contenido: String,
    pub fecha_ms: i64,
}

/// Muro de un npub: sus notas kind 1 ordenadas fecha ↓.
/// [desde_ms] 0 = sin límite de tiempo; otro valor = solo posteriores.
#[flutter_rust_bridge::frb]
pub fn nostr_posts_fetch(
    npub: String,
    relays: Vec<String>,
    limite: i64,
    desde_ms: i64,
    timeout_secs: i64,
) -> Result<Vec<PostItem>, String> {
    let desde = if desde_ms > 0 {
        Some((desde_ms / 1000).max(0) as u64)
    } else {
        None
    };
    posts_fetch(
        &npub,
        &a_relays(relays),
        limite.max(1) as usize,
        desde,
        timeout_secs.max(1) as u64,
    )
    .map(|v| {
        v.into_iter()
            .map(|p| PostItem {
                id_hex: p.id_hex,
                autor_npub: p.autor_npub,
                contenido: p.contenido,
                fecha_ms: p.fecha_ms as i64,
            })
            .collect()
    })
    .map_err(|e| format!("{e:#}"))
}

fn a_post(v: Vec<crate::gt::nostrbusca::Post>) -> Vec<PostItem> {
    v.into_iter()
        .map(|p| PostItem {
            id_hex: p.id_hex,
            autor_npub: p.autor_npub,
            contenido: p.contenido,
            fecha_ms: p.fecha_ms as i64,
        })
        .collect()
}

/// Búsqueda de posts en TODA la red (kind 1 vía NIP-50).
#[flutter_rust_bridge::frb]
pub fn nostr_buscar_posts(
    query: String,
    relays: Vec<String>,
    limite: i64,
    timeout_secs: i64,
) -> Result<Vec<PostItem>, String> {
    buscar_posts(
        &query,
        &a_relays(relays),
        limite.max(1) as usize,
        timeout_secs.max(1) as u64,
    )
    .map(a_post)
    .map_err(|e| format!("{e:#}"))
}

/// Lista de relays del usuario (NIP-65 kind 10002 + fallback NIP-02 kind 3).
#[flutter_rust_bridge::frb]
#[derive(Clone)]
pub struct RelayItem {
    pub url: String,
    pub lectura: bool,
    pub escritura: bool,
}

#[flutter_rust_bridge::frb]
pub fn nostr_relays_fetch(
    npub: String,
    relays: Vec<String>,
    timeout_secs: i64,
) -> Result<Vec<RelayItem>, String> {
    relays_fetch(
        &npub,
        &a_relays(relays),
        timeout_secs.max(1) as u64,
    )
    .map(|v| {
        v.into_iter()
            .map(|r| RelayItem {
                url: r.url,
                lectura: r.lectura,
                escritura: r.escritura,
            })
            .collect()
    })
    .map_err(|e| format!("{e:#}"))
}

/// Notificaciones: kind 1 dirigidos a mi npub (respuestas y menciones).
#[flutter_rust_bridge::frb]
pub fn nostr_notificaciones(
    mi_npub: String,
    relays: Vec<String>,
    limite: i64,
    timeout_secs: i64,
) -> Result<Vec<PostItem>, String> {
    notificaciones_fetch(
        &mi_npub,
        &a_relays(relays),
        limite.max(1) as usize,
        timeout_secs.max(1) as u64,
    )
    .map(a_post)
    .map_err(|e| format!("{e:#}"))
}
