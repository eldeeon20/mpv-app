# NostrDM Sync - Implementación Síncrona

Esta carpeta contiene una implementación **síncrona** del cliente NostrDM que **NO usa threads ni channels**.

## Diferencias con la implementación original (`src/`)

| Característica | Original (`src/`) | Síncrono (`src_sync/`) |
|----------------|-------------------|------------------------|
| **Threads** | ✅ Usa thread para stdin | ❌ Sin threads |
| **Channels** | ✅ Usa mpsc channels | ❌ Sin channels |
| **API** | Async con tokio::select! | Síncrona con block_on() |
| **Configuración** | Se crea en cada ejecución | Se guarda en struct reutilizable |
| **Reconexión** | Cada vez que se ejecuta | Solo al inicializar |

## Estructura de archivos

```
src_sync/
├── lib.rs              # Módulo principal y exports
├── client.rs           # NostrClient - struct principal
├── keys.rs             # Gestión de claves (copiado de src/)
├── relays.rs           # Gestión de relays (copiado de src/)
├── example_usage.rs    # Ejemplo de uso
└── README.md           # Este archivo
```

## Uso básico

```rust
use nostrdm_sync::NostrClient;

// 1. Inicializar UNA sola vez
let mut client = NostrClient::new(
    Some("nsec1...".to_string()),
    "npub1..."
)?;

// 2. Configurar relays UNA sola vez
client.add_relays(
    vec!["wss://relay.damus.io".to_string()],
    None
)?;

// 3. Suscribirse
client.subscribe()?;

// 4. Enviar mensajes (reutiliza la conexión)
client.send_message("Hola!")?;

// 5. Recibir mensajes (polling sin bloquear)
let messages = client.poll_messages()?;
for msg in messages {
    println!("Recibido: {}", msg.content);
}
```

## Ventajas

✅ **Sin threads**: Más simple, menos overhead  
✅ **Sin channels**: Menos complejidad de sincronización  
✅ **Reutilizable**: El cliente se inicializa una vez  
✅ **Eficiente**: No reconecta a relays en cada operación  
✅ **API simple**: Métodos síncronos fáciles de usar  

## Notas técnicas

- Internamente usa `tokio::runtime::block_on()` para convertir operaciones async en síncronas
- El runtime de Tokio se crea una vez y se almacena en el struct
- `poll_messages()` usa `try_recv()` para no bloquear
- El cliente se desconecta automáticamente al hacer Drop

## Ejemplo completo

Ver `example_usage.rs` para un ejemplo completo con comentarios.
