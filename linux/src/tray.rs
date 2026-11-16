//! Panel icon (StatusNotifierItem: XFCE, KDE, GNOME with the AppIndicator extension).

use crate::app::Command;
use ksni::menu::StandardItem;
use ksni::{Icon, MenuItem, OfflineReason, ToolTip};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

pub struct Tray {
    pub tx: async_channel::Sender<Command>,
    pub recording: bool,
    pub has_last: bool,
    /// Shortcut labels shown next to the items ("Alt+Shift+A").
    pub region_key: String,
    pub fullscreen_key: String,
    pub record_key: String,
    pub icons: Vec<Icon>,
    /// True while a panel (StatusNotifierWatcher) shows the icon.
    pub online: Arc<AtomicBool>,
}

pub fn icons() -> Vec<Icon> {
    [include_bytes!("../data/icons/ishot-32.png").as_slice(), include_bytes!("../data/icons/ishot-64.png").as_slice()]
        .iter()
        .filter_map(|bytes| image::load_from_memory(bytes).ok())
        .map(|img| {
            let img = img.to_rgba8();
            let (w, h) = img.dimensions();
            // SNI wants ARGB32 in network byte order.
            let data = img.pixels().flat_map(|p| [p[3], p[0], p[1], p[2]]).collect();
            Icon { width: w as i32, height: h as i32, data }
        })
        .collect()
}

fn item(label: String, enabled: bool, command: Command) -> MenuItem<Tray> {
    StandardItem {
        label,
        enabled,
        activate: Box::new(move |t: &mut Tray| {
            let _ = t.tx.try_send(command.clone());
        }),
        ..Default::default()
    }
    .into()
}

fn with_key(label: &str, key: &str) -> String {
    if key.is_empty() { label.to_string() } else { format!("{label}    {key}") }
}

impl ksni::Tray for Tray {
    fn id(&self) -> String {
        "ishot".into()
    }

    fn title(&self) -> String {
        "iShot".into()
    }

    fn icon_name(&self) -> String {
        if self.recording { "media-record".into() } else { String::new() }
    }

    fn icon_pixmap(&self) -> Vec<Icon> {
        if self.recording { Vec::new() } else { self.icons.clone() }
    }

    fn tool_tip(&self) -> ToolTip {
        ToolTip {
            title: if self.recording { "iShot — recording".into() } else { "iShot".into() },
            description: "Click: capture region · right-click: menu".into(),
            ..Default::default()
        }
    }

    /// Left click captures a region (or stops the recording).
    fn activate(&mut self, _x: i32, _y: i32) {
        let _ = self.tx.try_send(if self.recording { Command::ToggleRecording } else { Command::CaptureRegion });
    }

    /// The panel came (back): the icon is registered again by ksni.
    fn watcher_online(&self) {
        self.online.store(true, Ordering::SeqCst);
        crate::logln!("panel icon registered");
    }

    /// No panel right now (not started yet, restarted, or no tray plugin): keep waiting for one.
    fn watcher_offline(&self, reason: OfflineReason) -> bool {
        self.online.store(false, Ordering::SeqCst);
        crate::logln!("waiting for a panel to show the icon ({reason:?})");
        true
    }

    fn menu(&self) -> Vec<MenuItem<Self>> {
        vec![
            item(with_key("Capture Region", &self.region_key), true, Command::CaptureRegion),
            item(with_key("Capture Fullscreen", &self.fullscreen_key), true, Command::CaptureFullscreen),
            item(with_key(if self.recording { "Stop Recording" } else { "Record Screen" }, &self.record_key), true, Command::ToggleRecording),
            MenuItem::Separator,
            item("OCR Last Screenshot".into(), self.has_last, Command::OcrLast),
            MenuItem::Separator,
            item("Settings…".into(), true, Command::Settings),
            item("Check for Updates…".into(), true, Command::CheckUpdates),
            item("Report a Problem…".into(), true, Command::ReportProblem),
            item("About iShot".into(), true, Command::About),
            MenuItem::Separator,
            item("Quit iShot".into(), true, Command::Quit),
        ]
    }
}
