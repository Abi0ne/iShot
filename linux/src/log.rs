//! Always-on diagnostic log in `~/.cache/ishot/ishot.log` (rotated at 1 MB), crash capture and
//! detection of a previous run that ended abnormally.
//!
//! - Our own messages go through `logln!` (timestamped).
//! - When iShot runs without a terminal (menu, autostart), stderr is redirected to the log too, so
//!   GTK warnings and X errors end up there as well.
//! - A panic writes its message and location to `crash.txt`.
//! - `running` holds the PID of the primary instance; if it is still there at the next start, the
//!   previous run did not quit cleanly (crash, abort, kill).

use gtk::glib;
use std::io::Write;
use std::path::PathBuf;
use std::sync::Mutex;

static FILE: Mutex<Option<std::fs::File>> = Mutex::new(None);
static TO_STDERR: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(true);

pub fn dir() -> PathBuf {
    glib::user_cache_dir().join("ishot")
}

pub fn path() -> PathBuf {
    dir().join("ishot.log")
}

fn crash_path() -> PathBuf {
    dir().join("crash.txt")
}

fn running_path() -> PathBuf {
    dir().join("running")
}

fn timestamp() -> String {
    glib::DateTime::now_local()
        .and_then(|d| d.format("%Y-%m-%d %H:%M:%S"))
        .map(|s| s.to_string())
        .unwrap_or_default()
}

/// Opens the log (rotating it when large), redirects stderr when there is no terminal and
/// installs the panic hook. Call once, early.
pub fn init() {
    let _ = std::fs::create_dir_all(dir());
    let log = path();
    if std::fs::metadata(&log).map(|m| m.len() > 1024 * 1024).unwrap_or(false) {
        let _ = std::fs::rename(&log, dir().join("ishot.log.1"));
    }
    let Ok(file) = std::fs::OpenOptions::new().create(true).append(true).open(&log) else { return };

    // SAFETY: isatty/dup2 on file descriptors we own; done before any other thread starts.
    let interactive = unsafe { libc::isatty(2) } == 1;
    if !interactive {
        use std::os::fd::AsRawFd;
        unsafe {
            libc::dup2(file.as_raw_fd(), 2);
        }
        // stderr *is* the log now: don't write lines twice.
        TO_STDERR.store(false, std::sync::atomic::Ordering::SeqCst);
    }
    *FILE.lock().unwrap() = Some(file);

    let default_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let location = info.location().map(|l| format!("{}:{}", l.file(), l.line())).unwrap_or_default();
        let message = info
            .payload()
            .downcast_ref::<&str>()
            .map(|s| s.to_string())
            .or_else(|| info.payload().downcast_ref::<String>().cloned())
            .unwrap_or_else(|| "unknown panic".into());
        let thread = std::thread::current().name().unwrap_or("unnamed").to_string();
        let report = format!(
            "[{}] iShot {} crashed in thread '{thread}' at {location}: {message}\n{}",
            timestamp(),
            crate::updater::VERSION,
            std::backtrace::Backtrace::force_capture()
        );
        line(&format!("CRASH at {location}: {message}"));
        let _ = std::fs::write(crash_path(), &report);
        default_hook(info);
    }));
}

/// Writes one timestamped line to the log (and to the terminal when there is one).
pub fn line(message: &str) {
    let text = format!("[{}] {message}\n", timestamp());
    if TO_STDERR.load(std::sync::atomic::Ordering::SeqCst) {
        eprint!("{text}");
    }
    if let Ok(mut guard) = FILE.lock() {
        if let Some(f) = guard.as_mut() {
            let _ = f.write_all(text.as_bytes());
            let _ = f.flush();
        }
    }
}

#[macro_export]
macro_rules! logln {
    ($($arg:tt)*) => { $crate::log::line(&format!($($arg)*)) };
}

/// Marks this process as the running iShot. Returns true when the previous run ended abnormally.
pub fn mark_running() -> bool {
    let previous = std::fs::read_to_string(running_path()).ok();
    let crashed = match previous.as_deref().map(str::trim).and_then(|p| p.parse::<u32>().ok()) {
        // Still alive → not a crash (another iShot); gone → it never cleaned up.
        Some(pid) => pid != std::process::id() && !PathBuf::from(format!("/proc/{pid}")).exists(),
        None => false,
    };
    let _ = std::fs::write(running_path(), std::process::id().to_string());
    crashed || crash_path().exists()
}

/// Clean shutdown: the next start will not report a crash.
pub fn mark_stopped() {
    let _ = std::fs::remove_file(running_path());
}

/// Details of the last panic, if any.
pub fn last_crash() -> Option<String> {
    std::fs::read_to_string(crash_path()).ok()
}

/// Forget the last crash once it has been reported or dismissed.
pub fn clear_crash() {
    let _ = std::fs::remove_file(crash_path());
}

/// The last `max_lines` lines of the log (current file, plus the rotated one if needed).
pub fn tail(max_lines: usize) -> String {
    let mut lines: Vec<String> = Vec::new();
    for file in [dir().join("ishot.log.1"), path()] {
        if let Ok(text) = std::fs::read_to_string(file) {
            lines.extend(text.lines().map(str::to_string));
        }
    }
    let start = lines.len().saturating_sub(max_lines);
    lines[start..].join("\n")
}
