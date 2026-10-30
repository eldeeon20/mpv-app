/// Port del Unarc de Gtool (unarc_godot.rs) sin Godot: extracción universal
/// de archives vía unarc-rs. Todo devuelve JSON strings (patrón torrent/).
///
/// Soporta: 7z, ZIP, RAR5, tar/gz/bz2/z, arj, lha, zoo, ha, hyp... y
/// multi-volumen (.7z.001/.002, .zip.001, .z01+.zip) con password opcional.
///
/// PARTES EXPLÍCITAS: cada función acepta `paths_csv` (rutas separadas por
/// \n). Si vienen varias se usan tal cual (el file_picker de Android copia
/// suelto al cache: los hermanos no están al lado); si viene una sola, se
/// intenta auto-detectar hermanos (.001/.002 o .z01+.zip) junto a ella.
use std::fs::File;
use std::io::{Read, Seek, Write};
use std::path::{Path, PathBuf};

use unarc_rs::unified::{
    is_supported_archive, ArchiveEntry, ArchiveFormat, ArchiveOptions, UnifiedArchive,
};

/// Opciones de apertura: password solo si no está vacía.
fn opciones(password: &str) -> ArchiveOptions {
    if password.is_empty() {
        ArchiveOptions::new()
    } else {
        ArchiveOptions::new().with_password(password)
    }
}

/// Número de parte para ordenar numéricamente: ".7z.002" → Some(2).
fn numero_de_parte(nombre: &str) -> Option<u32> {
    let ext = nombre.rsplit('.').next()?;
    ext.parse::<u32>().ok()
}

/// Ordena partes numéricamente cuando tienen sufijo numérico (.002 < .010);
/// si no, deja el orden dado.
fn ordenar_partes(mut vols: Vec<PathBuf>) -> Vec<PathBuf> {
    let todos_numericos = vols.iter().all(|p| numero_de_parte(&p.to_string_lossy()).is_some());
    if todos_numericos && vols.len() > 1 {
        vols.sort_by_key(|p| numero_de_parte(&p.to_string_lossy()).unwrap_or(0));
    }
    vols
}

/// Resuelve las partes desde el CSV de Dart:
/// - varias rutas → esas mismas, ordenadas numéricamente
/// - una ruta → intenta auto-detectar hermanos (.7z.001/.002, .zip.001,
///   split clásico .z01..zNN + .zip); si no hay, queda sola.
fn volumenes(paths_csv: &str) -> Vec<PathBuf> {
    let mut dadas: Vec<PathBuf> = paths_csv
        .split('\n')
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .collect();
    if dadas.len() > 1 {
        return ordenar_partes(dadas);
    }
    let Some(p) = dadas.pop() else {
        return Vec::new();
    };
    auto_detectar(&p)
}

/// Auto-detección de hermanos junto a [p] (comportamiento original).
fn auto_detectar(p: &Path) -> Vec<PathBuf> {
    let s = p.to_string_lossy().to_string();

    // foo.7z.001 / foo.zip.001 → foo.NNN consecutivos desde .001
    if let Some(pos) = s.rfind(".001") {
        let base = &s[..pos];
        let mut out = Vec::new();
        let mut i: u32 = 1;
        loop {
            let cand = format!("{base}.{i:03}");
            if Path::new(&cand).exists() {
                out.push(PathBuf::from(cand));
                i += 1;
            } else {
                break;
            }
        }
        if !out.is_empty() {
            return out;
        }
    }

    // split zip clásico: foo.z01..foo.zNN + foo.zip final
    if s.len() >= 4 && s[s.len() - 4..].to_lowercase() == ".zip" {
        let stem = &s[..s.len() - 4];
        let mut parts: Vec<PathBuf> = Vec::new();
        let mut i: u32 = 1;
        loop {
            let cand = format!("{stem}.z{i:02}");
            if Path::new(&cand).exists() {
                parts.push(PathBuf::from(cand));
                i += 1;
            } else {
                break;
            }
        }
        if !parts.is_empty() {
            parts.push(p.to_path_buf());
            return parts;
        }
    }

    vec![p.to_path_buf()]
}

/// true si los volúmenes corresponden a un split ZIP (no 7z).
fn es_split_zip(vols: &[PathBuf]) -> bool {
    match vols.first() {
        Some(p) => {
            let s = p.to_string_lossy().to_lowercase();
            s.ends_with("z01") || s.contains(".zip.")
        }
        None => false,
    }
}

/// Evita zip-slip: componentes vacíos, "." y ".." fuera; siempre relativa.
fn ruta_segura(base: &Path, nombre: &str) -> Option<PathBuf> {
    let norm = nombre.replace('\\', "/");
    let rel: PathBuf = norm
        .split('/')
        .filter(|c| !c.is_empty() && *c != "." && *c != "..")
        .collect();
    if rel.as_os_str().is_empty() {
        None
    } else {
        Some(base.join(rel))
    }
}

fn es_dir(nombre: &str) -> bool {
    nombre.ends_with('/') || nombre.ends_with('\\')
}

/// Abre (multi)volumen y corre [f]. [f] por nombre (fn genérica): cada rama
/// infiere su T así nunca nombramos BufReader<File> vs MultiVolumeReader.
macro_rules! con_archive {
    ($vols:expr, $password:expr, $f:path $(, $arg:expr)*) => {{
        // Acepta Vec<PathBuf> o &Vec<PathBuf>: normaliza a dueño clonando.
        let vols: Vec<PathBuf> = ($vols).clone();
        let opts = opciones($password);
        if vols.is_empty() {
            Err("sin partes para abrir".to_string())
        } else if vols.len() > 1 && es_split_zip(&vols) {
            match ArchiveFormat::open_multi_volume_zip(&vols, opts) {
                Ok(mut a) => $f(&mut a $(, $arg)*),
                Err(e) => Err(format!("multivolumen zip ({} partes): {e:?}", vols.len())),
            }
        } else if vols.len() > 1 {
            match ArchiveFormat::open_multi_volume_7z(&vols, opts) {
                Ok(mut a) => $f(&mut a $(, $arg)*),
                Err(e) => Err(format!("multivolumen 7z ({} partes): {e:?}", vols.len())),
            }
        } else {
            let p = &vols[0];
            match ArchiveFormat::open_path_with_options(p, opts) {
                Ok(mut a) => $f(&mut a $(, $arg)*),
                Err(e) => Err(format!("abrir {}: {e:?}", p.display())),
            }
        }
    }};
}

/// Info de partes detectadas/resueltas: {"total":N,"nombres":[...]}.
pub fn unarc_volumenes(paths_csv: String) -> Result<String, String> {
    let vols = volumenes(&paths_csv);
    serde_json::to_string(&serde_json::json!({
        "total": vols.len(),
        "nombres": vols.iter().map(|v| v.display().to_string()).collect::<Vec<_>>(),
    }))
    .map_err(|e| e.to_string())
}

/// Lista de entradas como JSON: [{name,size,isDir,encrypted}].
pub fn unarc_listar(paths_csv: String, password: String) -> Result<String, String> {
    let vols = volumenes(&paths_csv);
    if vols.is_empty() {
        return Err("sin rutas".to_string());
    }
    if !vols[0].exists() {
        return Err(format!("no existe: {}", vols[0].display()));
    }
    con_archive!(&vols, &password, listar)
}

fn listar<T: Read + Seek>(a: &mut UnifiedArchive<T>) -> Result<String, String> {
    let mut out = Vec::new();
    loop {
        match a.next_entry() {
            Ok(Some(entry)) => {
                let name = entry.name().to_string();
                out.push(serde_json::json!({
                    "name": name,
                    "size": entry.original_size(),
                    "isDir": es_dir(&name),
                    "encrypted": entry.is_encrypted(),
                }));
            }
            Ok(None) => break,
            Err(e) => return Err(format!("entrada: {e:?}")),
        }
    }
    serde_json::to_string(&out).map_err(|e| e.to_string())
}

/// Extrae TODO a output_dir. Devuelve JSON {"files","bytes","dir","partes"}.
pub fn unarc_extraer_todo(
    paths_csv: String,
    output_dir: String,
    password: String,
) -> Result<String, String> {
    let vols = volumenes(&paths_csv);
    if vols.is_empty() {
        return Err("sin rutas".to_string());
    }
    if !vols[0].exists() {
        return Err(format!("no existe: {}", vols[0].display()));
    }
    let n_partes = vols.len();
    let out_dir = PathBuf::from(&output_dir);
    std::fs::create_dir_all(&out_dir)
        .map_err(|e| format!("crear {}: {e:?}", out_dir.display()))?;
    let res = con_archive!(&vols, &password, extraer_todo, &out_dir, &password)?;
    serde_json::to_string(
        &serde_json::json!({"files": res.0, "bytes": res.1, "dir": output_dir, "partes": n_partes}),
    )
    .map_err(|e| e.to_string())
}

fn extraer_todo<T: Read + Seek>(
    a: &mut UnifiedArchive<T>,
    out_dir: &Path,
    password: &str,
) -> Result<(u32, u64), String> {
    let mut files: u32 = 0;
    let mut bytes: u64 = 0;
    loop {
        match a.next_entry() {
            Ok(Some(entry)) => {
                let name = entry.name().to_string();
                let target = match ruta_segura(out_dir, &name) {
                    Some(t) => t,
                    None => continue,
                };
                if es_dir(&name) {
                    std::fs::create_dir_all(&target)
                        .map_err(|e| format!("dir {}: {e:?}", target.display()))?;
                } else {
                    if let Some(parent) = target.parent() {
                        std::fs::create_dir_all(parent)
                            .map_err(|e| format!("padre {}: {e:?}", parent.display()))?;
                    }
                    let mut f = File::create(&target)
                        .map_err(|e| format!("crear {}: {e:?}", target.display()))?;
                    bytes += leer_a(a, &entry, &mut f, password)?;
                    files += 1;
                }
            }
            Ok(None) => break,
            Err(e) => return Err(format!("entrada: {e:?}")),
        }
    }
    Ok((files, bytes))
}

/// Lectura streaming con password; si read_to_with_options falla con password
/// (bug documentado en DIAGNOSTICO_MULTI_VOLUMEN.md), cae a memoria SOLO si
/// la entrada es chica (< 512 MB): nunca revientamos la RAM por sorpresa.
fn leer_a<T: Read + Seek, W: Write>(
    a: &mut UnifiedArchive<T>,
    entry: &ArchiveEntry,
    out: &mut W,
    password: &str,
) -> Result<u64, String> {
    if password.is_empty() {
        return a.read_to(entry, out).map_err(|e| format!("{e:?}"));
    }
    let opts = opciones(password);
    match a.read_to_with_options(entry, out, &opts) {
        Ok(n) => Ok(n),
        Err(e_stream) => {
            const TOPE_RAM: u64 = 512 * 1024 * 1024;
            let size = entry.original_size();
            if size > TOPE_RAM {
                return Err(format!(
                    "entrada '{}' de {} MB falla streaming con password ({e_stream:?}); \
                     límite del camino-en-RAM: 512 MB",
                    entry.name(),
                    size / (1024 * 1024)
                ));
            }
            let data = a
                .read_with_options(entry, &opts)
                .map_err(|e| format!("{e:?}"))?;
            out.write_all(&data).map_err(|e| e.to_string())?;
            Ok(data.len() as u64)
        }
    }
}

/// Extrae UNA entrada a dest_path (archivo destino completo).
/// Devuelve JSON {"bytes":N,"dest":"..."}.
pub fn unarc_extraer_entrada(
    paths_csv: String,
    entry_name: String,
    dest_path: String,
    password: String,
) -> Result<String, String> {
    let vols = volumenes(&paths_csv);
    if vols.is_empty() {
        return Err("sin rutas".to_string());
    }
    if !vols[0].exists() {
        return Err(format!("no existe: {}", vols[0].display()));
    }
    let dest = PathBuf::from(&dest_path);
    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("crear {}: {e:?}", parent.display()))?;
    }
    let bytes = con_archive!(
        &vols,
        &password,
        extraer_una,
        &entry_name,
        &dest,
        &password
    )?;
    serde_json::to_string(&serde_json::json!({"bytes": bytes, "dest": dest_path}))
        .map_err(|e| e.to_string())
}

fn extraer_una<T: Read + Seek>(
    a: &mut UnifiedArchive<T>,
    entry_name: &str,
    dest: &Path,
    password: &str,
) -> Result<u64, String> {
    loop {
        match a.next_entry() {
            Ok(Some(entry)) => {
                if entry.name() == entry_name {
                    let mut f = File::create(dest)
                        .map_err(|e| format!("crear {}: {e:?}", dest.display()))?;
                    return leer_a(a, &entry, &mut f, password);
                }
            }
            Ok(None) => return Err(format!("entrada no encontrada: {entry_name}")),
            Err(e) => return Err(format!("entrada: {e:?}")),
        }
    }
}

/// Lee una entrada a memoria para preview, cortada a max_bytes.
pub fn unarc_leer_entrada(
    paths_csv: String,
    entry_name: String,
    password: String,
    max_bytes: u32,
) -> Result<Vec<u8>, String> {
    let vols = volumenes(&paths_csv);
    if vols.is_empty() {
        return Err("sin rutas".to_string());
    }
    con_archive!(&vols, &password, leer, &entry_name, &password, max_bytes)
}

fn leer<T: Read + Seek>(
    a: &mut UnifiedArchive<T>,
    entry_name: &str,
    password: &str,
    max_bytes: u32,
) -> Result<Vec<u8>, String> {
    loop {
        match a.next_entry() {
            Ok(Some(entry)) => {
                if entry.name() == entry_name {
                    let mut data = if password.is_empty() {
                        a.read(&entry).map_err(|e| format!("{e:?}"))?
                    } else {
                        let opts = opciones(password);
                        a.read_with_options(&entry, &opts)
                            .map_err(|e| format!("{e:?}"))?
                    };
                    data.truncate(max_bytes as usize);
                    return Ok(data);
                }
            }
            Ok(None) => return Err(format!("entrada no encontrada: {entry_name}")),
            Err(e) => return Err(format!("entrada: {e:?}")),
        }
    }
}

/// true si alguna entrada pide password (o no se pudo abrir sin ella),
/// igual que is_archive_encrypted de Gtool.
pub fn unarc_encriptado(paths_csv: String) -> bool {
    let vols = volumenes(&paths_csv);
    if vols.is_empty() || !vols[0].exists() {
        return false;
    }
    con_archive!(&vols, "", encriptado).unwrap_or(true)
}

fn encriptado<T: Read + Seek>(a: &mut UnifiedArchive<T>) -> Result<bool, String> {
    loop {
        match a.next_entry() {
            Ok(Some(entry)) => {
                if entry.is_encrypted() {
                    return Ok(true);
                }
            }
            Ok(None) => break,
            Err(e) => return Err(format!("entrada: {e:?}")),
        }
    }
    Ok(false)
}

/// true si la extensión figura entre las soportadas por unarc-rs.
pub fn unarc_soportado(paths_csv: String) -> bool {
    let vols = volumenes(&paths_csv);
    match vols.first() {
        Some(p) => is_supported_archive(p),
        None => false,
    }
}

/// Nombre legible del formato detectado por extensión ('' si desconocido).
pub fn unarc_formato(paths_csv: String) -> Result<String, String> {
    let vols = volumenes(&paths_csv);
    Ok(match vols.first() {
        Some(p) => ArchiveFormat::from_path(p)
            .map(|f| f.name().to_string())
            .unwrap_or_default(),
        None => String::new(),
    })
}
