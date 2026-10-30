/// Cliente HuggingFace — portado de Gtool `hf_godot.rs` sin Godot.
///
/// Subir/bajar archivos, crear/borrar repos, buscar modelos y rangos HTTP.
/// Patrón Gtool: match inline por tipo de repo en cada método (los tipos
/// HFRepositorySync<RepoTypeX> son genéricos y no se pueden unificar).
use std::path::PathBuf;

use hf_hub::repository::AddSource;
use hf_hub::{HFClientBuilder, HFClientSync, RepoTypeDataset, RepoTypeModel, RepoTypeSpace};

#[flutter_rust_bridge::frb(opaque)]
pub struct HfClient {
    client: Option<HFClientSync>,
}

fn split_repo(repo_id: &str) -> (String, String) {
    let parts: Vec<&str> = repo_id.split('/').collect();
    if parts.len() == 2 {
        (parts[0].to_string(), parts[1].to_string())
    } else {
        (String::new(), repo_id.to_string())
    }
}

/// Xet (uploads/descargas de hf-hub) necesita caché ESCRIBIBLE. En
/// Android HOME no existe y termina intentando "/" → "Read-only file
/// system (os error 30)". Dart pasa el dir de soporte de la app y acá
/// se exporta como HF_XET_CACHE (+ HOME de respaldo, también ausente).
fn asegurar_cache_xet(cache_dir: &str) {
    let d = cache_dir.trim();
    if d.is_empty() {
        return;
    }
    let _ = std::fs::create_dir_all(d);
    std::env::set_var("HF_XET_CACHE", d);
    if std::env::var_os("HOME").is_none() {
        std::env::set_var("HOME", d);
    }
}

/// Constructor libre (el codegen expone las clases opacas como abstractas).
/// Token de acceso HF vacío = anónimo, solo lectura pública.
#[flutter_rust_bridge::frb]
pub fn hf_client_new(token: String) -> Result<HfClient, String> {
    let mut b = HFClientBuilder::new();
    if !token.is_empty() {
        b = b.token(token);
    }
    let client = b.build_sync().map_err(|e| format!("HF client error: {e:?}"))?;
    Ok(HfClient { client: Some(client) })
}

impl HfClient {
    fn require(&self) -> Result<HFClientSync, String> {
        self.client
            .clone()
            .ok_or_else(|| "HfClient no inicializado".to_string())
    }

    /// Sube un archivo local al repo (requiere token con permiso write).
    pub fn upload_file(
        &self,
        repo_id: String,
        local_file_path: String,
        path_in_repo: String,
        commit_message: String,
        repo_type: String,
        cache_dir: String,
    ) -> Result<(), String> {
        asegurar_cache_xet(&cache_dir);
        let client = self.require()?;
        let (namespace, name) = split_repo(&repo_id);
        let bytes = std::fs::read(&local_file_path)
            .map_err(|e| format!("no se pudo leer {local_file_path}: {e:?}"))?;

        match repo_type.to_lowercase().as_str() {
            "dataset" => client
                .dataset(&namespace, &name)
                .upload_file()
                .source(AddSource::bytes(bytes))
                .path_in_repo(path_in_repo)
                .commit_message(commit_message)
                .send(),
            "space" => client
                .space(&namespace, &name)
                .upload_file()
                .source(AddSource::bytes(bytes))
                .path_in_repo(path_in_repo)
                .commit_message(commit_message)
                .send(),
            _ => client
                .model(&namespace, &name)
                .upload_file()
                .source(AddSource::bytes(bytes))
                .path_in_repo(path_in_repo)
                .commit_message(commit_message)
                .send(),
        }
        .map(|_| ())
        .map_err(|e| format!("upload falló ({repo_id}): {e:?}"))
    }

    /// Descarga un archivo del repo a local_dir; retorna el path final.
    pub fn download_file(
        &self,
        repo_id: String,
        filename: String,
        local_dir: String,
        repo_type: String,
        cache_dir: String,
    ) -> Result<String, String> {
        asegurar_cache_xet(&cache_dir);
        let client = self.require()?;
        let (namespace, name) = split_repo(&repo_id);
        let dir = PathBuf::from(local_dir);

        let err_ctx = format!("{repo_id}/{filename}");
        let path = match repo_type.to_lowercase().as_str() {
            "dataset" => client
                .dataset(&namespace, &name)
                .download_file()
                .filename(filename)
                .local_dir(dir)
                .send(),
            "space" => client
                .space(&namespace, &name)
                .download_file()
                .filename(filename)
                .local_dir(dir)
                .send(),
            _ => client
                .model(&namespace, &name)
                .download_file()
                .filename(filename)
                .local_dir(dir)
                .send(),
        }
        .map_err(|e| format!("download falló ({err_ctx}): {e:?}"))?;

        Ok(path.to_string_lossy().to_string())
    }

    /// Borra un archivo del repo.
    pub fn delete_file(
        &self,
        repo_id: String,
        path_in_repo: String,
        repo_type: String,
    ) -> Result<(), String> {
        let client = self.require()?;
        let (namespace, name) = split_repo(&repo_id);

        match repo_type.to_lowercase().as_str() {
            "dataset" => client
                .dataset(&namespace, &name)
                .delete_file()
                .path_in_repo(path_in_repo)
                .send(),
            "space" => client
                .space(&namespace, &name)
                .delete_file()
                .path_in_repo(path_in_repo)
                .send(),
            _ => client
                .model(&namespace, &name)
                .delete_file()
                .path_in_repo(path_in_repo)
                .send(),
        }
        .map(|_| ())
        .map_err(|e| format!("delete_file falló ({repo_id}): {e:?}"))
    }

    /// Borra un repositorio entero (peligroso). missing_ok: no falla si no existe.
    pub fn delete_repository(&self, repo_id: String, repo_type: String) -> Result<(), String> {
        let client = self.require()?;
        let res = match repo_type.to_lowercase().as_str() {
            "dataset" => client
                .delete_repository()
                .repo_type(RepoTypeDataset)
                .repo_id(repo_id.clone())
                .missing_ok(true)
                .send(),
            "space" => client
                .delete_repository()
                .repo_type(RepoTypeSpace)
                .repo_id(repo_id.clone())
                .missing_ok(true)
                .send(),
            _ => client
                .delete_repository()
                .repo_type(RepoTypeModel)
                .repo_id(repo_id.clone())
                .missing_ok(true)
                .send(),
        };
        res.map(|_| ())
            .map_err(|e| format!("delete_repository falló ({repo_id}): {e:?}"))
    }

    /// Crea un repositorio (exist_ok: no falla si ya existe).
    pub fn create_repository(
        &self,
        repo_id: String,
        repo_type: String,
        private: bool,
    ) -> Result<(), String> {
        let client = self.require()?;
        let res = match repo_type.to_lowercase().as_str() {
            "dataset" => client
                .create_repository()
                .repo_type(RepoTypeDataset)
                .repo_id(repo_id.clone())
                .private(private)
                .exist_ok(true)
                .send(),
            "space" => client
                .create_repository()
                .repo_type(RepoTypeSpace)
                .repo_id(repo_id.clone())
                .private(private)
                .exist_ok(true)
                .send(),
            _ => client
                .create_repository()
                .repo_type(RepoTypeModel)
                .repo_id(repo_id.clone())
                .private(private)
                .exist_ok(true)
                .send(),
        };
        res.map(|_| ())
            .map_err(|e| format!("create_repository falló ({repo_id}): {e:?}"))
    }

    /// Busca modelos de un autor → ids ("autor/modelo").
    pub fn search_models(&self, author: String, limit: i64) -> Result<Vec<String>, String> {
        let client = self.require()?;
        let models = client
            .list_models()
            .author(author)
            .limit(limit.clamp(1, 100) as usize)
            .send()
            .map_err(|e| format!("search_models falló: {e:?}"))?;
        Ok(models.into_iter().map(|m| m.id).collect())
    }

    /// ¿Existe el repo?
    pub fn repo_exists(&self, repo_id: String, repo_type: String) -> bool {
        let Ok(client) = self.require() else { return false };
        let (namespace, name) = split_repo(&repo_id);
        let res = match repo_type.to_lowercase().as_str() {
            "dataset" => client.dataset(&namespace, &name).exists().send(),
            "space" => client.space(&namespace, &name).exists().send(),
            _ => client.model(&namespace, &name).exists().send(),
        };
        res.unwrap_or(false)
    }

    /// ¿Existe un archivo dentro del repo?
    pub fn file_exists(&self, repo_id: String, filename: String, repo_type: String) -> bool {
        let Ok(client) = self.require() else { return false };
        let (namespace, name) = split_repo(&repo_id);
        let res = match repo_type.to_lowercase().as_str() {
            "dataset" => client
                .dataset(&namespace, &name)
                .file_exists()
                .filename(filename)
                .send(),
            "space" => client
                .space(&namespace, &name)
                .file_exists()
                .filename(filename)
                .send(),
            _ => client
                .model(&namespace, &name)
                .file_exists()
                .filename(filename)
                .send(),
        };
        res.unwrap_or(false)
    }

    /// Lista archivos del repo (recursive opcional).
    pub fn list_repo_files(
        &self,
        repo_id: String,
        recursive: bool,
        repo_type: String,
    ) -> Result<Vec<String>, String> {
        let client = self.require()?;
        let (namespace, name) = split_repo(&repo_id);

        let entries = match repo_type.to_lowercase().as_str() {
            "dataset" => client
                .dataset(&namespace, &name)
                .list_tree()
                .recursive(recursive)
                .send(),
            "space" => client
                .space(&namespace, &name)
                .list_tree()
                .recursive(recursive)
                .send(),
            _ => client
                .model(&namespace, &name)
                .list_tree()
                .recursive(recursive)
                .send(),
        }
        .map_err(|e| format!("list_repo_files falló ({repo_id}): {e:?}"))?;

        Ok(entries
            .into_iter()
            .map(|entry| match entry {
                hf_hub::repository::RepoTreeEntry::File { path, .. } => path,
                hf_hub::repository::RepoTreeEntry::Directory { path, .. } => path,
            })
            .collect())
    }
}

/// SHA-256 hex de un archivo (streaming de a 1MB, no lo carga entero).
/// Para nombrar uploads por hash: así se comprueba que es ese.
#[flutter_rust_bridge::frb]
pub fn sha256_archivo(ruta: String) -> Result<String, String> {
    use sha2::{Digest, Sha256};
    use std::io::Read;
    let f = std::fs::File::open(&ruta)
        .map_err(|e| format!("sha256: no abre {ruta}: {e:?}"))?;
    let mut h = Sha256::new();
    let mut buf = [0u8; 1024 * 1024];
    let mut r = std::io::BufReader::new(f);
    loop {
        let n = r
            .read(&mut buf)
            .map_err(|e| format!("sha256: lee {ruta}: {e:?}"))?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
    Ok(format!("{:x}", h.finalize()))
}

/// Baja un RANGO de bytes de un archivo grande (HTTP Range directo).
/// No requiere cliente inicializado ni login (token opcional).
#[flutter_rust_bridge::frb]
pub fn hf_download_file_range(
    repo_id: String,
    filename: String,
    start: i64,
    end: i64,
    token: String,
    repo_type: String,
) -> Result<Vec<u8>, String> {
    let base_url = match repo_type.to_lowercase().as_str() {
        "dataset" => "https://huggingface.co/datasets",
        "space" => "https://huggingface.co/spaces",
        _ => "https://huggingface.co",
    };
    let url = format!("{base_url}/{repo_id}/resolve/main/{filename}");

    let mut req = reqwest::blocking::Client::builder()
        .user_agent("pr_app-hf/1.0")
        .build()
        .map_err(|e| format!("{e:?}"))?
        .get(&url)
        .header("Range", format!("bytes={start}-{end}"));
    if !token.is_empty() {
        req = req.header("Authorization", format!("Bearer {token}"));
    }
    let response = req.send().map_err(|e| format!("request failed: {e:?}"))?;
    if !response.status().is_success() {
        return Err(format!("HTTP {} en {url}", response.status()));
    }
    let data = response.bytes().map_err(|e| format!("read failed: {e:?}"))?;
    Ok(data.to_vec())
}
