# MPV App

App Flutter independiente con **MediaBlock** (moldes cifrados `.mld`) y
**reproductor multimedia** (media_kit/libmpv).

El Rust quedó reducido a lo pedido:

- `unarc` — compresión/descompresión ZIP, RAR, 7z, tar, gz…
- `nostrn` — cliente Nostr (cuenta, perfil, mensajes)
- `nostringer` — firmas de anillo
- `shamir` — secretos compartidos
- `pkarr` — claves, publicar y resolver

Fuera: Tor, candle, needle, WebGPU, iroh, torrents/rqbit, HF, Colab,
Laurelia y el resto del árbol viejo.

## Cifrado (portado tal cual, sin cambios de formato)

- **PRBX** (`lib/services/crypto_vault.dart`): envelope
  `"PRBX" | version | salt16 | nonce12 | ciphertext | tag16`,
  AES-256-GCM + PBKDF2-HMAC-SHA256 (200k iteraciones). Compatible con
  los `.prbx` viejos; incluye modo LOTE v2 (`PRBX(maestro, [LOTE][len][pass][datos])`).
- **ToolSec** (`lib/toolsec/`): API de alto nivel sobre PRBX (más el XOR
  legado solo para migrar blobs viejos) + diálogo *Cifrado PRBX* en la home.
- **app.db** (`lib/services/app_db.dart`): archivo completo cifrado con
  sqlite3mc **ChaCha20** (`PRAGMA cipher = 'chacha20'`).
- **MediaBlock**: moldes `.mld` cifrados; la previa AVIF es aparte.

## Builds (GitHub Actions, NO local)

Los binarios se generan en CI en dos etapas separadas:

1. **`rust-lib`** (manual, `workflow_dispatch`)
   - Android arm64 → `librust_lib_pr_app.so` + `libc++_shared.so`
   - Windows x64 → `rust_lib_pr_app.dll`
   - Regenera los bindings FRB y **commitea** todo
     (`rust_builder/android/src/main/jniLibs/`,
     `rust_builder/windows/prebuilt/`, `lib/src/rust/`,
     `rust/src/frb_generated.rs`).

2. **`build-app`** (manual, `workflow_dispatch`)
   - Con `RUST_PREBUILT=1` **no compila Rust**.
   - `flutter analyze` + `flutter build apk --release` (arm64)
   - `flutter build windows --release`
   - Sube los artefactos `pr_app-android` y `pr_app-windows`.

### Orden

```
Actions → rust-lib → (esperar el commit del bot) → build-app
```

Si `build-app` dice que falta un `.so`, `.dll` o los bindings, es porque
todavía no corrió `rust-lib` para ese cambio de `rust/`.
