//! IntelliJ exported editor schemes only; no IDE theme plugins or executable extensions.
use super::{
    Error, Theme, assets,
    parser::{MAX_FILE_BYTES, brightness, checked_xml, title},
};
use crate::appearance::{Color, Scheme as Appearance, TokenRule, TokenStyle};
use std::collections::{BTreeMap, HashSet};

#[derive(Clone, Default)]
struct Attribute {
    base: Option<String>,
    has_value: bool,
    values: BTreeMap<String, String>,
}
#[derive(Default)]
struct Scheme {
    name: Option<String>,
    parent: Option<String>,
    colors: BTreeMap<String, String>,
    attributes: BTreeMap<String, Attribute>,
}
pub(super) fn parse(data: &[u8], name: &str, id: &str, imported: bool) -> Result<Theme, Error> {
    let scheme = read(data)?;
    if scheme.parent.is_none() && scheme.colors.is_empty() && scheme.attributes.is_empty() {
        return Err(Error::InvalidFormat);
    }
    let mut inherited = parent(scheme.parent.as_deref(), &mut HashSet::new())?;
    inherited.merge(scheme);
    inherited.theme(name, id, imported)
}
fn parent(name: Option<&str>, active: &mut HashSet<String>) -> Result<Scheme, Error> {
    let Some(name) = name.filter(|name| !name.is_empty()) else {
        return Ok(Scheme::default());
    };
    if active.len() >= 8 || !active.insert(name.into()) {
        return Err(Error::ReferenceCycle);
    }
    let source = match name {
        "Default" => "jetbrains-default.icls",
        "Darcula" => "jetbrains-darcula.icls",
        _ => return Err(Error::UnsupportedParent),
    };
    let scheme = read(assets::source(source).ok_or(Error::Unreadable)?)?;
    let mut inherited = parent(scheme.parent.as_deref(), active)?;
    inherited.merge(scheme);
    active.remove(name);
    Ok(inherited)
}
fn read(data: &[u8]) -> Result<Scheme, Error> {
    if data.len() > MAX_FILE_BYTES {
        return Err(Error::TooLarge);
    }
    let text = std::str::from_utf8(data).map_err(|_| Error::InvalidFormat)?;
    let upper = text.to_ascii_uppercase();
    if upper.contains("<!DOCTYPE") || upper.contains("<!ENTITY") {
        return Err(Error::InvalidFormat);
    }
    let document = checked_xml(text)?;
    if document
        .descendants()
        .filter(|node| node.is_element())
        .count()
        >= 20_000
    {
        return Err(Error::TooComplex);
    }
    let root = document.root_element();
    if root.tag_name().name() != "scheme" {
        return Err(Error::InvalidFormat);
    }
    let mut scheme = Scheme {
        name: root.attribute("name").map(str::to_owned),
        parent: root.attribute("parent_scheme").map(str::to_owned),
        ..Default::default()
    };
    for child in root.children().filter(|node| node.is_element()) {
        match child.tag_name().name() {
            "colors" => {
                for option in child.children().filter(|node| node.has_tag_name("option")) {
                    if let Some(name) = option.attribute("name") {
                        scheme
                            .colors
                            .insert(name.into(), option.attribute("value").unwrap_or("").into());
                    }
                }
            }
            "attributes" => {
                for option in child.children().filter(|node| node.has_tag_name("option")) {
                    let Some(name) = option.attribute("name") else {
                        continue;
                    };
                    let mut attribute = Attribute {
                        base: option.attribute("baseAttributes").map(str::to_owned),
                        ..Default::default()
                    };
                    if let Some(value) = option.children().find(|node| node.has_tag_name("value")) {
                        attribute.has_value = true;
                        for field in value.children().filter(|node| node.has_tag_name("option")) {
                            if let Some(key) = field.attribute("name") {
                                attribute.values.insert(
                                    key.into(),
                                    field.attribute("value").unwrap_or("").into(),
                                );
                            }
                        }
                    }
                    if attribute.has_value || attribute.base.is_some() {
                        scheme.attributes.insert(name.into(), attribute);
                    }
                }
            }
            _ => {}
        }
    }
    if scheme.colors.len() > 10_000 || scheme.attributes.len() > 10_000 {
        return Err(Error::TooComplex);
    }
    Ok(scheme)
}
impl Scheme {
    fn merge(&mut self, other: Self) {
        if other.name.is_some() {
            self.name = other.name;
        }
        self.colors.extend(other.colors);
        self.attributes.extend(other.attributes);
    }
    fn style(&self, key: &str, active: &mut HashSet<String>) -> Result<Option<TokenStyle>, Error> {
        let Some(attribute) = self.attributes.get(key) else {
            return Ok(None);
        };
        if active.len() >= 32 || !active.insert(key.into()) {
            return Err(Error::ReferenceCycle);
        }
        if !attribute.has_value
            && let Some(base) = &attribute.base
        {
            return self.style(base, active);
        }
        let mut style = TokenStyle::default();
        if let Some(raw) = attribute
            .values
            .get("FOREGROUND")
            .filter(|value| !value.is_empty())
        {
            style.foreground = Some(color(raw)?);
        }
        if let Some(raw) = attribute
            .values
            .get("BACKGROUND")
            .filter(|value| !value.is_empty())
        {
            style.background = Some(color(raw)?);
        }
        if attribute.has_value {
            let raw = attribute
                .values
                .get("FONT_TYPE")
                .filter(|value| !value.is_empty())
                .map(String::as_str)
                .unwrap_or("0");
            let font: u8 = raw.parse().map_err(|_| Error::InvalidFormat)?;
            if font > 3 {
                return Err(Error::InvalidFormat);
            }
            let mut traits = Vec::new();
            if font & 1 != 0 {
                traits.push("bold");
            }
            if font & 2 != 0 {
                traits.push("italic");
            }
            if attribute
                .values
                .get("EFFECT_TYPE")
                .is_some_and(|value| value == "1")
            {
                traits.push("underline");
            }
            style.font_style = Some(traits.join(" "));
        }
        Ok(Some(style))
    }
    fn get_style(&self, key: &str) -> Result<Option<TokenStyle>, Error> {
        self.style(key, &mut HashSet::new())
    }
    fn theme(self, fallback: &str, id: &str, imported: bool) -> Result<Theme, Error> {
        let mut colors = BTreeMap::new();
        for (source, destination) in [
            ("CARET_COLOR", "editorCursor.foreground"),
            ("CARET_ROW_COLOR", "editor.lineHighlightBackground"),
            ("SELECTION_BACKGROUND", "editor.selectionBackground"),
            ("SELECTION_FOREGROUND", "editor.selectionForeground"),
            (
                "SELECTION_BACKGROUND_INACTIVE",
                "editor.inactiveSelectionBackground",
            ),
            ("GUTTER_BACKGROUND", "editorGutter.background"),
            ("LINE_NUMBERS_COLOR", "editorLineNumber.foreground"),
            (
                "LINE_NUMBER_ON_CARET_ROW_COLOR",
                "editorLineNumber.activeForeground",
            ),
            ("RIGHT_MARGIN_COLOR", "editorRuler.foreground"),
            ("LOOKUP_COLOR", "editorSuggestWidget.background"),
            (
                "LOOKUP_SELECTION_COLOR",
                "editorSuggestWidget.selectedBackground",
            ),
        ] {
            if let Some(raw) = self.colors.get(source).filter(|value| !value.is_empty()) {
                colors.insert(destination.into(), color(raw)?);
            }
        }
        if let Some(text) = self.get_style("TEXT")? {
            if let Some(color) = text.foreground {
                colors.insert("editor.foreground".into(), color);
            }
            if let Some(color) = text.background {
                colors.insert("editor.background".into(), color);
            }
        }
        colors
            .entry("editor.foreground".into())
            .or_insert(Color::BLACK);
        if !colors.contains_key("editor.background") {
            colors.insert(
                "editor.background".into(),
                self.colors
                    .get("BACKGROUND")
                    .filter(|raw| !raw.is_empty())
                    .map(|raw| color(raw))
                    .transpose()?
                    .unwrap_or(Color::WHITE),
            );
        }
        let mut rules = Vec::new();
        let mapping: &[(&str, &[&str])] = &[
            ("DEFAULT_KEYWORD", &["keyword"]),
            ("DEFAULT_STRING", &["string"]),
            ("DEFAULT_NUMBER", &["constant.numeric"]),
            ("DEFAULT_LINE_COMMENT", &["comment.line"]),
            ("DEFAULT_BLOCK_COMMENT", &["comment.block"]),
            ("DEFAULT_IDENTIFIER", &["variable.other"]),
            ("DEFAULT_OPERATION_SIGN", &["keyword.operator"]),
            ("DEFAULT_FUNCTION_CALL", &["entity.name.function"]),
            ("SQL_KEYWORD", &["keyword.other.sql", "keyword.control.sql"]),
            ("SQL_STRING", &["string.quoted.single.sql"]),
            ("SQL_NUMBER", &["constant.numeric.sql"]),
            (
                "SQL_COMMENT",
                &[
                    "comment.line.sql",
                    "comment.line.double-dash.sql",
                    "comment.block.sql",
                ],
            ),
            (
                "SQL_LINE_COMMENT",
                &["comment.line.sql", "comment.line.double-dash.sql"],
            ),
            ("SQL_BLOCK_COMMENT", &["comment.block.sql"]),
            ("SQL_IDENTIFIER", &["variable.other.sql"]),
            ("SQL_COLUMN", &["variable.other.column.sql"]),
            ("SQL_DATABASE_OBJECT", &["variable.other.object.sql"]),
            ("SQL_FUNCTION", &["entity.name.function.sql"]),
            ("SQL_TYPE", &["storage.type.sql"]),
            ("SQL_OPERATION_SIGN", &["keyword.operator.sql"]),
        ];
        for (key, scopes) in mapping {
            if let Some(mut style) = self.get_style(key)? {
                if style.foreground.is_none() {
                    style.foreground = colors.get("editor.foreground").copied();
                }
                rules.push(TokenRule {
                    scopes: scopes.iter().map(|scope| (*scope).into()).collect(),
                    style,
                });
            }
        }
        for (key, destination) in [
            ("ERRORS_ATTRIBUTES", "editorError.foreground"),
            ("WARNING_ATTRIBUTES", "editorWarning.foreground"),
            ("INFO_ATTRIBUTES", "editorInfo.foreground"),
        ] {
            if let Some(raw) = self
                .attributes
                .get(key)
                .and_then(|attribute| attribute.values.get("EFFECT_COLOR"))
                .filter(|raw| !raw.is_empty())
            {
                colors.insert(destination.into(), color(raw)?);
            }
        }
        let appearance = if brightness(colors["editor.background"]) > 0.5 {
            Appearance::Light
        } else {
            Appearance::Dark
        };
        let requested = title(self.name.as_deref().unwrap_or(fallback));
        let fallback = title(fallback);
        let theme = Theme {
            id: id.into(),
            name: if !requested.is_empty() {
                requested
            } else if !fallback.is_empty() {
                fallback
            } else {
                "Imported Theme".into()
            },
            appearance,
            colors,
            token_rules: rules,
            is_imported: imported,
        };
        if !theme.is_valid() {
            return Err(Error::TooComplex);
        }
        Ok(theme)
    }
}
fn color(raw: &str) -> Result<Color, Error> {
    let raw = raw.strip_prefix('#').unwrap_or(raw);
    if raw.is_empty() || raw.len() > 8 || !raw.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(Error::InvalidColor);
    }
    Color::hex(&if raw.len() <= 6 {
        format!("#{raw:0>6}")
    } else {
        format!("#{raw}")
    })
    .ok_or(Error::InvalidColor)
}
