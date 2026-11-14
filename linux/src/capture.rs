//! Screen capture backends.
//!
//! - X11: read the root window directly and list the other apps' windows (for snapping).
//! - Wayland: ask the desktop portal for a full-screen screenshot.
//!
//! Either way the result is one image of the whole desktop, which the selection overlay shows
//! frozen; regions and windows are then cropped from it.

use crate::shot::{Rect, Shot};
use gtk::gio;
use gtk::prelude::*;
use x11rb::connection::Connection;
use x11rb::protocol::xproto::{self, AtomEnum, ConnectionExt as _};
use x11rb::rust_connection::RustConnection;

/// A top-level window of another app, in desktop image pixels.
#[derive(Clone, Debug, PartialEq)]
pub struct WindowTarget {
    pub id: u32,
    pub rect: Rect,
}

/// Captures the whole X11 screen (all monitors).
pub fn x11_grab_screen() -> Result<Shot, String> {
    let (conn, screen_num) = x11rb::connect(None).map_err(|e| format!("X11: {e}"))?;
    let screen = &conn.setup().roots[screen_num];
    let (w, h) = (screen.width_in_pixels, screen.height_in_pixels);
    let depth = screen.root_depth;
    let bpp = conn
        .setup()
        .pixmap_formats
        .iter()
        .find(|f| f.depth == depth)
        .map(|f| f.bits_per_pixel)
        .unwrap_or(0);
    if bpp != 32 {
        return Err(format!("unsupported X11 pixel format ({depth}-bit depth, {bpp} bpp)"));
    }
    let reply = conn
        .get_image(xproto::ImageFormat::Z_PIXMAP, screen.root, 0, 0, w, h, !0)
        .map_err(|e| e.to_string())?
        .reply()
        .map_err(|e| format!("X11 GetImage failed: {e}"))?;
    Ok(Shot::new_opaque_from_bgrx(w as i32, h as i32, reply.data))
}

struct Atoms {
    stacking: u32,
    active: u32,
    frame_extents: u32,
    gtk_frame_extents: u32,
    pid: u32,
    window_type: u32,
    type_desktop: u32,
    type_dock: u32,
    state: u32,
    state_hidden: u32,
    wm_desktop: u32,
    current_desktop: u32,
}

fn atom(conn: &RustConnection, name: &str) -> u32 {
    conn.intern_atom(false, name.as_bytes())
        .ok()
        .and_then(|c| c.reply().ok())
        .map(|r| r.atom)
        .unwrap_or(0)
}

fn prop32(conn: &RustConnection, win: u32, prop: u32) -> Vec<u32> {
    if prop == 0 {
        return vec![];
    }
    conn.get_property(false, win, prop, AtomEnum::ANY, 0, 1024)
        .ok()
        .and_then(|c| c.reply().ok())
        .and_then(|r| r.value32().map(|v| v.collect()))
        .unwrap_or_default()
}

/// Lists the visible windows of other apps, front to back, plus the active (front) one.
/// Rects include the window-manager frame and exclude client-side shadows.
pub fn x11_windows() -> (Vec<WindowTarget>, Option<u32>) {
    let Ok((conn, screen_num)) = x11rb::connect(None) else { return (vec![], None) };
    let root = conn.setup().roots[screen_num].root;
    let a = Atoms {
        stacking: atom(&conn, "_NET_CLIENT_LIST_STACKING"),
        active: atom(&conn, "_NET_ACTIVE_WINDOW"),
        frame_extents: atom(&conn, "_NET_FRAME_EXTENTS"),
        gtk_frame_extents: atom(&conn, "_GTK_FRAME_EXTENTS"),
        pid: atom(&conn, "_NET_WM_PID"),
        window_type: atom(&conn, "_NET_WM_WINDOW_TYPE"),
        type_desktop: atom(&conn, "_NET_WM_WINDOW_TYPE_DESKTOP"),
        type_dock: atom(&conn, "_NET_WM_WINDOW_TYPE_DOCK"),
        state: atom(&conn, "_NET_WM_STATE"),
        state_hidden: atom(&conn, "_NET_WM_STATE_HIDDEN"),
        wm_desktop: atom(&conn, "_NET_WM_DESKTOP"),
        current_desktop: atom(&conn, "_NET_CURRENT_DESKTOP"),
    };
    let own_pid = std::process::id();
    let current_desktop = prop32(&conn, root, a.current_desktop).first().copied();
    let active = prop32(&conn, root, a.active).first().copied().filter(|&w| w != 0);

    let mut out = Vec::new();
    // _NET_CLIENT_LIST_STACKING is bottom-to-top.
    for win in prop32(&conn, root, a.stacking).into_iter().rev() {
        if prop32(&conn, win, a.pid).first() == Some(&own_pid) {
            continue;
        }
        let types = prop32(&conn, win, a.window_type);
        if types.contains(&a.type_desktop) || types.contains(&a.type_dock) {
            continue;
        }
        if prop32(&conn, win, a.state).contains(&a.state_hidden) {
            continue;
        }
        if let (Some(cur), Some(&d)) = (current_desktop, prop32(&conn, win, a.wm_desktop).first()) {
            if d != cur && d != 0xFFFF_FFFF {
                continue;
            }
        }
        let Some(geo) = conn.get_geometry(win).ok().and_then(|c| c.reply().ok()) else { continue };
        let Some(pos) = conn.translate_coordinates(win, root, 0, 0).ok().and_then(|c| c.reply().ok()) else { continue };
        let mut rect = Rect::new(pos.dst_x as f64, pos.dst_y as f64, geo.width as f64, geo.height as f64);
        // Server-side decorations (xfwm4, KWin on X11): grow by the frame.
        if let [l, r, t, b] = prop32(&conn, win, a.frame_extents)[..] {
            rect = Rect::new(rect.x - l as f64, rect.y - t as f64, rect.w + (l + r) as f64, rect.h + (t + b) as f64);
        }
        // Client-side decorations (GTK): shrink by the invisible shadow area.
        if let [l, r, t, b] = prop32(&conn, win, a.gtk_frame_extents)[..] {
            rect = Rect::new(rect.x + l as f64, rect.y + t as f64, rect.w - (l + r) as f64, rect.h - (t + b) as f64);
        }
        if rect.w < 40.0 || rect.h < 40.0 {
            continue;
        }
        out.push(WindowTarget { id: win, rect });
    }
    (out, active)
}

/// Pointer position in root (desktop image) pixels.
pub fn x11_pointer() -> Option<(f64, f64)> {
    let (conn, screen_num) = x11rb::connect(None).ok()?;
    let root = conn.setup().roots[screen_num].root;
    let reply = conn.query_pointer(root).ok()?.reply().ok()?;
    Some((reply.root_x as f64, reply.root_y as f64))
}

/// Asks the desktop portal for a non-interactive screenshot of the whole desktop.
pub async fn portal_grab_screen() -> Result<Shot, String> {
    use ashpd::desktop::screenshot::Screenshot;
    let response = Screenshot::request()
        .interactive(false)
        .modal(false)
        .send()
        .await
        .map_err(|e| format!("Screenshot portal: {e}"))?
        .response()
        .map_err(|e| format!("Screenshot portal: {e}"))?;
    let file = gio::File::for_uri(response.uri().as_str());
    let (bytes, _) = file
        .load_contents_future()
        .await
        .map_err(|e| format!("cannot read the portal screenshot: {e}"))?;
    // The portal saved a file on our behalf (GNOME puts it in ~/Pictures/Screenshots): remove it.
    let _ = file.delete_future(gtk::glib::Priority::DEFAULT).await;
    Shot::decode(&bytes)
}
