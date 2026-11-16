//! Detects what the running desktop offers, so every feature can pick the best available backend.
//!
//! Decisions are based on what is actually present (an X11 connection, portal interfaces on
//! D-Bus, a StatusNotifier host) rather than on the desktop's name, so unknown desktops work too.

use gtk::gio;
use gtk::glib;
use gtk::prelude::*;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Session {
    X11,
    Wayland,
}

#[derive(Clone, Debug)]
pub struct Env {
    pub session: Session,
    /// Lower-case `XDG_CURRENT_DESKTOP` (e.g. "xfce", "kde", "gnome", "ubuntu:gnome").
    pub desktop: String,
    pub portal_screenshot: bool,
    pub portal_screencast: bool,
    pub portal_global_shortcuts: bool,
    /// A panel that shows StatusNotifierItem icons is running.
    pub tray_host: bool,
    /// Text recognition engine, if any.
    pub ocr_engine: Option<&'static str>,
    pub ffmpeg: bool,
    pub gst_launch: bool,
}

impl Env {
    /// True when a StatusNotifierWatcher (the service panels use to collect tray icons) runs.
    pub fn tray_watcher_present() -> bool {
        gio::bus_get_sync(gio::BusType::Session, gio::Cancellable::NONE)
            .ok()
            .and_then(|bus| {
                bus.call_sync(
                    Some("org.freedesktop.DBus"),
                    "/org/freedesktop/DBus",
                    "org.freedesktop.DBus",
                    "NameHasOwner",
                    Some(&("org.kde.StatusNotifierWatcher",).to_variant()),
                    None,
                    gio::DBusCallFlags::NONE,
                    2000,
                    gio::Cancellable::NONE,
                )
                .ok()
            })
            .and_then(|reply| reply.child_value(0).get::<bool>())
            .unwrap_or(false)
    }

    pub fn detect() -> Env {
        let wayland_display = std::env::var_os("WAYLAND_DISPLAY").is_some();
        let session_type = std::env::var("XDG_SESSION_TYPE").unwrap_or_default().to_lowercase();
        // GTK talks to X11 directly only when it uses the X11 backend.
        let gdk_is_x11 = gtk::gdk::Display::default()
            .map(|d| d.type_().name() == "GdkX11Display")
            .unwrap_or(false);
        let session = if gdk_is_x11 || (!wayland_display && session_type != "wayland") {
            Session::X11
        } else {
            Session::Wayland
        };

        let bus = gio::bus_get_sync(gio::BusType::Session, gio::Cancellable::NONE).ok();
        let portal_version = |iface: &str| -> bool {
            let Some(bus) = &bus else { return false };
            bus.call_sync(
                Some("org.freedesktop.portal.Desktop"),
                "/org/freedesktop/portal/desktop",
                "org.freedesktop.DBus.Properties",
                "Get",
                Some(&(iface, "version").to_variant()),
                None,
                gio::DBusCallFlags::NONE,
                2000,
                gio::Cancellable::NONE,
            )
            .is_ok()
        };
        let tray_host = bus
            .as_ref()
            .and_then(|bus| {
                bus.call_sync(
                    Some("org.kde.StatusNotifierWatcher"),
                    "/StatusNotifierWatcher",
                    "org.freedesktop.DBus.Properties",
                    "Get",
                    Some(&("org.kde.StatusNotifierWatcher", "IsStatusNotifierHostRegistered").to_variant()),
                    None,
                    gio::DBusCallFlags::NONE,
                    2000,
                    gio::Cancellable::NONE,
                )
                .ok()
            })
            .and_then(|reply| reply.child_value(0).as_variant())
            .and_then(|v| v.get::<bool>())
            .unwrap_or(false);

        Env {
            session,
            desktop: std::env::var("XDG_CURRENT_DESKTOP").unwrap_or_default().to_lowercase(),
            portal_screenshot: portal_version("org.freedesktop.portal.Screenshot"),
            portal_screencast: portal_version("org.freedesktop.portal.ScreenCast"),
            portal_global_shortcuts: portal_version("org.freedesktop.portal.GlobalShortcuts"),
            tray_host,
            ocr_engine: crate::ocr::engine_name(),
            ffmpeg: glib::find_program_in_path("ffmpeg").is_some(),
            gst_launch: glib::find_program_in_path("gst-launch-1.0").is_some(),
        }
    }

    pub fn is_x11(&self) -> bool {
        self.session == Session::X11
    }

    pub fn is_gnome(&self) -> bool {
        self.desktop.contains("gnome") || self.desktop.contains("unity")
    }

    pub fn desktop_name(&self) -> String {
        let name = if self.desktop.contains("xfce") {
            "XFCE"
        } else if self.desktop.contains("kde") {
            "KDE Plasma"
        } else if self.is_gnome() {
            "GNOME"
        } else if self.desktop.is_empty() {
            "unknown desktop"
        } else {
            return self.desktop.clone();
        };
        name.to_string()
    }

    /// Window snapping needs to know where other apps' windows are: only X11 tells us.
    pub fn can_snap_windows(&self) -> bool {
        self.is_x11()
    }

    pub fn can_record(&self) -> bool {
        if self.is_x11() { self.ffmpeg } else { self.portal_screencast && self.gst_launch }
    }

    /// How global shortcuts are provided, or None.
    pub fn shortcut_backend(&self) -> Option<ShortcutBackend> {
        if self.is_x11() {
            Some(ShortcutBackend::X11)
        } else if self.portal_global_shortcuts {
            Some(ShortcutBackend::Portal)
        } else if self.is_gnome() {
            Some(ShortcutBackend::GnomeCustomKeybindings)
        } else {
            None
        }
    }

    /// Human-readable lines for the "Available on this system" section of Settings.
    /// `tray_online`: whether the panel icon is shown right now.
    pub fn capability_report(&self, tray_online: bool) -> Vec<(bool, String)> {
        let session = match self.session {
            Session::X11 => "X11",
            Session::Wayland => "Wayland",
        };
        let mut lines = vec![(true, format!("Desktop: {} ({session})", self.desktop_name()))];
        lines.push(if self.is_x11() {
            (true, "Capture: direct (X11)".into())
        } else if self.portal_screenshot {
            (true, "Capture: desktop portal (may ask for permission the first time)".into())
        } else {
            (false, "Capture: unavailable — install xdg-desktop-portal and a backend for your desktop".into())
        });
        lines.push(if self.can_snap_windows() {
            (true, "Snap to the window in front: available".into())
        } else {
            (false, "Snap to the window in front: not available on Wayland (other apps' windows are private); drag to select instead".into())
        });
        lines.push(match self.shortcut_backend() {
            Some(ShortcutBackend::X11) => (true, "Global shortcuts: direct (X11)".into()),
            Some(ShortcutBackend::Portal) => (true, "Global shortcuts: desktop portal (confirm them once in the system dialog)".into()),
            Some(ShortcutBackend::GnomeCustomKeybindings) => {
                (true, "Global shortcuts: added to GNOME Settings › Keyboard › Custom Shortcuts".into())
            }
            None => (false, "Global shortcuts: set them in your desktop settings to run `ishot --region`, `--fullscreen`, `--record`".into()),
        });
        lines.push(if self.can_record() {
            (true, if self.is_x11() { "Screen recording: ffmpeg (X11)".into() } else { "Screen recording: desktop portal + GStreamer".into() })
        } else if self.is_x11() {
            (false, "Screen recording: install ffmpeg".into())
        } else {
            (false, "Screen recording: needs the ScreenCast portal and gstreamer1.0-tools / gstreamer1.0-pipewire".into())
        });
        lines.push(match self.ocr_engine {
            Some(engine) => (true, format!("Text recognition (OCR): {engine}")),
            None => (false, "Text recognition (OCR): models missing — reinstall iShot or install tesseract-ocr".into()),
        });
        lines.push(if tray_online {
            (true, "Panel icon: shown".into())
        } else if Env::tray_watcher_present() {
            (false, "Panel icon: the panel tray did not accept it yet — try restarting iShot".into())
        } else {
            (false, "Panel icon: no panel tray found (XFCE: add “Status Tray Plugin”; KDE: “System Tray”; GNOME: AppIndicator extension)".into())
        });
        lines
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ShortcutBackend {
    X11,
    Portal,
    GnomeCustomKeybindings,
}
