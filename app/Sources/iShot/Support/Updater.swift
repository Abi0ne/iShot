import AppKit
import Security

enum UpdateError: LocalizedError {
    case badResponse(Int)
    case noAsset
    case unzipFailed
    case appMissingInArchive
    case signatureMismatch
    case notInstalledApp
    case notWritable(String)

    var errorDescription: String? {
        switch self {
        case let .badResponse(code): return "GitHub answered with HTTP \(code)."
        case .noAsset: return "The release has no “\(Updater.assetName)” file to download."
        case .unzipFailed: return "The downloaded update could not be extracted."
        case .appMissingInArchive: return "The downloaded update does not contain iShot.app."
        case .signatureMismatch:
            return "The downloaded app is not signed with the same certificate as this copy of iShot, so it was not installed."
        case .notInstalledApp: return "iShot is not running from an app bundle, so it cannot update itself."
        case let .notWritable(path): return "iShot cannot write to \(path)."
        }
    }
}

/// Self-updater backed by the GitHub Releases of the project.
///
/// A release is an update when its tag (`vX.Y.Z`) is newer than `CFBundleShortVersionString`
/// and it carries an `iShot.zip` asset (made by `scripts/release.sh`). Before installing, the
/// downloaded app must satisfy this app's designated requirement, i.e. be signed with the same
/// certificate: an update can never swap in an app signed by someone else.
@MainActor
final class Updater {
    nonisolated static let shared = Updater()

    nonisolated private init() {}

    nonisolated static let repository = "Abi0ne/iShot"
    nonisolated static let assetName = "iShot.zip"

    struct Release {
        let version: String
        let notes: String
        let pageURL: URL
        let downloadURL: URL
    }

    private var settings: SettingsStore { .shared }
    private var isBusy = false

    nonisolated var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: - Checking

    /// Called at launch: quiet unless an update is available.
    nonisolated func checkOnLaunch() {
        Task { @MainActor in
            guard settings.checkForUpdates, Bundle.main.bundleURL.pathExtension == "app" else { return }
            // Let the app finish launching before hitting the network.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await check(userInitiated: false)
        }
    }

    /// "Check for Updates…" from the menu: always reports the outcome.
    nonisolated func checkNow() {
        Task { @MainActor in await check(userInitiated: true) }
    }

    private func check(userInitiated: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            guard let release = try await fetchLatestRelease(),
                  Self.isVersion(release.version, newerThan: currentVersion) else {
                if userInitiated {
                    showInfo("iShot is up to date", "You have the latest version (\(currentVersion)).")
                }
                return
            }
            if !userInitiated, settings.skippedVersion == release.version { return }
            await offer(release)
        } catch {
            NSLog("iShot: update check failed: \(error.localizedDescription)")
            if userInitiated { showInfo("Could not check for updates", error.localizedDescription) }
        }
    }

    private func fetchLatestRelease() async throws -> Release? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("iShot/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }   // no release published yet
        guard status == 200 else { throw UpdateError.badResponse(status) }

        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let tag_name: String
            let body: String?
            let html_url: URL
            let draft: Bool
            let prerelease: Bool
            let assets: [Asset]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard !payload.draft, !payload.prerelease else { return nil }
        guard let asset = payload.assets.first(where: { $0.name == Self.assetName }) else { throw UpdateError.noAsset }
        let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        return Release(version: version, notes: payload.body ?? "", pageURL: payload.html_url,
                       downloadURL: asset.browser_download_url)
    }

    // MARK: - Installing

    private func offer(_ release: Release) async {
        let alert = NSAlert()
        alert.messageText = "iShot \(release.version) is available"
        var info = "You have version \(currentVersion). Install the update now? iShot will relaunch."
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { info += "\n\n" + String(notes.prefix(800)) }
        alert.informativeText = info
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            do {
                try await install(release)
            } catch {
                showInfo("Update failed", error.localizedDescription + "\n\nYou can download it manually from \(release.pageURL.absoluteString)")
            }
        case .alertThirdButtonReturn:
            settings.skippedVersion = release.version
        default:
            break
        }
    }

    private func install(_ release: Release) async throws {
        let installedApp = Bundle.main.bundleURL
        guard installedApp.pathExtension == "app" else { throw UpdateError.notInstalledApp }
        let parent = installedApp.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else { throw UpdateError.notWritable(parent.path) }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("iShot-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // Download and extract.
        let (downloaded, response) = try await URLSession.shared.download(from: release.downloadURL)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.badResponse(status) }
        let zip = work.appendingPathComponent(Self.assetName)
        try FileManager.default.moveItem(at: downloaded, to: zip)
        let extracted = work.appendingPathComponent("extracted")
        guard try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, extracted.path]) == 0 else {
            throw UpdateError.unzipFailed
        }
        let newApp = extracted.appendingPathComponent("iShot.app")
        guard FileManager.default.fileExists(atPath: newApp.path) else { throw UpdateError.appMissingInArchive }

        // Only accept an app signed like this one.
        guard Self.satisfiesOwnDesignatedRequirement(newApp) else { throw UpdateError.signatureMismatch }

        // Swap the bundles (the running process keeps working from memory), then relaunch.
        _ = try FileManager.default.replaceItemAt(installedApp, withItemAt: newApp,
                                                  backupItemName: nil, options: [])
        relaunch(installedApp)
    }

    /// Starts the (new) bundle once this process has exited, then quits.
    private func relaunch(_ app: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                          app.path]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    /// True when `app` is validly signed and meets the designated requirement of the running app
    /// (same bundle ID and same signing certificate).
    nonisolated static func satisfiesOwnDesignatedRequirement(_ app: URL) -> Bool {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else { return false }
        var selfStatic: SecStaticCode?
        guard SecCodeCopyStaticCode(selfCode, [], &selfStatic) == errSecSuccess, let selfStatic else { return false }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(selfStatic, [], &requirement) == errSecSuccess, let requirement else { return false }

        var newStatic: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &newStatic) == errSecSuccess, let newStatic else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(newStatic, flags, requirement) == errSecSuccess
    }

    /// Compares dotted numeric versions ("0.1.10" > "0.1.9").
    nonisolated static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private nonisolated static func run(_ tool: String, _ arguments: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    private func showInfo(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
