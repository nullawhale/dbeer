//! LSP coordinates count UTF-16; the GPUI rope/editor uses UTF-8 byte offsets.
use super::{Error, Result};
use serde::{Deserialize, Serialize};
use std::ops::Range;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct Position {
    pub line: u32,
    pub character: u32,
}
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct TextRange {
    pub start: Position,
    pub end: Position,
}

pub fn position_at(text: &str, offset: usize) -> Result<Position> {
    if !text.is_char_boundary(offset)
        || (offset > 0
            && text.as_bytes().get(offset - 1) == Some(&b'\r')
            && text.as_bytes().get(offset) == Some(&b'\n'))
    {
        return Err(Error::InvalidPosition);
    }
    let mut position = Position {
        line: 0,
        character: 0,
    };
    let mut chars = text[..offset].chars().peekable();
    while let Some(character) = chars.next() {
        if character == '\r' || character == '\n' {
            if character == '\r' && chars.peek() == Some(&'\n') {
                chars.next();
            }
            position.line += 1;
            position.character = 0;
        } else {
            position.character += character.len_utf16() as u32;
        }
    }
    Ok(position)
}

pub fn offset_at(text: &str, target: Position) -> Result<usize> {
    let mut line = 0;
    let mut column = 0;
    let mut chars = text.char_indices().peekable();
    while let Some((offset, character)) = chars.next() {
        if line == target.line && column == target.character {
            return Ok(offset);
        }
        if character == '\r' || character == '\n' {
            if line == target.line {
                return Err(Error::InvalidPosition);
            }
            if character == '\r' && chars.peek().is_some_and(|(_, c)| *c == '\n') {
                chars.next();
            }
            line += 1;
            column = 0;
        } else {
            column += character.len_utf16() as u32;
            if line == target.line && column > target.character {
                return Err(Error::InvalidPosition);
            }
        }
    }
    if line == target.line && column == target.character {
        Ok(text.len())
    } else {
        Err(Error::InvalidPosition)
    }
}

pub fn byte_range(text: &str, range: TextRange) -> Result<Range<usize>> {
    let start = offset_at(text, range.start)?;
    let end = offset_at(text, range.end)?;
    if end < start {
        return Err(Error::InvalidPosition);
    }
    Ok(start..end)
}

/// Half-open UTF-16 offsets used in labels by the Go matcher/signature service.
pub fn label_range(label: &str, span: [usize; 2]) -> Result<Range<usize>> {
    if span[1] < span[0] {
        return Err(Error::InvalidPosition);
    }
    fn boundary(label: &str, target: usize) -> Option<usize> {
        let mut units = 0;
        for (offset, character) in label.char_indices() {
            if units == target {
                return Some(offset);
            }
            units += character.len_utf16();
        }
        (units == target).then_some(label.len())
    }
    Ok(boundary(label, span[0]).ok_or(Error::InvalidPosition)?
        ..boundary(label, span[1]).ok_or(Error::InvalidPosition)?)
}
