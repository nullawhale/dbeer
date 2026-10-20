//! Bounded Content-Length framing; no diagnostic contains peer-controlled text.
use super::{Error, Result};
use serde::Deserialize;
use serde_json::Value;
use std::fmt;

pub(super) const MAX_FRAME: usize = 4 * 1024 * 1024;
const MAX_HEADER: usize = 8 * 1024;
pub(super) const READ_CHUNK: usize = 16 * 1024;

#[derive(Default)]
pub(super) struct Framer {
    bytes: Vec<u8>,
    length: Option<usize>,
}
impl Framer {
    pub(super) fn append(&mut self, bytes: &[u8]) -> Result<Vec<Vec<u8>>> {
        if bytes.len() > READ_CHUNK
            || self.bytes.len().saturating_add(bytes.len()) > MAX_FRAME + MAX_HEADER + READ_CHUNK
        {
            return Err(Error::Limit);
        }
        self.bytes.extend_from_slice(bytes);
        let mut frames = Vec::new();
        loop {
            if self.length.is_none() {
                let Some(boundary) = self.bytes.windows(4).position(|v| v == b"\r\n\r\n") else {
                    if self.bytes.len() > MAX_HEADER {
                        return Err(Error::InvalidFrame);
                    }
                    break;
                };
                if boundary > MAX_HEADER || !self.bytes[..boundary].is_ascii() {
                    return Err(Error::InvalidFrame);
                }
                let header = std::str::from_utf8(&self.bytes[..boundary])
                    .map_err(|_| Error::InvalidFrame)?;
                let mut length = None;
                for line in header.split("\r\n") {
                    let (key, value) = line.split_once(':').ok_or(Error::InvalidFrame)?;
                    if key.trim().eq_ignore_ascii_case("Content-Length") {
                        let value = value.trim();
                        if length.is_some()
                            || value.is_empty()
                            || !value.bytes().all(|b| b.is_ascii_digit())
                        {
                            return Err(Error::InvalidFrame);
                        }
                        let parsed = value.parse::<usize>().map_err(|_| Error::InvalidFrame)?;
                        if parsed == 0 || parsed > MAX_FRAME {
                            return Err(Error::Limit);
                        }
                        length = Some(parsed);
                    }
                }
                self.length = Some(length.ok_or(Error::InvalidFrame)?);
                self.bytes.drain(..boundary + 4);
            }
            let length = self.length.ok_or(Error::InvalidFrame)?;
            if self.bytes.len() < length {
                break;
            }
            let tail = self.bytes.split_off(length);
            frames.push(std::mem::replace(&mut self.bytes, tail));
            self.length = None;
        }
        Ok(frames)
    }
    pub(super) fn finish(&self) -> Result<()> {
        if self.bytes.is_empty() && self.length.is_none() {
            Ok(())
        } else {
            Err(Error::InvalidFrame)
        }
    }
}

pub(super) fn encode(value: &Value) -> Result<Vec<u8>> {
    let body = serde_json::to_vec(value).map_err(|_| Error::InvalidMessage)?;
    if body.len() > MAX_FRAME {
        return Err(Error::Limit);
    }
    let mut frame = format!("Content-Length: {}\r\n\r\n", body.len()).into_bytes();
    frame.extend(body);
    Ok(frame)
}

/// Duplicate identity keys must not silently replace an earlier value.
pub(super) fn decode(body: &[u8]) -> Result<Value> {
    serde_json::from_slice::<UniqueValue>(body)
        .map(|value| value.0)
        .map_err(|_| Error::InvalidMessage)
}
struct UniqueValue(Value);
impl<'de> Deserialize<'de> for UniqueValue {
    fn deserialize<D: serde::Deserializer<'de>>(
        deserializer: D,
    ) -> std::result::Result<Self, D::Error> {
        struct Visitor;
        impl<'de> serde::de::Visitor<'de> for Visitor {
            type Value = UniqueValue;
            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("JSON with unique object keys")
            }
            fn visit_bool<E: serde::de::Error>(
                self,
                value: bool,
            ) -> std::result::Result<Self::Value, E> {
                Ok(UniqueValue(Value::Bool(value)))
            }
            fn visit_i64<E: serde::de::Error>(
                self,
                value: i64,
            ) -> std::result::Result<Self::Value, E> {
                Ok(UniqueValue(Value::from(value)))
            }
            fn visit_u64<E: serde::de::Error>(
                self,
                value: u64,
            ) -> std::result::Result<Self::Value, E> {
                Ok(UniqueValue(Value::from(value)))
            }
            fn visit_f64<E: serde::de::Error>(
                self,
                value: f64,
            ) -> std::result::Result<Self::Value, E> {
                serde_json::Number::from_f64(value)
                    .map(|value| UniqueValue(Value::Number(value)))
                    .ok_or_else(|| E::custom("invalid number"))
            }
            fn visit_str<E: serde::de::Error>(
                self,
                value: &str,
            ) -> std::result::Result<Self::Value, E> {
                Ok(UniqueValue(Value::String(value.into())))
            }
            fn visit_string<E: serde::de::Error>(
                self,
                value: String,
            ) -> std::result::Result<Self::Value, E> {
                Ok(UniqueValue(Value::String(value)))
            }
            fn visit_unit<E: serde::de::Error>(self) -> std::result::Result<Self::Value, E> {
                Ok(UniqueValue(Value::Null))
            }
            fn visit_seq<A: serde::de::SeqAccess<'de>>(
                self,
                mut sequence: A,
            ) -> std::result::Result<Self::Value, A::Error> {
                let mut values = Vec::new();
                while let Some(value) = sequence.next_element::<UniqueValue>()? {
                    values.push(value.0);
                }
                Ok(UniqueValue(Value::Array(values)))
            }
            fn visit_map<A: serde::de::MapAccess<'de>>(
                self,
                mut map: A,
            ) -> std::result::Result<Self::Value, A::Error> {
                let mut values = serde_json::Map::new();
                while let Some(key) = map.next_key::<String>()? {
                    if values.contains_key(&key) {
                        return Err(serde::de::Error::custom("duplicate key"));
                    }
                    values.insert(key, map.next_value::<UniqueValue>()?.0);
                }
                Ok(UniqueValue(Value::Object(values)))
            }
        }
        deserializer.deserialize_any(Visitor)
    }
}
