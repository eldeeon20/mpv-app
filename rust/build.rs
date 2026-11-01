// Link contra libc++ compartida en Android.
//
// OJO: en un build script `#[cfg(target_os = "android")]` evalúa el HOST
// (el runner Linux), NO el target Android, así que la línea nunca se
// ejecutaba y la .so quedaba con `_ZTISt12length_error` sin resolver.
// Hay que mirar la variable que Cargo define para el target.
fn main() {
    println!("cargo:rerun-if-changed=build.rs");

    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("android") {
        // El .so usa símbolos de libc++ (_ZTISt12length_error, etc.) que
        // aporta el código C++ de unrar. Android no trae libc++ en el
        // sistema: hay que declararla en DT_NEEDED para que el loader la
        // cargue antes (libc++_shared.so va empaquetada en el APK).
        // --no-as-needed evita que el linker descarte la -l por no ver
        // referencias en ese punto de la línea de link.
        println!("cargo:rustc-link-arg=-Wl,--no-as-needed");
        println!("cargo:rustc-link-lib=dylib=c++_shared");
    }
}
