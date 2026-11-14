//! A captured image kept as Cairo-compatible pixels (ARGB32 = BGRA bytes on little-endian,
//! premultiplied alpha), plus conversions to PNG/JPEG, Cairo surfaces and GDK textures.

use gtk::cairo;
use gtk::gdk;
use gtk::glib;

#[derive(Clone)]
pub struct Shot {
    pub width: i32,
    pub height: i32,
    /// BGRA, premultiplied, stride = width * 4.
    pub data: Vec<u8>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Rect {
    pub fn new(x: f64, y: f64, w: f64, h: f64) -> Rect {
        Rect { x, y, w, h }
    }

    pub fn from_points(a: (f64, f64), b: (f64, f64)) -> Rect {
        Rect::new(a.0.min(b.0), a.1.min(b.1), (a.0 - b.0).abs(), (a.1 - b.1).abs())
    }

    pub fn contains(&self, x: f64, y: f64) -> bool {
        x >= self.x && y >= self.y && x < self.x + self.w && y < self.y + self.h
    }

    pub fn intersect(&self, o: &Rect) -> Option<Rect> {
        let x0 = self.x.max(o.x);
        let y0 = self.y.max(o.y);
        let x1 = (self.x + self.w).min(o.x + o.w);
        let y1 = (self.y + self.h).min(o.y + o.h);
        (x1 > x0 && y1 > y0).then(|| Rect::new(x0, y0, x1 - x0, y1 - y0))
    }

    pub fn inset(&self, d: f64) -> Rect {
        Rect::new(self.x + d, self.y + d, self.w - 2.0 * d, self.h - 2.0 * d)
    }

    pub fn round(&self) -> Rect {
        let x0 = self.x.round();
        let y0 = self.y.round();
        Rect::new(x0, y0, (self.x + self.w).round() - x0, (self.y + self.h).round() - y0)
    }
}

impl Shot {
    pub fn new_opaque_from_bgrx(width: i32, height: i32, mut data: Vec<u8>) -> Shot {
        for px in data.chunks_exact_mut(4) {
            px[3] = 255;
        }
        Shot { width, height, data }
    }

    pub fn bounds(&self) -> Rect {
        Rect::new(0.0, 0.0, self.width as f64, self.height as f64)
    }

    /// Decodes PNG/JPEG bytes.
    pub fn decode(bytes: &[u8]) -> Result<Shot, String> {
        let img = image::load_from_memory(bytes).map_err(|e| e.to_string())?.to_rgba8();
        let (w, h) = img.dimensions();
        let mut data = img.into_raw();
        for px in data.chunks_exact_mut(4) {
            let a = px[3] as u32;
            let (r, g, b) = (px[0] as u32, px[1] as u32, px[2] as u32);
            px[0] = (b * a / 255) as u8;
            px[1] = (g * a / 255) as u8;
            px[2] = (r * a / 255) as u8;
        }
        Ok(Shot { width: w as i32, height: h as i32, data })
    }

    pub fn crop(&self, rect: Rect) -> Option<Shot> {
        let r = rect.round().intersect(&self.bounds())?;
        let (x, y, w, h) = (r.x as usize, r.y as usize, r.w as usize, r.h as usize);
        let stride = self.width as usize * 4;
        let mut data = Vec::with_capacity(w * h * 4);
        for row in y..y + h {
            let start = row * stride + x * 4;
            data.extend_from_slice(&self.data[start..start + w * 4]);
        }
        Some(Shot { width: w as i32, height: h as i32, data })
    }

    pub fn to_surface(&self) -> cairo::ImageSurface {
        cairo::ImageSurface::create_for_data(self.data.clone(), cairo::Format::ARgb32, self.width, self.height, self.width * 4)
            .expect("cairo surface")
    }

    pub fn from_surface(surface: &mut cairo::ImageSurface) -> Shot {
        surface.flush();
        let (w, h, stride) = (surface.width(), surface.height(), surface.stride() as usize);
        let src = surface.data().expect("surface data");
        let mut data = Vec::with_capacity((w * h * 4) as usize);
        for row in 0..h as usize {
            data.extend_from_slice(&src[row * stride..row * stride + w as usize * 4]);
        }
        Shot { width: w, height: h, data }
    }

    fn rgba(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(self.data.len());
        for px in self.data.chunks_exact(4) {
            let a = px[3] as u32;
            let un = |c: u8| if a == 0 { 0 } else { ((c as u32 * 255 + a / 2) / a).min(255) as u8 };
            out.extend_from_slice(&[un(px[2]), un(px[1]), un(px[0]), px[3]]);
        }
        out
    }

    pub fn encode_png(&self) -> Result<Vec<u8>, String> {
        let mut out = Vec::new();
        image::codecs::png::PngEncoder::new(&mut out)
            .write_image(&self.rgba(), self.width as u32, self.height as u32, image::ExtendedColorType::Rgba8)
            .map_err(|e| e.to_string())?;
        Ok(out)
    }

    pub fn encode_jpeg(&self) -> Result<Vec<u8>, String> {
        // JPEG has no alpha: flatten on white.
        let mut rgb = Vec::with_capacity((self.width * self.height * 3) as usize);
        for px in self.data.chunks_exact(4) {
            let inv = 255 - px[3] as u32;
            rgb.extend_from_slice(&[(px[2] as u32 + inv).min(255) as u8, (px[1] as u32 + inv).min(255) as u8, (px[0] as u32 + inv).min(255) as u8]);
        }
        let mut out = Vec::new();
        image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, 92)
            .write_image(&rgb, self.width as u32, self.height as u32, image::ExtendedColorType::Rgb8)
            .map_err(|e| e.to_string())?;
        Ok(out)
    }

    pub fn texture(&self) -> gdk::MemoryTexture {
        gdk::MemoryTexture::new(
            self.width,
            self.height,
            gdk::MemoryFormat::B8g8r8a8Premultiplied,
            &glib::Bytes::from(&self.data),
            self.width as usize * 4,
        )
    }
}

use image::ImageEncoder;
