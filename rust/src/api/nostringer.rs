/// Nostringer — firmas de anillo BLSAG/SAG (anonimato dentro de un grupo).
///
/// Portado de Gtool `nostringer_godot.rs` sin Godot. Firmás un mensaje
/// como miembro del ring sin revelar CUÁL clave es la tuya; la key image
/// evita doble-gasto/firmas duplicadas de la misma identidad.
use nostringer::blsag::{key_images_match, sign_blsag_hex, verify_blsag_hex};
use nostringer::types::{BlsagSignature, BlsagSignatureBinary, KeyImage};
use nostringer::{sign, verify, SignatureVariant};

/// Par de claves hex para firmar en anillo.
#[flutter_rust_bridge::frb]
pub struct RingKeypair {
    pub public_key: String,
    pub private_key: String,
}

/// Firma producida. Para BLSAG incluye key image y firma compacta
/// ("ringA..." base64-url); para SAG solo signature.
#[flutter_rust_bridge::frb]
pub struct RingSignature {
    pub signature: String,
    pub key_image: String,
}

#[flutter_rust_bridge::frb]
pub struct RingVerifyResult {
    pub valid: bool,
    pub key_image: String,
}

/// Genera par de claves. variant: "blsag" | "sag".
#[flutter_rust_bridge::frb]
pub fn ring_generate_keypair(variant: String) -> RingKeypair {
    let kp = nostringer::generate_keypair_hex(&variant);
    RingKeypair {
        public_key: kp.public_key_hex,
        private_key: kp.private_key_hex,
    }
}

/// Firma `message` como miembro del ring. variant: "blsag" | "sag".
/// El ring DEBE incluir la pública correspondiente a private_key.
#[flutter_rust_bridge::frb]
pub fn ring_sign(
    message: Vec<u8>,
    private_key: String,
    ring: Vec<String>,
    variant: String,
) -> Result<RingSignature, String> {
    if variant.to_lowercase() == "blsag" {
        match sign_blsag_hex(&message, &private_key, &ring) {
            Ok((sig, ki)) => {
                // Serialización compacta (mismo formato que usa verify_bin)
                let binary =
                    BlsagSignatureBinary::try_from(&sig).map_err(|e| format!("{e:?}"))?;
                let ki_point = KeyImage::from_hex(&ki).map_err(|e| format!("{e:?}"))?;
                let compact = nostringer::serialization::CompactSignature::Blsag(
                    binary, ki_point,
                );
                let sig_str = compact.serialize().map_err(|e| format!("{e:?}"))?;
                Ok(RingSignature {
                    signature: sig_str,
                    key_image: ki,
                })
            }
            Err(e) => Err(format!("ring_sign BLSAG error: {e:?}")),
        }
    } else {
        match sign(&message, &private_key, &ring, SignatureVariant::Sag) {
            Ok(sig_str) => Ok(RingSignature {
                signature: sig_str,
                key_image: String::new(),
            }),
            Err(e) => Err(format!("ring_sign SAG error: {e:?}")),
        }
    }
}

/// Verifica una firma contra el ring. Si es BLSAG válida devuelve la key image.
#[flutter_rust_bridge::frb]
pub fn ring_verify(
    signature: String,
    message: Vec<u8>,
    ring: Vec<String>,
) -> RingVerifyResult {
    match verify(&signature, &message, &ring) {
        Ok(valid) => {
            let mut ki = String::new();
            if valid {
                if let Ok(nostringer::serialization::CompactSignature::Blsag(_, k)) =
                    nostringer::serialization::CompactSignature::deserialize(&signature)
                {
                    ki = k.to_hex();
                }
            }
            RingVerifyResult {
                valid,
                key_image: ki,
            }
        }
        Err(_) => RingVerifyResult {
            valid: false,
            key_image: String::new(),
        },
    }
}

/// Verificación estricta BLSAG con key image explícita.
#[flutter_rust_bridge::frb]
pub fn ring_verify_blsag(
    signature: String,
    key_image: String,
    message: Vec<u8>,
    ring: Vec<String>,
) -> bool {
    let Ok(nostringer::serialization::CompactSignature::Blsag(binary_sig, _)) =
        nostringer::serialization::CompactSignature::deserialize(&signature)
    else {
        return false;
    };
    let sig_variant = BlsagSignature::from(&binary_sig);
    verify_blsag_hex(&sig_variant, &key_image, &message, &ring).unwrap_or(false)
}

/// true si dos key images son la misma identidad (detecta re-firmante).
#[flutter_rust_bridge::frb]
pub fn ring_key_images_match(ki1: String, ki2: String) -> bool {
    match (KeyImage::from_hex(&ki1), KeyImage::from_hex(&ki2)) {
        (Ok(a), Ok(b)) => key_images_match(&a, &b),
        _ => false,
    }
}
