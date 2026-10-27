use super::{Error, Theme, parser};
use std::path::Path;

/// Source files and their includes are compiled into GPUI independently of Mac resources.
pub(super) fn source(name: &str) -> Option<&'static [u8]> {
    Some(match name {
        "dbeer-light.json" => include_bytes!("../../assets/themes/dbeer-light.json"),
        "dbeer-dark.json" => include_bytes!("../../assets/themes/dbeer-dark.json"),
        "light_plus.json" => include_bytes!("../../assets/themes/light_plus.json"),
        "dark_plus.json" => include_bytes!("../../assets/themes/dark_plus.json"),
        "light_vs.json" => include_bytes!("../../assets/themes/light_vs.json"),
        "dark_vs.json" => include_bytes!("../../assets/themes/dark_vs.json"),
        "solarized-light-color-theme.json" => {
            include_bytes!("../../assets/themes/solarized-light-color-theme.json")
        }
        "solarized-dark-color-theme.json" => {
            include_bytes!("../../assets/themes/solarized-dark-color-theme.json")
        }
        "jetbrains-default.icls" => include_bytes!("../../assets/themes/jetbrains-default.icls"),
        "jetbrains-darcula.icls" => include_bytes!("../../assets/themes/jetbrains-darcula.icls"),
        _ => return None,
    })
}

pub fn builtin_themes() -> Result<Vec<Theme>, Error> {
    let mut themes = Vec::with_capacity(8);
    for (id, file) in [
        ("native-light", "dbeer-light.json"),
        ("native-dark", "dbeer-dark.json"),
        ("vscode-light-plus", "light_plus.json"),
        ("vscode-dark-plus", "dark_plus.json"),
        ("solarized-light", "solarized-light-color-theme.json"),
        ("solarized-dark", "solarized-dark-color-theme.json"),
        ("jetbrains-light", "jetbrains-default.icls"),
        ("jetbrains-darcula", "jetbrains-darcula.icls"),
    ] {
        let mut theme = if file.ends_with(".icls") {
            super::jetbrains::parse(source(file).ok_or(Error::Unreadable)?, file, id, false)?
        } else {
            parser::load_embedded(Path::new(file), id)?
        };
        if id == "jetbrains-light" {
            theme.name = "JetBrains Light".into();
        }
        themes.push(theme);
    }
    Ok(themes)
}
