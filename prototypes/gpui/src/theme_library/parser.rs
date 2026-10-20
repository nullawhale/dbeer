use super::{Error, ImportPreview, Theme, assets};
use crate::appearance::{Color, Scheme, TokenRule, TokenStyle};
use serde_json::{Map, Value};
use std::{
    collections::{BTreeMap, HashSet},
    fs,
    io::{Cursor, Read},
    path::{Component, Path, PathBuf},
};

pub const MAX_FILE_BYTES: usize = 1_048_576;
pub const MAX_TOTAL_BYTES: usize = 4_194_304;
const MAX_ITEMS: usize = 10_000;

pub fn preview_import(path: &Path) -> Result<ImportPreview, Error> {
    let file = checked_selected(path)?;
    let name = path
        .file_stem()
        .and_then(|part| part.to_str())
        .unwrap_or("Imported Theme");
    let id = format!("imported-{}", uuid::Uuid::new_v4());
    let theme = if path
        .extension()
        .and_then(|ext| ext.to_str())
        .is_some_and(|ext| ext.eq_ignore_ascii_case("icls"))
    {
        super::jetbrains::parse(&read_file(&file)?, name, &id, true)?
    } else {
        let root = file.parent().ok_or(Error::UnsafeReference)?.to_path_buf();
        let mut loader = Loader::new(Some(root));
        loader.load(&file, 0)?.theme(name, &id, true)?
    };
    if !super::valid_import(&theme) {
        return Err(Error::InvalidFormat);
    }
    Ok(ImportPreview { theme })
}

/// Standalone data has no filesystem authority. Local includes require preview_import.
#[allow(dead_code)] // Standalone parsing API and cross-language fixtures; UI supplies a local path.
pub fn parse_bytes(data: &[u8], name: &str, id: &str) -> Result<Theme, Error> {
    if !super::imported_id(id) {
        return Err(Error::InvalidIdentity);
    }
    if data.len() > MAX_FILE_BYTES {
        return Err(Error::TooLarge);
    }
    if std::str::from_utf8(data.get(..data.len().min(1024)).unwrap_or(data))
        .is_ok_and(|prefix| prefix.contains("<scheme"))
    {
        return super::jetbrains::parse(data, name, id, true);
    }
    let object = object(data)?;
    if object.contains_key("include") || object.get("tokenColors").is_some_and(Value::is_string) {
        return Err(Error::UnsafeReference);
    }
    Document::from_object(&object)?.theme(name, id, true)
}
pub(super) fn load_embedded(path: &Path, id: &str) -> Result<Theme, Error> {
    Loader::new(None).load(path, 0)?.theme(
        path.file_stem()
            .and_then(|part| part.to_str())
            .unwrap_or("Theme"),
        id,
        false,
    )
}

struct Loader {
    root: Option<PathBuf>,
    active: HashSet<PathBuf>,
    total: usize,
    count: usize,
}
impl Loader {
    fn new(root: Option<PathBuf>) -> Self {
        Self {
            root,
            active: HashSet::new(),
            total: 0,
            count: 0,
        }
    }
    fn load(&mut self, path: &Path, depth: usize) -> Result<Document, Error> {
        if depth >= 8 || self.active.contains(path) {
            return Err(Error::ReferenceCycle);
        }
        if self.count >= 16 {
            return Err(Error::TooLarge);
        }
        self.active.insert(path.into());
        let result = self.load_active(path, depth);
        self.active.remove(path);
        result
    }
    fn load_active(&mut self, path: &Path, depth: usize) -> Result<Document, Error> {
        let data = if self.root.is_some() {
            read_file(path)?
        } else {
            assets::source(path.to_str().ok_or(Error::UnsafeReference)?)
                .ok_or(Error::Unreadable)?
                .to_vec()
        };
        self.count += 1;
        self.total += data.len();
        if data.len() > MAX_FILE_BYTES || self.total > MAX_TOTAL_BYTES {
            return Err(Error::TooLarge);
        }
        let object = object(&data)?;
        let mut document = Document::default();
        if let Some(include) = object.get("include") {
            document = self.load(
                &self.reference(include.as_str().ok_or(Error::InvalidFormat)?, path)?,
                depth + 1,
            )?;
        }
        if let Some(reference) = object.get("tokenColors").and_then(Value::as_str) {
            document.merge(self.load(&self.reference(reference, path)?, depth + 1)?)?;
        }
        document.merge(Document::from_object(&object)?)?;
        Ok(document)
    }
    fn reference(&self, reference: &str, from: &Path) -> Result<PathBuf, Error> {
        if reference.is_empty()
            || reference.starts_with(['/', '~', '\\'])
            || reference.contains([':', '\\', '\0'])
        {
            return Err(Error::UnsafeReference);
        }
        let relative = Path::new(reference);
        if relative
            .components()
            .any(|part| !matches!(part, Component::Normal(_) | Component::CurDir))
        {
            return Err(Error::UnsafeReference);
        }
        let joined = from.parent().unwrap_or(Path::new("")).join(relative);
        if let Some(root) = &self.root {
            // Refuse symlink/reparse components before canonical containment validation.
            let mut current = root.clone();
            let tail = joined
                .strip_prefix(root)
                .map_err(|_| Error::UnsafeReference)?;
            for part in tail.components() {
                current.push(part);
                reject_link(&fs::symlink_metadata(&current).map_err(|_| Error::Unreadable)?)?;
            }
            let canonical = fs::canonicalize(&joined).map_err(|_| Error::Unreadable)?;
            if !canonical.starts_with(root) || canonical == *root {
                return Err(Error::UnsafeReference);
            }
            Ok(canonical)
        } else {
            let mut clean = PathBuf::new();
            for part in joined.components() {
                if let Component::Normal(name) = part {
                    clean.push(name);
                }
            }
            Ok(clean)
        }
    }
}
fn checked_selected(path: &Path) -> Result<PathBuf, Error> {
    if path
        .components()
        .any(|part| matches!(part, Component::ParentDir))
    {
        return Err(Error::UnsafeReference);
    }
    reject_link(&fs::symlink_metadata(path).map_err(|_| Error::Unreadable)?)?;
    let canonical = fs::canonicalize(path).map_err(|_| Error::Unreadable)?;
    Ok(canonical)
}
fn reject_link(metadata: &fs::Metadata) -> Result<(), Error> {
    if metadata.file_type().is_symlink() {
        return Err(Error::UnsafeReference);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes() & 0x400 != 0 {
            return Err(Error::UnsafeReference);
        }
    }
    Ok(())
}
fn read_file(path: &Path) -> Result<Vec<u8>, Error> {
    let before = fs::symlink_metadata(path).map_err(|_| Error::Unreadable)?;
    reject_link(&before)?;
    if !before.is_file() {
        return Err(Error::Unreadable);
    }
    if before.len() > MAX_FILE_BYTES as u64 {
        return Err(Error::TooLarge);
    }
    let mut options = fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(0x00200000);
    }
    let file = options.open(path).map_err(|_| Error::Unreadable)?;
    let metadata = file.metadata().map_err(|_| Error::Unreadable)?;
    reject_link(&metadata)?;
    if !metadata.is_file() {
        return Err(Error::Unreadable);
    }
    if metadata.len() > MAX_FILE_BYTES as u64 {
        return Err(Error::TooLarge);
    }
    let mut bytes = Vec::new();
    file.take(MAX_FILE_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| Error::Unreadable)?;
    if bytes.len() > MAX_FILE_BYTES {
        return Err(Error::TooLarge);
    }
    Ok(bytes)
}
#[derive(Default)]
struct Document {
    name: Option<String>,
    appearance: Option<Scheme>,
    colors: BTreeMap<String, Color>,
    rules: Vec<TokenRule>,
}
impl Document {
    fn from_object(object: &Map<String, Value>) -> Result<Self, Error> {
        let mut result = Self {
            name: object.get("name").and_then(Value::as_str).map(title),
            appearance: match object.get("type").and_then(Value::as_str) {
                Some("light" | "hcLight") => Some(Scheme::Light),
                Some("dark" | "hc" | "hcDark") => Some(Scheme::Dark),
                _ => None,
            },
            ..Default::default()
        };
        let mut explicit = BTreeMap::new();
        if let Some(colors) = object.get("colors") {
            for (key, value) in colors.as_object().ok_or(Error::InvalidFormat)? {
                if !value.is_null() {
                    explicit.insert(key.clone(), color(value)?);
                }
            }
        }
        let values = if let Some(values) = object.get("tokenColors").and_then(Value::as_array) {
            Some(values)
        } else if let Some(values) = object.get("settings").and_then(Value::as_array) {
            Some(values)
        } else if object.get("tokenColors").is_none_or(Value::is_string) {
            None
        } else {
            return Err(Error::InvalidFormat);
        };
        if let Some(values) = values {
            if values.len() > MAX_ITEMS {
                return Err(Error::TooComplex);
            }
            for value in values {
                let settings = value
                    .get("settings")
                    .and_then(Value::as_object)
                    .ok_or(Error::InvalidFormat)?;
                let mut style = TokenStyle::default();
                if let Some(value) = settings.get("foreground").filter(|value| !value.is_null()) {
                    style.foreground = Some(color(value)?);
                }
                if let Some(value) = settings.get("background").filter(|value| !value.is_null()) {
                    style.background = Some(color(value)?);
                }
                if let Some(value) = settings.get("fontStyle") {
                    style.font_style = Some(value.as_str().ok_or(Error::InvalidFormat)?.into());
                }
                let scopes = match value.get("scope") {
                    None => Vec::new(),
                    Some(Value::String(scope)) => vec![scope.as_str()],
                    Some(Value::Array(scopes)) => scopes
                        .iter()
                        .map(|scope| scope.as_str().ok_or(Error::InvalidFormat))
                        .collect::<Result<Vec<_>, _>>()?,
                    _ => return Err(Error::InvalidFormat),
                }
                .into_iter()
                .flat_map(|scope| scope.split(','))
                .map(str::trim)
                .filter(|scope| !scope.is_empty())
                .map(str::to_owned)
                .collect::<Vec<_>>();
                if scopes.is_empty() {
                    if let Some(color) = style.foreground {
                        result.colors.insert("editor.foreground".into(), color);
                    }
                    if let Some(color) = style.background {
                        result.colors.insert("editor.background".into(), color);
                    }
                    for (key, destination) in [
                        ("caret", "editorCursor.foreground"),
                        ("selection", "editor.selectionBackground"),
                        ("selectionForeground", "editor.selectionForeground"),
                        ("lineHighlight", "editor.lineHighlightBackground"),
                        ("gutter", "editorGutter.background"),
                        ("gutterForeground", "editorLineNumber.foreground"),
                    ] {
                        if let Some(value) = settings.get(key) {
                            result.colors.insert(destination.into(), color(value)?);
                        }
                    }
                }
                result.rules.push(TokenRule { scopes, style });
            }
        }
        result.colors.extend(explicit);
        result.bounds()?;
        Ok(result)
    }
    fn bounds(&self) -> Result<(), Error> {
        if self.colors.len() > MAX_ITEMS || self.rules.len() > MAX_ITEMS {
            Err(Error::TooComplex)
        } else {
            Ok(())
        }
    }
    fn merge(&mut self, other: Self) -> Result<(), Error> {
        if other.name.is_some() {
            self.name = other.name;
        }
        if other.appearance.is_some() {
            self.appearance = other.appearance;
        }
        self.colors.extend(other.colors);
        self.rules.extend(other.rules);
        self.bounds()
    }
    fn theme(self, fallback: &str, id: &str, imported: bool) -> Result<Theme, Error> {
        self.bounds()?;
        let prefixes = [
            "editor.",
            "editorCursor.",
            "editorGutter.",
            "editorLineNumber.",
            "editorError.",
            "editorWarning.",
            "editorInfo.",
            "editorSuggestWidget.",
        ];
        if !self
            .colors
            .keys()
            .any(|key| prefixes.iter().any(|prefix| key.starts_with(prefix)))
            && !self
                .rules
                .iter()
                .any(|rule| rule.style != TokenStyle::default())
        {
            return Err(Error::InvalidFormat);
        }
        let appearance = self.appearance.unwrap_or_else(|| {
            if self
                .colors
                .get("editor.background")
                .is_some_and(|color| brightness(*color) > 0.5)
            {
                Scheme::Light
            } else {
                Scheme::Dark
            }
        });
        let name = self
            .name
            .filter(|name| !name.is_empty())
            .unwrap_or_else(|| title(fallback));
        let theme = Theme {
            id: id.into(),
            name: if name.is_empty() {
                "Imported Theme".into()
            } else {
                name
            },
            appearance,
            colors: self.colors,
            token_rules: self.rules,
            is_imported: imported,
        };
        if !theme.is_valid() {
            return Err(Error::TooComplex);
        }
        Ok(theme)
    }
}
pub(super) fn title(value: &str) -> String {
    value
        .chars()
        .filter(|ch| !ch.is_control())
        .take(120)
        .collect::<String>()
        .trim()
        .into()
}
pub(super) fn brightness(color: Color) -> f64 {
    color.red * 0.2126 + color.green * 0.7152 + color.blue * 0.0722
}
fn color(value: &Value) -> Result<Color, Error> {
    value
        .as_str()
        .and_then(Color::hex)
        .ok_or(Error::InvalidColor)
}

fn object(data: &[u8]) -> Result<Map<String, Value>, Error> {
    if data.len() > MAX_FILE_BYTES {
        return Err(Error::TooLarge);
    }
    let value = if data.starts_with(b"bplist") {
        plist_object(data)?
    } else {
        let text = std::str::from_utf8(data).map_err(|_| Error::InvalidFormat)?;
        if text.trim_start().starts_with('<') {
            let text = sanitize_plist_xml(text)?;
            plist_object(text.as_bytes())?
        } else {
            serde_json::from_slice(&strip_jsonc(data)?).map_err(|_| Error::InvalidFormat)?
        }
    };
    value.as_object().cloned().ok_or(Error::InvalidFormat)
}
fn sanitize_plist_xml(text: &str) -> Result<String, Error> {
    let mut text = text.to_owned();
    if text.to_ascii_uppercase().contains("<!ENTITY") {
        return Err(Error::InvalidFormat);
    }
    loop {
        let upper = text.to_ascii_uppercase();
        let Some(start) = upper.find("<!DOCTYPE") else {
            break;
        };
        let end = start + text[start..].find('>').ok_or(Error::InvalidFormat)? + 1;
        let declaration = &text[start..end];
        if declaration.contains('[')
            || !declaration.contains("DTD PLIST 1.0//EN")
            || !declaration.contains("www.apple.com/DTDs/PropertyList-1.0.dtd")
        {
            return Err(Error::InvalidFormat);
        }
        text.replace_range(start..end, "");
    }
    // Mature XML parser validates structure, namespaces and depth before plist conversion.
    checked_xml(&text)?;
    Ok(text)
}
pub(super) fn checked_xml(text: &str) -> Result<roxmltree::Document<'_>, Error> {
    let document = roxmltree::Document::parse_with_options(
        text,
        roxmltree::ParsingOptions {
            allow_dtd: false,
            nodes_limit: 200_000,
            entity_resolver: None,
        },
    )
    .map_err(|_| Error::InvalidFormat)?;
    let mut elements = 0;
    for node in document.descendants().filter(|node| node.is_element()) {
        elements += 1;
        if elements > 100_000
            || node.ancestors().filter(|node| node.is_element()).count() > 32
            || node.tag_name().namespace().is_some()
            || node
                .attributes()
                .any(|attribute| attribute.namespace().is_some())
        {
            return Err(Error::TooComplex);
        }
    }
    Ok(document)
}

fn plist_object(data: &[u8]) -> Result<Value, Error> {
    use plist::stream::{Event, Reader};
    enum Container {
        Array(Vec<Value>),
        Dictionary(Map<String, Value>, Option<String>),
    }
    fn push(stack: &mut [Container], root: &mut Option<Value>, value: Value) -> Result<(), Error> {
        match stack.last_mut() {
            Some(Container::Array(array)) => array.push(value),
            Some(Container::Dictionary(map, key)) => {
                if let Some(key) = key.take() {
                    if map.insert(key, value).is_some() {
                        return Err(Error::InvalidFormat);
                    }
                } else {
                    *key = Some(value.as_str().ok_or(Error::InvalidFormat)?.into());
                }
            }
            None => {
                if root.replace(value).is_some() {
                    return Err(Error::InvalidFormat);
                }
            }
        }
        Ok(())
    }
    let mut stack = Vec::new();
    let mut root = None;
    let mut count = 0;
    let mut expanded_bytes = 0usize;
    for event in Reader::new(Cursor::new(data)) {
        count += 1;
        if count > 100_000 {
            return Err(Error::TooComplex);
        }
        match event.map_err(|_| Error::InvalidFormat)? {
            Event::StartArray(length) | Event::StartDictionary(length)
                if length.is_some_and(|length| length > 50_000) =>
            {
                return Err(Error::TooComplex);
            }
            Event::StartArray(_) => {
                if stack.len() >= 32 {
                    return Err(Error::TooComplex);
                }
                stack.push(Container::Array(Vec::new()));
            }
            Event::StartDictionary(_) => {
                if stack.len() >= 32 {
                    return Err(Error::TooComplex);
                }
                stack.push(Container::Dictionary(Map::new(), None));
            }
            Event::EndCollection => {
                let value = match stack.pop().ok_or(Error::InvalidFormat)? {
                    Container::Array(array) => Value::Array(array),
                    Container::Dictionary(map, None) => Value::Object(map),
                    _ => return Err(Error::InvalidFormat),
                };
                push(&mut stack, &mut root, value)?;
            }
            Event::String(value) => {
                expanded_bytes = expanded_bytes
                    .checked_add(value.len())
                    .ok_or(Error::TooLarge)?;
                if expanded_bytes > MAX_TOTAL_BYTES {
                    return Err(Error::TooLarge);
                }
                push(&mut stack, &mut root, Value::String(value.into_owned()))?;
            }
            Event::Boolean(value) => push(&mut stack, &mut root, Value::Bool(value))?,
            Event::Integer(value) => push(
                &mut stack,
                &mut root,
                value
                    .as_signed()
                    .map(Value::from)
                    .or_else(|| value.as_unsigned().map(Value::from))
                    .ok_or(Error::InvalidFormat)?,
            )?,
            Event::Real(value) => push(
                &mut stack,
                &mut root,
                serde_json::Number::from_f64(value)
                    .map(Value::Number)
                    .ok_or(Error::InvalidFormat)?,
            )?,
            // Unused plist metadata types retain their non-string nature.
            Event::Data(_) | Event::Date(_) | Event::Uid(_) => {
                push(&mut stack, &mut root, Value::Bool(false))?
            }
            _ => return Err(Error::InvalidFormat),
        }
    }
    if !stack.is_empty() {
        return Err(Error::InvalidFormat);
    }
    root.ok_or(Error::InvalidFormat)
}
fn strip_jsonc(data: &[u8]) -> Result<Vec<u8>, Error> {
    let mut result = data.to_vec();
    let mut index = 0;
    let mut string = false;
    let mut escaped = false;
    while index < data.len() {
        let current = data[index];
        if string {
            if escaped {
                escaped = false;
            } else if current == b'\\' {
                escaped = true;
            } else if current == b'"' {
                string = false;
            }
            index += 1;
        } else if current == b'"' {
            string = true;
            index += 1;
        } else if current == b'/' && data.get(index + 1) == Some(&b'/') {
            while index < data.len() && !matches!(data[index], b'\n' | b'\r') {
                result[index] = b' ';
                index += 1;
            }
        } else if current == b'/' && data.get(index + 1) == Some(&b'*') {
            result[index] = b' ';
            result[index + 1] = b' ';
            index += 2;
            let mut closed = false;
            while index + 1 < data.len() {
                if data[index] == b'*' && data[index + 1] == b'/' {
                    result[index] = b' ';
                    result[index + 1] = b' ';
                    index += 2;
                    closed = true;
                    break;
                }
                if !matches!(data[index], b'\n' | b'\r') {
                    result[index] = b' ';
                }
                index += 1;
            }
            if !closed {
                return Err(Error::InvalidFormat);
            }
        } else {
            index += 1;
        }
    }
    if string {
        return Err(Error::InvalidFormat);
    }
    index = 0;
    string = false;
    escaped = false;
    while index < result.len() {
        let current = result[index];
        if string {
            if escaped {
                escaped = false;
            } else if current == b'\\' {
                escaped = true;
            } else if current == b'"' {
                string = false;
            }
        } else if current == b'"' {
            string = true;
        } else if current == b',' {
            let mut next = index + 1;
            while result.get(next).is_some_and(u8::is_ascii_whitespace) {
                next += 1;
            }
            if result
                .get(next)
                .is_some_and(|byte| matches!(byte, b']' | b'}'))
            {
                result[index] = b' ';
            }
        }
        index += 1;
    }
    Ok(result)
}
