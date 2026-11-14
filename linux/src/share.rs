//! Share targets. Linux has no system share sheet, so iShot offers the messaging apps that are
//! actually installed (native package, Snap or Flatpak), plus "Other App…" and e-mail.
//!
//! - Telegram Desktop receives the file directly (`-sendpath`) and asks for the chat.
//! - Mattermost Desktop cannot receive files from other apps: the image is copied, Mattermost
//!   comes to the front and a notification says to paste it with Ctrl+V.
//! - WhatsApp has no official Linux app; unofficial clients (ZapZap, WasIstLos/WhatsApp for
//!   Linux, Whatsie) work like Mattermost. Without one, no WhatsApp entry is shown.

use crate::shot::Shot;
use crate::util;
use gtk::gio;

#[derive(Clone, Debug)]
pub enum Delivery {
    /// The command receives the file path as its last argument.
    SendFile(Vec<String>),
    /// Launch the app; the image goes on the clipboard.
    Paste(Vec<String>),
    OtherApp,
    Email,
}

#[derive(Clone, Debug)]
pub struct Target {
    pub title: String,
    pub delivery: Delivery,
}

fn flatpak_apps() -> Vec<String> {
    if !util::has_program("flatpak") {
        return vec![];
    }
    std::process::Command::new("flatpak")
        .args(["list", "--app", "--columns=application"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).lines().map(|l| l.trim().to_string()).collect())
        .unwrap_or_default()
}

/// First available way to run an app: a program in PATH, an absolute path, or a Flatpak id.
fn find(programs: &[&str], paths: &[&str], flatpaks: &[&str], installed_flatpaks: &[String]) -> Option<Vec<String>> {
    if let Some(p) = programs.iter().find(|p| util::has_program(p)) {
        return Some(vec![p.to_string()]);
    }
    if let Some(p) = paths.iter().find(|p| std::path::Path::new(p).exists()) {
        return Some(vec![p.to_string()]);
    }
    flatpaks
        .iter()
        .find(|id| installed_flatpaks.iter().any(|i| i == *id))
        .map(|id| vec!["flatpak".into(), "run".into(), id.to_string()])
}

pub fn targets() -> Vec<Target> {
    let flatpaks = flatpak_apps();
    let mut out = Vec::new();
    if let Some(mut cmd) = find(&["whatsapp", "zapzap", "wasistlos", "whatsapp-for-linux", "whatsie"], &[], &["com.rtosta.zapzap", "io.github.xeco23.WasIstLos", "com.github.eneshecan.WhatsAppForLinux"], &flatpaks) {
        cmd.shrink_to_fit();
        out.push(Target { title: "WhatsApp".into(), delivery: Delivery::Paste(cmd) });
    }
    if let Some(mut cmd) = find(&["telegram-desktop", "Telegram", "telegram"], &["/opt/telegram/Telegram"], &["org.telegram.desktop"], &flatpaks) {
        cmd.push("-sendpath".into());
        out.push(Target { title: "Telegram".into(), delivery: Delivery::SendFile(cmd) });
    }
    if let Some(cmd) = find(&["mattermost-desktop"], &["/opt/Mattermost/mattermost-desktop"], &["com.mattermost.Desktop"], &flatpaks) {
        out.push(Target { title: "Mattermost".into(), delivery: Delivery::Paste(cmd) });
    }
    out.push(Target { title: "Other App…".into(), delivery: Delivery::OtherApp });
    if util::has_program("xdg-email") {
        out.push(Target { title: "E-mail…".into(), delivery: Delivery::Email });
    }
    out
}

pub fn share(target: &Target, shot: &Shot, parent: Option<&gtk::Window>) {
    // Every target also gets the image on the clipboard as a fallback.
    util::copy_image(shot);
    let file = match util::temp_png(shot, "iShot") {
        Ok(f) => f,
        Err(err) => {
            util::alert(parent, "Could not prepare the image", &err);
            return;
        }
    };
    let path = file.to_string_lossy().to_string();
    let run = |cmd: &[String], extra: Option<&str>| {
        let mut args: Vec<&str> = cmd[1..].iter().map(String::as_str).collect();
        if let Some(e) = extra {
            args.push(e);
        }
        util::spawn_detached(&cmd[0], &args)
    };
    let result = match &target.delivery {
        Delivery::SendFile(cmd) => run(cmd, Some(&path)),
        Delivery::Paste(cmd) => run(cmd, None).map(|_| {
            util::notify("Image copied", &format!("Open a {} chat or channel and press Ctrl+V.", target.title));
        }),
        Delivery::Email => util::spawn_detached("xdg-email", &["--attach", &path]),
        Delivery::OtherApp => {
            let launcher = gtk::FileLauncher::new(Some(&gio::File::for_path(&file)));
            launcher.set_always_ask(true);
            launcher.launch(parent, gio::Cancellable::NONE, |_| {});
            Ok(())
        }
    };
    if let Err(err) = result {
        util::alert(parent, &format!("Could not open {}", target.title), &format!("{err}\n\nThe image is on the clipboard: paste it with Ctrl+V."));
    }
}
