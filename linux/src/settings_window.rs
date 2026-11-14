//! Settings window: save folder, format, file-name prefix, global shortcuts, launch at login,
//! updates, and what the current desktop supports.

use crate::app::App;
use crate::env::ShortcutBackend;
use crate::settings::{apply_launch_at_login, ImageFormat, ShortcutAction};
use crate::util;
use gtk::prelude::*;
use gtk::{gdk, gio, glib};
use std::cell::RefCell;
use std::rc::Rc;

thread_local! {
    static OPEN: RefCell<Option<gtk::Window>> = const { RefCell::new(None) };
}

fn label(text: &str) -> gtk::Label {
    let l = gtk::Label::new(Some(text));
    l.set_xalign(1.0);
    l
}

pub fn present(app: &Rc<App>) {
    if let Some(w) = OPEN.with(|o| o.borrow().clone()) {
        w.present();
        return;
    }
    let window = gtk::Window::builder().application(&app.gtk_app).title("iShot Settings").resizable(false).build();
    let grid = gtk::Grid::builder().row_spacing(10).column_spacing(10).margin_top(18).margin_bottom(18).margin_start(18).margin_end(18).build();
    let mut row = 0;

    // Save folder
    let folder = gtk::Label::new(Some(&app.settings.borrow().save_dir_path().display().to_string()));
    folder.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
    folder.set_max_width_chars(36);
    folder.set_xalign(0.0);
    let choose = gtk::Button::with_label("Choose…");
    let show = gtk::Button::with_label("Show");
    let folder_row = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    folder_row.append(&folder);
    folder_row.append(&choose);
    folder_row.append(&show);
    grid.attach(&label("Save to:"), 0, row, 1, 1);
    grid.attach(&folder_row, 1, row, 1, 1);
    row += 1;
    {
        let (app_c, win_c, folder_c) = (app.clone(), window.clone(), folder.clone());
        choose.connect_clicked(move |_| {
            let (app, win, folder) = (app_c.clone(), win_c.clone(), folder_c.clone());
            glib::spawn_future_local(async move {
                let dialog = gtk::FileDialog::builder().title("Save screenshots to").build();
                dialog.set_initial_folder(Some(&gio::File::for_path(app.settings.borrow().save_dir_path())));
                if let Ok(dir) = dialog.select_folder_future(Some(&win)).await {
                    if let Some(path) = dir.path() {
                        let mut s = app.settings.borrow_mut();
                        s.save_dir = path.display().to_string();
                        s.save();
                        folder.set_text(&s.save_dir);
                    }
                }
            });
        });
        let (app_c, win) = (app.clone(), window.clone());
        show.connect_clicked(move |_| {
            let app = &app_c;
            let dir = app.settings.borrow().save_dir_path();
            let _ = std::fs::create_dir_all(&dir);
            gtk::FileLauncher::new(Some(&gio::File::for_path(&dir))).launch(Some(&win), gio::Cancellable::NONE, |_| {});
        });
    }

    // Format
    let format = gtk::DropDown::from_strings(&["PNG", "JPG"]);
    format.set_halign(gtk::Align::Start);
    format.set_selected(if app.settings.borrow().format == ImageFormat::Jpg { 1 } else { 0 });
    grid.attach(&label("Format:"), 0, row, 1, 1);
    grid.attach(&format, 1, row, 1, 1);
    row += 1;

    // Prefix
    let prefix = gtk::Entry::builder().text(app.settings.borrow().file_name_prefix.clone()).placeholder_text("iShot").width_chars(16).build();
    let preview = gtk::Label::new(None);
    preview.add_css_class("dim-label");
    let prefix_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    prefix_row.append(&prefix);
    prefix_row.append(&preview);
    grid.attach(&label("File name prefix:"), 0, row, 1, 1);
    grid.attach(&prefix_row, 1, row, 1, 1);
    row += 1;
    let update_preview = {
        let (app, preview) = (app.clone(), preview.clone());
        move || {
            let s = app.settings.borrow();
            preview.set_text(&format!("e.g. {}", util::file_name(&s.prefix(), s.format.ext())));
        }
    };
    update_preview();
    {
        let (app_c, up) = (app.clone(), update_preview.clone());
        format.connect_selected_notify(move |d| {
            let app = &app_c;
            {
                let mut s = app.settings.borrow_mut();
                s.format = if d.selected() == 1 { ImageFormat::Jpg } else { ImageFormat::Png };
                s.save();
            }
            up();
        });
        let (app_c, up) = (app.clone(), update_preview.clone());
        prefix.connect_changed(move |e| {
            let app = &app_c;
            {
                let mut s = app.settings.borrow_mut();
                s.file_name_prefix = e.text().to_string();
                s.save();
            }
            up();
        });
    }

    // Shortcuts
    let backend = app.env.shortcut_backend();
    for action in ShortcutAction::ALL {
        let recorder = gtk::Button::with_label(&shortcut_title(app, action));
        recorder.set_size_request(170, -1);
        let reset = gtk::Button::with_label("Reset");
        reset.set_tooltip_text(Some(&format!("Restore {}", util::accel_label(action.default_accel()))));
        let r = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        r.append(&recorder);
        r.append(&reset);
        if action.can_be_turned_off() {
            let clear = gtk::Button::with_label("Clear");
            clear.set_tooltip_text(Some(&format!("Turn off the shortcut for {}", action.title())));
            let (app_c, rec) = (app.clone(), recorder.clone());
            clear.connect_clicked(move |_| {
                let app = &app_c;
                set_shortcut(&app, action, None);
                rec.set_label(&shortcut_title(&app, action));
            });
            r.append(&clear);
        }
        {
            let (app_c, rec, win) = (app.clone(), recorder.clone(), window.clone());
            reset.connect_clicked(move |_| {
                let app = &app_c;
                let accel = action.default_accel().to_string();
                if let Some(other) = app.settings.borrow().action_using(&accel, action) {
                    util::alert(Some(&win), "Shortcut already in use", &format!("{} is already the shortcut for {}.", util::accel_label(&accel), other.title()));
                    return;
                }
                set_shortcut(&app, action, Some(accel));
                rec.set_label(&shortcut_title(&app, action));
            });
            let (app_c, win) = (app.clone(), window.clone());
            recorder.connect_clicked(move |b| record_shortcut(&app_c, &win, b, action));
        }
        if backend.is_none() || backend == Some(ShortcutBackend::Portal) {
            r.set_tooltip_text(Some(if backend.is_none() {
                "This desktop has no global-shortcut service: set it in your desktop settings to run the iShot command."
            } else {
                "The desktop manages portal shortcuts: it may ask to confirm or let you change them in its settings."
            }));
        }
        let title = match action {
            ShortcutAction::Region => "Region shortcut:",
            ShortcutAction::Fullscreen => "Fullscreen shortcut:",
            ShortcutAction::Record => "Recording shortcut:",
        };
        grid.attach(&label(title), 0, row, 1, 1);
        grid.attach(&r, 1, row, 1, 1);
        row += 1;
    }

    // Startup
    let login = gtk::CheckButton::with_label("Launch iShot at login");
    login.set_active(app.settings.borrow().launch_at_login);
    {
        let (app, win) = (app.clone(), window.clone());
        login.connect_toggled(move |c| {
            let enabled = c.is_active();
            match apply_launch_at_login(enabled) {
                Ok(()) => {
                    let mut s = app.settings.borrow_mut();
                    s.launch_at_login = enabled;
                    s.save();
                }
                Err(err) => util::alert(Some(&win), "Could not change the login item", &err.to_string()),
            }
        });
    }
    grid.attach(&label("Startup:"), 0, row, 1, 1);
    grid.attach(&login, 1, row, 1, 1);
    row += 1;

    // Updates
    let updates = gtk::CheckButton::with_label("Check for updates when iShot opens");
    updates.set_active(app.settings.borrow().check_for_updates);
    {
        let app = app.clone();
        updates.connect_toggled(move |c| {
            let mut s = app.settings.borrow_mut();
            s.check_for_updates = c.is_active();
            s.save();
        });
    }
    let check_now = gtk::Button::with_label("Check Now");
    {
        let app = app.clone();
        check_now.connect_clicked(move |_| {
            let app = app.clone();
            glib::spawn_future_local(async move { crate::updater::check(&app, true).await });
        });
    }
    let version = gtk::Label::new(Some(&format!("Version {}", crate::updater::VERSION)));
    version.add_css_class("dim-label");
    let updates_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    updates_row.append(&updates);
    updates_row.append(&check_now);
    updates_row.append(&version);
    grid.attach(&label("Updates:"), 0, row, 1, 1);
    grid.attach(&updates_row, 1, row, 1, 1);
    row += 1;

    // What this desktop supports
    let caps_title = gtk::Label::new(Some("Available on this system"));
    caps_title.add_css_class("heading");
    caps_title.set_xalign(0.0);
    caps_title.set_margin_top(10);
    grid.attach(&caps_title, 0, row, 2, 1);
    row += 1;
    let caps = gtk::Box::new(gtk::Orientation::Vertical, 3);
    for (ok, text) in app.env.capability_report() {
        let l = gtk::Label::new(Some(&format!("{}  {text}", if ok { "✓" } else { "✗" })));
        l.set_xalign(0.0);
        l.set_wrap(true);
        l.set_max_width_chars(70);
        if !ok {
            l.add_css_class("warning");
        }
        caps.append(&l);
    }
    grid.attach(&caps, 0, row, 2, 1);

    window.set_child(Some(&grid));
    window.connect_close_request(|_| {
        OPEN.with(|o| o.borrow_mut().take());
        glib::Propagation::Proceed
    });
    OPEN.with(|o| *o.borrow_mut() = Some(window.clone()));
    window.present();
}

fn shortcut_title(app: &Rc<App>, action: ShortcutAction) -> String {
    app.settings.borrow().shortcut(action).map(|a| util::accel_label(&a)).unwrap_or_else(|| "None".into())
}

fn set_shortcut(app: &Rc<App>, action: ShortcutAction, accel: Option<String>) {
    {
        let mut s = app.settings.borrow_mut();
        s.set_shortcut(action, accel);
        s.save();
    }
    app.apply_shortcuts(true);
}

/// Waits for the next key combination (with at least one modifier) on the settings window.
fn record_shortcut(app: &Rc<App>, window: &gtk::Window, button: &gtk::Button, action: ShortcutAction) {
    button.set_label("Press shortcut… (Esc cancels)");
    // While recording, iShot's own grabs would swallow the keys: release them.
    app.suspend_shortcuts();
    let keys = gtk::EventControllerKey::new();
    keys.set_propagation_phase(gtk::PropagationPhase::Capture);
    let (app, win, b) = (app.clone(), window.clone(), button.clone());
    let controller: Rc<RefCell<Option<gtk::EventControllerKey>>> = Rc::new(RefCell::new(None));
    let ctl = controller.clone();
    keys.connect_key_pressed(move |_, key, _, state| {
        let mods = state & (gdk::ModifierType::SHIFT_MASK | gdk::ModifierType::CONTROL_MASK | gdk::ModifierType::ALT_MASK | gdk::ModifierType::SUPER_MASK);
        let is_modifier = matches!(
            key,
            gdk::Key::Shift_L | gdk::Key::Shift_R | gdk::Key::Control_L | gdk::Key::Control_R | gdk::Key::Alt_L | gdk::Key::Alt_R | gdk::Key::Super_L | gdk::Key::Super_R | gdk::Key::Meta_L | gdk::Key::Meta_R | gdk::Key::ISO_Level3_Shift
        );
        if is_modifier {
            return glib::Propagation::Stop;
        }
        let finish = |app: &Rc<App>| {
            if let Some(c) = ctl.borrow_mut().take() {
                win.remove_controller(&c);
            }
            b.set_label(&shortcut_title(app, action));
            app.apply_shortcuts(true);
        };
        if key == gdk::Key::Escape {
            finish(&app);
            return glib::Propagation::Stop;
        }
        if mods.is_empty() {
            gdk::Display::default().map(|d| d.beep());
            return glib::Propagation::Stop;
        }
        let accel = gtk::accelerator_name(key.to_lower(), mods).to_string();
        let conflict = app.settings.borrow().action_using(&accel, action);
        if let Some(other) = conflict {
            finish(&app);
            util::alert(Some(&win), "Shortcut already in use", &format!("{} is already the shortcut for {}. Choose a different combination.", util::accel_label(&accel), other.title()));
            return glib::Propagation::Stop;
        }
        {
            let mut s = app.settings.borrow_mut();
            s.set_shortcut(action, Some(accel));
            s.save();
        }
        finish(&app);
        glib::Propagation::Stop
    });
    window.add_controller(keys.clone());
    *controller.borrow_mut() = Some(keys);
}
