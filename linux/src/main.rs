//! iShot for Linux: panel screenshot tool (capture, annotate, OCR, pin, share, record) that
//! adapts to the desktop it runs on (X11, or Wayland through the desktop portals).

mod annotation;
mod app;
mod capture;
mod editor;
mod env;
mod hotkeys;
mod ocr;
mod ocr_rapid;
mod overlay;
mod pin;
mod recorder;
mod settings;
mod settings_window;
mod share;
mod shot;
mod tray;
mod updater;
mod util;

use gtk::prelude::*;
use gtk::{gdk, gio, glib};
use std::cell::RefCell;
use std::rc::Rc;

pub const APP_ID: &str = "io.github.abi0ne.iShot";

const HELP: &str = "iShot — screenshot tool

Usage: ishot [OPTION]

  (none)          start iShot, or show its window if it is already running
  --region        capture a region / the window in front
  --fullscreen    capture the screen under the pointer
  --record        start or stop screen recording
  --ocr-last      open the last screenshot with its text selectable
  --settings      open the settings
  --background    start without showing anything (used at login)
  --quit          quit the running iShot
  --version       print the version
  --help          show this help

Bind --region / --fullscreen / --record to keys in your desktop settings if iShot cannot
register global shortcuts on your desktop.";

thread_local! {
    static APP: RefCell<Option<Rc<app::App>>> = const { RefCell::new(None) };
}

fn install_css() {
    let mut css = String::from(
        ".ishot-overlay { background: black; }
         .ishot-canvas { box-shadow: 0 2px 10px alpha(black, 0.35); }
         .ishot-tool { font-size: 15px; min-width: 30px; padding-left: 4px; padding-right: 4px; }
         .ishot-swatch { min-width: 18px; min-height: 18px; padding: 0; margin: 0; border-radius: 9px;
                         border: 1px solid alpha(black, 0.3); background-image: none; box-shadow: none; }
         .ishot-pin { background: transparent; }
         label.warning { color: #c0392b; }
        ",
    );
    for (name, c) in editor::SWATCHES {
        css.push_str(&format!(
            ".swatch-{name} {{ background-color: rgb({}, {}, {}); }}\n",
            (c.0 * 255.0) as u8,
            (c.1 * 255.0) as u8,
            (c.2 * 255.0) as u8
        ));
    }
    let provider = gtk::CssProvider::new();
    provider.load_from_string(&css);
    if let Some(display) = gdk::Display::default() {
        gtk::style_context_add_provider_for_display(&display, &provider, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);
    }
}

fn main() -> glib::ExitCode {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("--help") | Some("-h") => {
            println!("{HELP}");
            return glib::ExitCode::SUCCESS;
        }
        // Diagnostics: print the text recognized in an image file.
        Some("--ocr-file") => {
            let Some(path) = args.get(2) else {
                eprintln!("usage: ishot --ocr-file IMAGE");
                return glib::ExitCode::FAILURE;
            };
            let result = std::fs::read(path).map_err(|e| e.to_string()).and_then(|b| ocr::recognize(&b));
            return match result {
                Ok(words) => {
                    println!("{}", ocr::join(&words));
                    glib::ExitCode::SUCCESS
                }
                Err(err) => {
                    eprintln!("iShot: {err}");
                    glib::ExitCode::FAILURE
                }
            };
        }
        Some("--version") | Some("-V") => {
            println!("iShot {}", updater::VERSION);
            return glib::ExitCode::SUCCESS;
        }
        _ => {}
    }

    // Single instance: a second `ishot --region` is forwarded to the running one.
    let gtk_app = gtk::Application::builder().application_id(APP_ID).flags(gio::ApplicationFlags::HANDLES_COMMAND_LINE).build();
    gtk_app.connect_startup(|gtk_app| {
        install_css();
        gtk::Window::set_default_icon_name(APP_ID);
        let app = app::App::new(gtk_app);
        APP.with(|a| *a.borrow_mut() = Some(app));
    });
    let first = std::cell::Cell::new(true);
    gtk_app.connect_command_line(move |_, cmdline| {
        let args: Vec<String> = cmdline.arguments().iter().map(|a| a.to_string_lossy().into_owned()).collect();
        let is_first = first.replace(false) && !cmdline.is_remote();
        if let Some(app) = APP.with(|a| a.borrow().clone()) {
            app.handle_args(&args, is_first);
        }
        glib::ExitCode::SUCCESS
    });
    gtk_app.connect_shutdown(|_| {
        APP.with(|a| a.borrow_mut().take());
    });
    gtk_app.run()
}
