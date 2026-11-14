//! Text recognition: words with their boxes, so the editor can lay them over the image as
//! selectable text. RapidOCR (PP-OCRv6, bundled models) is the main engine; Tesseract
//! (`tesseract … tsv`) is the fallback when the models are missing or fail to load.

use crate::shot::Rect;
use std::process::Command;

#[derive(Clone, Debug)]
pub struct Word {
    pub text: String,
    pub rect: Rect,
    /// (block, paragraph, line): words sharing it are on the same line.
    pub line: (u32, u32, u32),
}

/// Languages to use: Italian and English when installed, otherwise whatever is there.
fn languages() -> String {
    let out = Command::new("tesseract").arg("--list-langs").output();
    let installed: Vec<String> = out
        .map(|o| String::from_utf8_lossy(&o.stdout).lines().skip(1).map(|l| l.trim().to_string()).collect())
        .unwrap_or_default();
    let mut wanted: Vec<&str> = ["ita", "eng"].into_iter().filter(|l| installed.iter().any(|i| i == l)).collect();
    if wanted.is_empty() {
        if let Some(first) = installed.iter().find(|l| *l != "osd") {
            return first.clone();
        }
        return "eng".into();
    }
    wanted.dedup();
    wanted.join("+")
}

/// Which engine OCR will use, for the UI.
pub fn engine_name() -> Option<&'static str> {
    if crate::ocr_rapid::available() {
        Some("RapidOCR (PP-OCRv6)")
    } else if crate::util::has_program("tesseract") {
        Some("Tesseract")
    } else {
        None
    }
}

/// Recognizes text in PNG bytes with the best engine available. Blocking: call from a worker thread.
pub fn recognize(png: &[u8]) -> Result<Vec<Word>, String> {
    if crate::ocr_rapid::available() {
        match crate::ocr_rapid::recognize(png) {
            Ok(words) => return Ok(words),
            Err(err) if crate::util::has_program("tesseract") => eprintln!("iShot: RapidOCR failed ({err}), using Tesseract"),
            Err(err) => return Err(err),
        }
    }
    recognize_tesseract(png)
}

fn recognize_tesseract(png: &[u8]) -> Result<Vec<Word>, String> {
    let dir = std::env::temp_dir().join(format!("ishot-ocr-{}", std::process::id()));
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let input = dir.join("input.png");
    std::fs::write(&input, png).map_err(|e| e.to_string())?;
    let output = Command::new("tesseract")
        .arg(&input)
        .arg("stdout")
        .args(["-l", &languages(), "--psm", "3", "tsv"])
        .output()
        .map_err(|e| format!("cannot run tesseract: {e}"))?;
    let _ = std::fs::remove_dir_all(&dir);
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_string());
    }
    Ok(parse_tsv(&String::from_utf8_lossy(&output.stdout)))
}

fn parse_tsv(tsv: &str) -> Vec<Word> {
    // level page_num block_num par_num line_num word_num left top width height conf text
    tsv.lines()
        .skip(1)
        .filter_map(|line| {
            let cols: Vec<&str> = line.splitn(12, '\t').collect();
            if cols.len() < 12 || cols[0] != "5" {
                return None;
            }
            let text = cols[11].trim();
            let conf: f64 = cols[10].parse().unwrap_or(-1.0);
            if text.is_empty() || conf < 0.0 {
                return None;
            }
            let n = |i: usize| cols[i].parse::<f64>().unwrap_or(0.0);
            let line_key = (n(2) as u32, n(3) as u32, n(4) as u32);
            Some(Word { text: text.to_string(), rect: Rect::new(n(6), n(7), n(8), n(9)), line: line_key })
        })
        .collect()
}

/// Joins words into text: spaces within a line, newlines between lines, blank lines between blocks.
pub fn join(words: &[Word]) -> String {
    let mut out = String::new();
    let mut prev: Option<(u32, u32, u32)> = None;
    for w in words {
        if let Some(p) = prev {
            if p == w.line {
                out.push(' ');
            } else if p.0 != w.line.0 || p.1 != w.line.1 {
                out.push_str("\n\n");
            } else {
                out.push('\n');
            }
        }
        out.push_str(&w.text);
        prev = Some(w.line);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_and_joins() {
        let tsv = "level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext\n\
                   5\t1\t1\t1\t1\t1\t10\t10\t40\t12\t95\tCiao\n\
                   5\t1\t1\t1\t1\t2\t55\t10\t40\t12\t95\tmondo\n\
                   5\t1\t1\t1\t2\t1\t10\t30\t40\t12\t90\tsecond\n\
                   5\t1\t2\t1\t1\t1\t10\t60\t40\t12\t90\tblock\n";
        let words = parse_tsv(tsv);
        assert_eq!(words.len(), 4);
        assert_eq!(join(&words), "Ciao mondo\nsecond\n\nblock");
    }
}
