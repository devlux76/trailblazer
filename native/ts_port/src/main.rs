//! The Port's program: one JSON object in, one JSON object out, one request at
//! a time.
//!
//! The VM opens the Port with `{:packet, 4}`, which frames what it writes to
//! this program and what this program writes back, so both sides read and
//! write a four byte length before each message. A file that does not parse is
//! answered with what parsed before the error; a request this program cannot
//! answer at all is answered with an error object, because the VM has to hear
//! something either way.

use std::io::{BufReader, BufWriter, Read, Write};

use serde_json::{Value, json};

fn main() {
    let stdin = BufReader::new(std::io::stdin());
    let mut stdout = BufWriter::new(std::io::stdout());

    let mut input = stdin;

    while let Some(request) = read(&mut input) {
        let frame = reply(&request);
        let length = (frame.len() as u32).to_be_bytes();

        if stdout.write_all(&length).is_err()
            || stdout.write_all(frame.as_bytes()).is_err()
            || stdout.flush().is_err()
        {
            break;
        }
    }
}

fn read(input: &mut impl Read) -> Option<String> {
    let mut header = [0u8; 4];
    input.read_exact(&mut header).ok()?;

    let mut body = vec![0u8; u32::from_be_bytes(header) as usize];
    input.read_exact(&mut body).ok()?;

    String::from_utf8(body).ok()
}

fn reply(request: &str) -> String {
    let request: Value = match serde_json::from_str(request) {
        Ok(value) => value,
        Err(error) => return error_json(&format!("bad request: {error}")),
    };

    let lang = request["lang"].as_str().unwrap_or_default();
    let path = request["path"].as_str().unwrap_or_default();
    let source = request["source"].as_str().unwrap_or_default();

    match ts_port::parse(lang, path, source) {
        Ok(value) => value.to_string(),
        Err(error) => error_json(&error),
    }
}

fn error_json(message: &str) -> String {
    json!({ "error": message }).to_string()
}
