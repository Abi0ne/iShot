//! Global shortcuts, with the best backend the desktop offers:
//! - X11: grab the keys on the root window (XFCE, KDE/GNOME on Xorg…).
//! - Wayland: the GlobalShortcuts portal (KDE Plasma, GNOME 48+); the desktop confirms them.
//! - GNOME without the portal: custom keybindings in GNOME Settings that run `ishot --region` etc.

use crate::settings::ShortcutAction;
use gtk::glib::translate::IntoGlib;
use gtk::prelude::*;
use gtk::{gio, glib};
use std::sync::{Arc, Mutex};
use x11rb::connection::Connection;
use x11rb::protocol::xproto::{self, ConnectionExt as _, GrabMode, ModMask};
use x11rb::protocol::Event;
use x11rb::rust_connection::RustConnection;

pub type Bindings = Vec<(ShortcutAction, String)>;

// ---------------------------------------------------------------------------------------------
// X11

const LOCK: u16 = 1 << 1; // Caps Lock
const MOD2: u16 = 1 << 4; // Num Lock

pub struct X11Hotkeys {
    conn: Arc<RustConnection>,
    root: u32,
    active: Arc<Mutex<Vec<(u8, u16, ShortcutAction)>>>,
}

impl X11Hotkeys {
    pub fn start(tx: async_channel::Sender<ShortcutAction>) -> Option<X11Hotkeys> {
        let (conn, screen_num) = x11rb::connect(None).ok()?;
        let root = conn.setup().roots[screen_num].root;
        let conn = Arc::new(conn);
        let active: Arc<Mutex<Vec<(u8, u16, ShortcutAction)>>> = Arc::default();
        let (c, a) = (conn.clone(), active.clone());
        std::thread::Builder::new()
            .name("ishot-hotkeys".into())
            .spawn(move || loop {
                let Ok(event) = c.wait_for_event() else { break };
                if let Event::KeyPress(e) = event {
                    let state = u16::from(e.state) & !(LOCK | MOD2) & 0x00ff;
                    let hit = a.lock().ok().and_then(|list| list.iter().find(|(k, m, _)| *k == e.detail && *m == state).map(|x| x.2));
                    if let Some(action) = hit {
                        let _ = tx.send_blocking(action);
                    }
                }
            })
            .ok()?;
        Some(X11Hotkeys { conn, root, active })
    }

    fn keycode_for(&self, keysym: u32) -> Option<u8> {
        let setup = self.conn.setup();
        let (min, max) = (setup.min_keycode, setup.max_keycode);
        let map = self.conn.get_keyboard_mapping(min, max - min + 1).ok()?.reply().ok()?;
        let per = map.keysyms_per_keycode as usize;
        map.keysyms
            .chunks(per.max(1))
            .position(|syms| syms.contains(&keysym))
            .map(|i| min + i as u8)
    }

    /// Replaces all grabs. Returns the titles of the shortcuts that could not be registered.
    pub fn register(&self, bindings: &Bindings) -> Vec<String> {
        let mut active = self.active.lock().unwrap();
        for (keycode, mods, _) in active.drain(..) {
            for extra in [0, LOCK, MOD2, LOCK | MOD2] {
                let _ = self.conn.ungrab_key(keycode, self.root, ModMask::from(mods | extra));
            }
        }
        let mut failed = Vec::new();
        for (action, accel) in bindings {
            let Some((key, mods)) = gtk::accelerator_parse(accel) else {
                failed.push(format!("{} ({accel})", action.title()));
                continue;
            };
            let keysym = key.to_lower().into_glib();
            let Some(keycode) = self.keycode_for(keysym) else {
                failed.push(format!("{} ({})", action.title(), crate::util::accel_label(accel)));
                continue;
            };
            let mut mask: u16 = 0;
            if mods.contains(gtk::gdk::ModifierType::SHIFT_MASK) {
                mask |= u16::from(ModMask::SHIFT);
            }
            if mods.contains(gtk::gdk::ModifierType::CONTROL_MASK) {
                mask |= u16::from(ModMask::CONTROL);
            }
            if mods.contains(gtk::gdk::ModifierType::ALT_MASK) {
                mask |= u16::from(ModMask::M1);
            }
            if mods.contains(gtk::gdk::ModifierType::SUPER_MASK) {
                mask |= u16::from(ModMask::M4);
            }
            let mut ok = true;
            for extra in [0, LOCK, MOD2, LOCK | MOD2] {
                let res = self
                    .conn
                    .grab_key(false, self.root, ModMask::from(mask | extra), keycode, GrabMode::ASYNC, GrabMode::ASYNC)
                    .map(|c| c.check());
                if !matches!(res, Ok(Ok(()))) {
                    ok = false;
                }
            }
            if ok {
                active.push((keycode, mask, *action));
            } else {
                failed.push(format!("{} ({})", action.title(), crate::util::accel_label(accel)));
            }
        }
        let _ = self.conn.flush();
        failed
    }
}

// ---------------------------------------------------------------------------------------------
// GlobalShortcuts portal (Wayland)

/// "<Alt><Shift>a" → "ALT+SHIFT+a" (XDG shortcuts specification).
fn portal_trigger(accel: &str) -> Option<String> {
    let (key, mods) = gtk::accelerator_parse(accel)?;
    let mut parts = Vec::new();
    if mods.contains(gtk::gdk::ModifierType::CONTROL_MASK) {
        parts.push("CTRL".to_string());
    }
    if mods.contains(gtk::gdk::ModifierType::ALT_MASK) {
        parts.push("ALT".to_string());
    }
    if mods.contains(gtk::gdk::ModifierType::SHIFT_MASK) {
        parts.push("SHIFT".to_string());
    }
    if mods.contains(gtk::gdk::ModifierType::SUPER_MASK) {
        parts.push("LOGO".to_string());
    }
    parts.push(key.to_lower().name()?.to_string());
    Some(parts.join("+"))
}

/// Binds the shortcuts through the portal and forwards activations. Runs until the session ends.
pub async fn portal_run(bindings: Bindings, tx: async_channel::Sender<ShortcutAction>) -> Result<(), String> {
    use ashpd::desktop::global_shortcuts::{GlobalShortcuts, NewShortcut};
    use futures_util::StreamExt;
    let err = |e: ashpd::Error| format!("GlobalShortcuts portal: {e}");
    let portal = GlobalShortcuts::new().await.map_err(err)?;
    let session = portal.create_session(Default::default()).await.map_err(err)?;
    let shortcuts: Vec<NewShortcut> = ShortcutAction::ALL
        .into_iter()
        .map(|action| {
            let trigger = bindings.iter().find(|(a, _)| *a == action).and_then(|(_, accel)| portal_trigger(accel));
            NewShortcut::new(action.id(), format!("iShot: {}", action.title())).preferred_trigger(trigger.as_deref())
        })
        .collect();
    portal.bind_shortcuts(&session, &shortcuts, None, Default::default()).await.map_err(err)?.response().map_err(err)?;
    let mut activated = portal.receive_activated().await.map_err(err)?;
    while let Some(event) = activated.next().await {
        if let Some(action) = ShortcutAction::ALL.into_iter().find(|a| a.id() == event.shortcut_id()) {
            let _ = tx.send(action).await;
        }
    }
    drop(session);
    Ok(())
}

// ---------------------------------------------------------------------------------------------
// GNOME custom keybindings (fallback without the portal)

const MEDIA_KEYS: &str = "org.gnome.settings-daemon.plugins.media-keys";
const CUSTOM: &str = "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding";

fn schema_exists(id: &str) -> bool {
    gio::SettingsSchemaSource::default().and_then(|s| s.lookup(id, true)).is_some()
}

/// Writes iShot's shortcuts into GNOME Settings › Keyboard › Custom Shortcuts.
pub fn gnome_apply(bindings: &Bindings) -> Result<(), String> {
    if !schema_exists(MEDIA_KEYS) || !schema_exists(CUSTOM) {
        return Err("GNOME keybinding settings are not available".into());
    }
    let media = gio::Settings::new(MEDIA_KEYS);
    let mut list: Vec<String> = media.strv("custom-keybindings").iter().map(|s| s.to_string()).collect();
    for action in ShortcutAction::ALL {
        let path = format!("/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/ishot-{}/", action.id());
        let entry = gio::Settings::with_path(CUSTOM, &path);
        match bindings.iter().find(|(a, _)| *a == action) {
            Some((_, accel)) => {
                let _ = entry.set_string("name", &format!("iShot: {}", action.title()));
                let _ = entry.set_string("command", &format!("ishot {}", action.cli_flag()));
                let _ = entry.set_string("binding", accel);
                if !list.contains(&path) {
                    list.push(path);
                }
            }
            None => {
                entry.reset("name");
                entry.reset("command");
                entry.reset("binding");
                list.retain(|p| p != &path);
            }
        }
    }
    let refs: Vec<&str> = list.iter().map(String::as_str).collect();
    media.set_strv("custom-keybindings", refs.as_slice()).map_err(|e| e.to_string())?;
    gio::Settings::sync();
    Ok(())
}

pub fn spawn_portal(bindings: Bindings, tx: async_channel::Sender<ShortcutAction>) {
    glib::spawn_future_local(async move {
        if let Err(err) = portal_run(bindings, tx).await {
            crate::logln!("{err}");
        }
    });
}

#[allow(dead_code)]
fn _assert_types(_: xproto::Window) {}
