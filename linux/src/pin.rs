//! Pinned image: a borderless window that stays on top (X11) showing a capture.
//! Drag to move, scroll to zoom, Ctrl+C to copy, double-click or Esc to close.

use crate::app::App;
use crate::shot::Shot;
use crate::util;
use gtk::prelude::*;
use gtk::{gdk, glib};
use std::cell::Cell;
use std::rc::Rc;

pub fn show(app: &Rc<App>, shot: Shot, scale: f64) {
    let scale = scale.max(1.0);
    let (lw, lh) = (shot.width as f64 / scale, shot.height as f64 / scale);
    let window = gtk::Window::builder()
        .application(&app.gtk_app)
        .title("iShot pin")
        .decorated(false)
        .resizable(true)
        .default_width(lw.round() as i32)
        .default_height(lh.round() as i32)
        .build();
    window.add_css_class("ishot-pin");

    let picture = gtk::Picture::for_paintable(&shot.texture());
    picture.set_content_fit(gtk::ContentFit::Fill);
    picture.set_can_shrink(true);
    picture.set_tooltip_text(Some("Drag to move · scroll to zoom · Ctrl+C copy · double-click or Esc to close"));
    window.set_child(Some(&picture));

    // Move with the window manager (works on X11 and Wayland).
    let press = gtk::GestureClick::new();
    press.set_button(gdk::BUTTON_PRIMARY);
    let win = window.clone();
    press.connect_pressed(move |g, n, x, y| {
        if n == 2 {
            win.close();
            return;
        }
        if let (Some(toplevel), Some(device)) = (win.surface().and_downcast::<gdk::Toplevel>(), g.current_event_device()) {
            toplevel.begin_move(&device, gdk::BUTTON_PRIMARY as i32, x, y, g.current_event_time());
        }
    });
    picture.add_controller(press);

    let zoom = Rc::new(Cell::new(1.0f64));
    let scroll = gtk::EventControllerScroll::new(gtk::EventControllerScrollFlags::VERTICAL);
    let win = window.clone();
    scroll.connect_scroll(move |_, _, dy| {
        let z = (zoom.get() * if dy < 0.0 { 1.1 } else { 1.0 / 1.1 }).clamp(0.1, 5.0);
        zoom.set(z);
        win.set_default_size((lw * z).round().max(24.0) as i32, (lh * z).round().max(24.0) as i32);
        glib::Propagation::Stop
    });
    picture.add_controller(scroll);

    let keys = gtk::EventControllerKey::new();
    let win = window.clone();
    keys.connect_key_pressed(move |_, key, _, state| {
        if key == gdk::Key::Escape {
            win.close();
        } else if state.contains(gdk::ModifierType::CONTROL_MASK) && key.to_lower() == gdk::Key::c {
            util::copy_image(&shot);
        } else {
            return glib::Propagation::Proceed;
        }
        glib::Propagation::Stop
    });
    window.add_controller(keys);

    window.connect_map(|w| {
        let w = w.clone();
        // The window manager must know the window before it can be raised above others.
        glib::timeout_add_local_once(std::time::Duration::from_millis(150), move || keep_above(&w));
    });
    window.present();
}

/// Asks an X11 window manager to keep the window above the others (_NET_WM_STATE_ABOVE).
/// Wayland offers no such request to regular apps.
fn keep_above(window: &gtk::Window) {
    use x11rb::connection::Connection;
    use x11rb::protocol::xproto::{ClientMessageEvent, ConnectionExt, EventMask};
    let Some(surface) = window.surface().and_downcast::<gdk_x11::X11Surface>() else { return };
    let xid = surface.xid() as u32;
    let Ok((conn, screen_num)) = x11rb::connect(None) else { return };
    let root = conn.setup().roots[screen_num].root;
    let intern = |name: &str| conn.intern_atom(false, name.as_bytes()).ok().and_then(|c| c.reply().ok()).map(|r| r.atom);
    let (Some(state), Some(above)) = (intern("_NET_WM_STATE"), intern("_NET_WM_STATE_ABOVE")) else { return };
    // data: action (1 = add), first property, second property, source (1 = application).
    let event = ClientMessageEvent::new(32, xid, state, [1u32, above, 0, 1, 0]);
    let _ = conn.send_event(false, root, EventMask::SUBSTRUCTURE_REDIRECT | EventMask::SUBSTRUCTURE_NOTIFY, event);
    let _ = conn.flush();
}
