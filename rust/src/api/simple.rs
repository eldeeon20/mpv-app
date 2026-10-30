#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    // Default utilities - feel free to customize
    flutter_rust_bridge::setup_default_user_utils();

    // Igual que el gdextension de Gtool: en rustls 0.23, si en el árbol de
    // deps conviven aws-lc-rs y ring (pkarr + nostr-sdk), hay que instalar
    // el proveedor criptográfico explícitamente o TLS paniquea al primer uso.
    // Corre una sola vez, cuando Dart llama RustLib.init() (bootstrap).
    let _ = rustls::crypto::ring::default_provider().install_default();
}

/// Saluda a un nombre. Expuesto a Dart y llamable desde las páginas Lua.
#[flutter_rust_bridge::frb(sync)]
pub fn greet(name: String) -> String {
    format!("Hello, {name}!")
}

/// Suma dos enteros. Ejemplo de lógica de negocio en Rust.
#[flutter_rust_bridge::frb(sync)]
pub fn sum(a: i32, b: i32) -> i32 {
    a + b
}

/// Fibonacci iterativo (rápido). Ejemplo de cálculo pesado en Rust.
#[flutter_rust_bridge::frb(sync)]
pub fn fibonacci(n: u32) -> u32 {
    match n {
        0 => 0,
        1 => 1,
        _ => {
            let (mut a, mut b) = (0u32, 1u32);
            for _ in 2..=n {
                let next = a + b;
                a = b;
                b = next;
            }
            b
        }
    }
}