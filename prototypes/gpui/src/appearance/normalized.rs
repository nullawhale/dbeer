//! Swift EditorTheme-compatible normalized values; source parsers belong to Task 27.
use gpui_kit::{
    FontStyle, FontWeight, HighlightStyle, Hsla, StrikethroughStyle, UnderlineStyle, px,
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Scheme {
    Light,
    Dark,
}
impl Scheme {
    pub fn is_dark(self) -> bool {
        self == Self::Dark
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Color {
    pub red: f64,
    pub green: f64,
    pub blue: f64,
    pub alpha: f64,
}
impl Color {
    pub const BLACK: Self = Self {
        red: 0.,
        green: 0.,
        blue: 0.,
        alpha: 1.,
    };
    pub const WHITE: Self = Self {
        red: 1.,
        green: 1.,
        blue: 1.,
        alpha: 1.,
    };
    pub fn hex(hex: &str) -> Option<Self> {
        let digits = hex.strip_prefix('#')?;
        if !matches!(digits.len(), 3 | 4 | 6 | 8)
            || !digits.bytes().all(|byte| byte.is_ascii_hexdigit())
        {
            return None;
        }
        let value = u32::from_str_radix(digits, 16).ok()?;
        let (bits, alpha) = if digits.len() <= 4 {
            (4, digits.len() == 4)
        } else {
            (8, digits.len() == 8)
        };
        let mask = (1 << bits) - 1;
        let shift = if alpha { bits } else { 0 };
        Some(Self {
            red: ((value >> (2 * bits + shift)) & mask) as f64 / mask as f64,
            green: ((value >> (bits + shift)) & mask) as f64 / mask as f64,
            blue: ((value >> shift) & mask) as f64 / mask as f64,
            alpha: if alpha {
                (value & mask) as f64 / mask as f64
            } else {
                1.
            },
        })
    }
    pub fn is_valid(self) -> bool {
        [self.red, self.green, self.blue, self.alpha]
            .into_iter()
            .all(|value| value.is_finite() && (0. ..=1.).contains(&value))
    }
    /// Application surfaces use the Swift opaque-background composition rule.
    pub fn over(self, background: Self) -> Self {
        Self {
            red: self.red * self.alpha + background.red * (1. - self.alpha),
            green: self.green * self.alpha + background.green * (1. - self.alpha),
            blue: self.blue * self.alpha + background.blue * (1. - self.alpha),
            alpha: 1.,
        }
    }
    pub fn mix(self, other: Self, fraction: f64) -> Self {
        Self {
            red: self.red + (other.red - self.red) * fraction,
            green: self.green + (other.green - self.green) * fraction,
            blue: self.blue + (other.blue - self.blue) * fraction,
            alpha: 1.,
        }
    }
    pub fn contrast(self, other: Self) -> f64 {
        fn luminance(color: Color) -> f64 {
            fn channel(v: f64) -> f64 {
                if v <= 0.04045 {
                    v / 12.92
                } else {
                    ((v + 0.055) / 1.055).powf(2.4)
                }
            }
            channel(color.red) * 0.2126
                + channel(color.green) * 0.7152
                + channel(color.blue) * 0.0722
        }
        let a = luminance(self);
        let b = luminance(other);
        (a.max(b) + 0.05) / (a.min(b) + 0.05)
    }
    pub fn readable(self, surfaces: &[Self], minimum: f64) -> Self {
        let score = |color: Self| {
            surfaces
                .iter()
                .map(|surface| color.contrast(*surface))
                .fold(21., f64::min)
        };
        if score(self) >= minimum {
            return self;
        }
        let endpoint = if score(Self::BLACK) > score(Self::WHITE) {
            Self::BLACK
        } else {
            Self::WHITE
        };
        if score(endpoint) < minimum {
            return endpoint;
        }
        let (mut low, mut high) = (0., 1.);
        for _ in 0..20 {
            let fraction = (low + high) / 2.;
            if score(self.mix(endpoint, fraction)) < minimum {
                low = fraction;
            } else {
                high = fraction;
            }
        }
        self.mix(endpoint, high)
    }
    pub fn hsla(self) -> Hsla {
        gpui_kit::Rgba {
            r: self.red as f32,
            g: self.green as f32,
            b: self.blue as f32,
            a: self.alpha as f32,
        }
        .into()
    }
}
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TokenStyle {
    pub foreground: Option<Color>,
    pub background: Option<Color>,
    /// None inherits; Some("") explicitly clears inherited traits.
    pub font_style: Option<String>,
}
impl TokenStyle {
    fn overlay(&mut self, other: &Self) {
        if other.foreground.is_some() {
            self.foreground = other.foreground;
        }
        if other.background.is_some() {
            self.background = other.background;
        }
        if other.font_style.is_some() {
            self.font_style.clone_from(&other.font_style);
        }
    }
    pub fn highlight(&self) -> HighlightStyle {
        let has = |word| {
            self.font_style
                .as_deref()
                .unwrap_or("")
                .split_whitespace()
                .any(|part| part == word)
        };
        HighlightStyle {
            color: self.foreground.map(Color::hsla),
            background_color: self.background.map(Color::hsla),
            font_weight: self.font_style.as_ref().map(|_| {
                if has("bold") {
                    FontWeight::BOLD
                } else {
                    FontWeight::NORMAL
                }
            }),
            font_style: self.font_style.as_ref().map(|_| {
                if has("italic") {
                    FontStyle::Italic
                } else {
                    FontStyle::Normal
                }
            }),
            underline: has("underline").then_some(UnderlineStyle {
                thickness: px(1.),
                color: None,
                wavy: false,
            }),
            strikethrough: has("strikethrough").then_some(StrikethroughStyle {
                thickness: px(1.),
                color: None,
            }),
            ..Default::default()
        }
    }
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TokenRule {
    pub scopes: Vec<String>,
    pub style: TokenStyle,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Theme {
    pub id: String,
    pub name: String,
    pub appearance: Scheme,
    pub colors: BTreeMap<String, Color>,
    pub token_rules: Vec<TokenRule>,
    pub is_imported: bool,
}
impl Theme {
    pub fn is_valid(&self) -> bool {
        !self.id.is_empty()
            && self.id.len() <= 256
            && !self.id.chars().any(char::is_control)
            && !self.name.is_empty()
            && self.name.chars().count() <= 120
            && !self.name.chars().any(char::is_control)
            && self.colors.len() <= 10_000
            && self.token_rules.len() <= 10_000
            && self
                .colors
                .iter()
                .all(|(key, color)| key.len() <= 1024 && color.is_valid())
            && self.token_rules.iter().all(|rule| {
                rule.scopes.len() <= 1024
                    && rule.scopes.iter().all(|scope| scope.len() <= 4096)
                    && rule.style.foreground.is_none_or(Color::is_valid)
                    && rule.style.background.is_none_or(Color::is_valid)
                    && rule
                        .style
                        .font_style
                        .as_ref()
                        .is_none_or(|style| style.len() <= 1024)
            })
    }
    pub fn style(&self, scopes: &[&str]) -> TokenStyle {
        let mut matches: Vec<_> = self
            .token_rules
            .iter()
            .enumerate()
            .filter_map(|(order, rule)| {
                let score = if rule.scopes.is_empty() {
                    Some(0)
                } else {
                    rule.scopes
                        .iter()
                        .flat_map(|selector| selector.split(','))
                        .filter_map(|selector| match_score(selector.trim(), scopes))
                        .max()
                }?;
                Some((score, order, &rule.style))
            })
            .collect();
        matches.sort_by_key(|(score, order, _)| (*score, *order));
        let mut result = TokenStyle::default();
        for (_, _, style) in matches {
            result.overlay(style);
        }
        result
    }
    /// Exact built-in DBeer editor colors, independent of a Mac bundle/build.
    /// Task 27 supplies the complete asset library and notices.
    pub fn native(appearance: Scheme) -> Self {
        let dark = appearance.is_dark();
        let pairs = if dark {
            [
                ("editor.background", "#1E1E1E"),
                ("editor.foreground", "#FFFFFFD9"),
                ("editorCursor.foreground", "#FFFFFF"),
                ("editor.selectionBackground", "#3F638B"),
                ("editor.selectionForeground", "#FFFFFF"),
                ("editor.inactiveSelectionBackground", "#4B4B4B"),
                ("editor.lineHighlightBackground", "#FFFFFF05"),
                ("editorGutter.background", "#252525"),
                ("editorLineNumber.foreground", "#98989D"),
                ("editorLineNumber.activeForeground", "#FFFFFFD9"),
                ("editorError.foreground", "#FF453A"),
                ("editorWarning.foreground", "#FF9F0A"),
                ("editorInfo.foreground", "#0A84FF"),
                ("editorSuggestWidget.background", "#282828"),
                ("editorSuggestWidget.foreground", "#FFFFFFD9"),
                ("editorSuggestWidget.highlightForeground", "#0A84FF"),
                ("editorSuggestWidget.focusHighlightForeground", "#8CC8FF"),
                ("editorSuggestWidget.selectedBackground", "#34516F"),
                ("editorSuggestWidget.selectedForeground", "#FFFFFF"),
                ("editorSuggestWidget.border", "#555555"),
            ]
        } else {
            [
                ("editor.background", "#FFFFFF"),
                ("editor.foreground", "#000000D9"),
                ("editorCursor.foreground", "#000000"),
                ("editor.selectionBackground", "#B2D7FF"),
                ("editor.selectionForeground", "#000000"),
                ("editor.inactiveSelectionBackground", "#DCDCDC"),
                ("editor.lineHighlightBackground", "#00000005"),
                ("editorGutter.background", "#F5F5F5"),
                ("editorLineNumber.foreground", "#6C6C70"),
                ("editorLineNumber.activeForeground", "#000000D9"),
                ("editorError.foreground", "#FF3B30"),
                ("editorWarning.foreground", "#FF9500"),
                ("editorInfo.foreground", "#007AFF"),
                ("editorSuggestWidget.background", "#FFFFFF"),
                ("editorSuggestWidget.foreground", "#000000D9"),
                ("editorSuggestWidget.highlightForeground", "#007AFF"),
                ("editorSuggestWidget.focusHighlightForeground", "#005BB5"),
                ("editorSuggestWidget.selectedBackground", "#CBE4FF"),
                ("editorSuggestWidget.selectedForeground", "#000000"),
                ("editorSuggestWidget.border", "#C6C6C6"),
            ]
        };
        let token_colors = if dark {
            ["#C799F2", "#8CC27D", "#7AB3F5", "#98989D"]
        } else {
            ["#6E38A6", "#296E45", "#1757AD", "#6C6C70"]
        };
        Self {
            id: if dark { "native-dark" } else { "native-light" }.into(),
            name: if dark { "DBeer Dark" } else { "DBeer Light" }.into(),
            appearance,
            colors: pairs
                .into_iter()
                .map(|(key, color)| (key.into(), Color::hex(color).unwrap()))
                .collect(),
            token_rules: ["keyword", "string", "constant.numeric", "comment"]
                .into_iter()
                .zip(token_colors)
                .map(|(scope, color)| TokenRule {
                    scopes: vec![scope.into()],
                    style: TokenStyle {
                        foreground: Color::hex(color),
                        ..Default::default()
                    },
                })
                .collect(),
            is_imported: false,
        }
    }
}
fn match_score(selector: &str, scopes: &[&str]) -> Option<usize> {
    if selector.contains(['(', ')', '|', '&', '>']) {
        return None;
    }
    let mut exclusions = selector.split(" - ");
    let positive = exclusions.next()?;
    if exclusions.any(|excluded| chain_score(excluded, scopes).is_some()) {
        return None;
    }
    chain_score(positive, scopes)
}
fn chain_score(selector: &str, scopes: &[&str]) -> Option<usize> {
    let selector = selector
        .trim()
        .strip_prefix("L:")
        .or_else(|| selector.trim().strip_prefix("R:"))
        .unwrap_or(selector.trim());
    let components: Vec<_> = selector.split_whitespace().collect();
    if components.is_empty() {
        return None;
    }
    let mut stack_index = scopes.len();
    let mut score = 0;
    for (component_index, component) in components.iter().enumerate().rev() {
        loop {
            stack_index = stack_index.checked_sub(1)?;
            if *component == "*"
                || scopes[stack_index] == *component
                || scopes[stack_index]
                    .strip_prefix(*component)
                    .is_some_and(|suffix| suffix.starts_with('.'))
            {
                break;
            }
        }
        score += if component_index == components.len() - 1 {
            (stack_index + 1) * 1_000_000 + component.split('.').count() * 10_000
        } else {
            component.split('.').count() * 100 + stack_index
        };
    }
    Some(score)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn short_long_alpha_hex_and_composition_match_swift() {
        assert_eq!(Color::hex("#f008"), Color::hex("#ff000088"));
        assert_eq!(Color::hex("#fff"), Some(Color::WHITE));
        for invalid in ["ffffff", "#12", "#gggggg", "#12345", "#123456789"] {
            assert!(Color::hex(invalid).is_none());
        }
        let mixed = Color::hex("#00000080").unwrap().over(Color::WHITE);
        assert!((mixed.red - 127. / 255.).abs() < 1e-12);
        assert_eq!(mixed.alpha, 1.);
        assert_eq!(Color::hex("#ffffff80").unwrap().hsla().a, 128. / 255.);
    }
    #[test]
    fn scope_precedence_exclusion_partial_inheritance_and_font_reset() {
        let color = Color::hex("#aabbcc").unwrap();
        let rule = |scopes: &[&str], style| TokenRule {
            scopes: scopes.iter().map(|scope| (*scope).into()).collect(),
            style,
        };
        let mut theme = Theme::native(Scheme::Dark);
        theme.token_rules = vec![
            rule(
                &[],
                TokenStyle {
                    foreground: Some(color),
                    font_style: Some("bold italic".into()),
                    ..Default::default()
                },
            ),
            rule(
                &["keyword"],
                TokenStyle {
                    background: Color::hex("#ff000080"),
                    ..Default::default()
                },
            ),
            rule(
                &["source.sql keyword.control"],
                TokenStyle {
                    font_style: Some(String::new()),
                    ..Default::default()
                },
            ),
            rule(
                &["keyword - keyword.control"],
                TokenStyle {
                    foreground: Some(Color::BLACK),
                    ..Default::default()
                },
            ),
            rule(
                &["(keyword | string)"],
                TokenStyle {
                    foreground: Some(Color::WHITE),
                    ..Default::default()
                },
            ),
        ];
        let style = theme.style(&["source.sql", "keyword.control.sql"]);
        assert_eq!(style.foreground, Some(color));
        assert_eq!(style.background, Color::hex("#ff000080"));
        assert_eq!(style.font_style.as_deref(), Some(""));
        assert_eq!(style.highlight().font_weight, Some(FontWeight::NORMAL));
        assert_eq!(
            theme.style(&["source.sql", "keyword.other.sql"]).foreground,
            Some(Color::BLACK)
        );
        theme.token_rules.push(rule(
            &["keyword.control"],
            TokenStyle {
                foreground: Some(Color::WHITE),
                ..Default::default()
            },
        ));
        theme.token_rules.push(rule(
            &["keyword.control"],
            TokenStyle {
                foreground: Some(Color::BLACK),
                ..Default::default()
            },
        ));
        assert_eq!(
            theme.style(&["keyword.control.sql"]).foreground,
            Some(Color::BLACK)
        );
    }
    #[test]
    fn normalized_fixture_roundtrips_and_rejects_invalid_channels() {
        let theme: Theme =
            serde_json::from_str(include_str!("../../fixtures/appearance/normalized.json"))
                .unwrap();
        assert!(theme.is_valid());
        assert_eq!(
            serde_json::from_slice::<Theme>(&serde_json::to_vec(&theme).unwrap()).unwrap(),
            theme
        );
        let mut invalid = theme;
        invalid.colors.insert(
            "editor.background".into(),
            Color {
                alpha: f64::NAN,
                ..Color::BLACK
            },
        );
        assert!(!invalid.is_valid());
    }
}
