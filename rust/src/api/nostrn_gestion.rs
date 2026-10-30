/// Nostrn+ (GestionNostrn): cuentas con PIN, perfil kind 0, bandeja sin
/// peer y chat NIP-17. Wrapper FRB fino sobre `gt::nostrn::gestion`.
use anyhow::{anyhow, Result};
use nostr_sdk::ToBech32;

use crate::gt::nostrn::gestion as g;
use crate::gt::nostrn::GestionNostrn;

/// Cuenta guardada/cargada desde Dart.
#[flutter_rust_bridge::frb]
pub struct GestionCuenta {
    pub nombre: String,
    pub npub: String,
    pub nsec: String,
}

/// Entrada de la bandeja: mensaje de CUALQUIER remitente dirigido a mí.
#[flutter_rust_bridge::frb]
pub struct BandejaItem {
    pub sender_npub: String,
    pub content: String,
    pub timestamp_ms: i64,
}

/// Perfil kind 0 (propio o de tercero).
#[flutter_rust_bridge::frb]
pub struct PerfilNostrn {
    pub name: String,
    pub display_name: String,
    pub about: String,
    pub picture: String,
}

#[flutter_rust_bridge::frb(opaque)]
pub struct GestionViva {
    inner: GestionNostrn,
}

impl GestionViva {
    /// Relays DM (+ lectura opcional). Requiere al menos un DM relay.
    pub fn add_relays(&mut self, dm_relays: Vec<String>, read_relays: Vec<String>) -> Result<()> {
        let read = if read_relays.is_empty() { None } else { Some(read_relays) };
        self.inner
            .add_relays(dm_relays, read)
            .map_err(|e| anyhow!("relays: {e:#}"))
    }

    /// Ventana (segundos atrás; 0 = SIN límite de tiempo) y tope, luego
    /// suscribe la bandeja.
    pub fn subscribe(&mut self, n_seconds: i64, n_limit: i64) -> Result<()> {
        self.inner.n_seconds = n_seconds.max(0) as u64;
        self.inner.n_limit = n_limit.max(1) as usize;
        self.inner
            .subscribe()
            .map_err(|e| anyhow!("subscribe: {e:#}"))
    }

    /// Fija el peer del chat (bech32 o hex).
    pub fn set_peer(&mut self, npub: String) -> Result<()> {
        self.inner.set_peer(&npub).map_err(|e| anyhow!("{e:#}"))
    }

    /// Peer actual ('' si no hay).
    pub fn get_peer(&self) -> String {
        self.inner.get_peer().unwrap_or_default()
    }

    /// Mi npub.
    pub fn public_key(&self) -> Result<String> {
        self.inner.get_public_key().map_err(|e| anyhow!("{e:#}"))
    }

    /// Envía al peer fijado (NIP-17).
    pub fn send(&self, content: String) -> Result<()> {
        self.inner.send_message(&content).map_err(|e| anyhow!("enviar: {e:#}"))
    }

    /// Drena la bandeja (mensajes de cualquier remitente).
    pub fn poll_bandeja(&self) -> Result<Vec<BandejaItem>> {
        let msgs = self
            .inner
            .poll_messages()
            .map_err(|e| anyhow!("poll: {e:#}"))?;
        Ok(msgs
            .into_iter()
            .map(|m| BandejaItem {
                sender_npub: m.sender.to_bech32().unwrap_or_else(|_| m.sender.to_string()),
                content: m.content,
                timestamp_ms: m.timestamp.as_u64() as i64 * 1000,
            })
            .collect())
    }

    /// Publica MI perfil kind 0. Campos vacíos no se modifican.
    pub fn set_perfil(
        &self,
        name: String,
        display_name: String,
        about: String,
        picture: String,
    ) -> Result<()> {
        self.inner
            .set_perfil(&name, &display_name, &about, &picture)
            .map_err(|e| anyhow!("{e:#}"))
    }

    /// Registro de eventos para la UI.
    pub fn take_logs(&mut self) -> Vec<String> {
        self.inner.take_logs()
    }

    /// Cierra suscripción y relays.
    pub fn disconnect(&mut self) -> Result<()> {
        self.inner.disconnect().map_err(|e| anyhow!("{e:#}"))
    }
}

/// Constructor del cliente vivo. nsec vacío = identidad efímera nueva.
#[flutter_rust_bridge::frb]
pub fn gestion_new(nsec: Option<String>) -> Result<GestionViva> {
    Ok(GestionViva {
        inner: GestionNostrn::new(nsec.as_deref())
            .map_err(|e| anyhow!("init gestión: {e:#}"))?,
    })
}

/// Crea identidad nueva y la guarda (PIN vacío = plano).
#[flutter_rust_bridge::frb]
pub fn gestion_crear_cuenta(pin: String, dir: String, nombre: String) -> Result<GestionCuenta> {
    let c = g::crear_cuenta(&pin, &dir, &nombre).map_err(|e| anyhow!("{e:#}"))?;
    Ok(GestionCuenta { nombre: c.nombre, npub: c.npub, nsec: c.nsec })
}

/// Guarda una identidad existente bajo ese PIN.
#[flutter_rust_bridge::frb]
pub fn gestion_guardar_cuenta(
    pin: String,
    dir: String,
    nombre: String,
    nsec: String,
) -> Result<GestionCuenta> {
    // Normalizamos a partir del nsec para que npub SIEMPRE coincida.
    let keys = nostr_sdk::Keys::parse(nsec.trim()).map_err(|e| anyhow!("nsec inválido: {e:?}"))?;
    let c = g::CuentaGuardada {
        nombre,
        npub: keys.public_key().to_bech32()?,
        nsec: keys.secret_key().to_bech32()?,
    };
    g::guardar_cuenta(&pin, &dir, &c).map_err(|e| anyhow!("{e:#}"))?;
    Ok(GestionCuenta { nombre: c.nombre, npub: c.npub, nsec: c.nsec })
}

/// Carga la cuenta guardada con ese PIN.
#[flutter_rust_bridge::frb]
pub fn gestion_cargar_cuenta(pin: String, dir: String) -> Result<GestionCuenta> {
    let c = g::cargar_cuenta(&pin, &dir).map_err(|e| anyhow!("{e:#}"))?;
    Ok(GestionCuenta { nombre: c.nombre, npub: c.npub, nsec: c.nsec })
}

/// ¿Hay cuenta guardada en [dir]?
#[flutter_rust_bridge::frb]
pub fn gestion_hay_cuenta(dir: String) -> bool {
    g::hay_cuenta(&dir)
}

/// Trae el perfil kind 0 más reciente de un npub (read-only efímero).
#[flutter_rust_bridge::frb]
pub async fn gestion_perfil_get(
    npub: String,
    relays: Vec<String>,
    timeout_secs: i64,
) -> Result<PerfilNostrn> {
    let p = crate::gt::nostrbusca::perfil_fetch(
        &npub,
        &relays,
        timeout_secs.max(1) as u64,
    )
    .map_err(|e| anyhow!("perfil: {e:#}"))?;
    Ok(PerfilNostrn {
        name: p.name,
        display_name: p.display_name,
        about: p.about,
        picture: p.picture,
    })
}

// ------------------------------------------------- social (escritura)

impl GestionViva {
    /// Publica una nota kind 1. Devuelve id hex.
    pub fn postear(&self, texto: String) -> Result<String> {
        self.inner.postear(&texto).map_err(|e| anyhow!("{e:#}"))
    }

    /// Responde un evento (tags e+p). Devuelve id hex de tu respuesta.
    pub fn responder(&self, texto: String, id_evento: String, autor: String) -> Result<String> {
        self.inner
            .responder(&texto, &id_evento, &autor)
            .map_err(|e| anyhow!("{e:#}"))
    }

    /// Cita un evento (tu texto + bloque citado + tags).
    pub fn citar(
        &self,
        texto: String,
        id_evento: String,
        autor: String,
        texto_citado: String,
    ) -> Result<String> {
        self.inner
            .citar(&texto, &id_evento, &autor, &texto_citado)
            .map_err(|e| anyhow!("{e:#}"))
    }

    /// Reacción "+" (NIP-25).
    pub fn reaccionar(&self, id_evento: String, autor: String) -> Result<String> {
        self.inner
            .reaccionar(&id_evento, &autor)
            .map_err(|e| anyhow!("{e:#}"))
    }

    /// Repost (NIP-18).
    pub fn repost(&self, id_evento: String, autor: String) -> Result<String> {
        self.inner.repost(&id_evento, &autor).map_err(|e| anyhow!("{e:#}"))
    }

    /// Mi lista de seguidos (kind 3 más reciente, npubs bech32).
    pub fn seguidos(&self) -> Result<Vec<String>> {
        self.inner.seguidos().map_err(|e| anyhow!("{e:#}"))
    }

    /// Sigue o deja de seguir un npub; devuelve la lista actualizada.
    pub fn seguir(&self, npub: String, seguir: bool) -> Result<Vec<String>> {
        self.inner.seguir(&npub, seguir).map_err(|e| anyhow!("{e:#}"))
    }

    /// Publica artículo largo NIP-23 (kind 30023).
    pub fn articulo_publicar(
        &self,
        titulo: String,
        resumen: String,
        imagen_url: String,
        cuerpo: String,
    ) -> Result<String> {
        self.inner
            .articulo_publicar(&titulo, &resumen, &imagen_url, &cuerpo)
            .map_err(|e| anyhow!("{e:#}"))
    }
}
