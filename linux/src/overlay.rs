//! Full-screen selection overlay (one window per monitor) over a frozen screenshot of the desktop.
//!
//! - When window rects are known (X11), the window in front is highlighted right away; moving the
//!   pointer over another window snaps to that one. A click (or Return) picks the snapped window.
//! - Click-and-drag selects a custom area.
//! - Esc or right-click cancels.
//!
//! All coordinates are desktop-image pixels; each monitor maps its logical area onto the image.

use crate::capture::WindowTarget;
use crate::shot::{Rect, Shot};
use gtk::prelude::*;
use gtk::{cairo, gdk, glib};
use std::cell::RefCell;
use std::rc::Rc;

pub enum Choice {
    Region(Rect),
    Window(WindowTarget),
}

struct Monitor {
    window: gtk::Window,
    area: gtk::DrawingArea,
}

struct State {
    surface: cairo::ImageSurface,
    /// Image pixels per logical pixel.
    scale: f64,
    windows: Vec<WindowTarget>,
    front: Option<usize>,
    highlighted: Option<usize>,
    drag_start: Option<(f64, f64)>,
    drag_current: Option<(f64, f64)>,
    dragging: bool,
    monitors: Vec<Monitor>,
    done: Option<Box<dyn FnOnce(Option<Choice>)>>,
}

impl State {
    fn selection(&self) -> Option<Rect> {
        Some(Rect::from_points(self.drag_start?, self.drag_current?))
    }

    fn pointer_moved(&mut self, x: f64, y: f64) {
        if self.dragging {
            return;
        }
        let hit = self.windows.iter().position(|w| w.rect.contains(x, y)).or(self.front);
        if hit != self.highlighted {
            self.highlighted = hit;
            self.redraw();
        }
    }

    fn redraw(&self) {
        for m in &self.monitors {
            m.area.queue_draw();
        }
    }
}

pub fn run(
    app: &gtk::Application,
    shot: &Shot,
    windows: Vec<WindowTarget>,
    front_id: Option<u32>,
    done: impl FnOnce(Option<Choice>) + 'static,
) {
    let display = gdk::Display::default().expect("display");
    let monitors: Vec<gdk::Monitor> = (0..display.monitors().n_items())
        .filter_map(|i| display.monitors().item(i).and_downcast::<gdk::Monitor>())
        .collect();
    // Logical bounding box of all monitors, mapped onto the desktop image.
    let (mut bx0, mut by0, mut bx1) = (i32::MAX, i32::MAX, i32::MIN);
    for m in &monitors {
        let g = m.geometry();
        bx0 = bx0.min(g.x());
        by0 = by0.min(g.y());
        bx1 = bx1.max(g.x() + g.width());
    }
    let scale = if monitors.is_empty() || bx1 <= bx0 { 1.0 } else { shot.width as f64 / (bx1 - bx0) as f64 };

    let front = front_id.and_then(|id| windows.iter().position(|w| w.id == id)).or(if windows.is_empty() { None } else { Some(0) });
    let state = Rc::new(RefCell::new(State {
        surface: shot.to_surface(),
        scale,
        windows,
        front,
        highlighted: front,
        drag_start: None,
        drag_current: None,
        dragging: false,
        monitors: Vec::new(),
        done: Some(Box::new(done)),
    }));

    let pointer = crate::capture::x11_pointer();
    let mut key_window = None;
    for monitor in &monitors {
        let g = monitor.geometry();
        let origin = ((g.x() - bx0) as f64 * scale, (g.y() - by0) as f64 * scale);
        let window = gtk::Window::builder().application(app).decorated(false).title("iShot selection").build();
        window.add_css_class("ishot-overlay");
        let area = gtk::DrawingArea::new();
        area.set_cursor_from_name(Some("crosshair"));
        area.set_focusable(true);
        window.set_child(Some(&area));

        let st = state.clone();
        area.set_draw_func(move |_, cr, w, h| draw(&st.borrow(), cr, origin, w as f64, h as f64));
        install_input(&state, &window, &area, origin);
        state.borrow_mut().monitors.push(Monitor { window: window.clone(), area });

        window.fullscreen_on_monitor(monitor);
        window.present();
        let contains_pointer = pointer
            .map(|(px, py)| Rect::new(origin.0, origin.1, g.width() as f64 * scale, g.height() as f64 * scale).contains(px, py))
            .unwrap_or(false);
        if contains_pointer || key_window.is_none() {
            key_window = Some(window);
        }
    }
    if let Some(w) = key_window {
        w.present();
    }
}

fn to_image(state: &State, origin: (f64, f64), x: f64, y: f64) -> (f64, f64) {
    (origin.0 + x * state.scale, origin.1 + y * state.scale)
}

fn finish(state: &Rc<RefCell<State>>, choice: Option<Choice>) {
    let (done, windows) = {
        let mut s = state.borrow_mut();
        let windows: Vec<gtk::Window> = s.monitors.drain(..).map(|m| m.window).collect();
        (s.done.take(), windows)
    };
    for w in windows {
        w.close();
    }
    if let Some(done) = done {
        // Give the compositor a moment to remove the overlay before anything else happens.
        glib::timeout_add_local_once(std::time::Duration::from_millis(120), move || done(choice));
    }
}

fn install_input(state: &Rc<RefCell<State>>, window: &gtk::Window, area: &gtk::DrawingArea, origin: (f64, f64)) {
    let motion = gtk::EventControllerMotion::new();
    let st = state.clone();
    motion.connect_motion(move |_, x, y| {
        let mut s = st.borrow_mut();
        let (ix, iy) = to_image(&s, origin, x, y);
        s.pointer_moved(ix, iy);
    });
    area.add_controller(motion);

    let drag = gtk::GestureDrag::new();
    drag.set_button(gdk::BUTTON_PRIMARY);
    let st = state.clone();
    drag.connect_drag_begin(move |_, x, y| {
        let mut s = st.borrow_mut();
        let p = to_image(&s, origin, x, y);
        s.pointer_moved(p.0, p.1);
        s.drag_start = Some(p);
        s.drag_current = Some(p);
        s.dragging = false;
    });
    let st = state.clone();
    drag.connect_drag_update(move |g, dx, dy| {
        let mut s = st.borrow_mut();
        let Some((sx, sy)) = g.start_point() else { return };
        let p = to_image(&s, origin, sx + dx, sy + dy);
        s.drag_current = Some(p);
        if dx.abs() > 3.0 || dy.abs() > 3.0 {
            s.dragging = true;
        }
        s.redraw();
    });
    let st = state.clone();
    drag.connect_drag_end(move |_, _, _| {
        let choice = {
            let mut s = st.borrow_mut();
            let selection = s.selection().filter(|r| s.dragging && r.w >= 3.0 && r.h >= 3.0);
            s.drag_start = None;
            s.drag_current = None;
            s.dragging = false;
            match selection {
                Some(r) => Some(Choice::Region(r)),
                None => s.highlighted.map(|i| Choice::Window(s.windows[i].clone())),
            }
        };
        match choice {
            Some(c) => finish(&st, Some(c)),
            None => st.borrow().redraw(),
        }
    });
    area.add_controller(drag);

    let right = gtk::GestureClick::new();
    right.set_button(gdk::BUTTON_SECONDARY);
    let st = state.clone();
    right.connect_pressed(move |_, _, _, _| finish(&st, None));
    area.add_controller(right);

    let keys = gtk::EventControllerKey::new();
    let st = state.clone();
    keys.connect_key_pressed(move |_, key, _, _| {
        match key {
            gdk::Key::Escape => finish(&st, None),
            gdk::Key::Return | gdk::Key::KP_Enter => {
                let target = {
                    let s = st.borrow();
                    s.highlighted.map(|i| s.windows[i].clone())
                };
                if let Some(t) = target {
                    finish(&st, Some(Choice::Window(t)));
                }
            }
            _ => return glib::Propagation::Proceed,
        }
        glib::Propagation::Stop
    });
    window.add_controller(keys);
}

fn draw(s: &State, cr: &cairo::Context, origin: (f64, f64), w: f64, h: f64) {
    let scale = s.scale;
    // Work in desktop-image pixels.
    cr.scale(1.0 / scale, 1.0 / scale);
    cr.translate(-origin.0, -origin.1);
    let view = Rect::new(origin.0, origin.1, w * scale, h * scale);

    let _ = cr.set_source_surface(&s.surface, 0.0, 0.0);
    let _ = cr.paint();

    let hole = if s.dragging {
        s.selection()
    } else {
        s.highlighted.map(|i| s.windows[i].rect)
    };

    // Dim everything except the hole.
    cr.set_fill_rule(cairo::FillRule::EvenOdd);
    cr.rectangle(view.x, view.y, view.w, view.h);
    if let Some(r) = hole {
        cr.rectangle(r.x, r.y, r.w, r.h);
    }
    cr.set_source_rgba(0.0, 0.0, 0.0, 0.40);
    let _ = cr.fill();
    cr.set_fill_rule(cairo::FillRule::Winding);

    match (s.dragging, hole) {
        (true, Some(r)) => {
            cr.set_source_rgb(1.0, 1.0, 1.0);
            cr.set_line_width(1.0 * scale);
            cr.set_dash(&[4.0 * scale, 3.0 * scale], 0.0);
            cr.rectangle(r.x + 0.5, r.y + 0.5, r.w, r.h);
            let _ = cr.stroke();
            cr.set_dash(&[], 0.0);
            size_label(cr, scale, r, &view);
        }
        (false, Some(r)) => {
            cr.set_source_rgba(0.21, 0.52, 0.89, 0.12);
            cr.rectangle(r.x, r.y, r.w, r.h);
            let _ = cr.fill();
            cr.set_source_rgb(0.21, 0.52, 0.89);
            cr.set_line_width(3.0 * scale);
            let inner = r.inset(1.5 * scale);
            cr.rectangle(inner.x, inner.y, inner.w, inner.h);
            let _ = cr.stroke();
            if r.intersect(&view).is_some() {
                size_label(cr, scale, r, &view);
                let area = r.intersect(&view).unwrap_or(view);
                hint(cr, scale, "Click to capture this window — drag to select an area — Esc to cancel", area);
            }
        }
        _ => hint(cr, scale, "Drag to select an area — Esc to cancel", view),
    }
}

fn pill(cr: &cairo::Context, x: f64, y: f64, w: f64, h: f64, r: f64) {
    cr.new_sub_path();
    cr.arc(x + w - r, y + r, r, -std::f64::consts::FRAC_PI_2, 0.0);
    cr.arc(x + w - r, y + h - r, r, 0.0, std::f64::consts::FRAC_PI_2);
    cr.arc(x + r, y + h - r, r, std::f64::consts::FRAC_PI_2, std::f64::consts::PI);
    cr.arc(x + r, y + r, r, std::f64::consts::PI, 1.5 * std::f64::consts::PI);
    cr.close_path();
}

fn size_label(cr: &cairo::Context, scale: f64, r: Rect, view: &Rect) {
    let text = format!("{} × {}", r.w.round() as i64, r.h.round() as i64);
    cr.select_font_face("Sans", cairo::FontSlant::Normal, cairo::FontWeight::Bold);
    cr.set_font_size(12.0 * scale);
    let Ok(ext) = cr.text_extents(&text) else { return };
    let (pw, ph) = (ext.x_advance() + 10.0 * scale, 20.0 * scale);
    let mut x = r.x;
    let mut y = r.y - ph - 6.0 * scale;
    if y < view.y {
        y = r.y + 6.0 * scale;
        x += 6.0 * scale;
    }
    x = x.max(view.x + 4.0 * scale).min(view.x + view.w - pw - 4.0 * scale);
    cr.set_source_rgba(0.0, 0.0, 0.0, 0.75);
    pill(cr, x, y, pw, ph, 4.0 * scale);
    let _ = cr.fill();
    cr.set_source_rgb(1.0, 1.0, 1.0);
    cr.move_to(x + 5.0 * scale, y + 14.0 * scale);
    let _ = cr.show_text(&text);
}

fn hint(cr: &cairo::Context, scale: f64, text: &str, area: Rect) {
    cr.select_font_face("Sans", cairo::FontSlant::Normal, cairo::FontWeight::Bold);
    cr.set_font_size(15.0 * scale);
    let Ok(ext) = cr.text_extents(text) else { return };
    let (pw, ph) = (ext.x_advance() + 24.0 * scale, 32.0 * scale);
    let x = area.x + (area.w - pw) / 2.0;
    let y = area.y + (area.h - ph) / 2.0;
    cr.set_source_rgba(0.0, 0.0, 0.0, 0.6);
    pill(cr, x, y, pw, ph, 8.0 * scale);
    let _ = cr.fill();
    cr.set_source_rgb(1.0, 1.0, 1.0);
    cr.move_to(x + 12.0 * scale, y + 21.0 * scale);
    let _ = cr.show_text(text);
}
