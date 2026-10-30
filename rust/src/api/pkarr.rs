/// PKARR v8 (pubky/pkarr) — TXT firmado sobre Mainline DHT + relays HTTPS.
///
/// - pkarr "=8.0.0": publish devuelve StoredNodeCount; resolve exige
///   ResolvePolicy; el builder default ya es modo "both" (DHT+relays).
/// - La secret key se guarda CIFRADA en disco: AES-256-GCM con clave
///   derivada del PIN (PBKDF2-HMAC-SHA256). Lo publicado NUNCA va cifrado:
///   sale como TXT público firmado, como corresponde a pkarr.
use std::convert::TryInto;
use std::path::Path;
use std::str::FromStr;

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use pbkdf2::pbkdf2_hmac;
use pkarr::dns::rdata::TXT;
use pkarr::dns::Name;
use pkarr::{Keypair, ResolvePolicy, SignedPacket};
use sha2::{Digest, Sha256};

pub const DEFAULT_RELAYS: &[&str] =
    &["https://relay.pkarr.org", "https://pkarr.pubky.org"];

/// Formato del archivo de clave cifrada:
/// "PRPK1" || salt[16] || nonce[12] || ciphertext(secret 32)
const KEYFILE_MAGIC: &[u8; 5] = b"PRPK1";
const PBKDF2_ITERS: u32 = 200_000;

// ---------------------------------------------------------------- helpers

fn keypair_from_secret(secret: &[u8]) -> Result<Keypair, String> {
    if secret.len() != 32 {
        return Err(format!(
            "la clave debe tener 32 bytes y tiene {}",
            secret.len()
        ));
    }
    let mut arr = [0u8; 32];
    arr.copy_from_slice(secret);
    Ok(Keypair::from_secret_key(&arr))
}

fn build_client(mode: &str, relays: &[String]) -> Result<pkarr::Client, String> {
    let mut b = pkarr::Client::builder();
    match mode.to_lowercase().as_str() {
        "dht" => {
            b.no_relays();
        }
        "relays" => {
            b.no_dht();
            let list: Vec<&str> = if relays.is_empty() {
                DEFAULT_RELAYS.to_vec()
            } else {
                relays.iter().map(|s| s.as_str()).collect()
            };
            b.relays(&list).map_err(|e| format!("relay inválido: {e:?}"))?;
        }
        _ => {
            // both: DHT por defecto + relays custom encima de los defaults
            if !relays.is_empty() {
                let list: Vec<&str> = relays.iter().map(|s| s.as_str()).collect();
                b.relays(&list).map_err(|e| format!("relay inválido: {e:?}"))?;
            }
        }
    }
    b.build().map_err(|e| format!("cliente: {e:?}"))
}

// ------------------------------------------------------------ crypto PIN

fn keyfile_path(dir: &str) -> String {
    Path::new(dir).join("pkarr_key.bin").to_string_lossy().into_owned()
}

fn derive_pin_key(pin: &str, salt: &[u8]) -> [u8; 32] {
    let mut out = [0u8; 32];
    pbkdf2_hmac::<Sha256>(pin.as_bytes(), salt, PBKDF2_ITERS, &mut out);
    out
}

fn save_encrypted_secret(dir: &str, pin: &str, secret: &[u8; 32]) -> Result<(), String> {
    let path = keyfile_path(dir);
    let salt: [u8; 16] = rand::random();
    let nonce_bytes: [u8; 12] = rand::random();

    let cipher = Aes256Gcm::new_from_slice(&derive_pin_key(pin, &salt)[..])
        .map_err(|e| format!("AES init: {e:?}"))?;
    let ct = cipher
        .encrypt(Nonce::from_slice(&nonce_bytes), secret.as_ref())
        .map_err(|e| format!("AES encrypt: {e:?}"))?;

    let mut blob = Vec::with_capacity(33 + ct.len());
    blob.extend_from_slice(KEYFILE_MAGIC);
    blob.extend_from_slice(&salt);
    blob.extend_from_slice(&nonce_bytes);
    blob.extend_from_slice(&ct);
    std::fs::write(&path, blob).map_err(|e| format!("escribiendo {}: {e}", path))
}

fn load_encrypted_secret(dir: &str, pin: &str) -> Result<[u8; 32], String> {
    let path = keyfile_path(dir);
    let blob = std::fs::read(&path).map_err(|_| format!("no hay clave guardada en {}", path))?;
    if blob.len() < 65 || &blob[..5] != KEYFILE_MAGIC {
        return Err("archivo de clave corrupto o de otra versión".into());
    }
    let nonce = Nonce::from_slice(&blob[21..33]);
    let cipher =
        Aes256Gcm::new_from_slice(&derive_pin_key(pin, &blob[5..21])[..])
            .map_err(|e| format!("AES init: {e:?}"))?;
    // PIN incorrecto → falla la autenticación GCM acá
    let pt = cipher
        .decrypt(nonce, &blob[33..])
        .map_err(|_| "PIN incorrecto".to_string())?;
    let mut secret = [0u8; 32];
    secret.copy_from_slice(&pt);
    Ok(secret)
}

// ------------------------------------------------------------- API sync

#[flutter_rust_bridge::frb]
pub fn pkarr_key_rand() -> Vec<u8> {
    Keypair::random().secret_key().to_vec()
}

/// Secreto determinístico desde una semilla textual (SHA256 → 32 bytes).
#[flutter_rust_bridge::frb]
pub fn pkarr_seed_to_key(seed: String) -> Vec<u8> {
    let mut h = Sha256::new();
    h.update(seed.as_bytes());
    h.finalize().to_vec()
}

/// Clave pública zbase32 a partir del secreto. Vacío si es inválido.
#[flutter_rust_bridge::frb]
pub fn pkarr_public_key(secret: Vec<u8>) -> String {
    match keypair_from_secret(&secret) {
        Ok(kp) => kp.public_key().to_string(),
        Err(_) => String::new(),
    }
}

/// ¿Hay una clave cifrada guardada?
#[flutter_rust_bridge::frb]
pub fn pkarr_has_saved_key(dir: String) -> bool {
    Path::new(&keyfile_path(&dir)).exists()
}

/// Identidad completa para mostrar en pantalla: pub (compartir) y
/// secreto hex 64 chars (NUNCA compartir).
#[flutter_rust_bridge::frb]
#[derive(Clone)]
pub struct PkarrIdentidad {
    pub pubkey: String,
    pub secreto: String,
}

fn hex32(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Genera identidad nueva, la guarda CIFRADA con el PIN y devuelve
/// pubkey + secreto.
#[flutter_rust_bridge::frb]
pub fn pkarr_generate_encrypted(pin: String, dir: String) -> Result<PkarrIdentidad, String> {
    let kp = Keypair::random();
    let s = kp.secret_key().to_vec();
    let mut secret = [0u8; 32];
    secret.copy_from_slice(&s);
    save_encrypted_secret(&dir, &pin, &secret)?;
    Ok(PkarrIdentidad {
        pubkey: kp.public_key().to_string(),
        secreto: hex32(&secret),
    })
}

/// Descifra la clave guardada con ese PIN; devuelve pubkey + secreto.
#[flutter_rust_bridge::frb]
pub fn pkarr_load_encrypted(pin: String, dir: String) -> Result<PkarrIdentidad, String> {
    let secret = load_encrypted_secret(&dir, &pin)?;
    let kp = keypair_from_secret(&secret)?;
    Ok(PkarrIdentidad {
        pubkey: kp.public_key().to_string(),
        secreto: hex32(&secret),
    })
}

// ------------------------------------------------------------ API async

/// Firma un TXT (`name`=`value`) con la clave guardada (PIN) y publica.
/// mode: "both" (default) | "dht" | "relays".
#[flutter_rust_bridge::frb]
pub async fn pkarr_publish(
    pin: String,
    dir: String,
    name: String,
    value: String,
    ttl: u32,
    mode: String,
    relays: Vec<String>,
) -> Result<String, String> {
    let keypair = keypair_from_secret(&load_encrypted_secret(&dir, &pin)?)?;
    let converted: Name<'_> = name
        .as_str()
        .try_into()
        .map_err(|e| format!("nombre inválido '{name}': {e:?}"))?;
    let txt = TXT::try_from(value.as_str())
        .map_err(|e| format!("valor TXT inválido: {e:?}"))?;

    let packet = SignedPacket::builder()
        .txt(converted, txt, ttl)
        .sign(&keypair)
        .map_err(|e| format!("al firmar: {e:?}"))?;

    let client = build_client(&mode, &relays)?;
    match client.publish(&packet).await {
        Ok(count) => Ok(format!(
            "publicado {} · confirmado por {:?} nodo(s)",
            keypair.public_key(),
            count
        )),
        Err(err) => Err(format!(
            "falló la publicación de {}: {err}",
            keypair.public_key()
        )),
    }
}

/// Resuelve un pubkey zbase32 de TERCEROS y devuelve los registros del
/// paquete como líneas legibles (nombre · ttl · tipo/valor).
/// policy: "network_only" (default, más preciso) | "cache_first" | "cache_only".
#[flutter_rust_bridge::frb]
pub async fn pkarr_resolve(
    pubkey_zbase32: String,
    mode: String,
    relays: Vec<String>,
    policy: String,
) -> Result<Vec<String>, String> {
    let public_key: pkarr::PublicKey = pubkey_zbase32
        .as_str()
        .try_into()
        .map_err(|_| format!("clave zbase32 inválida: {pubkey_zbase32}"))?;

    let pol = ResolvePolicy::from_str(&policy.to_lowercase())
        .unwrap_or(ResolvePolicy::NetworkOnly);

    let client = build_client(&mode, &relays)?;
    let packet = client
        .resolve(&public_key, pol)
        .await
        .map_err(|e| format!("sin resolución para {}: {e}", pubkey_zbase32))?;

    let mut out = vec![format!(
        "paquete de {} · timestamp {:?}",
        public_key, packet.timestamp()
    )];
    for rr in packet.all_resource_records() {
        out.push(format!("{} · ttl {} · {:?}", rr.name, rr.ttl, rr.rdata));
    }
    Ok(out)
}
