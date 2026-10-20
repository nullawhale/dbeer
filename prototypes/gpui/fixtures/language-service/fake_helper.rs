//! Standalone owned-child fixture, compiled only by final-integration tests.
//! It deliberately uses std only and records no input text or environment values.
use std::{
    env, fs,
    io::{self, BufRead, BufReader, Read, Write},
    path::PathBuf,
    thread,
    time::Duration,
};

fn response(value: &str) {
    let mut output = io::stdout().lock();
    write!(output, "Content-Length: {}\r\n\r\n{}", value.len(), value).unwrap();
    output.flush().unwrap();
}
fn field<'a>(text: &'a str, key: &str) -> Option<&'a str> {
    let key = format!("\"{key}\":");
    let value = text.split_once(&key)?.1.trim_start();
    if let Some(value) = value.strip_prefix('"') {
        value.split('"').next()
    } else {
        Some(value.split([',', '}']).next()?.trim())
    }
}
fn main() {
    if env::args().skip(1).collect::<Vec<_>>() != ["--language-server"] {
        std::process::exit(2);
    }
    let path = env::current_exe().unwrap();
    let mode = path.file_stem().unwrap().to_string_lossy().to_string();
    let marker = PathBuf::from(format!("{}.owned", path.display()));
    fs::write(&marker, std::process::id().to_string()).unwrap();
    if env::vars_os().any(|(name, _)| {
        !matches!(
            name.to_string_lossy().to_ascii_uppercase().as_str(),
            "LANG" | "LC_ALL" | "SYSTEMROOT" | "WINDIR" | "TEMP" | "TMP"
        )
    }) {
        std::process::exit(3);
    }
    let mut input = BufReader::new(io::stdin().lock());
    let mut completions = 0;
    loop {
        let mut length = None;
        loop {
            let mut line = String::new();
            if input.read_line(&mut line).unwrap() == 0 {
                return;
            }
            if line == "\r\n" {
                break;
            }
            if let Some(value) = line.strip_prefix("Content-Length:") {
                length = Some(value.trim().parse::<usize>().unwrap());
            }
        }
        let mut bytes = vec![0; length.unwrap()];
        input.read_exact(&mut bytes).unwrap();
        let message = String::from_utf8(bytes).unwrap();
        let method = field(&message, "method").unwrap_or("");
        // No database protocol/session/credential message is accepted here.
        if !matches!(
            method,
            "initialize"
                | "initialized"
                | "shutdown"
                | "exit"
                | "$/cancelRequest"
                | "textDocument/didOpen"
                | "textDocument/didChange"
                | "textDocument/didClose"
                | "workspace/didChangeConfiguration"
                | "textDocument/completion"
                | "textDocument/signatureHelp"
        ) {
            std::process::exit(4);
        }
        // Method names only: source/configuration/positions are never recorded.
        if mode.contains("record") {
            use std::fs::OpenOptions;
            let events = PathBuf::from(format!("{}.events", path.display()));
            if fs::metadata(&events).map_or(0, |m| m.len()) < 65_536 {
                if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(events) {
                    let _ = writeln!(file, "{method}");
                }
            }
        }
        let id = field(&message, "id");
        match method {
            "initialize" => response(&format!(
                r#"{{"jsonrpc":"2.0","id":{},"result":{{"capabilities":{{"positionEncoding":"utf-16"}}}}}}"#,
                id.unwrap()
            )),
            "textDocument/completion" => {
                completions += 1;
                if mode.contains("gated") && completions == 1 {
                    let entered = PathBuf::from(format!("{}.entered", path.display()));
                    let release = PathBuf::from(format!("{}.release", path.display()));
                    fs::write(entered, b"pending").unwrap();
                    while !release.exists() {
                        thread::sleep(Duration::from_millis(5));
                    }
                }
                if mode.contains("stall") {
                    thread::sleep(Duration::from_secs(60));
                } else if mode.contains("malformed") {
                    response("{");
                } else if mode.contains("die") {
                    std::process::exit(5);
                } else if mode.contains("remote") {
                    if mode.contains("slow") {
                        thread::sleep(Duration::from_millis(100));
                    }
                    response(&format!(
                        r#"{{"jsonrpc":"2.0","id":{},"error":{{"code":-1,"message":"PRIVATE_PEER_MESSAGE"}}}}"#,
                        id.unwrap()
                    ));
                } else {
                    if mode.contains("slow") {
                        thread::sleep(Duration::from_millis(100));
                    }
                    response(&format!(
                        r#"{{"jsonrpc":"2.0","id":{},"result":{{"items":[{{"label":"safe","insertText":"safe"}}],"isIncomplete":false}}}}"#,
                        id.unwrap()
                    ));
                }
            }
            "textDocument/signatureHelp" => response(&format!(
                r#"{{"jsonrpc":"2.0","id":{},"result":null}}"#,
                id.unwrap()
            )),
            "shutdown" => {
                response(&format!(
                    r#"{{"jsonrpc":"2.0","id":{},"result":null}}"#,
                    id.unwrap()
                ));
            }
            "exit" => {
                let _ = fs::remove_file(marker);
                return;
            }
            _ => {}
        }
    }
}
