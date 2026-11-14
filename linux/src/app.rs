//! Application state and commands (capture, record, OCR, settings…), dispatched from the panel
//! icon, global shortcuts, the command line (`ishot --region`) and the control window.

use crate::capture;
use crate::editor::Editor;
use crate::env::{Env, ShortcutBackend};
use crate::hotkeys::{self, X11Hotkeys};
use crate::overlay::{self, Choice};
use crate::recorder::{self, Recorder};
use crate::settings::{Settings, ShortcutAction};
use crate::shot::{Rect, Shot};
use crate::tray::{self, Tray};
use crate::util;
use gtk::prelude::*;
use gtk::{gdk, gio, glib};
use std::cell::{Cell, RefCell};
use std::path::PathBuf;
use std::rc::Rc;

#[derive(Clone, Debug)]
pub enum Command {
    CaptureRegion,
    CaptureFullscreen,
    ToggleRecording,
    OcrLast,
    Settings,
    CheckUpdates,
    About,
    ShowControls,
    Quit,
}

impl Command {
    fn for_shortcut(action: ShortcutAction) -> Command {
        match action {
            ShortcutAction::Region => Command::CaptureRegion,
            ShortcutAction::Fullscreen => Command::CaptureFullscreen,
            ShortcutAction::Record => Command::ToggleRecording,
        }
    }
}

pub struct App {
    pub gtk_app: gtk::Application,
    pub env: Env,
    pub settings: RefCell<Settings>,
    last: RefCell<Option<(Shot, f64)>>,
    recorder: Recorder,
    x11_hotkeys: RefCell<Option<X11Hotkeys>>,
    hotkey_tx: async_channel::Sender<ShortcutAction>,
    cmd_tx: async_channel::Sender<Command>,
    tray: RefCell<Option<ksni::blocking::Handle<Tray>>>,
    capturing: Cell<bool>,
    portal_shortcuts_started: Cell<bool>,
    controls: RefCell<Option<gtk::Window>>,
    _hold: gio::ApplicationHoldGuard,
}

impl App {
    pub fn new(gtk_app: &gtk::Application) -> Rc<App> {
        let (cmd_tx, cmd_rx) = async_channel::unbounded::<Command>();
        let (hotkey_tx, hotkey_rx) = async_channel::unbounded::<ShortcutAction>();
        let app = Rc::new(App {
            gtk_app: gtk_app.clone(),
            env: Env::detect(),
            settings: RefCell::new(Settings::load()),
            last: RefCell::new(None),
            recorder: Recorder::default(),
            x11_hotkeys: RefCell::new(None),
            hotkey_tx,
            cmd_tx,
            tray: RefCell::new(None),
            capturing: Cell::new(false),
            portal_shortcuts_started: Cell::new(false),
            controls: RefCell::new(None),
            // A panel app keeps running without windows.
            _hold: gtk_app.hold(),
        });

        let weak = Rc::downgrade(&app);
        glib::spawn_future_local(async move {
            while let Ok(cmd) = cmd_rx.recv().await {
                if let Some(app) = weak.upgrade() {
                    app.perform(cmd);
                }
            }
        });
        let weak = Rc::downgrade(&app);
        glib::spawn_future_local(async move {
            while let Ok(action) = hotkey_rx.recv().await {
                if let Some(app) = weak.upgrade() {
                    app.perform(Command::for_shortcut(action));
                }
            }
        });

        if app.env.is_x11() {
            *app.x11_hotkeys.borrow_mut() = X11Hotkeys::start(app.hotkey_tx.clone());
        }
        app.apply_shortcuts(false);
        app.start_tray();
        crate::updater::check_on_launch(&app);
        app
    }

    pub fn has_tray(&self) -> bool {
        self.tray.borrow().is_some()
    }

    fn start_tray(&self) {
        use ksni::blocking::TrayMethods;
        let s = self.settings.borrow();
        let key = |a| s.shortcut(a).map(|k| util::accel_label(&k)).unwrap_or_default();
        let tray = Tray {
            tx: self.cmd_tx.clone(),
            recording: false,
            has_last: false,
            region_key: key(ShortcutAction::Region),
            fullscreen_key: key(ShortcutAction::Fullscreen),
            record_key: key(ShortcutAction::Record),
            icons: tray::icons(),
        };
        match tray.spawn() {
            Ok(handle) => *self.tray.borrow_mut() = Some(handle),
            Err(err) => eprintln!("iShot: no panel icon ({err})"),
        }
    }

    fn update_tray(&self) {
        let recording = self.recorder.is_recording();
        let has_last = self.last.borrow().is_some();
        let s = self.settings.borrow();
        let key = |a| s.shortcut(a).map(|k| util::accel_label(&k)).unwrap_or_default();
        let (r, f, rec) = (key(ShortcutAction::Region), key(ShortcutAction::Fullscreen), key(ShortcutAction::Record));
        if let Some(handle) = self.tray.borrow().as_ref() {
            handle.update(move |t| {
                t.recording = recording;
                t.has_last = has_last;
                t.region_key = r;
                t.fullscreen_key = f;
                t.record_key = rec;
            });
        }
    }

    pub fn perform(self: &Rc<Self>, cmd: Command) {
        match cmd {
            Command::CaptureRegion => self.capture(false),
            Command::CaptureFullscreen => self.capture(true),
            Command::ToggleRecording => self.toggle_recording(),
            Command::OcrLast => self.ocr_last(),
            Command::Settings => crate::settings_window::present(self),
            Command::CheckUpdates => {
                let app = self.clone();
                glib::spawn_future_local(async move { crate::updater::check(&app, true).await });
            }
            Command::About => self.about(),
            Command::ShowControls => self.show_controls(),
            Command::Quit => self.gtk_app.quit(),
        }
    }

    /// Handles `ishot [--region|--fullscreen|--record|--settings|--ocr-last|--quit|--background]`.
    pub fn handle_args(self: &Rc<Self>, args: &[String], first_launch: bool) {
        let flags: Vec<&str> = args.iter().skip(1).map(String::as_str).collect();
        let cmd = match flags.first().copied() {
            Some("--region") => Some(Command::CaptureRegion),
            Some("--fullscreen") => Some(Command::CaptureFullscreen),
            Some("--record") => Some(Command::ToggleRecording),
            Some("--settings") => Some(Command::Settings),
            Some("--ocr-last") => Some(Command::OcrLast),
            Some("--quit") => Some(Command::Quit),
            Some("--background") => None,
            Some(other) => {
                eprintln!("iShot: unknown option {other} (see ishot --help)");
                None
            }
            // Launched from the app menu: show the controls (always useful without a panel icon).
            None if !first_launch || !self.has_tray() => Some(Command::ShowControls),
            None => {
                util::notify("iShot is running", "Use the panel icon or the shortcuts to capture the screen.");
                None
            }
        };
        if let Some(cmd) = cmd {
            self.perform(cmd);
        }
    }

    // MARK: - Shortcuts

    fn bindings(&self) -> hotkeys::Bindings {
        let s = self.settings.borrow();
        ShortcutAction::ALL.into_iter().filter_map(|a| s.shortcut(a).map(|k| (a, k))).collect()
    }

    /// (Re)registers the global shortcuts with the desktop's backend.
    pub fn apply_shortcuts(&self, show_errors: bool) {
        let bindings = self.bindings();
        let failed = match self.env.shortcut_backend() {
            Some(ShortcutBackend::X11) => self.x11_hotkeys.borrow().as_ref().map(|h| h.register(&bindings)).unwrap_or_default(),
            Some(ShortcutBackend::Portal) => {
                // The portal session lives for the whole run; the desktop owns later changes.
                if !self.portal_shortcuts_started.replace(true) {
                    hotkeys::spawn_portal(bindings, self.hotkey_tx.clone());
                }
                vec![]
            }
            Some(ShortcutBackend::GnomeCustomKeybindings) => match hotkeys::gnome_apply(&bindings) {
                Ok(()) => vec![],
                Err(err) => vec![err],
            },
            None => vec![],
        };
        self.update_tray();
        if show_errors && !failed.is_empty() {
            util::alert(
                None,
                "Shortcut unavailable",
                &format!("{} could not be registered — another app may use it. Choose a different combination.", failed.join(", ")),
            );
        }
    }

    /// Releases the X11 grabs (while the settings window records a new combination).
    pub fn suspend_shortcuts(&self) {
        if let Some(h) = self.x11_hotkeys.borrow().as_ref() {
            h.register(&vec![]);
        }
    }

    // MARK: - Capture

    async fn grab_desktop(&self) -> Result<(Shot, Vec<capture::WindowTarget>, Option<u32>), String> {
        if self.env.is_x11() {
            let result = gio::spawn_blocking(|| {
                let (windows, active) = capture::x11_windows();
                capture::x11_grab_screen().map(|shot| (shot, windows, active))
            })
            .await;
            result.unwrap_or_else(|_| Err("capture crashed".into()))
        } else if self.env.portal_screenshot {
            capture::portal_grab_screen().await.map(|shot| (shot, vec![], None))
        } else {
            Err("This desktop offers no way to capture the screen.\nInstall xdg-desktop-portal and the portal backend for your desktop (e.g. xdg-desktop-portal-gnome or -kde).".into())
        }
    }

    /// Monitor rects in desktop-image pixels, and image pixels per logical pixel.
    fn monitors(shot: &Shot) -> (Vec<Rect>, f64) {
        let Some(display) = gdk::Display::default() else { return (vec![shot.bounds()], 1.0) };
        let monitors: Vec<gdk::Monitor> = (0..display.monitors().n_items())
            .filter_map(|i| display.monitors().item(i).and_downcast::<gdk::Monitor>())
            .collect();
        let (mut x0, mut y0, mut x1) = (i32::MAX, i32::MAX, i32::MIN);
        for m in &monitors {
            let g = m.geometry();
            x0 = x0.min(g.x());
            y0 = y0.min(g.y());
            x1 = x1.max(g.x() + g.width());
        }
        if monitors.is_empty() || x1 <= x0 {
            return (vec![shot.bounds()], 1.0);
        }
        let scale = shot.width as f64 / (x1 - x0) as f64;
        let rects = monitors
            .iter()
            .map(|m| {
                let g = m.geometry();
                Rect::new((g.x() - x0) as f64 * scale, (g.y() - y0) as f64 * scale, g.width() as f64 * scale, g.height() as f64 * scale)
            })
            .collect();
        (rects, scale)
    }

    fn capture(self: &Rc<Self>, fullscreen: bool) {
        if self.capturing.replace(true) {
            return;
        }
        let app = self.clone();
        glib::spawn_future_local(async move {
            let grabbed = app.grab_desktop().await;
            let (shot, windows, active) = match grabbed {
                Ok(g) => g,
                Err(err) => {
                    app.capturing.set(false);
                    util::alert(None, "Capture failed", &err);
                    return;
                }
            };
            let (monitors, scale) = App::monitors(&shot);
            if fullscreen {
                app.capturing.set(false);
                let pointer = capture::x11_pointer().filter(|_| app.env.is_x11());
                let rect = pointer
                    .and_then(|(x, y)| monitors.iter().find(|r| r.contains(x, y)).copied())
                    .or_else(|| monitors.first().copied())
                    .unwrap_or_else(|| shot.bounds());
                if let Some(image) = shot.crop(rect) {
                    app.open_editor(image, scale, false);
                }
                return;
            }
            let app2 = app.clone();
            let source = shot.clone();
            overlay::run(&app.gtk_app, &shot, windows, active, move |choice| {
                app2.capturing.set(false);
                let rect = match choice {
                    Some(Choice::Region(r)) => r,
                    Some(Choice::Window(w)) => w.rect,
                    None => return,
                };
                match source.crop(rect) {
                    Some(image) => app2.open_editor(image, scale, false),
                    None => util::alert(None, "Capture failed", "The selected area is outside the screen."),
                }
            });
        });
    }

    pub fn open_editor(self: &Rc<Self>, shot: Shot, scale: f64, start_ocr: bool) {
        self.set_last_screenshot(shot.clone(), scale);
        Editor::open(self, shot, scale, start_ocr);
    }

    pub fn set_last_screenshot(&self, shot: Shot, scale: f64) {
        *self.last.borrow_mut() = Some((shot, scale));
        self.update_tray();
    }

    fn ocr_last(self: &Rc<Self>) {
        let last = self.last.borrow().clone();
        match last {
            Some((shot, scale)) => {
                Editor::open(self, shot, scale, true);
            }
            None => util::alert(None, "No screenshot yet", "Capture a region or the full screen first."),
        }
    }

    pub fn save_image(&self, shot: &Shot) -> Result<PathBuf, String> {
        let s = self.settings.borrow();
        let dir = s.save_dir_path();
        std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        let path = util::unique_path(&dir, &util::file_name(&s.prefix(), s.format.ext()));
        let bytes = match s.format {
            crate::settings::ImageFormat::Png => shot.encode_png()?,
            crate::settings::ImageFormat::Jpg => shot.encode_jpeg()?,
        };
        std::fs::write(&path, bytes).map_err(|e| format!("{}: {e}", path.display()))?;
        Ok(path)
    }

    // MARK: - Recording

    fn toggle_recording(self: &Rc<Self>) {
        let app = self.clone();
        glib::spawn_future_local(async move {
            if app.recorder.is_recording() {
                let result = app.recorder.stop().await;
                app.update_tray();
                match result {
                    Ok(path) => {
                        util::notify("Recording saved", &path.display().to_string());
                        util::reveal(&path, None);
                    }
                    Err(err) => util::alert(None, "Recording failed", &err),
                }
            } else {
                let (dir, prefix) = {
                    let s = app.settings.borrow();
                    (s.save_dir_path(), s.prefix())
                };
                let output = recorder::output_path(dir, &prefix);
                let result = app.recorder.start(&app.env, output).await;
                app.update_tray();
                match result {
                    Ok(()) => {
                        let how = app
                            .settings
                            .borrow()
                            .shortcut(ShortcutAction::Record)
                            .map(|k| format!("press {} or click the panel icon", util::accel_label(&k)))
                            .unwrap_or_else(|| "click the panel icon".into());
                        util::notify("Recording…", &format!("To stop, {how}."));
                    }
                    Err(err) => util::alert(None, "Could not start recording", &err),
                }
            }
        });
    }

    // MARK: - Windows

    fn about(&self) {
        let dialog = gtk::AboutDialog::builder()
            .program_name("iShot")
            .version(crate::updater::VERSION)
            .comments(format!("Capture, annotate, OCR, pin, share and record the screen.\nRunning on {}.", self.env.desktop_name()))
            .website("https://github.com/Abi0ne/iShot")
            .logo_icon_name(crate::APP_ID)
            .build();
        dialog.set_application(Some(&self.gtk_app));
        dialog.present();
    }

    /// Small window with the main commands — the entry point when there is no panel icon.
    fn show_controls(self: &Rc<Self>) {
        if let Some(w) = self.controls.borrow().as_ref() {
            w.present();
            return;
        }
        let window = gtk::Window::builder().application(&self.gtk_app).title("iShot").resizable(false).build();
        window.set_hide_on_close(true);
        let list = gtk::Box::new(gtk::Orientation::Vertical, 6);
        list.set_margin_top(14);
        list.set_margin_bottom(14);
        list.set_margin_start(14);
        list.set_margin_end(14);
        let entries = [
            ("Capture Region", Command::CaptureRegion, Some(ShortcutAction::Region)),
            ("Capture Fullscreen", Command::CaptureFullscreen, Some(ShortcutAction::Fullscreen)),
            ("Record Screen / Stop", Command::ToggleRecording, Some(ShortcutAction::Record)),
            ("OCR Last Screenshot", Command::OcrLast, None),
            ("Settings…", Command::Settings, None),
            ("Quit iShot", Command::Quit, None),
        ];
        for (title, cmd, action) in entries {
            let key = action.and_then(|a| self.settings.borrow().shortcut(a)).map(|k| format!("   {}", util::accel_label(&k))).unwrap_or_default();
            let b = gtk::Button::with_label(&format!("{title}{key}"));
            let (tx, win) = (self.cmd_tx.clone(), window.clone());
            let is_capture = matches!(cmd, Command::CaptureRegion | Command::CaptureFullscreen);
            b.connect_clicked(move |_| {
                if is_capture {
                    // Get out of the way of the capture.
                    win.set_visible(false);
                }
                let _ = tx.try_send(cmd.clone());
            });
            list.append(&b);
        }
        if !self.has_tray() {
            let note = gtk::Label::new(Some("No panel icon on this desktop: close this window and iShot keeps running.\nOpen it again from the app menu."));
            note.add_css_class("dim-label");
            note.set_wrap(true);
            note.set_max_width_chars(40);
            list.append(&note);
        }
        window.set_child(Some(&list));
        *self.controls.borrow_mut() = Some(window.clone());
        window.present();
    }

    /// Starts a new iShot once this process has exited (after an update), then quits.
    pub fn restart(&self) {
        let pid = std::process::id();
        let script = format!("while kill -0 {pid} 2>/dev/null; do sleep 0.2; done; exec ishot --background");
        let _ = util::spawn_detached("setsid", &["sh", "-c", &script]).or_else(|_| util::spawn_detached("sh", &["-c", &script]));
        self.gtk_app.quit();
    }
}
