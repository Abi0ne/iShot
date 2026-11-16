import AppKit
import VisionKit

/// "Report a Problem…": gathers a description, system diagnostics and the end of the log, lets the
/// user review (and edit) everything, then opens a pre-filled GitHub issue in the browser. The
/// user submits it with their own GitHub account: iShot holds no token and sends nothing by itself.
final class ReportWindowController: NSWindowController, NSWindowDelegate {
    private static let newIssueURL = "https://github.com/Abi0ne/iShot/issues/new"
    /// GitHub accepts URLs up to ~8 KB: keep the encoded body below that.
    private static let maxURLLength = 7600

    private static var current: ReportWindowController?

    private let crashed: Bool
    private let titleField = NSTextField()
    private let descriptionView = NSTextView()
    private let reportView = NSTextView()

    static func present(crashed: Bool) {
        if let current {
            current.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = ReportWindowController(crashed: crashed)
        current = controller
        controller.window?.center()
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(crashed: Bool) {
        self.crashed = crashed
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Report a Problem"
        window.minSize = NSSize(width: 520, height: 440)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI(in: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - UI

    private func buildUI(in window: NSWindow) {
        let intro = NSTextField(wrappingLabelWithString: crashed
            ? "iShot closed unexpectedly last time. Describe what you were doing, check the report below, then open it on GitHub and press “Submit new issue”."
            : "Describe the problem, check the report below (you can edit or remove anything), then open it on GitHub and press “Submit new issue”.")

        titleField.placeholderString = "Short title, e.g. “Window capture is blank”"
        if crashed { titleField.stringValue = "iShot crashed" }

        let descLabel = NSTextField(labelWithString: "What happened? What did you expect?")
        let descScroll = Self.scrolling(descriptionView, monospace: false)
        descScroll.heightAnchor.constraint(equalToConstant: 100).isActive = true

        let reportLabel = NSTextField(labelWithString: "Report (user name and home folder already hidden):")
        let reportScroll = Self.scrolling(reportView, monospace: true)
        reportScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        reportView.string = Self.initialReport(crashed: crashed)

        let logButton = NSButton(title: "Show Log in Finder", target: self, action: #selector(showLog))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let send = NSButton(title: "Open on GitHub", target: self, action: #selector(openOnGitHub))
        send.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [logButton, spacer, cancel, send])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [intro, titleField, descLabel, descScroll, reportLabel, reportScroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [intro, titleField, descScroll, reportScroll, buttons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }

        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        ])
        window.initialFirstResponder = crashed ? descriptionView : titleField
    }

    private static func scrolling(_ textView: NSTextView, monospace: Bool) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = monospace ? .monospacedSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        return scroll
    }

    // MARK: - Content

    private static func initialReport(crashed: Bool) -> String {
        var text = "### System\n\n" + diagnostics() + "\n"
        if crashed, let crash = AppLog.lastCrash() {
            text += "\n### Crash\n\n" + crash + "\n"
        }
        text += "\n### Log (last lines)\n\n" + AppLog.tail(150)
        return redact(text)
    }

    static func diagnostics() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        var lines = [
            "iShot \(version) (build \(build), \(arch))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(hardwareModel())",
            "Locale: \(Locale.current.identifier)",
            "Installed at: \(Bundle.main.bundlePath)"
        ]
        for (i, screen) in NSScreen.screens.enumerated() {
            let f = screen.frame
            lines.append("Screen \(i + 1): \(Int(f.width))×\(Int(f.height)) pt @\(screen.backingScaleFactor)x")
        }
        lines.append("\(ScreenCapture.hasPermission ? "✓" : "✗") Screen Recording permission")
        lines.append("\(ImageAnalyzer.isSupported ? "✓" : "✗") Live Text (OCR)")
        let settings = SettingsStore.shared
        for action in ShortcutAction.allCases {
            lines.append("Shortcut \(action.title): \(settings.hotkey(for: action)?.displayString ?? "off")")
        }
        return lines.joined(separator: "\n")
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    /// Hides the user name and home folder.
    static func redact(_ text: String) -> String {
        var out = text
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if home.count > 1 { out = out.replacingOccurrences(of: home, with: "~") }
        for name in [NSUserName(), NSFullUserName()] where name.count > 2 {
            out = out.replacingOccurrences(of: name, with: "<user>")
        }
        return out
    }

    private static func body(description: String, report: String) -> String {
        // The report shown is plain text with "### " headings: wrap each section in a code block.
        var body = "### What happened\n\n\(description)\n"
        let sections = report.components(separatedBy: "### ").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        for section in sections {
            let (heading, content): (String, String)
            if let newline = section.firstIndex(of: "\n") {
                heading = String(section[..<newline]).trimmingCharacters(in: .whitespaces)
                content = String(section[section.index(after: newline)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                (heading, content) = ("Details", section.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            body += "\n### \(heading)\n\n```\n\(content)\n```\n"
        }
        return body
    }

    private static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// Issue URL; when the report is too long for a URL, the end of it is cut (the caller puts the
    /// full report on the clipboard and in a file).
    private static func issueURL(title: String, body: String) -> (URL, shortened: Bool) {
        func make(_ b: String) -> String {
            "\(newIssueURL)?labels=bug&title=\(encode(title))&body=\(encode(b))"
        }
        let full = make(body)
        if full.count <= maxURLLength { return (URL(string: full)!, false) }
        let note = "\n```\n\n_(Report shortened: the full report is pasted below from the clipboard.)_\n"
        var cut = body.count
        while cut > 0 {
            cut = max(0, cut - 400)
            let candidate = make(String(body.prefix(cut)) + note)
            if candidate.count <= maxURLLength { return (URL(string: candidate)!, true) }
        }
        return (URL(string: make(note))!, true)
    }

    // MARK: - Actions

    @objc private func showLog() {
        NSWorkspace.shared.activateFileViewerSelecting([AppLog.logURL])
    }

    @objc private func cancelClicked() {
        if crashed { AppLog.clearCrash() }
        close()
    }

    @objc private func openOnGitHub() {
        let desc = descriptionView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = desc.isEmpty ? "_(no description)_" : Self.redact(desc)
        let body = Self.body(description: description, report: reportView.string)
        var title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = "Problem report" }
        let (url, shortened) = Self.issueURL(title: "[macOS] \(title)", body: body)

        AppLog.write("report: opening GitHub issue form (\(body.utf8.count) bytes\(shortened ? ", shortened" : ""))")
        AppLog.clearCrash()
        if shortened {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(body, forType: .string)
            let file = AppLog.directory.appendingPathComponent("report.md")
            try? body.write(to: file, atomically: true, encoding: .utf8)
            let alert = NSAlert()
            alert.messageText = "The report is long"
            alert.informativeText = "GitHub opens with a shortened report. The full report is on the clipboard (paste it as a comment) and saved in\n\(Self.redact(file.path))"
            alert.runModal()
        }
        if !NSWorkspace.shared.open(url) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            let alert = NSAlert()
            alert.messageText = "Could not open the browser"
            alert.informativeText = "The GitHub link is on the clipboard: paste it into your browser."
            alert.runModal()
        }
        close()
    }

    func windowWillClose(_ notification: Notification) {
        Self.current = nil
    }
}
