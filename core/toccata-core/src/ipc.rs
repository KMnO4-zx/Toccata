//! Unix socket IPC：JSON Lines 协议。
//! 客户端发 {"cmd":"subscribe"}，daemon 回包含采集与权限状态的 hello，
//! 此后广播按键、落盘更新与 capture 状态消息。

use std::io::{BufRead, BufReader, Write};
use std::net::Shutdown;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

const CLIENT_WRITE_TIMEOUT: Duration = Duration::from_millis(250);

pub fn hello() -> String {
    hello_json(
        crate::tap::capture_enabled(),
        crate::writer_ready(),
        crate::tap::permission_required(),
    )
}

fn hello_json(capture_active: bool, ready: bool, permission_required: bool) -> String {
    serde_json::json!({
        "type": "hello",
        "version": 1,
        "capture_enabled": capture_active && ready,
        "permission_required": permission_required,
    })
    .to_string()
}

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
                // The reader owns a clone. Closing this stream alone would
                // leave its thread and descriptor waiting for a stalled peer.
                let _ = c.stream.shutdown(Shutdown::Both);
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
    // Broadcasting shares the persistence writer. A paused subscriber must not
    // indefinitely prevent recording keys, serving other clients, or shutdown.
    if stream.set_write_timeout(Some(CLIENT_WRITE_TIMEOUT)).is_err() {
        return;
    }
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
        let hello = hello();
        let mut hello_stream = match stream.try_clone() {
            Ok(s) => s,
            Err(_) => return,
        };
        if hello_stream.write_all(hello.as_bytes()).is_err()
            || hello_stream.write_all(b"\n").is_err()
        {
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    #[test]
    fn stalled_subscriber_cannot_block_broadcast_or_healthy_subscribers() {
        let broadcaster = Broadcaster::empty();
        let (slow_peer, slow_control, slow_handler) = subscribed_pair(1, broadcaster.clone());
        let (healthy_peer, healthy_control, healthy_handler) = subscribed_pair(2, broadcaster.clone());
        let healthy_reader = healthy_peer.try_clone().unwrap();
        // Exceed the Unix socket send buffer while the slow peer stops reading.
        // The healthy peer keeps draining concurrently, as Studio normally does.
        let payload = "x".repeat(2 * 1024 * 1024);
        let expected = payload.clone();
        let reader = std::thread::spawn(move || {
            let mut line = String::new();
            let result = BufReader::new(healthy_reader).read_line(&mut line);
            (result, line)
        });
        let (finished, completion) = mpsc::channel();
        let sender = broadcaster.clone();
        let writer = std::thread::spawn(move || {
            sender.broadcast(&payload);
            let _ = finished.send(());
        });

        let completed = completion.recv_timeout(Duration::from_secs(2)).is_ok();
        // Unblock even the old implementation before asserting. A failed
        // regression must not strand the test runner inside write_all or join.
        if !completed {
            let _ = slow_control.shutdown(Shutdown::Both);
            let _ = healthy_control.shutdown(Shutdown::Both);
            let _ = slow_peer.shutdown(Shutdown::Both);
            let _ = healthy_peer.shutdown(Shutdown::Both);
        }
        writer.join().unwrap();
        let (read_result, received) = reader.join().unwrap();
        let registered: Vec<_> = broadcaster.clients.lock().unwrap().iter().map(|c| c.id).collect();
        let disconnected = (0..100).any(|_| {
            if slow_handler.is_finished() { return true; }
            std::thread::sleep(Duration::from_millis(5));
            false
        });
        let _ = slow_control.shutdown(Shutdown::Both);
        let _ = healthy_control.shutdown(Shutdown::Both);
        let _ = slow_peer.shutdown(Shutdown::Both);
        let _ = healthy_peer.shutdown(Shutdown::Both);
        slow_handler.join().unwrap();
        healthy_handler.join().unwrap();

        assert!(completed, "a non-reading subscriber blocked the writer for more than two seconds");
        assert!(read_result.is_ok(), "healthy subscriber must remain readable: {read_result:?}");
        assert_eq!(received.len(), expected.len() + 1);
        assert!(received.ends_with('\n') && received[..received.len() - 1] == expected);
        assert!(!registered.contains(&1), "stalled subscriber must be disconnected");
        assert!(registered.contains(&2), "healthy subscriber must stay registered");
        assert!(disconnected, "disconnect must also release the stalled subscriber's reader thread");
    }

    fn subscribed_pair(id: u64, broadcaster: Broadcaster) -> (UnixStream, UnixStream, std::thread::JoinHandle<()>) {
        let (server, mut peer) = UnixStream::pair().unwrap();
        let control = server.try_clone().unwrap();
        peer.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
        let handler_broadcaster = broadcaster.clone();
        let handler = std::thread::spawn(move || client_loop(id, server, handler_broadcaster));
        peer.write_all(b"{\"cmd\":\"subscribe\"}\n").unwrap();
        let mut hello = String::new();
        BufReader::new(peer.try_clone().unwrap()).read_line(&mut hello).unwrap();
        assert!(hello.contains("\"hello\""));
        for _ in 0..100 {
            if broadcaster.clients.lock().unwrap().iter().any(|c| c.id == id) {
                return (peer, control, handler);
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        let _ = peer.shutdown(Shutdown::Both);
        handler.join().unwrap();
        panic!("subscriber did not register");
    }

    #[test]
    fn hello_keeps_version_and_reports_capture_status() {
        let waiting: serde_json::Value =
            serde_json::from_str(&hello_json(true, false, true)).unwrap();
        assert_eq!(waiting["type"], "hello");
        assert_eq!(waiting["version"], 1);
        assert_eq!(waiting["capture_enabled"], false);
        assert_eq!(waiting["permission_required"], true);

        let active: serde_json::Value =
            serde_json::from_str(&hello_json(true, true, false)).unwrap();
        assert_eq!(active["type"], "hello");
        assert_eq!(active["version"], 1);
        assert_eq!(active["capture_enabled"], true);
        assert_eq!(active["permission_required"], false);
    }
}
