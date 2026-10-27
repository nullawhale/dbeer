//! Final-integration-only owned LSP fixture. No SQL/database/session API.
//! Records method names only; never source, result labels or environment values.
use std::{
    env, fs,
    io::{self, BufRead, BufReader, Read, Write},
    thread,
    time::Duration,
};

fn field<'a>(text: &'a str, key: &str) -> Option<&'a str> {
    let key = format!("\"{key}\":");
    let text = text.split_once(&key)?.1.trim_start();
    if let Some(text) = text.strip_prefix('"') {
        text.split('"').next()
    } else {
        Some(text.split([',', '}']).next()?.trim())
    }
}
fn response(id: &str, result: &str) {
    let value = format!(r#"{{"jsonrpc":"2.0","id":{id},"result":{result}}}"#);
    let mut output = io::stdout().lock();
    write!(output, "Content-Length: {}\r\n\r\n{value}", value.len()).unwrap();
    output.flush().unwrap();
}
fn main() {
    if env::args().skip(1).collect::<Vec<_>>() != ["--language-server"] {
        std::process::exit(2);
    }
    if env::vars_os().any(|(name, _)| {
        !matches!(
            name.to_string_lossy().to_ascii_uppercase().as_str(),
            "LANG" | "LC_ALL" | "SYSTEMROOT" | "WINDIR" | "TEMP" | "TMP"
        )
    }) {
        std::process::exit(3);
    }
    let path = env::current_exe().unwrap();
    let mode = path.file_stem().unwrap().to_string_lossy();
    let mut input = BufReader::new(io::stdin().lock());
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
                length = value.trim().parse::<usize>().ok();
            }
        }
        let Some(length) = length.filter(|length| *length <= 4 * 1024 * 1024) else {
            return;
        };
        let mut bytes = vec![0; length];
        input.read_exact(&mut bytes).unwrap();
        let message = String::from_utf8(bytes).unwrap();
        let method = field(&message, "method").unwrap_or("");
        let id = field(&message, "id").unwrap_or("null");
        match method {
            "initialize" => response(id, r#"{"capabilities":{"positionEncoding":"utf-16"}}"#),
            "textDocument/completion" => response(id,
                r#"{"items":[{"label":"value","insertText":"value"}],"isIncomplete":false}"#),
            "textDocument/signatureHelp" => {
                if mode.contains("slow") {
                    thread::sleep(Duration::from_millis(100));
                }
                if mode.contains("null") {
                    response(id, "null");
                } else if mode.contains("bad") {
                    response(
                        id,
                        r#"{"signatures":[{"label":"f(😀)","parameters":[{"label":[2,3]}]}],"activeSignature":0}"#,
                    );
                } else {
                    response(
                        id,
                        r#"{"signatures":[{"label":"f(value: integer) → integer","parameters":[{"label":[2,16]}],"activeParameter":0},{"label":"f(value: numeric, scale: integer = DEFAULT) → numeric","parameters":[{"label":[2,16]},{"label":[18,42]}],"activeParameter":1}],"activeSignature":1}"#,
                    );
                }
            }
            "shutdown" => response(id, "null"),
            "exit" => return,
            "initialized"
            | "$/cancelRequest"
            | "textDocument/didOpen"
            | "textDocument/didChange"
            | "textDocument/didClose"
            | "workspace/didChangeConfiguration" => {}
            _ => std::process::exit(4),
        }
        // The private fixture's bounded method-only audit proves that requests
        // stayed on this exact LSP owner. It cannot contain SQL or catalog data.
        let events = path.with_extension("events");
        if fs::metadata(&events).map_or(0, |value| value.len()) < 64 * 1024 {
            let mut output = fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(events)
                .unwrap();
            writeln!(output, "{method}").unwrap();
        }
    }
}
