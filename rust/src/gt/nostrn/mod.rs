//! # NostrDM Sync - Cliente Nostr Síncrono
//! 
//! Esta biblioteca proporciona una interfaz síncrona para enviar y recibir mensajes
//! privados usando el protocolo Nostr (NIP-17).
//! 
//! A diferencia de la implementación original, esta versión:
//! - No usa threads ni channels
//! - Almacena la configuración del cliente para reutilización
//! - Proporciona una API síncrona simple
//! 
//! ## Ejemplo de uso
//! 
//! ```rust,no_run
//! use nostrdm_sync::NostrClient;
//! 
//! // Inicializar cliente una sola vez
//! let mut client = NostrClient::new(
//!     Some("nsec1...".to_string()),
//!     "npub1..."
//! )?;
//! 
//! // Configurar relays
//! client.add_relays(
//!     vec!["wss://relay.example.com".to_string()],
//!     None
//! )?;
//! 
//! // Suscribirse a mensajes
//! client.subscribe()?;
//! 
//! // Enviar mensaje
//! client.send_message("Hola!")?;
//! 
//! // Obtener mensajes nuevos
//! let messages = client.poll_messages()?;
//! for msg in messages {
//!     println!("Recibido: {}", msg.content);
//! }
//! ```

mod client;
pub mod gestion;
mod relays;

pub use gestion::{
    cargar_cuenta, crear_cuenta, guardar_cuenta, hay_cuenta, GestionNostrn, MsgIn,
};

pub use client::{NostrClient, ReceivedMessage};
