//! Screen recording.
//!
//! - X11: ffmpeg `x11grab` of the monitor under the pointer → H.264 MP4.
//! - Wayland: ScreenCast portal (the desktop asks what to share) → PipeWire stream recorded by
//!   `gst-launch-1.0` → H.264 MP4.

use crate::env::Env;
use crate::util;
use gtk::prelude::*;
use gtk::{gdk, gio};
use std::cell::RefCell;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};

enum Kind {
    Ffmpeg,
    Gst,
}

struct Active {
    child: Child,
    output: PathBuf,
    kind: Kind,
    log: PathBuf,
    /// Keeps the portal session (and its PipeWire stream) alive while recording.
    _portal: Option<Box<dyn std::any::Any>>,
}

#[derive(Default)]
pub struct Recorder {
    active: RefCell<Option<Active>>,
}

fn log_path() -> PathBuf {
    let dir = gtk::glib::user_runtime_dir().join("ishot");
    let _ = std::fs::create_dir_all(&dir);
    dir.join("recorder.log")
}

fn read_log(path: &PathBuf) -> String {
    let text = std::fs::read_to_string(path).unwrap_or_default();
    let tail: Vec<&str> = text.lines().rev().take(6).collect();
    tail.into_iter().rev().collect::<Vec<_>>().join("\n")
}

/// Physical rect (x, y, w, h) of the monitor under the pointer (X11).
fn monitor_under_pointer() -> Option<(i32, i32, i32, i32)> {
    let display = gdk::Display::default()?;
    let (px, py) = crate::capture::x11_pointer().unwrap_or((0.0, 0.0));
    let monitors: Vec<gdk::Monitor> = (0..display.monitors().n_items())
        .filter_map(|i| display.monitors().item(i).and_downcast::<gdk::Monitor>())
        .collect();
    let rects: Vec<(i32, i32, i32, i32)> = monitors
        .iter()
        .map(|m| {
            let g = m.geometry();
            let s = m.scale_factor();
            (g.x() * s, g.y() * s, g.width() * s, g.height() * s)
        })
        .collect();
    rects
        .iter()
        .copied()
        .find(|&(x, y, w, h)| px >= x as f64 && py >= y as f64 && px < (x + w) as f64 && py < (y + h) as f64)
        .or_else(|| rects.first().copied())
}

impl Recorder {
    pub fn is_recording(&self) -> bool {
        self.active.borrow().is_some()
    }

    pub async fn start(&self, env: &Env, output: PathBuf) -> Result<(), String> {
        if self.is_recording() {
            return Ok(());
        }
        if let Some(dir) = output.parent() {
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        }
        let log = log_path();
        let log_file = std::fs::File::create(&log).map_err(|e| e.to_string())?;
        let active = if env.is_x11() {
            if !env.ffmpeg {
                return Err("Screen recording needs ffmpeg: sudo apt install ffmpeg".into());
            }
            let (x, y, w, h) = monitor_under_pointer().ok_or("no monitor found")?;
            let display = std::env::var("DISPLAY").unwrap_or_else(|_| ":0".into());
            let child = Command::new("ffmpeg")
                .args(["-y", "-loglevel", "error", "-f", "x11grab", "-framerate", "30", "-draw_mouse", "1"])
                .args(["-video_size", &format!("{}x{}", w & !1, h & !1)])
                .args(["-i", &format!("{display}+{x},{y}")])
                .args(["-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p"])
                .arg(&output)
                .stdin(Stdio::piped())
                .stdout(Stdio::null())
                .stderr(log_file)
                .spawn()
                .map_err(|e| format!("cannot run ffmpeg: {e}"))?;
            Active { child, output, kind: Kind::Ffmpeg, log, _portal: None }
        } else {
            if !(env.portal_screencast && env.gst_launch) {
                return Err("Screen recording on Wayland needs the ScreenCast portal and GStreamer:\nsudo apt install gstreamer1.0-tools gstreamer1.0-pipewire gstreamer1.0-plugins-good gstreamer1.0-plugins-ugly".into());
            }
            self.start_portal(output, log, log_file).await?
        };
        *self.active.borrow_mut() = Some(active);

        // Fail fast if the recorder exits right away (bad device, missing codec…).
        gtk::glib::timeout_future(std::time::Duration::from_millis(700)).await;
        let failed = {
            let mut guard = self.active.borrow_mut();
            match guard.as_mut().map(|a| a.child.try_wait()) {
                Some(Ok(Some(_))) => guard.take(),
                _ => None,
            }
        };
        if let Some(a) = failed {
            return Err(format!("The recorder stopped immediately.\n{}", read_log(&a.log)));
        }
        Ok(())
    }

    async fn start_portal(&self, output: PathBuf, log: PathBuf, log_file: std::fs::File) -> Result<Active, String> {
        use ashpd::desktop::screencast::{CursorMode, Screencast, SelectSourcesOptions, SourceType};
        use ashpd::desktop::PersistMode;
        use std::os::fd::AsRawFd;
        use std::os::unix::process::CommandExt;

        let err = |e: ashpd::Error| format!("ScreenCast portal: {e}");
        let proxy = Screencast::new().await.map_err(err)?;
        let session = proxy.create_session(Default::default()).await.map_err(err)?;
        proxy
            .select_sources(
                &session,
                SelectSourcesOptions::default()
                    .set_cursor_mode(CursorMode::EMBEDDED)
                    .set_sources(SourceType::MONITOR)
                    .set_multiple(false)
                    .set_persist_mode(PersistMode::DoNot),
            )
            .await
            .map_err(err)?;
        let streams = proxy.start(&session, None, Default::default()).await.map_err(err)?.response().map_err(err)?;
        let node = streams.streams().first().ok_or("the portal returned no stream")?.pipe_wire_node_id();
        let fd = proxy.open_pipe_wire_remote(&session, Default::default()).await.map_err(err)?;
        let raw = fd.as_raw_fd();

        let mut cmd = Command::new("gst-launch-1.0");
        cmd.args(["-e", "pipewiresrc", "fd=3", &format!("path={node}"), "do-timestamp=true", "keepalive-time=1000", "always-copy=true"])
            .args(["!", "videoconvert", "!", "queue", "!", "x264enc", "speed-preset=veryfast", "tune=zerolatency"])
            .args(["!", "video/x-h264,profile=baseline", "!", "mp4mux", "!", "filesink"])
            .arg(format!("location={}", output.display()))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(log_file);
        // SAFETY: dup2 is async-signal-safe; it maps the PipeWire fd to fd 3 in the child.
        unsafe {
            cmd.pre_exec(move || {
                if libc::dup2(raw, 3) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let child = cmd.spawn().map_err(|e| format!("cannot run gst-launch-1.0: {e}"))?;
        Ok(Active { child, output, kind: Kind::Gst, log, _portal: Some(Box::new((proxy, session, fd))) })
    }

    /// Stops recording and returns the file.
    pub async fn stop(&self) -> Result<PathBuf, String> {
        let Some(mut active) = self.active.borrow_mut().take() else { return Err("not recording".into()) };
        match active.kind {
            Kind::Ffmpeg => {
                if let Some(stdin) = active.child.stdin.as_mut() {
                    let _ = stdin.write_all(b"q\n");
                    let _ = stdin.flush();
                }
            }
            Kind::Gst => unsafe {
                libc::kill(active.child.id() as libc::pid_t, libc::SIGINT);
            },
        }
        let output = active.output.clone();
        let log = active.log.clone();
        let mut child = active.child;
        let status = gio::spawn_blocking(move || child.wait()).await.map_err(|_| "recorder wait failed".to_string())?;
        drop(active._portal);
        match status {
            Ok(_) if output.exists() && std::fs::metadata(&output).map(|m| m.len() > 0).unwrap_or(false) => Ok(output),
            _ => Err(format!("The recording could not be saved.\n{}", read_log(&log))),
        }
    }
}

pub fn output_path(dir: PathBuf, prefix: &str) -> PathBuf {
    util::unique_path(&dir, &util::file_name(prefix, "mp4"))
}
