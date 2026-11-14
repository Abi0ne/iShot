//! Editor annotations: model, hit testing and Cairo drawing. Coordinates are image pixels.

use crate::shot::{Rect, Shot};
use gtk::cairo;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tool {
    Select,
    Pen,
    Rect,
    Ellipse,
    Line,
    Arrow,
    Text,
    Mosaic,
}

impl Tool {
    pub const ALL: [Tool; 8] = [Tool::Select, Tool::Pen, Tool::Rect, Tool::Ellipse, Tool::Line, Tool::Arrow, Tool::Text, Tool::Mosaic];

    /// Glyph shown on the tool button (font-based, so it works with any icon theme).
    pub fn glyph(self) -> &'static str {
        match self {
            Tool::Select => "↖",
            Tool::Pen => "✎",
            Tool::Rect => "▭",
            Tool::Ellipse => "◯",
            Tool::Line => "╱",
            Tool::Arrow => "➚",
            Tool::Text => "T",
            Tool::Mosaic => "▦",
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Tool::Select => "Select / move (V)",
            Tool::Pen => "Pen (P)",
            Tool::Rect => "Rectangle (R)",
            Tool::Ellipse => "Ellipse (O)",
            Tool::Line => "Line (L)",
            Tool::Arrow => "Arrow (A)",
            Tool::Text => "Text (T)",
            Tool::Mosaic => "Mosaic (M)",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rgba(pub f64, pub f64, pub f64, pub f64);

#[derive(Clone, Debug)]
pub enum Shape {
    Pen(Vec<(f64, f64)>),
    Rect(Rect),
    Ellipse(Rect),
    Line((f64, f64), (f64, f64)),
    Arrow((f64, f64), (f64, f64)),
    /// Top-left corner, text, font size (px).
    Text((f64, f64), String, f64),
    Mosaic(Rect),
}

#[derive(Clone, Debug)]
pub struct Annotation {
    pub id: u64,
    pub shape: Shape,
    pub color: Rgba,
    /// Stroke width in image pixels.
    pub width: f64,
}

fn text_extents(text: &str, size: f64) -> (f64, f64) {
    thread_local! {
        static CTX: cairo::Context = cairo::Context::new(cairo::ImageSurface::create(cairo::Format::ARgb32, 1, 1).unwrap()).unwrap();
    }
    CTX.with(|cr| {
        cr.select_font_face("Sans", cairo::FontSlant::Normal, cairo::FontWeight::Bold);
        cr.set_font_size(size);
        let w = cr.text_extents(text).map(|e| e.x_advance()).unwrap_or(size * text.len() as f64 * 0.6);
        (w.max(size * 0.5), size * 1.25)
    })
}

impl Annotation {
    pub fn bounds(&self) -> Rect {
        match &self.shape {
            Shape::Pen(points) => {
                let (mut x0, mut y0, mut x1, mut y1) = (f64::MAX, f64::MAX, f64::MIN, f64::MIN);
                for &(x, y) in points {
                    x0 = x0.min(x);
                    y0 = y0.min(y);
                    x1 = x1.max(x);
                    y1 = y1.max(y);
                }
                Rect::new(x0, y0, x1 - x0, y1 - y0)
            }
            Shape::Rect(r) | Shape::Ellipse(r) | Shape::Mosaic(r) => *r,
            Shape::Line(a, b) | Shape::Arrow(a, b) => Rect::from_points(*a, *b),
            Shape::Text(p, text, size) => {
                let (w, h) = text_extents(text, *size);
                Rect::new(p.0, p.1, w, h)
            }
        }
    }

    pub fn hit(&self, x: f64, y: f64, tolerance: f64) -> bool {
        let t = tolerance.max(self.width);
        let b = self.bounds();
        Rect::new(b.x - t, b.y - t, b.w + 2.0 * t, b.h + 2.0 * t).contains(x, y)
    }

    pub fn translate(&mut self, dx: f64, dy: f64) {
        let mv = |p: &mut (f64, f64)| {
            p.0 += dx;
            p.1 += dy;
        };
        match &mut self.shape {
            Shape::Pen(points) => points.iter_mut().for_each(mv),
            Shape::Rect(r) | Shape::Ellipse(r) | Shape::Mosaic(r) => {
                r.x += dx;
                r.y += dy;
            }
            Shape::Line(a, b) | Shape::Arrow(a, b) => {
                mv(a);
                mv(b);
            }
            Shape::Text(p, _, _) => mv(p),
        }
    }

    pub fn is_empty(&self) -> bool {
        match &self.shape {
            Shape::Pen(points) => points.len() < 2,
            Shape::Rect(r) | Shape::Ellipse(r) | Shape::Mosaic(r) => r.w < 2.0 || r.h < 2.0,
            Shape::Line(a, b) | Shape::Arrow(a, b) => (a.0 - b.0).hypot(a.1 - b.1) < 2.0,
            Shape::Text(_, text, _) => text.trim().is_empty(),
        }
    }

    pub fn draw(&self, cr: &cairo::Context, mosaic: Option<&Mosaic>) {
        let Rgba(r, g, b, a) = self.color;
        cr.save().ok();
        cr.set_source_rgba(r, g, b, a);
        cr.set_line_width(self.width);
        cr.set_line_cap(cairo::LineCap::Round);
        cr.set_line_join(cairo::LineJoin::Round);
        match &self.shape {
            Shape::Pen(points) => {
                if let Some((first, rest)) = points.split_first() {
                    cr.move_to(first.0, first.1);
                    // Smooth with midpoints (quadratic-like curves through the samples).
                    let mut prev = *first;
                    for &p in rest {
                        let mid = ((prev.0 + p.0) / 2.0, (prev.1 + p.1) / 2.0);
                        cr.curve_to(prev.0, prev.1, prev.0, prev.1, mid.0, mid.1);
                        prev = p;
                    }
                    cr.line_to(prev.0, prev.1);
                    let _ = cr.stroke();
                }
            }
            Shape::Rect(rect) => {
                cr.rectangle(rect.x, rect.y, rect.w, rect.h);
                let _ = cr.stroke();
            }
            Shape::Ellipse(rect) => {
                if rect.w > 0.0 && rect.h > 0.0 {
                    cr.save().ok();
                    cr.translate(rect.x + rect.w / 2.0, rect.y + rect.h / 2.0);
                    cr.scale(rect.w / 2.0, rect.h / 2.0);
                    cr.arc(0.0, 0.0, 1.0, 0.0, std::f64::consts::TAU);
                    cr.restore().ok();
                    let _ = cr.stroke();
                }
            }
            Shape::Line(p, q) => {
                cr.move_to(p.0, p.1);
                cr.line_to(q.0, q.1);
                let _ = cr.stroke();
            }
            Shape::Arrow(p, q) => {
                let angle = (q.1 - p.1).atan2(q.0 - p.0);
                let head = (self.width * 4.0).max(12.0);
                let spread = 0.45;
                // Shaft stops at the head's base so the tip stays sharp.
                let base = (q.0 - head * 0.8 * angle.cos(), q.1 - head * 0.8 * angle.sin());
                cr.move_to(p.0, p.1);
                cr.line_to(base.0, base.1);
                let _ = cr.stroke();
                cr.move_to(q.0, q.1);
                cr.line_to(q.0 - head * (angle - spread).cos(), q.1 - head * (angle - spread).sin());
                cr.line_to(q.0 - head * (angle + spread).cos(), q.1 - head * (angle + spread).sin());
                cr.close_path();
                let _ = cr.fill();
            }
            Shape::Text(p, text, size) => {
                cr.select_font_face("Sans", cairo::FontSlant::Normal, cairo::FontWeight::Bold);
                cr.set_font_size(*size);
                cr.move_to(p.0, p.1 + size * 0.95);
                let _ = cr.show_text(text);
            }
            Shape::Mosaic(rect) => {
                if let Some(m) = mosaic {
                    m.paint(cr, *rect);
                }
            }
        }
        cr.restore().ok();
    }
}

/// Pixelated copy of the screenshot, painted inside mosaic rectangles.
pub struct Mosaic {
    small: cairo::ImageSurface,
    block: f64,
}

impl Mosaic {
    pub fn new(shot: &Shot, block: f64) -> Option<Mosaic> {
        let block = block.max(4.0);
        let w = ((shot.width as f64) / block).ceil().max(1.0) as i32;
        let h = ((shot.height as f64) / block).ceil().max(1.0) as i32;
        let small = cairo::ImageSurface::create(cairo::Format::ARgb32, w, h).ok()?;
        {
            let cr = cairo::Context::new(&small).ok()?;
            cr.scale(1.0 / block, 1.0 / block);
            let base = shot.to_surface();
            cr.set_source_surface(&base, 0.0, 0.0).ok()?;
            cr.source().set_filter(cairo::Filter::Good);
            cr.paint().ok()?;
        }
        Some(Mosaic { small, block })
    }

    fn paint(&self, cr: &cairo::Context, rect: Rect) {
        cr.save().ok();
        cr.rectangle(rect.x, rect.y, rect.w, rect.h);
        cr.clip();
        cr.scale(self.block, self.block);
        if cr.set_source_surface(&self.small, 0.0, 0.0).is_ok() {
            cr.source().set_filter(cairo::Filter::Nearest);
            let _ = cr.paint();
        }
        cr.restore().ok();
    }
}
