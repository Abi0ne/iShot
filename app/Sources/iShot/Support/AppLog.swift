import Foundation
import Darwin

/// Always-on log in `~/Library/Logs/iShot/iShot.log` (rotated at 1 MB into `iShot.log.1`), plus
/// crash detection:
/// - a `running` marker exists while iShot runs and is removed on a clean quit, so at the next
///   launch a leftover marker means the previous run ended unexpectedly;
/// - fatal signals and uncaught Objective-C exceptions write `crash.txt` (with a backtrace);
/// - macOS's own crash report (`~/Library/Logs/DiagnosticReports/iShot-*.ips`) is summarized too.
enum AppLog {
    static let directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/iShot", isDirectory: true)
    static let logURL = directory.appendingPathComponent("iShot.log")
    static let crashURL = directory.appendingPathComponent("crash.txt")
    private static let markerURL = directory.appendingPathComponent("running")
    private static let maxSize = 1_000_000

    private static let queue = DispatchQueue(label: "iShot.log")
    private static var handle: FileHandle?
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Set at launch: what the previous run left behind, when it did not quit cleanly.
    private(set) static var previousRunCrashed = false
    /// When this process started (crash reports newer than the previous launch belong to it).
    private static var previousLaunch: Date?

    // MARK: - Setup

    static func start() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        rotateIfNeeded()
        // O_APPEND: stderr (below) writes to the same file.
        let logFD = open(logURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        if logFD >= 0 { handle = FileHandle(fileDescriptor: logFD, closeOnDealloc: true) }

        // Started from Finder/launchd: send stderr (system and framework messages) to the log too.
        if isatty(STDERR_FILENO) == 0 {
            let fd = open(logURL.path, O_WRONLY | O_APPEND)
            if fd >= 0 {
                dup2(fd, STDERR_FILENO)
                close(fd)
            }
        }

        if let marker = try? String(contentsOf: markerURL, encoding: .utf8) {
            previousRunCrashed = true
            let attrs = try? FileManager.default.attributesOfItem(atPath: markerURL.path)
            previousLaunch = attrs?[.modificationDate] as? Date
            write("previous run (pid \(marker.trimmingCharacters(in: .whitespacesAndNewlines))) did not quit cleanly")
        }
        try? "\(getpid())".write(to: markerURL, atomically: true, encoding: .utf8)

        installCrashHandlers()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        write("iShot \(version) starting (pid \(getpid())) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    /// Clean quit: the next launch must not report a crash.
    static func markStopped() {
        write("iShot quitting")
        try? FileManager.default.removeItem(at: markerURL)
    }

    private static func rotateIfNeeded() {
        let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int) ?? 0
        guard size > maxSize else { return }
        let old = directory.appendingPathComponent("iShot.log.1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: logURL, to: old)
    }

    // MARK: - Writing

    static func write(_ message: String) {
        let line = "[\(stampFormatter.string(from: Date()))] \(message)\n"
        queue.sync {
            if let data = line.data(using: .utf8) { try? handle?.write(contentsOf: data) }
        }
        if isatty(STDERR_FILENO) != 0 { FileHandle.standardError.write(Data(("iShot: " + message + "\n").utf8)) }
    }

    /// Last `count` lines of the log (current file, preceded by the rotated one if needed).
    static func tail(_ count: Int) -> String {
        queue.sync { try? handle?.synchronize() }
        let old = (try? String(contentsOf: directory.appendingPathComponent("iShot.log.1"), encoding: .utf8)) ?? ""
        let current = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        let lines = (old + current).split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(count).joined(separator: "\n")
    }

    // MARK: - Crashes

    /// What is known about the previous crash: our own crash.txt and macOS's crash report.
    static func lastCrash() -> String? {
        var parts: [String] = []
        if let text = try? String(contentsOf: crashURL, encoding: .utf8), !text.isEmpty {
            parts.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let report = systemCrashReport() { parts.append(report) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    static func clearCrash() {
        try? FileManager.default.removeItem(at: crashURL)
        previousRunCrashed = false
    }

    /// Summary of the newest `iShot-*.ips` written since the previous launch: exception and the
    /// crashed thread's frames.
    private static func systemCrashReport() -> String? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let since = previousLaunch ?? Date.distantPast
        let newest = files
            .filter { $0.lastPathComponent.hasPrefix("iShot") && $0.pathExtension == "ips" }
            .compactMap { url -> (URL, Date)? in
                guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      date >= since else { return nil }
                return (url, date)
            }
            .max { $0.1 < $1.1 }
        guard let (url, _) = newest, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        // .ips = one JSON header line, then the JSON report.
        guard let split = text.firstIndex(of: "\n"),
              let data = String(text[text.index(after: split)...]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "macOS crash report: \(url.lastPathComponent) (unreadable)"
        }
        var out = ["macOS crash report: \(url.lastPathComponent)"]
        if let exception = json["exception"] as? [String: Any] {
            out.append("Exception: \(exception["type"] ?? "?") \(exception["signal"] ?? "") \(exception["subtype"] ?? "")")
        }
        if let termination = json["termination"] as? [String: Any], let indicator = termination["indicator"] {
            out.append("Termination: \(indicator)")
        }
        if let asi = json["asi"] as? [String: Any] {
            for (_, value) in asi { if let lines = value as? [String] { out.append(contentsOf: lines.prefix(3)) } }
        }
        let images = (json["usedImages"] as? [[String: Any]]) ?? []
        if let threads = json["threads"] as? [[String: Any]],
           let faulting = json["faultingThread"] as? Int, faulting < threads.count,
           let frames = threads[faulting]["frames"] as? [[String: Any]] {
            out.append("Crashed thread \(faulting):")
            for (i, frame) in frames.prefix(25).enumerated() {
                let imageIndex = frame["imageIndex"] as? Int ?? -1
                let image = imageIndex >= 0 && imageIndex < images.count ? (images[imageIndex]["name"] as? String ?? "?") : "?"
                let symbol = frame["symbol"] as? String ?? "0x" + String(frame["imageOffset"] as? Int ?? 0, radix: 16)
                out.append("  \(i) \(image)  \(symbol)")
            }
        }
        return out.joined(separator: "\n")
    }

    private static func installCrashHandlers() {
        crashPath = strdup(crashURL.path)
        NSSetUncaughtExceptionHandler { exception in
            let text = "Uncaught exception: \(exception.name.rawValue): \(exception.reason ?? "")\n"
                + exception.callStackSymbols.joined(separator: "\n") + "\n"
            try? text.write(to: AppLog.crashURL, atomically: true, encoding: .utf8)
        }
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP] {
            signal(sig, crashSignalHandler)
        }
    }
}

/// C string path of crash.txt, prepared in advance: a signal handler must not allocate.
private var crashPath: UnsafeMutablePointer<CChar>?

/// Writes the signal and a backtrace (async-signal-safe calls only), then lets the default action
/// run so macOS still writes its crash report.
private func crashSignalHandler(_ sig: Int32) {
    if let path = crashPath {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd >= 0 {
            let header: StaticString
            switch sig {
            case SIGSEGV: header = "Fatal signal SIGSEGV (bad memory access)\n"
            case SIGBUS: header = "Fatal signal SIGBUS (bad memory access)\n"
            case SIGILL: header = "Fatal signal SIGILL (illegal instruction)\n"
            case SIGFPE: header = "Fatal signal SIGFPE (arithmetic error)\n"
            case SIGABRT: header = "Fatal signal SIGABRT (abort)\n"
            case SIGTRAP: header = "Fatal signal SIGTRAP (Swift runtime error)\n"
            default: header = "Fatal signal\n"
            }
            _ = Darwin.write(fd, header.utf8Start, header.utf8CodeUnitCount)
            withUnsafeTemporaryAllocation(of: UnsafeMutableRawPointer?.self, capacity: 64) { frames in
                let count = backtrace(frames.baseAddress, 64)
                backtrace_symbols_fd(frames.baseAddress, count, fd)
            }
            close(fd)
        }
    }
    signal(sig, SIG_DFL)
    raise(sig)
}
