//! Small helpers shared by the whole app.

use crate::shot::Shot;
use gtk::prelude::*;
use gtk::{gdk, gio, glib};
use std::path::{Path, PathBuf};

/// Canonical form of a GTK accelerator ("<Shift><Alt>A" == "<Alt><Shift>a").
pub fn normalize_accel(accel: &str) -> String {
    match gtk::accelerator_parse(accel) {
        Some((key, mods)) => gtk::accelerator_name(key.to_lower(), mods).to_string(),
        None => accel.to_string(),
    }
}

/// "Alt+Shift+A" style label.
pub fn accel_label(accel: &str) -> String {
    match gtk::accelerator_parse(accel) {
        Some((key, mods)) => gtk::accelerator_get_label(key, mods).to_string(),
        None => accel.to_string(),
    }
}

pub fn file_name(prefix: &str, ext: &str) -> String {
    let stamp = glib::DateTime::now_local()
        .and_then(|d| d.format("%Y%m%d_%H%M%S"))
        .map(|s| s.to_string())
        .unwrap_or_else(|_| "capture".into());
    format!("{prefix}_{stamp}.{ext}")
}

pub fn unique_path(dir: &Path, name: &str) -> PathBuf {
    let candidate = dir.join(name);
    if !candidate.exists() {
        return candidate;
    }
    let (stem, ext) = match name.rsplit_once('.') {
        Some((s, e)) => (s.to_string(), format!(".{e}")),
        None => (name.to_string(), String::new()),
    };
    (2..)
        .map(|n| dir.join(format!("{stem}-{n}{ext}")))
        .find(|p| !p.exists())
        .expect("unique name")
}

pub fn copy_image(shot: &Shot) {
    if let Some(display) = gdk::Display::default() {
        display.clipboard().set_texture(&shot.texture());
    }
}

pub fn copy_text(text: &str) {
    if let Some(display) = gdk::Display::default() {
        display.clipboard().set_text(text);
    }
}

/// Writes the image as a temporary PNG (for apps that receive files).
pub fn temp_png(shot: &Shot, prefix: &str) -> Result<PathBuf, String> {
    let dir = glib::user_runtime_dir().join("ishot");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let path = dir.join(file_name(prefix, "png"));
    std::fs::write(&path, shot.encode_png()?).map_err(|e| e.to_string())?;
    Ok(path)
}

/// Desktop notification (also works with xfce4-notifyd, KDE and GNOME).
pub fn notify(title: &str, body: &str) {
    if let Some(app) = gio::Application::default() {
        let n = gio::Notification::new(title);
        n.set_body(Some(body));
        app.send_notification(None, &n);
    }
}

/// Simple modal message.
pub fn alert(parent: Option<&gtk::Window>, message: &str, detail: &str) {
    crate::logln!("alert: {message} — {}", detail.replace('\n', " "));
    let dialog = gtk::AlertDialog::builder().message(message).detail(detail).modal(true).build();
    dialog.show(parent);
}

/// Opens the folder containing `path` in the file manager.
pub fn reveal(path: &Path, parent: Option<&gtk::Window>) {
    let launcher = gtk::FileLauncher::new(Some(&gio::File::for_path(path)));
    launcher.open_containing_folder(parent, gio::Cancellable::NONE, |_| {});
}

/// Runs a command without waiting for it.
pub fn spawn_detached(program: &str, args: &[&str]) -> Result<(), String> {
    std::process::Command::new(program)
        .args(args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map(|_| ())
        .map_err(|e| format!("{program}: {e}"))
}

pub fn has_program(name: &str) -> bool {
    glib::find_program_in_path(name).is_some()
}
