//! User settings, stored as TOML in `~/.config/ishot/config.toml`.

use gtk::glib;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ImageFormat {
    Png,
    Jpg,
}

impl ImageFormat {
    pub fn ext(self) -> &'static str {
        match self {
            ImageFormat::Png => "png",
            ImageFormat::Jpg => "jpg",
        }
    }
}

/// Actions that have a global keyboard shortcut.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ShortcutAction {
    Region,
    Fullscreen,
    Record,
}

impl ShortcutAction {
    pub const ALL: [ShortcutAction; 3] = [ShortcutAction::Region, ShortcutAction::Fullscreen, ShortcutAction::Record];

    pub fn title(self) -> &'static str {
        match self {
            ShortcutAction::Region => "Capture Region",
            ShortcutAction::Fullscreen => "Capture Fullscreen",
            ShortcutAction::Record => "Record Screen",
        }
    }

    pub fn id(self) -> &'static str {
        match self {
            ShortcutAction::Region => "region",
            ShortcutAction::Fullscreen => "fullscreen",
            ShortcutAction::Record => "record",
        }
    }

    pub fn cli_flag(self) -> &'static str {
        match self {
            ShortcutAction::Region => "--region",
            ShortcutAction::Fullscreen => "--fullscreen",
            ShortcutAction::Record => "--record",
        }
    }

    /// GTK accelerator syntax.
    pub fn default_accel(self) -> &'static str {
        match self {
            ShortcutAction::Region => "<Alt><Shift>a",
            ShortcutAction::Fullscreen => "<Alt><Shift>f",
            ShortcutAction::Record => "<Alt><Shift>r",
        }
    }

    /// Capture Region always keeps a shortcut; the others can be turned off.
    pub fn can_be_turned_off(self) -> bool {
        self != ShortcutAction::Region
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub save_dir: String,
    pub format: ImageFormat,
    pub file_name_prefix: String,
    /// GTK accelerators; an empty string means "turned off".
    pub region_shortcut: String,
    pub fullscreen_shortcut: String,
    pub record_shortcut: String,
    pub launch_at_login: bool,
    pub check_for_updates: bool,
    pub skipped_version: Option<String>,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            save_dir: default_save_dir().to_string_lossy().into_owned(),
            format: ImageFormat::Png,
            file_name_prefix: "iShot".into(),
            region_shortcut: ShortcutAction::Region.default_accel().into(),
            fullscreen_shortcut: ShortcutAction::Fullscreen.default_accel().into(),
            record_shortcut: ShortcutAction::Record.default_accel().into(),
            launch_at_login: false,
            check_for_updates: true,
            skipped_version: None,
        }
    }
}

pub fn default_save_dir() -> PathBuf {
    let pictures = glib::user_special_dir(glib::UserDirectory::Pictures)
        .unwrap_or_else(|| glib::home_dir().join("Pictures"));
    pictures.join("Screenshots")
}

fn config_path() -> PathBuf {
    glib::user_config_dir().join("ishot").join("config.toml")
}

impl Settings {
    pub fn load() -> Settings {
        std::fs::read_to_string(config_path())
            .ok()
            .and_then(|text| toml::from_str(&text).ok())
            .unwrap_or_default()
    }

    pub fn save(&self) {
        let path = config_path();
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        match toml::to_string_pretty(self) {
            Ok(text) => {
                if let Err(err) = std::fs::write(&path, text) {
                    crate::logln!("cannot write {}: {err}", path.display());
                }
            }
            Err(err) => crate::logln!("cannot serialize settings: {err}"),
        }
    }

    pub fn save_dir_path(&self) -> PathBuf {
        let raw = self.save_dir.trim();
        if raw.is_empty() {
            return default_save_dir();
        }
        if let Some(rest) = raw.strip_prefix("~/") {
            return glib::home_dir().join(rest);
        }
        PathBuf::from(raw)
    }

    pub fn prefix(&self) -> String {
        let p = self.file_name_prefix.trim();
        if p.is_empty() { "iShot".into() } else { p.into() }
    }

    pub fn shortcut(&self, action: ShortcutAction) -> Option<String> {
        let value = match action {
            ShortcutAction::Region => &self.region_shortcut,
            ShortcutAction::Fullscreen => &self.fullscreen_shortcut,
            ShortcutAction::Record => &self.record_shortcut,
        };
        let value = value.trim();
        if value.is_empty() {
            // Region can never be off: fall back to its default.
            (action == ShortcutAction::Region).then(|| action.default_accel().to_string())
        } else {
            Some(value.to_string())
        }
    }

    pub fn set_shortcut(&mut self, action: ShortcutAction, accel: Option<String>) {
        let value = accel.unwrap_or_default();
        match action {
            ShortcutAction::Region => {
                if !value.is_empty() {
                    self.region_shortcut = value
                }
            }
            ShortcutAction::Fullscreen => self.fullscreen_shortcut = value,
            ShortcutAction::Record => self.record_shortcut = value,
        }
    }

    /// The other action already using `accel`, if any.
    pub fn action_using(&self, accel: &str, except: ShortcutAction) -> Option<ShortcutAction> {
        let wanted = crate::util::normalize_accel(accel);
        ShortcutAction::ALL.into_iter().find(|&a| {
            a != except && self.shortcut(a).map(|s| crate::util::normalize_accel(&s)) == Some(wanted.clone())
        })
    }
}

/// Writes or removes `~/.config/autostart/<app id>.desktop`.
pub fn apply_launch_at_login(enabled: bool) -> std::io::Result<()> {
    let dir = glib::user_config_dir().join("autostart");
    let path = dir.join(format!("{}.desktop", crate::APP_ID));
    if enabled {
        std::fs::create_dir_all(&dir)?;
        std::fs::write(
            &path,
            "[Desktop Entry]\nType=Application\nName=iShot\nComment=Screenshot tool\n\
             Exec=ishot --background\nIcon=io.github.abi0ne.iShot\nTerminal=false\n\
             X-GNOME-Autostart-enabled=true\n",
        )
    } else {
        match std::fs::remove_file(&path) {
            Err(err) if err.kind() != std::io::ErrorKind::NotFound => Err(err),
            _ => Ok(()),
        }
    }
}
