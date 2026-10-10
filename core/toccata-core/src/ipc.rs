//! Unix socket IPC：JSON Lines 协议。
//! 客户端发 {"cmd":"subscribe"}，daemon 回 {"type":"hello","version":1}，
//! 此后每个有效事件广播一行 {"type":"key",...}。

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

const HELLO: &str = r#"{"type":"hello","version":1}"#;

struct Client {
    id: u64,
    stream: UnixStream,
}

/// 客户端集合。无客户端时 broadcast 只是空 Vec 遍历，零开销。
#[derive(Clone)]
pub struct Broadcaster {
    clients: Arc<Mutex<Vec<Client>>>,
}

impl Broadcaster {
    /// 无监听器时的空广播器（所有 broadcast 都是空集合遍历）。
    pub fn empty() -> Self {
        Self {
            clients: Arc::new(Mutex::new(Vec::new())),
        }
    }

    /// 广播一行 JSON（末尾补 \n）。写失败的客户端立即剔除。
    pub fn broadcast(&self, line: &str) {
        let mut clients = self.clients.lock().unwrap();
        if clients.is_empty() {
            return; // 空集合遍历，零开销
        }
        let mut dead = Vec::new();
        for c in clients.iter_mut() {
            if c.stream.write_all(line.as_bytes()).is_err()
                || c.stream.write_all(b"\n").is_err()
            {
                dead.push(c.id);
            }
        }
        if !dead.is_empty() {
            clients.retain(|c| !dead.contains(&c.id));
        }
    }

    fn remove(&self, id: u64) {
        self.clients.lock().unwrap().retain(|c| c.id != id);
    }
}

/// 删除残留 socket 文件后 bind，并启动 accept 线程。返回共享的 Broadcaster。
pub fn start_listener(path: PathBuf) -> std::io::Result<Broadcaster> {
    if path.exists() {
        std::fs::remove_file(&path)?; // 清理上次异常退出留下的 socket 文件
    }
    let listener = UnixListener::bind(&path)?;
    let broadcaster = Broadcaster {
        clients: Arc::new(Mutex::new(Vec::new())),
    };
    let b = broadcaster.clone();
    std::thread::Builder::new()
        .name("ipc-accept".into())
        .spawn(move || accept_loop(listener, b))?;
    Ok(broadcaster)
}

fn accept_loop(listener: UnixListener, broadcaster: Broadcaster) {
    let next_id = AtomicU64::new(1);
    for stream in listener.incoming() {
        match stream {
            Ok(s) => {
                let id = next_id.fetch_add(1, Ordering::Relaxed);
                let b = broadcaster.clone();
                std::thread::Builder::new()
                    .name(format!("ipc-client-{id}"))
                    .spawn(move || client_loop(id, s, b))
                    .ok();
            }
            Err(e) => {
                eprintln!("[toccata-core] socket accept 失败: {e}");
                std::thread::sleep(std::time::Duration::from_millis(100));
            }
        }
    }
}

fn client_loop(id: u64, stream: UnixStream, broadcaster: Broadcaster) {
    let mut reader = BufReader::new(match stream.try_clone() {
        Ok(s) => s,
        Err(_) => return,
    });
    // 第一条消息必须是 subscribe，否则直接断开
    let mut line = String::new();
    match reader.read_line(&mut line) {
        Ok(0) | Err(_) => return,
        Ok(_) => {}
    }
    let is_subscribe = serde_json::from_str::<serde_json::Value>(&line)
        .ok()
        .and_then(|v| v.get("cmd")?.as_str().map(|s| s == "subscribe"))
        .unwrap_or(false);
    if !is_subscribe {
        return;
    }
    {
        let mut hello = match stream.try_clone() {
            Ok(s) => s,
            Err(_) => return,
        };
        if hello.write_all(HELLO.as_bytes()).is_err() || hello.write_all(b"\n").is_err() {
            return;
        }
    }
    broadcaster.clients.lock().unwrap().push(Client { id, stream });
    // 持续读以探测断连（协议上客户端此后无需再发数据）
    let mut buf = String::new();
    loop {
        buf.clear();
        match reader.read_line(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
    }
    broadcaster.remove(id);
}
