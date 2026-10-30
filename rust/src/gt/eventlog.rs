//! Registro de eventos consultable desde la UI (equivalente a los
//! godot_print! de Gtool): cada paso del chat queda anotado y el host lo
//! drena con take_logs() para mostrarlo en pantalla.

use std::sync::{Arc, Mutex};

#[derive(Clone, Default)]
pub struct EventLog(Arc<Mutex<Vec<String>>>);

impl EventLog {
    pub fn new() -> Self {
        Self(Arc::new(Mutex::new(Vec::new())))
    }

    /// Anota un evento con timestamp local.
    pub fn push(&self, msg: impl AsRef<str>) {
        let ts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let (h, m, s) = ((ts / 3600) % 24, (ts / 60) % 60, ts % 60);
        if let Ok(mut v) = self.0.lock() {
            v.push(format!("[{h:02}:{m:02}:{s:02}] {}", msg.as_ref()));
            // tope duro para no crecer infinito
            if v.len() > 500 {
                let drop = v.len() - 500;
                v.drain(0..drop);
            }
        }
    }

    /// Drena los eventos pendientes (los saca de la cola).
    pub fn drain(&self) -> Vec<String> {
        match self.0.lock() {
            Ok(mut v) => std::mem::take(&mut *v),
            Err(_) => Vec::new(),
        }
    }
}
