//! Text recognition with the RapidOCR / PaddleOCR PP-OCRv6 "small" models through ONNX Runtime.
//!
//! On screenshots it is clearly more accurate than Tesseract (white text on coloured buttons,
//! small grey labels, dots vs commas in numbers), see ARCHITECTURE.md for the benchmark.
//!
//! The pipeline mirrors RapidOCR 3.x:
//! 1. keep the image between 30 and 2000 px per side, pad very flat images vertically;
//! 2. detection (DBNet): resize so the short side is ≥ 736 (multiples of 32), probability map →
//!    threshold 0.3 → 2×2 dilation → connected regions → score ≥ 0.5 → "unclip" ×1.6;
//! 3. recognition (CTC): each line resized to height 48, batches of 6, greedy decoding with the
//!    character list stored in the model metadata; lines scoring < 0.5 are dropped.
//!
//! Screen text is horizontal, so regions are axis-aligned rectangles (no rotation step).
//! Word rectangles come from the CTC time steps of each character.

use crate::ocr::Word;
use crate::shot::Rect;
use image::{imageops, imageops::FilterType, RgbImage};
use ort::session::builder::GraphOptimizationLevel;
use ort::session::Session;
use ort::value::Tensor;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

pub const DET_MODEL: &str = "PP-OCRv6_det_small.onnx";
pub const REC_MODEL: &str = "PP-OCRv6_rec_small.onnx";

const MAX_SIDE: u32 = 2000;
const MIN_SIDE: u32 = 30;
const PAD_MIN_HEIGHT: u32 = 30;
const PAD_RATIO: f32 = 8.0;
const DET_LIMIT: u32 = 736;
const DET_THRESH: f32 = 0.3;
const BOX_THRESH: f32 = 0.5;
const UNCLIP_RATIO: f32 = 1.6;
const MAX_CANDIDATES: usize = 1000;
const REC_HEIGHT: u32 = 48;
const REC_WIDTH: u32 = 320;
const REC_BATCH: usize = 6;
const TEXT_SCORE: f32 = 0.5;
const LINE_Y_THRESHOLD: f32 = 10.0;

struct Engine {
    _env: ort::environment::Environment,
    det: Session,
    rec: Session,
    /// Index 0 is the CTC blank; the last entry is a space.
    chars: Vec<String>,
}

static ENGINE: OnceLock<Mutex<Result<Engine, String>>> = OnceLock::new();

/// Where the models live: $ISHOT_OCR_MODELS, the installed package, or the source tree (dev).
pub fn models_dir() -> Option<PathBuf> {
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Some(dir) = std::env::var_os("ISHOT_OCR_MODELS") {
        candidates.push(dir.into());
    }
    candidates.push("/usr/share/ishot/ocr".into());
    if let Ok(exe) = std::env::current_exe() {
        if let Some(prefix) = exe.parent().and_then(|p| p.parent()) {
            candidates.push(prefix.join("share/ishot/ocr"));
        }
    }
    candidates.push(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("models"));
    candidates.into_iter().find(|d| d.join(DET_MODEL).is_file() && d.join(REC_MODEL).is_file())
}

pub fn available() -> bool {
    models_dir().is_some()
}

fn load() -> Result<Engine, String> {
    let dir = models_dir().ok_or("RapidOCR models not found")?;
    let env = ort::init().with_name("ishot").build().map_err(|e| format!("ONNX Runtime: {e}"))?;
    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4).min(8);
    let open = |file: &str| -> Result<Session, String> {
        Session::builder(&env)
            .map_err(|e| e.to_string())?
            .with_optimization_level(GraphOptimizationLevel::Level3)
            .map_err(|e| e.to_string())?
            .with_intra_threads(threads)
            .map_err(|e| e.to_string())?
            .commit_from_file(dir.join(file))
            .map_err(|e| format!("{file}: {e}"))
    };
    let det = open(DET_MODEL)?;
    let rec = open(REC_MODEL)?;
    let keys = rec
        .metadata()
        .map_err(|e| e.to_string())?
        .custom("character")
        .ok_or("the recognition model has no character list")?;
    let mut chars = vec!["".to_string()];
    chars.extend(keys.lines().map(str::to_string));
    chars.push(" ".into());
    Ok(Engine { _env: env, det, rec, chars })
}

/// Recognizes text in PNG/JPEG bytes. Blocking: call from a worker thread.
pub fn recognize(bytes: &[u8]) -> Result<Vec<Word>, String> {
    let original = image::load_from_memory(bytes).map_err(|e| e.to_string())?.to_rgb8();
    let lock = ENGINE.get_or_init(|| Mutex::new(load()));
    let mut guard = lock.lock().map_err(|_| "OCR engine poisoned".to_string())?;
    let engine = guard.as_mut().map_err(|e| e.clone())?;
    run(engine, &original)
}

/// Resizes to whole multiples of 32 (as the networks expect).
fn round32(v: f32) -> u32 {
    ((v / 32.0).round() as u32 * 32).max(32)
}

fn run(engine: &mut Engine, original: &RgbImage) -> Result<Vec<Word>, String> {
    let (ow, oh) = original.dimensions();
    if ow < 4 || oh < 4 {
        return Ok(vec![]);
    }

    // 1. Bounds and vertical padding.
    let mut img = original.clone();
    let (mut w, mut h) = img.dimensions();
    if w.max(h) > MAX_SIDE {
        let r = MAX_SIDE as f32 / w.max(h) as f32;
        img = imageops::resize(&img, round32(w as f32 * r), round32(h as f32 * r), FilterType::Triangle);
        (w, h) = img.dimensions();
    }
    if w.min(h) < MIN_SIDE {
        let r = MIN_SIDE as f32 / w.min(h) as f32;
        img = imageops::resize(&img, round32(w as f32 * r), round32(h as f32 * r), FilterType::Triangle);
        (w, h) = img.dimensions();
    }
    let (scale_x, scale_y) = (ow as f32 / w as f32, oh as f32 / h as f32);
    let mut pad_top = 0u32;
    if h <= PAD_MIN_HEIGHT || w as f32 / h as f32 > PAD_RATIO {
        let new_h = ((w as f32 / PAD_RATIO) as u32).max(PAD_MIN_HEIGHT) * 2;
        pad_top = new_h.abs_diff(h) / 2;
        let mut padded = RgbImage::new(w, h + 2 * pad_top);
        imageops::replace(&mut padded, &img, 0, pad_top as i64);
        img = padded;
    }

    // 2. Detection.
    let boxes = detect(engine, &img)?;
    if boxes.is_empty() {
        return Ok(vec![]);
    }

    // Map boxes back to the original image and crop from it (best quality).
    let mut lines: Vec<(Rect, usize)> = Vec::new(); // rect in original pixels, visual line index
    let mut crops: Vec<RgbImage> = Vec::new();
    for (b, line) in boxes {
        let x0 = (b[0] * scale_x).max(0.0);
        let y0 = ((b[1] - pad_top as f32) * scale_y).max(0.0);
        let x1 = (b[2] * scale_x).min(ow as f32);
        let y1 = ((b[3] - pad_top as f32) * scale_y).min(oh as f32);
        let (cw, ch) = ((x1 - x0) as u32, (y1 - y0) as u32);
        if cw < 2 || ch < 2 {
            continue;
        }
        crops.push(imageops::crop_imm(original, x0 as u32, y0 as u32, cw, ch).to_image());
        lines.push((Rect::new(x0 as f64, y0 as f64, cw as f64, ch as f64), line));
    }

    // 3. Recognition.
    let results = recognize_lines(engine, &crops)?;
    let mut words = Vec::new();
    for ((rect, line), (text_words, score)) in lines.into_iter().zip(results) {
        if score < TEXT_SCORE {
            continue;
        }
        for (text, from, to) in text_words {
            let x = rect.x + from as f64 * rect.w;
            let wdt = ((to - from) as f64 * rect.w).max(1.0);
            words.push(Word { text, rect: Rect::new(x, rect.y, wdt, rect.h), line: (0, 0, line as u32) });
        }
    }
    Ok(words)
}

/// Normalized CHW float tensor in BGR order ((x/255 − 0.5) / 0.5), as the models were trained.
fn to_tensor(img: &RgbImage, width: u32) -> Vec<f32> {
    let h = img.height();
    let plane = (width * h) as usize;
    let mut data = vec![0.0f32; plane * 3];
    for (x, y, p) in img.enumerate_pixels() {
        if x >= width {
            continue;
        }
        let i = (y * width + x) as usize;
        for (c, &v) in [p[2], p[1], p[0]].iter().enumerate() {
            data[c * plane + i] = v as f32 / 127.5 - 1.0;
        }
    }
    data
}

/// Returns axis-aligned boxes [x0, y0, x1, y1] in `img` pixels with their visual line index,
/// in reading order.
fn detect(engine: &mut Engine, img: &RgbImage) -> Result<Vec<([f32; 4], usize)>, String> {
    let (w, h) = img.dimensions();
    let ratio = if w.min(h) < DET_LIMIT { DET_LIMIT as f32 / w.min(h) as f32 } else { 1.0 };
    let (dw, dh) = (round32(w as f32 * ratio), round32(h as f32 * ratio));
    let resized = imageops::resize(img, dw, dh, FilterType::Triangle);
    let input = Tensor::from_array(([1usize, 3, dh as usize, dw as usize], to_tensor(&resized, dw))).map_err(|e| e.to_string())?;
    let outputs = engine.det.run(ort::inputs![input]).map_err(|e| format!("detection: {e}"))?;
    let (shape, pred) = outputs[0].try_extract_tensor::<f32>().map_err(|e| e.to_string())?;
    let (ph, pw) = (shape[2] as usize, shape[3] as usize);

    // Threshold + 2×2 dilation.
    let mut mask = vec![false; pw * ph];
    for y in 0..ph {
        for x in 0..pw {
            let on = |xx: usize, yy: usize| pred[yy * pw + xx] > DET_THRESH;
            mask[y * pw + x] = on(x, y) || (x > 0 && on(x - 1, y)) || (y > 0 && on(x, y - 1)) || (x > 0 && y > 0 && on(x - 1, y - 1));
        }
    }

    // Connected regions (8-connectivity) → boxes.
    let mut seen = vec![false; pw * ph];
    let mut boxes: Vec<[f32; 4]> = Vec::new();
    let mut stack = Vec::new();
    for start in 0..pw * ph {
        if !mask[start] || seen[start] || boxes.len() >= MAX_CANDIDATES {
            continue;
        }
        let (mut x0, mut y0, mut x1, mut y1) = (usize::MAX, usize::MAX, 0, 0);
        seen[start] = true;
        stack.push(start);
        while let Some(i) = stack.pop() {
            let (x, y) = (i % pw, i / pw);
            x0 = x0.min(x);
            x1 = x1.max(x);
            y0 = y0.min(y);
            y1 = y1.max(y);
            for dy in -1i64..=1 {
                for dx in -1i64..=1 {
                    let (nx, ny) = (x as i64 + dx, y as i64 + dy);
                    if nx < 0 || ny < 0 || nx >= pw as i64 || ny >= ph as i64 {
                        continue;
                    }
                    let j = ny as usize * pw + nx as usize;
                    if mask[j] && !seen[j] {
                        seen[j] = true;
                        stack.push(j);
                    }
                }
            }
        }
        let (bw, bh) = ((x1 - x0) as f32, (y1 - y0) as f32);
        if bw.min(bh) < 3.0 {
            continue;
        }
        // Mean probability inside the box.
        let mut sum = 0.0f32;
        for y in y0..=y1 {
            sum += pred[y * pw + x0..=y * pw + x1].iter().sum::<f32>();
        }
        let score = sum / ((x1 - x0 + 1) * (y1 - y0 + 1)) as f32;
        if score < BOX_THRESH {
            continue;
        }
        // Grow the shrunk text kernel back to the full text area.
        let d = bw * bh * UNCLIP_RATIO / (2.0 * (bw + bh));
        let (ux0, uy0, ux1, uy1) = (x0 as f32 - d, y0 as f32 - d, x1 as f32 + d, y1 as f32 + d);
        if (ux1 - ux0).min(uy1 - uy0) < 5.0 {
            continue;
        }
        let sx = w as f32 / pw as f32;
        let sy = h as f32 / ph as f32;
        let b = [
            (ux0 * sx).round().clamp(0.0, w as f32 - 1.0),
            (uy0 * sy).round().clamp(0.0, h as f32 - 1.0),
            (ux1 * sx).round().clamp(0.0, w as f32 - 1.0),
            (uy1 * sy).round().clamp(0.0, h as f32 - 1.0),
        ];
        if b[2] - b[0] <= 3.0 || b[3] - b[1] <= 3.0 {
            continue;
        }
        boxes.push(b);
    }

    // Reading order: by top edge, rows split where the gap reaches 10 px, then left to right.
    boxes.sort_by(|a, b| a[1].total_cmp(&b[1]));
    let mut line = 0usize;
    let mut with_lines: Vec<([f32; 4], usize)> = Vec::with_capacity(boxes.len());
    for (i, b) in boxes.iter().enumerate() {
        if i > 0 && b[1] - boxes[i - 1][1] >= LINE_Y_THRESHOLD {
            line += 1;
        }
        with_lines.push((*b, line));
    }
    with_lines.sort_by(|a, b| a.1.cmp(&b.1).then(a.0[0].total_cmp(&b.0[0])));
    Ok(with_lines)
}

/// One result per crop: words with their horizontal extent as fractions of the crop width, and
/// the line score.
type LineResult = (Vec<(String, f32, f32)>, f32);

fn recognize_lines(engine: &mut Engine, crops: &[RgbImage]) -> Result<Vec<LineResult>, String> {
    let mut order: Vec<usize> = (0..crops.len()).collect();
    let ratio = |i: usize| crops[i].width() as f32 / crops[i].height() as f32;
    order.sort_by(|&a, &b| ratio(a).total_cmp(&ratio(b)));
    let mut results: Vec<LineResult> = vec![(Vec::new(), 0.0); crops.len()];

    for batch in order.chunks(REC_BATCH) {
        let max_ratio = batch.iter().map(|&i| ratio(i)).fold(REC_WIDTH as f32 / REC_HEIGHT as f32, f32::max);
        let width = (REC_HEIGHT as f32 * max_ratio) as u32;
        let mut data = Vec::with_capacity(batch.len() * 3 * (REC_HEIGHT * width) as usize);
        let mut resized_widths = Vec::with_capacity(batch.len());
        for &i in batch {
            let rw = ((REC_HEIGHT as f32 * ratio(i)).ceil() as u32).clamp(1, width);
            let resized = imageops::resize(&crops[i], rw, REC_HEIGHT, FilterType::Triangle);
            data.extend(to_tensor(&resized, width));
            resized_widths.push(rw);
        }
        let input = Tensor::from_array(([batch.len(), 3, REC_HEIGHT as usize, width as usize], data)).map_err(|e| e.to_string())?;
        let outputs = engine.rec.run(ort::inputs![input]).map_err(|e| format!("recognition: {e}"))?;
        let (shape, probs) = outputs[0].try_extract_tensor::<f32>().map_err(|e| e.to_string())?;
        let (steps, classes) = (shape[1] as usize, shape[2] as usize);
        for (k, &i) in batch.iter().enumerate() {
            let seq = &probs[k * steps * classes..(k + 1) * steps * classes];
            // Fraction of the crop covered by one time step.
            let step = width as f32 / steps as f32 / resized_widths[k] as f32;
            results[i] = decode(seq, steps, classes, &engine.chars, step);
        }
    }
    Ok(results)
}

/// Greedy CTC decoding into words (split on spaces) with their extents.
fn decode(seq: &[f32], steps: usize, classes: usize, chars: &[String], step: f32) -> LineResult {
    let mut kept: Vec<(usize, usize, f32)> = Vec::new(); // (time step, class, prob)
    let mut prev = usize::MAX;
    for t in 0..steps {
        let row = &seq[t * classes..(t + 1) * classes];
        let (best, p) = row.iter().enumerate().fold((0, f32::MIN), |acc, (c, &v)| if v > acc.1 { (c, v) } else { acc });
        if best != 0 && best != prev {
            kept.push((t, best, p));
        }
        prev = best;
    }
    if kept.is_empty() {
        return (Vec::new(), 0.0);
    }
    let score = kept.iter().map(|k| k.2).sum::<f32>() / kept.len() as f32;
    let mut words = Vec::new();
    let mut current = String::new();
    let mut span: Option<(usize, usize)> = None;
    let mut flush = |current: &mut String, span: &mut Option<(usize, usize)>| {
        if let Some((a, b)) = span.take() {
            if !current.is_empty() {
                words.push((std::mem::take(current), (a as f32 * step).min(1.0), ((b + 1) as f32 * step).min(1.0)));
            }
        }
        current.clear();
    };
    for &(t, c, _) in &kept {
        let ch = chars.get(c).map(String::as_str).unwrap_or("");
        if ch == " " {
            flush(&mut current, &mut span);
            continue;
        }
        current.push_str(ch);
        span = Some(span.map_or((t, t), |(a, _)| (a, t)));
    }
    flush(&mut current, &mut span);
    (words, score)
}
