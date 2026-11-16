//! "Report a Problem…": gathers a description, system diagnostics and the end of the log, lets the
//! user review (and edit) everything, then opens a pre-filled GitHub issue in the browser. The user
//! submits it with their own GitHub account: iShot holds no token and sends nothing by itself.

use crate::app::App;
use crate::util;
use gtk::prelude::*;
use gtk::{gio, glib};
use std::rc::Rc;

const NEW_ISSUE: &str = "https://github.com/Abi0ne/iShot/issues/new";
/// GitHub accepts URLs up to ~8 KB: keep the body below that once encoded.
const MAX_URL: usize = 7600;

fn os_release() -> String {
    std::fs::read_to_string("/etc/os-release")
        .ok()
        .and_then(|t| t.lines().find_map(|l| l.strip_prefix("PRETTY_NAME=").map(|v| v.trim_matches('"').to_string())))
        .unwrap_or_else(|| "unknown".into())
}

/// Hides the user name and home folder.
fn redact(text: &str) -> String {
    let home = glib::home_dir().to_string_lossy().to_string();
    let user = glib::user_name().to_string_lossy().to_string();
    let mut out = if home.len() > 1 { text.replace(&home, "~") } else { text.to_string() };
    if user.len() > 2 {
        out = out.replace(&user, "<user>");
    }
    out
}

pub fn diagnostics(app: &App) -> String {
    let mut lines = vec![
        format!("iShot {} ({})", crate::updater::VERSION, std::env::consts::ARCH),
        format!("System: {}", os_release()),
        format!(
            "Session: XDG_CURRENT_DESKTOP={} XDG_SESSION_TYPE={} WAYLAND_DISPLAY={}",
            std::env::var("XDG_CURRENT_DESKTOP").unwrap_or_default(),
            std::env::var("XDG_SESSION_TYPE").unwrap_or_default(),
            std::env::var("WAYLAND_DISPLAY").unwrap_or_default()
        ),
        format!("GTK {}.{}.{}", gtk::major_version(), gtk::minor_version(), gtk::micro_version()),
        format!("StatusNotifierWatcher: {}", crate::env::Env::tray_watcher_present()),
    ];
    for (ok, line) in app.env.capability_report(app.has_tray()) {
        lines.push(format!("{} {line}", if ok { "✓" } else { "✗" }));
    }
    lines.join("\n")
}

fn body(description: &str, diagnostics: &str, crash: Option<&str>, log: &str) -> String {
    let mut body = format!("### What happened\n\n{}\n\n### System\n\n```\n{diagnostics}\n```\n", description.trim());
    if let Some(crash) = crash {
        body.push_str(&format!("\n### Crash\n\n```\n{}\n```\n", crash.trim()));
    }
    body.push_str(&format!("\n### Log (last lines)\n\n```\n{}\n```\n", log.trim()));
    body
}

fn encode(s: &str) -> String {
    glib::Uri::escape_string(s, None, false).to_string()
}

/// Issue URL; when the report is too long for a URL, the log is shortened (the full report is
/// copied to the clipboard and saved to a file to attach).
fn issue_url(title: &str, report: &str) -> (String, bool) {
    let make = |b: &str| format!("{NEW_ISSUE}?labels=bug&title={}&body={}", encode(title), encode(b));
    let url = make(report);
    if url.len() <= MAX_URL {
        return (url, false);
    }
    // Keep the head (description, system, crash) and as much of the log end as fits.
    let note = "\n\n_(Report shortened: the full report is attached below / pasted from the clipboard.)_\n";
    let mut cut = report.len();
    while cut > 0 {
        cut = cut.saturating_sub(400);
        while !report.is_char_boundary(cut) {
            cut -= 1;
        }
        let shortened = format!("{}\n```{note}", &report[..cut]);
        let url = make(&shortened);
        if url.len() <= MAX_URL {
            return (url, true);
        }
    }
    (make(note), true)
}

pub fn present(app: &Rc<App>, crashed: bool) {
    let window = gtk::Window::builder()
        .application(&app.gtk_app)
        .title("Report a Problem")
        .default_width(720)
        .default_height(620)
        .build();
    let root = gtk::Box::new(gtk::Orientation::Vertical, 8);
    root.set_margin_top(14);
    root.set_margin_bottom(14);
    root.set_margin_start(14);
    root.set_margin_end(14);

    let intro = gtk::Label::new(Some(if crashed {
        "iShot closed unexpectedly last time. Describe what you were doing, check the report below, then open it on GitHub and press “Submit new issue”."
    } else {
        "Describe the problem, check the report below (you can edit or remove anything), then open it on GitHub and press “Submit new issue”."
    }));
    intro.set_wrap(true);
    intro.set_xalign(0.0);
    root.append(&intro);

    let title = gtk::Entry::builder().placeholder_text("Short title, e.g. “Panel icon missing on XFCE”").build();
    if crashed {
        title.set_text("iShot crashed");
    }
    root.append(&title);

    let description = gtk::TextView::builder().wrap_mode(gtk::WrapMode::WordChar).top_margin(6).bottom_margin(6).left_margin(6).right_margin(6).build();
    description.buffer().set_text("");
    let desc_scroll = gtk::ScrolledWindow::builder().child(&description).min_content_height(90).build();
    desc_scroll.add_css_class("frame");
    let desc_label = gtk::Label::new(Some("What happened? What did you expect?"));
    desc_label.set_xalign(0.0);
    root.append(&desc_label);
    root.append(&desc_scroll);

    let crash = if crashed { crate::log::last_crash() } else { None };
    let report_text = redact(&format!(
        "### System\n\n{}\n{}\n### Log (last lines)\n\n{}",
        diagnostics(app),
        crash.as_deref().map(|c| format!("\n### Crash\n\n{}\n", c.trim())).unwrap_or_default(),
        crate::log::tail(150)
    ));
    let details_label = gtk::Label::new(Some("Report (user name and home folder already hidden):"));
    details_label.set_xalign(0.0);
    root.append(&details_label);
    let details = gtk::TextView::builder().monospace(true).top_margin(6).bottom_margin(6).left_margin(6).right_margin(6).build();
    details.buffer().set_text(&report_text);
    let details_scroll = gtk::ScrolledWindow::builder().child(&details).vexpand(true).build();
    details_scroll.add_css_class("frame");
    root.append(&details_scroll);

    let buttons = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let log_button = gtk::Button::with_label("Open Log Folder");
    let spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    spacer.set_hexpand(true);
    let cancel = gtk::Button::with_label("Cancel");
    let send = gtk::Button::with_label("Open on GitHub");
    send.add_css_class("suggested-action");
    buttons.append(&log_button);
    buttons.append(&spacer);
    buttons.append(&cancel);
    buttons.append(&send);
    root.append(&buttons);
    window.set_child(Some(&root));

    let win = window.clone();
    log_button.connect_clicked(move |_| util::reveal(&crate::log::path(), Some(&win)));
    let win = window.clone();
    cancel.connect_clicked(move |_| {
        if crashed {
            crate::log::clear_crash();
        }
        win.close();
    });
    let win = window.clone();
    send.connect_clicked(move |_| {
        let buf = description.buffer();
        let desc = buf.text(&buf.start_iter(), &buf.end_iter(), false).to_string();
        let dbuf = details.buffer();
        let details_text = dbuf.text(&dbuf.start_iter(), &dbuf.end_iter(), false).to_string();
        // The user may have edited the report: send what they see, in GitHub markdown.
        let (system, rest) = details_text.split_once("### Log (last lines)").unwrap_or((&details_text, ""));
        let system = system.trim_start_matches("### System").trim();
        let (system, crash) = match system.split_once("### Crash") {
            Some((s, c)) => (s.trim().to_string(), Some(c.trim().to_string())),
            None => (system.to_string(), None),
        };
        let description = if desc.trim().is_empty() { "_(no description)_".to_string() } else { redact(&desc) };
        let report = body(&description, &system, crash.as_deref(), rest.trim());
        let title_text = title.text().trim().to_string();
        let title_text = if title_text.is_empty() { "Problem report".to_string() } else { title_text };
        let (url, shortened) = issue_url(&format!("[Linux] {title_text}"), &report);
        if shortened {
            // Full report: clipboard + file next to the log, to paste or attach.
            util::copy_text(&report);
            let file = crate::log::dir().join("report.md");
            let _ = std::fs::write(&file, &report);
            util::alert(
                Some(&win),
                "The report is long",
                &format!("GitHub opens with a shortened report. The full report is on the clipboard (paste it as a comment) and saved in\n{}", file.display()),
            );
        }
        crate::logln!("report: opening GitHub issue form ({} bytes{})", report.len(), if shortened { ", shortened" } else { "" });
        crate::log::clear_crash();
        // No parent window, and close ours only once GTK is done with the launch: closing it
        // while the launch is pending makes GTK crash when the launch completes.
        win.set_sensitive(false);
        let launcher = gtk::UriLauncher::new(&url);
        let w = win.clone();
        launcher.launch(None::<&gtk::Window>, gio::Cancellable::NONE, move |res| {
            if let Err(err) = res {
                crate::logln!("report: cannot open the browser: {err}");
                util::copy_text(&url);
                util::alert(None, "Could not open the browser", "The GitHub link is on the clipboard: paste it into your browser.");
            }
            w.close();
        });
    });
    window.present();
}
