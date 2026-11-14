//! Editor window: tool bar on top, the capture in the middle (centered when small), action bar at
//! the bottom. OCR turns the image text into a selectable layer right on the canvas.

use crate::annotation::{Annotation, Mosaic, Rgba, Shape, Tool};
use crate::app::App;
use crate::ocr::{self, Word};
use crate::shot::{Rect, Shot};
use crate::util;
use gtk::prelude::*;
use gtk::{cairo, gdk, gio, glib};
use std::cell::{Cell, RefCell};
use std::rc::{Rc, Weak};

pub const SWATCHES: [(&str, Rgba); 8] = [
    ("red", Rgba(1.0, 0.23, 0.19, 1.0)),
    ("orange", Rgba(1.0, 0.58, 0.0, 1.0)),
    ("yellow", Rgba(1.0, 0.8, 0.0, 1.0)),
    ("green", Rgba(0.2, 0.78, 0.35, 1.0)),
    ("blue", Rgba(0.0, 0.48, 1.0, 1.0)),
    ("purple", Rgba(0.69, 0.32, 0.87, 1.0)),
    ("black", Rgba(0.0, 0.0, 0.0, 1.0)),
    ("white", Rgba(1.0, 1.0, 1.0, 1.0)),
];
const WIDTHS: [f64; 6] = [1.0, 2.0, 3.0, 5.0, 8.0, 12.0];
const DEFAULT_HINT: &str = "Ctrl+S Save · Ctrl+C Copy · Ctrl+Z Undo · Del Delete · Esc Cancel";

#[derive(Default)]
struct Drag {
    start: (f64, f64),
    moved_annotation: Option<u64>,
    pushed_undo: bool,
    last: (f64, f64),
}

struct TextLayer {
    words: Vec<Word>,
    anchor: Option<usize>,
    selection: Option<(usize, usize)>,
}

pub struct Editor {
    app: Rc<App>,
    window: gtk::Window,
    area: gtk::DrawingArea,
    scroller: gtk::ScrolledWindow,
    base: Shot,
    base_surface: cairo::ImageSurface,
    mosaic: Option<Mosaic>,
    /// Image pixels per logical pixel of the screen it came from (2 on HiDPI).
    scale: f64,
    zoom: Cell<f64>,
    annotations: RefCell<Vec<Annotation>>,
    undo_stack: RefCell<Vec<Vec<Annotation>>>,
    selected: Cell<Option<u64>>,
    draft: RefCell<Option<Annotation>>,
    next_id: Cell<u64>,
    tool: Cell<Tool>,
    color: Cell<Rgba>,
    width_pt: Cell<f64>,
    drag: RefCell<Drag>,
    text: RefCell<Option<TextLayer>>,
    ocr_running: Cell<bool>,
    tool_buttons: RefCell<Vec<(Tool, gtk::ToggleButton)>>,
    undo_button: gtk::Button,
    hint: gtk::Label,
    spinner: gtk::Spinner,
    ocr_button: gtk::ToggleButton,
    copy_text_button: gtk::Button,
    color_button: gtk::ColorDialogButton,
    width_dropdown: gtk::DropDown,
    hint_generation: Rc<Cell<u64>>,
    bars: RefCell<Vec<gtk::Box>>,
}

macro_rules! upgrade {
    ($weak:expr) => {
        match $weak.upgrade() {
            Some(e) => e,
            None => return,
        }
    };
    ($weak:expr, $ret:expr) => {
        match $weak.upgrade() {
            Some(e) => e,
            None => return $ret,
        }
    };
}

impl Editor {
    pub fn open(app: &Rc<App>, shot: Shot, scale: f64, start_ocr: bool) -> Rc<Editor> {
        let scale = scale.max(1.0);
        let window = gtk::Window::builder()
            .application(&app.gtk_app)
            .title(format!("iShot — {} × {}", shot.width, shot.height))
            .build();
        let area = gtk::DrawingArea::new();
        area.add_css_class("ishot-canvas");
        area.set_halign(gtk::Align::Center);
        area.set_valign(gtk::Align::Center);
        area.set_margin_top(24);
        area.set_margin_bottom(24);
        area.set_margin_start(24);
        area.set_margin_end(24);
        area.set_focusable(true);
        let scroller = gtk::ScrolledWindow::builder().child(&area).hexpand(true).vexpand(true).build();
        scroller.add_css_class("ishot-canvas-bg");

        let editor = Rc::new(Editor {
            app: app.clone(),
            window: window.clone(),
            area: area.clone(),
            scroller: scroller.clone(),
            base_surface: shot.to_surface(),
            mosaic: Mosaic::new(&shot, 14.0 * scale),
            base: shot,
            scale,
            zoom: Cell::new(1.0 / scale),
            annotations: RefCell::new(Vec::new()),
            undo_stack: RefCell::new(Vec::new()),
            selected: Cell::new(None),
            draft: RefCell::new(None),
            next_id: Cell::new(1),
            tool: Cell::new(Tool::Arrow),
            color: Cell::new(SWATCHES[0].1),
            width_pt: Cell::new(3.0),
            drag: RefCell::new(Drag::default()),
            text: RefCell::new(None),
            ocr_running: Cell::new(false),
            tool_buttons: RefCell::new(Vec::new()),
            undo_button: gtk::Button::from_icon_name("edit-undo-symbolic"),
            hint: gtk::Label::new(Some(DEFAULT_HINT)),
            spinner: gtk::Spinner::new(),
            ocr_button: gtk::ToggleButton::with_label("OCR"),
            copy_text_button: gtk::Button::with_label("Copy All Text"),
            color_button: gtk::ColorDialogButton::new(Some(gtk::ColorDialog::new())),
            width_dropdown: gtk::DropDown::from_strings(&["1 pt", "2 pt", "3 pt", "5 pt", "8 pt", "12 pt"]),
            hint_generation: Rc::new(Cell::new(0)),
            bars: RefCell::new(Vec::new()),
        });
        editor.build_ui();
        editor.install_input();
        editor.apply_zoom(1.0 / scale);
        editor.size_window();
        editor.sync_controls();
        // The window keeps its editor alive until it closes (closures only hold weak refs).
        let holder = RefCell::new(Some(editor.clone()));
        window.connect_close_request(move |_| {
            holder.borrow_mut().take();
            glib::Propagation::Proceed
        });
        window.present();
        area.grab_focus();
        if start_ocr {
            editor.start_text_recognition();
        }
        editor
    }

    fn weak(self: &Rc<Self>) -> Weak<Editor> {
        Rc::downgrade(self)
    }

    // MARK: - UI

    fn build_ui(self: &Rc<Self>) {
        let root = gtk::Box::new(gtk::Orientation::Vertical, 0);

        // Tool bar
        let toolbar = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        toolbar.add_css_class("toolbar");
        toolbar.set_margin_start(8);
        toolbar.set_margin_end(8);
        toolbar.set_margin_top(6);
        toolbar.set_margin_bottom(6);
        let tools = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        tools.add_css_class("linked");
        let mut first: Option<gtk::ToggleButton> = None;
        for tool in Tool::ALL {
            let b = gtk::ToggleButton::with_label(tool.glyph());
            b.set_tooltip_text(Some(tool.title()));
            b.add_css_class("ishot-tool");
            if let Some(f) = &first {
                b.set_group(Some(f));
            } else {
                first = Some(b.clone());
            }
            let w = self.weak();
            b.connect_toggled(move |b| {
                if b.is_active() {
                    let e = upgrade!(w);
                    e.select_tool(tool);
                }
            });
            tools.append(&b);
            self.tool_buttons.borrow_mut().push((tool, b));
        }
        toolbar.append(&tools);
        toolbar.append(&gtk::Separator::new(gtk::Orientation::Vertical));

        for (i, (name, color)) in SWATCHES.iter().enumerate() {
            let b = gtk::Button::new();
            b.add_css_class("ishot-swatch");
            b.add_css_class(&format!("swatch-{name}"));
            b.set_tooltip_text(Some(name));
            b.set_valign(gtk::Align::Center);
            let w = self.weak();
            let color = *color;
            b.connect_clicked(move |_| {
                let e = upgrade!(w);
                e.set_color(color);
            });
            let _ = i;
            toolbar.append(&b);
        }
        self.color_button.set_tooltip_text(Some("Custom color"));
        self.color_button.set_valign(gtk::Align::Center);
        let w = self.weak();
        self.color_button.connect_rgba_notify(move |b| {
            let e = upgrade!(w);
            let c = b.rgba();
            let rgba = Rgba(c.red() as f64, c.green() as f64, c.blue() as f64, c.alpha() as f64);
            if rgba != e.color.get() {
                e.set_color(rgba);
            }
        });
        toolbar.append(&self.color_button);
        toolbar.append(&gtk::Separator::new(gtk::Orientation::Vertical));

        self.width_dropdown.set_tooltip_text(Some("Line width / text size"));
        self.width_dropdown.set_selected(2);
        let w = self.weak();
        self.width_dropdown.connect_selected_notify(move |d| {
            let e = upgrade!(w);
            e.width_pt.set(WIDTHS[(d.selected() as usize).min(WIDTHS.len() - 1)]);
            e.apply_style_to_selection();
        });
        toolbar.append(&self.width_dropdown);

        let spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        spacer.set_hexpand(true);
        toolbar.append(&spacer);
        self.undo_button.set_tooltip_text(Some("Undo (Ctrl+Z)"));
        let w = self.weak();
        self.undo_button.connect_clicked(move |_| upgrade!(w).undo());
        toolbar.append(&self.undo_button);
        let clear = gtk::Button::from_icon_name("edit-clear-all-symbolic");
        clear.set_tooltip_text(Some("Clear all annotations"));
        let w = self.weak();
        clear.connect_clicked(move |_| upgrade!(w).clear());
        toolbar.append(&clear);

        // Action bar
        let actions = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        actions.set_margin_start(8);
        actions.set_margin_end(8);
        actions.set_margin_top(6);
        actions.set_margin_bottom(6);
        actions.append(&self.spinner);
        self.hint.set_xalign(0.0);
        self.hint.set_hexpand(true);
        self.hint.set_ellipsize(gtk::pango::EllipsizeMode::End);
        self.hint.add_css_class("dim-label");
        actions.append(&self.hint);

        let cancel = gtk::Button::with_label("Cancel");
        let w = self.weak();
        cancel.connect_clicked(move |_| upgrade!(w).window.close());
        actions.append(&cancel);

        self.copy_text_button.set_visible(false);
        let w = self.weak();
        self.copy_text_button.connect_clicked(move |_| upgrade!(w).copy_all_text());
        actions.append(&self.copy_text_button);

        self.ocr_button.set_tooltip_text(Some("Make the text in the image selectable"));
        let w = self.weak();
        self.ocr_button.connect_clicked(move |b| {
            let e = upgrade!(w);
            if b.is_active() {
                e.start_text_recognition();
            } else {
                e.end_text_mode();
            }
        });
        actions.append(&self.ocr_button);

        let share = gtk::MenuButton::builder().label("Share").direction(gtk::ArrowType::Up).build();
        let w = self.weak();
        share.set_create_popup_func(move |mb| {
            let e = upgrade!(w);
            mb.set_popover(Some(&e.share_popover()));
        });
        actions.append(&share);

        let pin = gtk::Button::with_label("Pin");
        pin.set_tooltip_text(Some("Keep the image on screen (Ctrl+P)"));
        let w = self.weak();
        pin.connect_clicked(move |_| upgrade!(w).pin());
        actions.append(&pin);
        let copy = gtk::Button::with_label("Copy");
        let w = self.weak();
        copy.connect_clicked(move |_| upgrade!(w).copy_image());
        actions.append(&copy);
        let save = gtk::Button::with_label("Save");
        save.add_css_class("suggested-action");
        let w = self.weak();
        save.connect_clicked(move |_| upgrade!(w).save());
        actions.append(&save);

        root.append(&toolbar);
        root.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
        root.append(&self.scroller);
        root.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
        root.append(&actions);
        self.window.set_child(Some(&root));

        let w = self.weak();
        self.area.set_draw_func(move |_, cr, _, _| {
            let e = upgrade!(w);
            e.draw(cr);
        });
        // Remember the bars: their natural width sets the minimum window width.
        *self.bars.borrow_mut() = vec![toolbar, actions];
    }

    fn share_popover(self: &Rc<Self>) -> gtk::Popover {
        let popover = gtk::Popover::new();
        let list = gtk::Box::new(gtk::Orientation::Vertical, 2);
        for target in crate::share::targets() {
            let b = gtk::Button::with_label(&target.title);
            b.add_css_class("flat");
            b.set_halign(gtk::Align::Fill);
            if let Some(label) = b.child().and_downcast::<gtk::Label>() {
                label.set_xalign(0.0);
            }
            let w = self.weak();
            let p = popover.clone();
            b.connect_clicked(move |_| {
                p.popdown();
                let e = upgrade!(w);
                if let Some(image) = e.final_image() {
                    crate::share::share(&target, &image, Some(&e.window));
                }
            });
            list.append(&b);
        }
        popover.set_child(Some(&list));
        popover
    }

    /// Fits the window to the capture: large shots fill it (zoomed out to stay within 85% of the
    /// screen), small ones sit centered in a compact window.
    fn size_window(&self) {
        let chrome_w = self
            .bars
            .borrow()
            .iter()
            .map(|b| b.measure(gtk::Orientation::Horizontal, -1).1)
            .max()
            .unwrap_or(700)
            .max(600);
        let chrome_h = 110.0;
        let (sw, sh) = gdk::Display::default()
            .and_then(|d| d.monitors().item(0).and_downcast::<gdk::Monitor>())
            .map(|m| (m.geometry().width() as f64, m.geometry().height() as f64))
            .unwrap_or((1440.0, 900.0));
        let max_canvas = (sw * 0.85, sh * 0.85 - chrome_h);
        let logical = (self.base.width as f64 / self.scale, self.base.height as f64 / self.scale);
        let fit = (max_canvas.0 / (logical.0 + 48.0)).min(max_canvas.1 / (logical.1 + 48.0)).min(1.0);
        if fit < 1.0 {
            self.apply_zoom(fit / self.scale);
        }
        let canvas = (
            (logical.0 * fit + 48.0).max(chrome_w as f64).min(max_canvas.0),
            (logical.1 * fit + 48.0).max(220.0).min(max_canvas.1),
        );
        self.window.set_default_size(canvas.0.ceil() as i32, (canvas.1 + chrome_h).ceil() as i32);
    }

    fn apply_zoom(&self, zoom: f64) {
        let zoom = zoom.clamp(0.05, 8.0);
        self.zoom.set(zoom);
        self.area.set_content_width((self.base.width as f64 * zoom).round().max(1.0) as i32);
        self.area.set_content_height((self.base.height as f64 * zoom).round().max(1.0) as i32);
        self.area.queue_draw();
    }

    fn sync_controls(&self) {
        for (tool, b) in self.tool_buttons.borrow().iter() {
            if *tool == self.tool.get() && !b.is_active() {
                b.set_active(true);
            }
        }
        self.undo_button.set_sensitive(!self.undo_stack.borrow().is_empty());
        let c = self.color.get();
        let rgba = gdk::RGBA::new(c.0 as f32, c.1 as f32, c.2 as f32, c.3 as f32);
        if self.color_button.rgba() != rgba {
            self.color_button.set_rgba(&rgba);
        }
        self.area.queue_draw();
    }

    /// Shows a status message; with `flash`, it reverts after a few seconds.
    fn set_hint(&self, text: &str, flash: bool) {
        let generation = self.hint_generation.get() + 1;
        self.hint_generation.set(generation);
        self.hint.set_text(text);
        if flash {
            let label = self.hint.clone();
            let current = self.hint_generation.clone();
            let back = if self.text.borrow().is_some() { "Drag to select text · Ctrl+C copy · Esc exit" } else { DEFAULT_HINT };
            let back = back.to_string();
            glib::timeout_add_local_once(std::time::Duration::from_secs(3), move || {
                if current.get() == generation {
                    label.set_text(&back);
                }
            });
        }
    }

    // MARK: - Editing

    fn new_id(&self) -> u64 {
        let id = self.next_id.get();
        self.next_id.set(id + 1);
        id
    }

    fn push_undo(&self) {
        let snapshot = self.annotations.borrow().clone();
        self.undo_stack.borrow_mut().push(snapshot);
        self.undo_button.set_sensitive(true);
    }

    fn annotations_changed(&self) {
        if self.text.borrow().is_some() {
            self.end_text_mode();
        }
        self.sync_controls();
    }

    fn undo(&self) {
        let Some(prev) = self.undo_stack.borrow_mut().pop() else { return };
        *self.annotations.borrow_mut() = prev;
        self.selected.set(None);
        self.annotations_changed();
    }

    fn clear(&self) {
        if self.annotations.borrow().is_empty() {
            return;
        }
        self.push_undo();
        self.annotations.borrow_mut().clear();
        self.selected.set(None);
        self.annotations_changed();
    }

    fn delete_selection(&self) {
        let Some(id) = self.selected.get() else { return };
        self.push_undo();
        self.annotations.borrow_mut().retain(|a| a.id != id);
        self.selected.set(None);
        self.annotations_changed();
    }

    fn select_tool(&self, tool: Tool) {
        self.end_text_mode();
        self.tool.set(tool);
        if tool != Tool::Select {
            self.selected.set(None);
        }
        self.area.set_cursor_from_name(Some(if tool == Tool::Select { "default" } else if tool == Tool::Text { "text" } else { "crosshair" }));
        self.sync_controls();
    }

    fn set_color(&self, color: Rgba) {
        self.color.set(color);
        self.apply_style_to_selection();
        self.sync_controls();
    }

    fn line_width_px(&self) -> f64 {
        self.width_pt.get() * self.scale
    }

    fn font_size_px(&self) -> f64 {
        (12.0 + self.width_pt.get() * 2.5) * self.scale
    }

    fn apply_style_to_selection(&self) {
        let Some(id) = self.selected.get() else { return };
        self.push_undo();
        let (color, width, font) = (self.color.get(), self.line_width_px(), self.font_size_px());
        if let Some(a) = self.annotations.borrow_mut().iter_mut().find(|a| a.id == id) {
            a.color = color;
            a.width = width;
            if let Shape::Text(_, _, size) = &mut a.shape {
                *size = font;
            }
        }
        self.area.queue_draw();
    }

    fn to_image(&self, x: f64, y: f64) -> (f64, f64) {
        let z = self.zoom.get();
        ((x / z).clamp(0.0, self.base.width as f64), (y / z).clamp(0.0, self.base.height as f64))
    }

    fn hit(&self, p: (f64, f64)) -> Option<u64> {
        let tol = 6.0 * self.scale;
        self.annotations.borrow().iter().rev().find(|a| a.hit(p.0, p.1, tol)).map(|a| a.id)
    }

    fn install_input(self: &Rc<Self>) {
        let drag = gtk::GestureDrag::new();
        drag.set_button(gdk::BUTTON_PRIMARY);
        let w = self.weak();
        drag.connect_drag_begin(move |_, x, y| upgrade!(w).drag_begin(x, y));
        let w = self.weak();
        drag.connect_drag_update(move |g, dx, dy| {
            let e = upgrade!(w);
            let Some((sx, sy)) = g.start_point() else { return };
            let shift = g.current_event_state().contains(gdk::ModifierType::SHIFT_MASK);
            e.drag_update(sx + dx, sy + dy, shift);
        });
        let w = self.weak();
        drag.connect_drag_end(move |_, _, _| upgrade!(w).drag_end());
        self.area.add_controller(drag);

        let double = gtk::GestureClick::new();
        let w = self.weak();
        double.connect_pressed(move |_, n, x, y| {
            let e = upgrade!(w);
            if n == 2 && e.tool.get() == Tool::Select && e.text.borrow().is_none() {
                let p = e.to_image(x, y);
                if let Some(id) = e.hit(p) {
                    let is_text = e.annotations.borrow().iter().any(|a| a.id == id && matches!(a.shape, Shape::Text(..)));
                    if is_text {
                        e.edit_text(p, Some(id));
                    }
                }
            }
        });
        self.area.add_controller(double);

        let scroll = gtk::EventControllerScroll::new(gtk::EventControllerScrollFlags::VERTICAL);
        let w = self.weak();
        scroll.connect_scroll(move |c, _, dy| {
            let e = upgrade!(w, glib::Propagation::Proceed);
            if c.current_event_state().contains(gdk::ModifierType::CONTROL_MASK) {
                e.apply_zoom(e.zoom.get() * if dy < 0.0 { 1.15 } else { 1.0 / 1.15 });
                return glib::Propagation::Stop;
            }
            glib::Propagation::Proceed
        });
        self.scroller.add_controller(scroll);

        let keys = gtk::EventControllerKey::new();
        let w = self.weak();
        keys.connect_key_pressed(move |_, key, _, state| {
            let e = upgrade!(w, glib::Propagation::Proceed);
            if e.handle_key(key, state) { glib::Propagation::Stop } else { glib::Propagation::Proceed }
        });
        self.window.add_controller(keys);
    }

    fn handle_key(&self, key: gdk::Key, state: gdk::ModifierType) -> bool {
        let ctrl = state.contains(gdk::ModifierType::CONTROL_MASK);
        let key = key.to_lower();
        if ctrl {
            match key {
                gdk::Key::s => self.save(),
                gdk::Key::c if self.text.borrow().is_some() => self.copy_selected_text(),
                gdk::Key::c => self.copy_image(),
                gdk::Key::a if self.text.borrow().is_some() => self.select_all_text(),
                gdk::Key::z => self.undo(),
                gdk::Key::p => self.pin(),
                gdk::Key::w => self.window.close(),
                gdk::Key::_0 => self.apply_zoom(1.0 / self.scale),
                gdk::Key::plus | gdk::Key::equal | gdk::Key::KP_Add => self.apply_zoom(self.zoom.get() * 1.25),
                gdk::Key::minus | gdk::Key::KP_Subtract => self.apply_zoom(self.zoom.get() / 1.25),
                _ => return false,
            }
            return true;
        }
        if !state.intersects(gdk::ModifierType::ALT_MASK | gdk::ModifierType::SUPER_MASK) {
            let tool = match key {
                gdk::Key::v => Some(Tool::Select),
                gdk::Key::p => Some(Tool::Pen),
                gdk::Key::r => Some(Tool::Rect),
                gdk::Key::o => Some(Tool::Ellipse),
                gdk::Key::l => Some(Tool::Line),
                gdk::Key::a => Some(Tool::Arrow),
                gdk::Key::t => Some(Tool::Text),
                gdk::Key::m => Some(Tool::Mosaic),
                _ => None,
            };
            if let Some(tool) = tool {
                if let Some((_, b)) = self.tool_buttons.borrow().iter().find(|(t, _)| *t == tool) {
                    b.set_active(true);
                }
                return true;
            }
        }
        match key {
            gdk::Key::Escape => {
                if self.text.borrow().is_some() || self.ocr_running.get() {
                    self.end_text_mode();
                } else if self.selected.get().is_some() {
                    self.selected.set(None);
                    self.area.queue_draw();
                } else {
                    self.window.close();
                }
            }
            gdk::Key::Delete | gdk::Key::BackSpace => self.delete_selection(),
            gdk::Key::Return | gdk::Key::KP_Enter => self.save(),
            _ => return false,
        }
        true
    }

    fn drag_begin(self: &Rc<Self>, x: f64, y: f64) {
        self.area.grab_focus();
        let p = self.to_image(x, y);
        if let Some(layer) = self.text.borrow_mut().as_mut() {
            let idx = nearest_word(&layer.words, p);
            layer.anchor = idx;
            layer.selection = idx.map(|i| (i, i));
            self.area.queue_draw();
            return;
        }
        *self.drag.borrow_mut() = Drag { start: p, last: p, ..Default::default() };
        let (color, width) = (self.color.get(), self.line_width_px());
        let shape = match self.tool.get() {
            Tool::Select => {
                let hit = self.hit(p);
                self.selected.set(hit);
                self.drag.borrow_mut().moved_annotation = hit;
                self.area.queue_draw();
                return;
            }
            Tool::Text => {
                self.edit_text(p, None);
                return;
            }
            Tool::Pen => Shape::Pen(vec![p]),
            Tool::Rect => Shape::Rect(Rect::new(p.0, p.1, 0.0, 0.0)),
            Tool::Ellipse => Shape::Ellipse(Rect::new(p.0, p.1, 0.0, 0.0)),
            Tool::Line => Shape::Line(p, p),
            Tool::Arrow => Shape::Arrow(p, p),
            Tool::Mosaic => Shape::Mosaic(Rect::new(p.0, p.1, 0.0, 0.0)),
        };
        *self.draft.borrow_mut() = Some(Annotation { id: self.new_id(), shape, color, width });
    }

    fn drag_update(&self, x: f64, y: f64, shift: bool) {
        let p = self.to_image(x, y);
        if let Some(layer) = self.text.borrow_mut().as_mut() {
            if let (Some(a), Some(b)) = (layer.anchor, nearest_word(&layer.words, p)) {
                layer.selection = Some((a.min(b), a.max(b)));
            }
            self.area.queue_draw();
            return;
        }
        let start = self.drag.borrow().start;
        if let Some(id) = self.drag.borrow().moved_annotation {
            let last = self.drag.borrow().last;
            if !self.drag.borrow().pushed_undo {
                self.push_undo();
                self.drag.borrow_mut().pushed_undo = true;
            }
            if let Some(a) = self.annotations.borrow_mut().iter_mut().find(|a| a.id == id) {
                a.translate(p.0 - last.0, p.1 - last.1);
            }
            self.drag.borrow_mut().last = p;
            self.area.queue_draw();
            return;
        }
        let mut draft = self.draft.borrow_mut();
        let Some(d) = draft.as_mut() else { return };
        let constrained_box = |p: (f64, f64)| {
            if !shift {
                return Rect::from_points(start, p);
            }
            let side = (p.0 - start.0).abs().max((p.1 - start.1).abs());
            let q = (start.0 + side * (p.0 - start.0).signum(), start.1 + side * (p.1 - start.1).signum());
            Rect::from_points(start, q)
        };
        let snapped = |p: (f64, f64)| {
            if !shift {
                return p;
            }
            let (dx, dy) = (p.0 - start.0, p.1 - start.1);
            let len = dx.hypot(dy);
            let angle = (dy.atan2(dx) / std::f64::consts::FRAC_PI_4).round() * std::f64::consts::FRAC_PI_4;
            (start.0 + len * angle.cos(), start.1 + len * angle.sin())
        };
        match &mut d.shape {
            Shape::Pen(points) => points.push(p),
            Shape::Rect(r) | Shape::Ellipse(r) => *r = constrained_box(p),
            Shape::Mosaic(r) => *r = Rect::from_points(start, p),
            Shape::Line(_, q) | Shape::Arrow(_, q) => *q = snapped(p),
            Shape::Text(..) => {}
        }
        drop(draft);
        self.area.queue_draw();
    }

    fn drag_end(&self) {
        if self.text.borrow().is_some() {
            return;
        }
        self.drag.borrow_mut().moved_annotation = None;
        let Some(draft) = self.draft.borrow_mut().take() else { return };
        if draft.is_empty() {
            self.area.queue_draw();
            return;
        }
        self.push_undo();
        self.annotations.borrow_mut().push(draft);
        self.annotations_changed();
    }

    /// Text entry in a popover at the click point; `existing` edits a text annotation.
    fn edit_text(self: &Rc<Self>, p: (f64, f64), existing: Option<u64>) {
        let z = self.zoom.get();
        let current = existing.and_then(|id| {
            self.annotations.borrow().iter().find(|a| a.id == id).and_then(|a| match &a.shape {
                Shape::Text(pos, text, _) => Some((*pos, text.clone())),
                _ => None,
            })
        });
        let pos = current.as_ref().map(|c| c.0).unwrap_or(p);
        let popover = gtk::Popover::new();
        popover.set_parent(&self.area);
        popover.set_pointing_to(Some(&gdk::Rectangle::new((pos.0 * z) as i32, (pos.1 * z) as i32, 1, 1)));
        popover.set_position(gtk::PositionType::Bottom);
        let entry = gtk::Entry::new();
        entry.set_placeholder_text(Some("Type text, then Enter"));
        entry.set_width_chars(24);
        if let Some((_, text)) = &current {
            entry.set_text(text);
        }
        popover.set_child(Some(&entry));
        let w = self.weak();
        let pop = popover.clone();
        entry.connect_activate(move |entry| {
            let e = upgrade!(w);
            let text = entry.text().to_string();
            e.push_undo();
            {
                let mut anns = e.annotations.borrow_mut();
                match existing {
                    Some(id) => {
                        if text.trim().is_empty() {
                            anns.retain(|a| a.id != id);
                        } else if let Some(a) = anns.iter_mut().find(|a| a.id == id) {
                            if let Shape::Text(_, t, _) = &mut a.shape {
                                *t = text;
                            }
                        }
                    }
                    None if !text.trim().is_empty() => anns.push(Annotation {
                        id: e.new_id(),
                        shape: Shape::Text(pos, text, e.font_size_px()),
                        color: e.color.get(),
                        width: e.line_width_px(),
                    }),
                    None => {}
                }
            }
            e.annotations_changed();
            pop.popdown();
        });
        popover.connect_closed(|p| {
            let p = p.clone();
            glib::idle_add_local_once(move || p.unparent());
        });
        popover.popup();
        entry.grab_focus();
    }

    // MARK: - Drawing

    fn draw(&self, cr: &cairo::Context) {
        let z = self.zoom.get();
        cr.scale(z, z);
        let _ = cr.set_source_surface(&self.base_surface, 0.0, 0.0);
        if z < 1.0 {
            cr.source().set_filter(cairo::Filter::Good);
        }
        let _ = cr.paint();
        self.draw_annotations(cr, true);

        if let Some(layer) = self.text.borrow().as_ref() {
            for (i, word) in layer.words.iter().enumerate() {
                let selected = layer.selection.map(|(a, b)| i >= a && i <= b).unwrap_or(false);
                cr.set_source_rgba(0.21, 0.52, 0.89, if selected { 0.45 } else { 0.14 });
                let r = word.rect.inset(-2.0 * self.scale);
                cr.rectangle(r.x, r.y, r.w, r.h);
                let _ = cr.fill();
            }
        }
    }

    fn draw_annotations(&self, cr: &cairo::Context, show_selection: bool) {
        for a in self.annotations.borrow().iter() {
            a.draw(cr, self.mosaic.as_ref());
        }
        if let Some(d) = self.draft.borrow().as_ref() {
            d.draw(cr, self.mosaic.as_ref());
        }
        if show_selection {
            if let Some(a) = self.selected.get().and_then(|id| self.annotations.borrow().iter().find(|a| a.id == id).cloned()) {
                let r = a.bounds().inset(-3.0 * self.scale);
                cr.set_source_rgb(0.21, 0.52, 0.89);
                cr.set_line_width(1.0 * self.scale);
                cr.set_dash(&[4.0 * self.scale, 3.0 * self.scale], 0.0);
                cr.rectangle(r.x, r.y, r.w, r.h);
                let _ = cr.stroke();
                cr.set_dash(&[], 0.0);
            }
        }
    }

    /// Flattens the image and annotations at full resolution.
    fn render(&self) -> Option<Shot> {
        let mut surface = cairo::ImageSurface::create(cairo::Format::ARgb32, self.base.width, self.base.height).ok()?;
        {
            let cr = cairo::Context::new(&surface).ok()?;
            cr.set_source_surface(&self.base_surface, 0.0, 0.0).ok()?;
            cr.paint().ok()?;
            self.draw_annotations(&cr, false);
        }
        Some(Shot::from_surface(&mut surface))
    }

    fn final_image(&self) -> Option<Shot> {
        let image = self.render();
        if let Some(image) = &image {
            self.app.set_last_screenshot(image.clone(), self.scale);
        } else {
            util::alert(Some(&self.window), "Could not render the image", "");
        }
        image
    }

    // MARK: - Actions

    fn save(&self) {
        let Some(image) = self.final_image() else { return };
        match self.app.save_image(&image) {
            Ok(path) => {
                util::notify("Screenshot saved", &path.display().to_string());
                self.window.close();
            }
            Err(err) => util::alert(Some(&self.window), "Could not save the screenshot", &err),
        }
    }

    fn copy_image(&self) {
        let Some(image) = self.final_image() else { return };
        util::copy_image(&image);
        self.window.close();
    }

    fn pin(&self) {
        let Some(image) = self.final_image() else { return };
        crate::pin::show(&self.app, image, self.scale);
        self.window.close();
    }

    // MARK: - Text mode (OCR)

    fn start_text_recognition(self: &Rc<Self>) {
        if self.text.borrow().is_some() || self.ocr_running.get() {
            return;
        }
        if self.app.env.ocr_engine.is_none() {
            self.ocr_button.set_active(false);
            util::alert(
                Some(&self.window),
                "Text recognition is not available",
                "The OCR models are missing. Reinstall iShot, or install Tesseract:\nsudo apt install tesseract-ocr tesseract-ocr-ita tesseract-ocr-eng",
            );
            return;
        }
        // Both OCR engines read small screen fonts much better when they are enlarged.
        let factor = if self.scale < 1.5 { 2.0 } else { 1.0 };
        let Some(png) = self.render().and_then(|s| upscale(&s, factor)).and_then(|s| s.encode_png().ok()) else { return };
        self.ocr_button.set_active(true);
        self.ocr_running.set(true);
        self.spinner.start();
        self.set_hint("Recognizing text…", false);
        let w = self.weak();
        glib::spawn_future_local(async move {
            let result = gio::spawn_blocking(move || {
                ocr::recognize(&png).map(|words| {
                    words
                        .into_iter()
                        .map(|mut w| {
                            w.rect = Rect::new(w.rect.x / factor, w.rect.y / factor, w.rect.w / factor, w.rect.h / factor);
                            w
                        })
                        .collect::<Vec<_>>()
                })
            })
            .await;
            let e = upgrade!(w);
            if !e.ocr_running.get() {
                return; // cancelled meanwhile
            }
            e.ocr_running.set(false);
            e.spinner.stop();
            match result {
                Ok(Ok(words)) if words.is_empty() => {
                    e.end_text_mode();
                    e.set_hint("No text found in the image.", true);
                }
                Ok(Ok(words)) => {
                    let lines = ocr::join(&words).lines().filter(|l| !l.trim().is_empty()).count();
                    *e.text.borrow_mut() = Some(TextLayer { words, anchor: None, selection: None });
                    e.copy_text_button.set_visible(true);
                    e.area.set_cursor_from_name(Some("text"));
                    e.set_hint(
                        &format!("{lines} line{} of text found — drag to select · Ctrl+C copy · Esc exit", if lines == 1 { "" } else { "s" }),
                        false,
                    );
                    e.area.queue_draw();
                }
                Ok(Err(err)) => {
                    e.end_text_mode();
                    util::alert(Some(&e.window), "Text recognition failed", &err);
                }
                Err(_) => e.end_text_mode(),
            }
        });
    }

    fn end_text_mode(&self) {
        self.ocr_running.set(false);
        self.spinner.stop();
        *self.text.borrow_mut() = None;
        self.ocr_button.set_active(false);
        self.copy_text_button.set_visible(false);
        self.area.set_cursor_from_name(Some(if self.tool.get() == Tool::Select { "default" } else { "crosshair" }));
        self.set_hint(DEFAULT_HINT, false);
        self.area.queue_draw();
    }

    fn copy_all_text(&self) {
        let text = self.text.borrow().as_ref().map(|l| ocr::join(&l.words));
        if let Some(text) = text.filter(|t| !t.is_empty()) {
            util::copy_text(&text);
            self.set_hint("All text copied to the clipboard.", true);
        }
    }

    fn copy_selected_text(&self) {
        let selected = self.text.borrow().as_ref().and_then(|l| l.selection.map(|(a, b)| ocr::join(&l.words[a..=b])));
        match selected {
            Some(text) if !text.is_empty() => {
                util::copy_text(&text);
                self.set_hint("Selected text copied to the clipboard.", true);
            }
            _ => self.copy_all_text(),
        }
    }

    fn select_all_text(&self) {
        if let Some(layer) = self.text.borrow_mut().as_mut() {
            if !layer.words.is_empty() {
                layer.selection = Some((0, layer.words.len() - 1));
            }
        }
        self.area.queue_draw();
    }
}

/// Index of the word under the point, or the closest one.
fn nearest_word(words: &[Word], p: (f64, f64)) -> Option<usize> {
    if let Some(i) = words.iter().position(|w| w.rect.inset(-3.0).contains(p.0, p.1)) {
        return Some(i);
    }
    words
        .iter()
        .enumerate()
        .map(|(i, w)| {
            let dx = (w.rect.x - p.0).max(0.0).max(p.0 - (w.rect.x + w.rect.w));
            let dy = (w.rect.y - p.1).max(0.0).max(p.1 - (w.rect.y + w.rect.h));
            // Prefer words on the same line: vertical distance weighs more.
            (i, dx + dy * 4.0)
        })
        .min_by(|a, b| a.1.total_cmp(&b.1))
        .map(|(i, _)| i)
}

/// Enlarges an image (smooth filtering) for text recognition.
fn upscale(shot: &Shot, factor: f64) -> Option<Shot> {
    if factor <= 1.0 {
        return Some(shot.clone());
    }
    let (w, h) = ((shot.width as f64 * factor) as i32, (shot.height as f64 * factor) as i32);
    let mut surface = cairo::ImageSurface::create(cairo::Format::ARgb32, w, h).ok()?;
    {
        let cr = cairo::Context::new(&surface).ok()?;
        cr.scale(factor, factor);
        cr.set_source_surface(&shot.to_surface(), 0.0, 0.0).ok()?;
        cr.source().set_filter(cairo::Filter::Best);
        cr.paint().ok()?;
    }
    Some(Shot::from_surface(&mut surface))
}
