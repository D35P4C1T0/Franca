// SPDX-License-Identifier: GPL-2.0-or-later

//! Scriptable local IPC server for Franca (Unix domain socket, line-delimited JSON).
//! Allows `francamsg` and automated UI regression suites to inspect and drive a live instance.

#![allow(dead_code)]

use std::collections::hash_map::DefaultHasher;
use std::fs;
use std::hash::{Hash, Hasher};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::thread::{self, JoinHandle};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

pub const PROTOCOL_VERSION: u32 = 1;
pub const MAX_REQUEST_BYTES: usize = 64 * 1024;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct IpcRequest {
    #[serde(default = "default_proto_version")]
    pub v: u32,
    pub cmd: String,
    #[serde(default)]
    pub args: Value,
}

fn default_proto_version() -> u32 {
    PROTOCOL_VERSION
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct IpcResponse {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl IpcResponse {
    pub fn ok(result: Value) -> Self {
        Self {
            ok: true,
            result: Some(result),
            error: None,
        }
    }

    pub fn err(msg: impl Into<String>) -> Self {
        Self {
            ok: false,
            result: None,
            error: Some(msg.into()),
        }
    }
}

pub struct PendingIpcCommand {
    pub request: IpcRequest,
    pub reply_tx: mpsc::Sender<IpcResponse>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct InstanceRegistryEntry {
    pub key: String,
    pub pid: u32,
    pub socket: String,
    pub version: String,
    pub project: String,
    pub started_unix: u64,
}

pub fn runtime_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("XDG_RUNTIME_DIR") {
        let p = PathBuf::from(dir);
        if p.is_dir() {
            return p;
        }
    }
    std::env::temp_dir()
}

pub fn session_token() -> String {
    for key in ["XDG_SESSION_ID", "WAYLAND_DISPLAY", "DISPLAY"] {
        if let Ok(v) = std::env::var(key) {
            if !v.is_empty() {
                return format!("{key}={v}");
            }
        }
    }
    "session=default".to_string()
}

pub fn instance_key() -> String {
    if let Ok(override_key) = std::env::var("FRANCA_INSTANCE_KEY") {
        let trimmed = override_key.trim();
        if !trimmed.is_empty() {
            let safe: String = trimmed
                .chars()
                .map(|c| {
                    if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                        c
                    } else {
                        '_'
                    }
                })
                .collect();
            return safe;
        }
    }
    let uid = current_uid();
    let raw = format!("franca|{}|{}", uid, session_token());
    let mut hasher = DefaultHasher::new();
    raw.hash(&mut hasher);
    format!("{:010x}", hasher.finish() & 0x00FF_FFFF_FFFF)
}

fn current_uid() -> u32 {
    #[cfg(unix)]
    {
        unsafe { libc::geteuid() }
    }
    #[cfg(not(unix))]
    {
        0
    }
}

pub fn registry_dir() -> PathBuf {
    runtime_dir().join("franca-instances")
}

pub fn socket_path_for(key: &str) -> PathBuf {
    runtime_dir().join(format!("franca-{key}.sock"))
}

pub fn registry_path_for(key: &str) -> PathBuf {
    registry_dir().join(format!("{key}.json"))
}

pub struct IpcServer {
    key: String,
    socket_path: PathBuf,
    registry_path: PathBuf,
    started_unix: u64,
    stop_flag: Arc<AtomicBool>,
    inbox: Arc<Mutex<Vec<PendingIpcCommand>>>,
    thread: Option<JoinHandle<()>>,
}

impl IpcServer {
    #[cfg(unix)]
    pub fn start(version: &str) -> Result<Self, String> {
        let key = instance_key();
        let socket_path = socket_path_for(&key);
        let registry_path = registry_path_for(&key);
        Self::start_at(key, socket_path, registry_path, version)
    }

    #[cfg(not(unix))]
    pub fn start(_version: &str) -> Result<Self, String> {
        Err("Local IPC is only supported on Unix platforms".into())
    }

    #[cfg(unix)]
    pub fn start_at(
        key: String,
        socket_path: PathBuf,
        registry_path: PathBuf,
        version: &str,
    ) -> Result<Self, String> {
        use std::os::unix::fs::PermissionsExt;
        use std::os::unix::net::UnixListener;

        if let Some(parent) = socket_path.parent() {
            fs::create_dir_all(parent).map_err(|e| format!("IPC mkdir failed: {e}"))?;
        }
        // Remove stale socket file if no listener is alive on it
        if socket_path.exists() {
            if std::os::unix::net::UnixStream::connect(&socket_path).is_err() {
                let _ = fs::remove_file(&socket_path);
            } else {
                // Another live instance owns this key; fall back to pid-scoped key
                let pid_key = format!("{key}-{}", std::process::id());
                let pid_sock = socket_path
                    .parent()
                    .unwrap_or_else(|| Path::new("/tmp"))
                    .join(format!("franca-{pid_key}.sock"));
                let pid_reg = registry_path
                    .parent()
                    .unwrap_or_else(|| Path::new("/tmp"))
                    .join(format!("{pid_key}.json"));
                return Self::start_at(pid_key, pid_sock, pid_reg, version);
            }
        }

        let listener =
            UnixListener::bind(&socket_path).map_err(|e| format!("IPC bind failed: {e}"))?;
        let _ = fs::set_permissions(&socket_path, fs::Permissions::from_mode(0o600));
        listener
            .set_nonblocking(true)
            .map_err(|e| format!("IPC nonblocking failed: {e}"))?;

        let started_unix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);

        let entry = InstanceRegistryEntry {
            key: key.clone(),
            pid: std::process::id(),
            socket: socket_path.to_string_lossy().into_owned(),
            version: version.to_string(),
            project: String::new(),
            started_unix,
        };
        if let Some(reg_parent) = registry_path.parent() {
            let _ = fs::create_dir_all(reg_parent);
            let _ = fs::set_permissions(reg_parent, fs::Permissions::from_mode(0o700));
        }
        if let Ok(json_bytes) = serde_json::to_vec_pretty(&entry) {
            let _ = crate::session::write_file_atomic(&registry_path, &json_bytes);
        }

        let stop_flag = Arc::new(AtomicBool::new(false));
        let inbox: Arc<Mutex<Vec<PendingIpcCommand>>> = Arc::new(Mutex::new(Vec::new()));

        let stop_clone = Arc::clone(&stop_flag);
        let inbox_clone = Arc::clone(&inbox);
        let handle = thread::Builder::new()
            .name("franca-ipc".into())
            .spawn(move || {
                ipc_accept_loop(listener, stop_clone, inbox_clone);
            })
            .map_err(|e| format!("IPC thread spawn failed: {e}"))?;

        Ok(Self {
            key,
            socket_path,
            registry_path,
            started_unix,
            stop_flag,
            inbox,
            thread: Some(handle),
        })
    }

    pub fn key(&self) -> &str {
        &self.key
    }

    pub fn socket_path(&self) -> &Path {
        &self.socket_path
    }

    pub fn update_registered_project(&self, version: &str, project: &str) {
        let entry = InstanceRegistryEntry {
            key: self.key.clone(),
            pid: std::process::id(),
            socket: self.socket_path.to_string_lossy().into_owned(),
            version: version.to_string(),
            project: project.to_string(),
            started_unix: self.started_unix,
        };
        if let Ok(bytes) = serde_json::to_vec_pretty(&entry) {
            let _ = crate::session::write_file_atomic(&self.registry_path, &bytes);
        }
    }

    pub fn drain_pending(&self) -> Vec<PendingIpcCommand> {
        if let Ok(mut guard) = self.inbox.lock() {
            std::mem::take(&mut *guard)
        } else {
            Vec::new()
        }
    }

    pub fn shutdown(&mut self) {
        self.stop_flag.store(true, Ordering::SeqCst);
        if let Some(handle) = self.thread.take() {
            let _ = handle.join();
        }
        let _ = fs::remove_file(&self.socket_path);
        let _ = fs::remove_file(&self.registry_path);
    }
}

impl Drop for IpcServer {
    fn drop(&mut self) {
        self.shutdown();
    }
}

#[cfg(unix)]
fn ipc_accept_loop(
    listener: std::os::unix::net::UnixListener,
    stop_flag: Arc<AtomicBool>,
    inbox: Arc<Mutex<Vec<PendingIpcCommand>>>,
) {
    while !stop_flag.load(Ordering::SeqCst) {
        match listener.accept() {
            Ok((stream, _addr)) => {
                let _ = stream.set_nonblocking(false);
                let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
                let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));
                let inbox_ref = Arc::clone(&inbox);
                // Handle each client on a short-lived worker so slow commands never block new accepts
                let _ = thread::Builder::new()
                    .name("franca-ipc-conn".into())
                    .spawn(move || handle_client(stream, inbox_ref));
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(15));
            }
            Err(_) => {
                if stop_flag.load(Ordering::SeqCst) {
                    break;
                }
                thread::sleep(Duration::from_millis(50));
            }
        }
    }
}

#[cfg(unix)]
fn handle_client(
    mut stream: std::os::unix::net::UnixStream,
    inbox: Arc<Mutex<Vec<PendingIpcCommand>>>,
) {
    let mut reader = BufReader::new(match stream.try_clone() {
        Ok(s) => s,
        Err(_) => return,
    });
    let mut line = String::new();
    let n = match reader.read_line(&mut line) {
        Ok(n) => n,
        Err(_) => return,
    };
    if n == 0 {
        return;
    }
    if line.len() > MAX_REQUEST_BYTES {
        let _ = write_response(
            &mut stream,
            &IpcResponse::err("Request exceeds maximum size (64 KB)"),
        );
        return;
    }

    let req: IpcRequest = match serde_json::from_str(line.trim()) {
        Ok(r) => r,
        Err(e) => {
            let _ = write_response(
                &mut stream,
                &IpcResponse::err(format!("Malformed JSON request: {e}")),
            );
            return;
        }
    };

    if req.cmd == "ping" {
        let _ = write_response(
            &mut stream,
            &IpcResponse::ok(json!({ "pong": true, "v": PROTOCOL_VERSION })),
        );
        return;
    }

    let (tx, rx) = mpsc::channel();
    if let Ok(mut guard) = inbox.lock() {
        guard.push(PendingIpcCommand {
            request: req,
            reply_tx: tx,
        });
    } else {
        let _ = write_response(&mut stream, &IpcResponse::err("IPC queue lock poisoned"));
        return;
    }

    let resp = match rx.recv_timeout(Duration::from_secs(30)) {
        Ok(r) => r,
        Err(_) => IpcResponse::err("Timed out waiting for GUI thread to handle IPC request"),
    };
    let _ = write_response(&mut stream, &resp);
}

#[cfg(unix)]
fn write_response(
    stream: &mut std::os::unix::net::UnixStream,
    resp: &IpcResponse,
) -> std::io::Result<()> {
    let mut data = serde_json::to_vec(resp).unwrap_or_else(|_| {
        b"{\"ok\":false,\"error\":\"Serialization failure\"}".to_vec()
    });
    data.push(b'\n');
    stream.write_all(&data)?;
    stream.flush()
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::net::UnixStream;

    fn send_json(sock: &Path, payload: &str) -> IpcResponse {
        let mut s = UnixStream::connect(sock).expect("connect ipc");
        s.write_all(payload.as_bytes()).unwrap();
        s.write_all(b"\n").unwrap();
        s.flush().unwrap();
        let mut line = String::new();
        BufReader::new(s).read_line(&mut line).unwrap();
        serde_json::from_str(line.trim()).expect("valid json reply")
    }

    #[test]
    fn ipc_server_ping_dispatch_and_cleanup() {
        let dir = tempfile::Builder::new()
            .prefix("franca-ipc-")
            .tempdir_in("/tmp")
            .unwrap_or_else(|_| tempfile::tempdir().unwrap());
        let sock = dir.path().join("f.sock");
        let reg = dir.path().join("reg/test.json");
        let mut srv = IpcServer::start_at("test".into(), sock.clone(), reg.clone(), "2.6.0-test")
            .expect("start ipc server");

        assert!(sock.exists());
        assert!(reg.exists());

        // 1. Ping is answered immediately by the IPC thread
        let pong = send_json(&sock, r#"{"v":1,"cmd":"ping"}"#);
        assert!(pong.ok);
        assert_eq!(pong.result.unwrap()["pong"], json!(true));

        // 2. Malformed JSON returns structured error
        let bad = send_json(&sock, "not-json");
        assert!(!bad.ok);
        assert!(bad.error.unwrap().contains("Malformed JSON"));

        // 3. Dispatched command goes through inbox and receives GUI reply
        let sock_c = sock.clone();
        let client_t = thread::spawn(move || {
            send_json(&sock_c, r#"{"v":1,"cmd":"status","args":{}}"#)
        });
        let mut handled = false;
        for _ in 0..100 {
            for pending in srv.drain_pending() {
                assert_eq!(pending.request.cmd, "status");
                let _ = pending
                    .reply_tx
                    .send(IpcResponse::ok(json!({ "engine_running": true })));
                handled = true;
            }
            if handled {
                break;
            }
            thread::sleep(Duration::from_millis(10));
        }
        assert!(handled);
        let status = client_t.join().unwrap();
        assert!(status.ok);
        assert_eq!(status.result.unwrap()["engine_running"], json!(true));

        // 4. Shutdown cleans up socket and registry file
        srv.shutdown();
        assert!(!sock.exists());
        assert!(!reg.exists());
    }
}
