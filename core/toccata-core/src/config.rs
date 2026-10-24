use serde::Deserialize;
use std::path::PathBuf;

/// 全部字段可选，缺省走 Default。
#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct Config {
    pub idle_gap_secs: u64,
    pub trailing_grace_secs: u64,
    pub flush_interval_secs: u64,
    pub flush_batch_size: usize,
    pub db_path: Option<String>,
    pub socket_path: Option<String>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            idle_gap_secs: 60,
            trailing_grace_secs: 5,
            flush_interval_secs: 2,
            flush_batch_size: 500,
            db_path: None,
            socket_path: None,
        }
    }
}

impl Config {
    /// ~/Library/Application Support/Toccata/
    pub fn data_dir() -> PathBuf {
        if let Some(path) = std::env::var_os("TOCCATA_DATA_DIR").filter(|path| !path.is_empty()) {
            return PathBuf::from(path);
        }
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
        PathBuf::from(home).join("Library/Application Support/Toccata")
    }

    pub fn load() -> Self {
        let path = Self::data_dir().join("config.json");
        match std::fs::read_to_string(&path) {
            Ok(text) => match serde_json::from_str::<Config>(&text) {
                Ok(cfg) => cfg,
                Err(e) => {
                    eprintln!("[toccata-core] 配置文件 {path:?} 解析失败（{e}），使用默认配置");
                    Config::default()
                }
            },
            Err(_) => Config::default(), // 文件不存在属正常情况
        }
    }

    pub fn db_path(&self) -> PathBuf {
        self.db_path
            .as_ref()
            .map(PathBuf::from)
            .unwrap_or_else(|| Self::data_dir().join("toccata.db"))
    }

    pub fn socket_path(&self) -> PathBuf {
        self.socket_path
            .as_ref()
            .map(PathBuf::from)
            .unwrap_or_else(|| Self::data_dir().join("toccata.sock"))
    }
}
