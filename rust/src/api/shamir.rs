/// Shamir secret sharing — portado de Gtool `shamir_godot.rs` sin Godot.
/// Divide datos en N partes (se necesitan `threshold` para reconstruir).
use shamirsecretsharing::*;

/// Divide `data` en `count` partes; con `threshold` se reconstruye.
/// Error si los parámetros no son válidos (1 <= threshold <= count <= 255).
#[flutter_rust_bridge::frb]
pub fn shamir_split(
    data: Vec<u8>,
    count: i64,
    threshold: i64,
) -> Result<Vec<Vec<u8>>, String> {
    if !(1..=255).contains(&count) || !(1..=255).contains(&threshold) {
        return Err("count y threshold deben estar entre 1 y 255".into());
    }
    if threshold > count {
        return Err("threshold no puede ser mayor que count".into());
    }
    create_shares(&data, count as u8, threshold as u8)
        .map_err(|e| format!("shamir_split error: {e:?}"))
}

/// Reconstruye los datos a partir de >= threshold partes.
/// None = secreto perdido (partes insuficientes o corruptas).
#[flutter_rust_bridge::frb]
pub fn shamir_combine(shares: Vec<Vec<u8>>) -> Option<Vec<u8>> {
    combine_shares(&shares).unwrap_or(None)
}
