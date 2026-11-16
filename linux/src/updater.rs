//! Self-updater backed by the GitHub Releases of the project (same releases as the macOS app).
//!
//! A release is an update when its tag (vX.Y.Z) is newer than this build and it carries
//! `ishot_X.Y.Z_<arch>.deb`. The download is checked against the release's `SHA256SUMS`, then
//! installed with `pkexec apt-get install` (the desktop asks for the password) and iShot restarts.

use crate::app::App;
use crate::util;
use gtk::{gio, glib};
use sha2::Digest;
use std::rc::Rc;

pub const REPOSITORY: &str = "Abi0ne/iShot";
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Clone, Debug)]
pub struct Release {
    pub version: String,
    pub notes: String,
    pub page: String,
    pub deb_name: String,
    pub deb_url: String,
    pub sums_url: Option<String>,
}

fn deb_arch() -> &'static str {
    match std::env::consts::ARCH {
        "x86_64" => "amd64",
        "aarch64" => "arm64",
        other => other,
    }
}

/// Only copies installed from the .deb update themselves.
pub fn is_installed_package() -> bool {
    std::env::current_exe().map(|p| p.starts_with("/usr/bin")).unwrap_or(false)
}

pub fn is_newer(a: &str, b: &str) -> bool {
    let parse = |v: &str| v.split('.').map(|p| p.parse::<u64>().unwrap_or(0)).collect::<Vec<_>>();
    let (pa, pb) = (parse(a), parse(b));
    for i in 0..pa.len().max(pb.len()) {
        let (x, y) = (pa.get(i).copied().unwrap_or(0), pb.get(i).copied().unwrap_or(0));
        if x != y {
            return x > y;
        }
    }
    false
}

fn agent() -> ureq::Agent {
    ureq::Agent::config_builder()
        .timeout_global(Some(std::time::Duration::from_secs(60)))
        .user_agent(format!("iShot-Linux/{VERSION}"))
        .build()
        .into()
}

/// Blocking: latest release with a .deb for this architecture, if any.
fn fetch_latest() -> Result<Option<Release>, String> {
    let url = format!("https://api.github.com/repos/{REPOSITORY}/releases/latest");
    let mut response = agent()
        .get(&url)
        .header("Accept", "application/vnd.github+json")
        .call()
        .map_err(|e| match e {
            ureq::Error::StatusCode(404) => "no release yet".to_string(),
            other => other.to_string(),
        })?;
    let json: serde_json::Value = serde_json::from_slice(&response.body_mut().read_to_vec().map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    if json["draft"].as_bool() == Some(true) || json["prerelease"].as_bool() == Some(true) {
        return Ok(None);
    }
    let tag = json["tag_name"].as_str().unwrap_or_default();
    let version = tag.trim_start_matches('v').to_string();
    let assets = json["assets"].as_array().cloned().unwrap_or_default();
    let suffix = format!("_{}.deb", deb_arch());
    let deb = assets.iter().find(|a| a["name"].as_str().map(|n| n.starts_with("ishot_") && n.ends_with(&suffix)).unwrap_or(false));
    let Some(deb) = deb else { return Ok(None) };
    let sums = assets.iter().find(|a| a["name"].as_str() == Some("SHA256SUMS"));
    Ok(Some(Release {
        version,
        notes: json["body"].as_str().unwrap_or_default().to_string(),
        page: json["html_url"].as_str().unwrap_or_default().to_string(),
        deb_name: deb["name"].as_str().unwrap_or_default().to_string(),
        deb_url: deb["browser_download_url"].as_str().unwrap_or_default().to_string(),
        sums_url: sums.and_then(|s| s["browser_download_url"].as_str()).map(String::from),
    }))
}

/// Blocking: downloads and verifies the package, returns its path.
fn download(release: &Release) -> Result<std::path::PathBuf, String> {
    let agent = agent();
    let bytes = agent
        .get(&release.deb_url)
        .call()
        .map_err(|e| e.to_string())?
        .body_mut()
        .with_config()
        .limit(200 * 1024 * 1024)
        .read_to_vec()
        .map_err(|e| e.to_string())?;
    if let Some(url) = &release.sums_url {
        let sums = agent.get(url).call().map_err(|e| e.to_string())?.body_mut().read_to_string().map_err(|e| e.to_string())?;
        let expected = sums
            .lines()
            .find(|l| l.trim_end().ends_with(&release.deb_name))
            .and_then(|l| l.split_whitespace().next())
            .ok_or("SHA256SUMS does not list the package")?
            .to_lowercase();
        let actual: String = sha2::Sha256::digest(&bytes).iter().map(|b| format!("{b:02x}")).collect();
        if actual != expected {
            return Err("the downloaded package is corrupted (checksum mismatch)".into());
        }
    }
    let path = std::env::temp_dir().join(&release.deb_name);
    std::fs::write(&path, &bytes).map_err(|e| e.to_string())?;
    Ok(path)
}

pub fn check_on_launch(app: &Rc<App>) {
    if !app.settings.borrow().check_for_updates || !is_installed_package() {
        return;
    }
    let app = app.clone();
    glib::timeout_add_seconds_local_once(5, move || {
        glib::spawn_future_local(async move { check(&app, false).await });
    });
}

pub async fn check(app: &Rc<App>, user_initiated: bool) {
    let result = gio::spawn_blocking(fetch_latest).await.unwrap_or_else(|_| Err("update check crashed".into()));
    let release = match result {
        Ok(Some(r)) if is_newer(&r.version, VERSION) => r,
        Ok(_) => {
            if user_initiated {
                util::alert(None, "iShot is up to date", &format!("You have the latest version ({VERSION})."));
            }
            return;
        }
        Err(err) if err == "no release yet" => {
            if user_initiated {
                util::alert(None, "iShot is up to date", &format!("You have the latest version ({VERSION})."));
            }
            return;
        }
        Err(err) => {
            crate::logln!("update check failed: {err}");
            if user_initiated {
                util::alert(None, "Could not check for updates", &err);
            }
            return;
        }
    };
    if !user_initiated && app.settings.borrow().skipped_version.as_deref() == Some(release.version.as_str()) {
        return;
    }
    let notes: String = release.notes.trim().chars().take(700).collect();
    let dialog = gtk::AlertDialog::builder()
        .message(format!("iShot {} is available", release.version))
        .detail(format!("You have version {VERSION}. Install the update now? iShot will restart.\n\n{notes}"))
        .buttons(["Install and Restart", "Later", "Skip This Version"])
        .default_button(0)
        .cancel_button(1)
        .modal(true)
        .build();
    match dialog.choose_future(None::<&gtk::Window>).await {
        Ok(0) => install(app, release).await,
        Ok(2) => {
            let mut s = app.settings.borrow_mut();
            s.skipped_version = Some(release.version.clone());
            s.save();
        }
        _ => {}
    }
}

async fn install(app: &Rc<App>, release: Release) {
    if !is_installed_package() {
        util::alert(None, "Cannot update this copy", "Only iShot installed from the .deb package can update itself.");
        return;
    }
    util::notify("Downloading iShot update", &format!("Version {}", release.version));
    let rel = release.clone();
    let path = match gio::spawn_blocking(move || download(&rel)).await.unwrap_or_else(|_| Err("download crashed".into())) {
        Ok(p) => p,
        Err(err) => {
            util::alert(None, "Update failed", &format!("{err}\n\nYou can download it from {}", release.page));
            return;
        }
    };
    let deb = path.to_string_lossy().to_string();
    let status = gio::spawn_blocking(move || {
        std::process::Command::new("pkexec").args(["apt-get", "install", "-y", "--allow-downgrades", &deb]).status()
    })
    .await;
    match status {
        Ok(Ok(s)) if s.success() => app.restart(),
        _ => {
            // No polkit agent or cancelled: hand the package to the software center instead.
            let _ = util::spawn_detached("xdg-open", &[&path.to_string_lossy()]);
            util::alert(None, "Update not installed", "The package was opened with your software installer. If nothing appears, install it with:\nsudo apt install ./ishot_*.deb");
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn versions() {
        assert!(super::is_newer("0.1.10", "0.1.9"));
        assert!(super::is_newer("0.2.0", "0.1.99"));
        assert!(!super::is_newer("0.1.6", "0.1.6"));
        assert!(!super::is_newer("0.1.5", "0.1.6"));
    }
}
