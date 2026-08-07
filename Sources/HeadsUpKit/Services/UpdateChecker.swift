import AppKit

/// Semantic-ish version ("1.2.3") parsed for numeric comparison. Missing
/// components compare as 0, so "1.1" == "1.1.0".
struct AppVersion: Comparable, Equatable {
    let components: [Int]

    init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var parsed: [Int] = []
        for part in trimmed.split(separator: ".") {
            guard let n = Int(part), n >= 0 else { return nil }
            parsed.append(n)
        }
        guard !parsed.isEmpty else { return nil }
        components = parsed
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for i in 0..<count {
            let l = i < lhs.components.count ? lhs.components[i] : 0
            let r = i < rhs.components.count ? rhs.components[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

/// Polls the repo's published VERSION file and, when it is newer than the
/// running build, offers a one-click self-update: pull the source checkout
/// this bundle was built from and re-run build_app.sh (which installs to
/// /Applications and relaunches).
///
/// This is a pull-based updater by design: the app is distributed as source
/// and signed per-machine with each user's own self-signed certificate, so
/// there is no central binary to push. "Pushing" an update to every install
/// means bumping VERSION on the default branch; every running instance
/// notices within one poll interval and surfaces the update in its tray menu.
public final class UpdateChecker {
    /// Raw VERSION file on the default branch — the single source of truth
    /// for "what is the latest released version".
    static let remoteVersionURL = URL(string:
        "https://raw.githubusercontent.com/yoavcaspi1/heads-up/main/VERSION")!
    static let repoPageURL = URL(string: "https://github.com/yoavcaspi1/heads-up")!

    private static let pollInterval: TimeInterval = 6 * 60 * 60

    /// Set when a newer remote version was seen; read by the tray menu.
    public private(set) var availableVersion: String?
    /// Fired on the main queue whenever availableVersion transitions.
    public var onUpdateAvailable: ((String) -> Void)?

    private var timer: Timer?

    public init() {}

    public static func currentVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Starts the periodic check: once shortly after launch (network and
    /// keychain settle first), then every pollInterval.
    public func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.checkNow() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.checkNow()
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    func checkNow() {
        var request = URLRequest(url: Self.remoteVersionURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data, let text = String(data: data, encoding: .utf8) else { return }
            let remoteString = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let remote = AppVersion(remoteString),
                  let local = AppVersion(Self.currentVersion()),
                  local < remote else { return }
            DispatchQueue.main.async {
                guard self.availableVersion != remoteString else { return }
                self.availableVersion = remoteString
                FileDiag.log("update available: \(Self.currentVersion()) -> \(remoteString)")
                self.onUpdateAvailable?(remoteString)
            }
        }.resume()
    }

    /// The source checkout this bundle was built from, recorded by
    /// build_app.sh at build time. Nil when missing or no longer a checkout
    /// with build_app.sh in it (moved, deleted, or a bare `swift run`).
    static func sourceDirectory() -> URL? {
        guard let recorded = Bundle.main.url(forResource: "source_path", withExtension: "txt"),
              let raw = try? String(contentsOf: recorded, encoding: .utf8) else { return nil }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue,
              FileManager.default.isExecutableFile(atPath: dir.appendingPathComponent("build_app.sh").path)
        else { return nil }
        return dir
    }

    /// Confirm, then pull + rebuild + reinstall detached from this process
    /// (build_app.sh quits the running instance and relaunches the new one).
    /// Falls back to opening the repo page when the source checkout is gone.
    public func runSelfUpdate() {
        guard let version = availableVersion else { return }
        guard let sourceDir = Self.sourceDirectory() else {
            NSWorkspace.shared.open(Self.repoPageURL)
            return
        }

        let confirm = NSAlert()
        confirm.messageText = "Update Heads Up to \(version)?"
        confirm.informativeText = "This pulls the latest code into \(sourceDir.path), rebuilds, "
            + "and reinstalls the app. Heads Up will quit and relaunch itself when done "
            + "(usually under a minute). Progress is written to ~/Library/Logs/HeadsUp-update.log."
        confirm.addButton(withTitle: "Update Now")
        confirm.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let log = NSString(string: "~/Library/Logs/HeadsUp-update.log").expandingTildeInPath
        let script = """
        exec > '\(log)' 2>&1
        echo "== Heads Up self-update $(date) =="
        cd '\(sourceDir.path)' || exit 1
        git pull --ff-only || exit 1
        ./build_app.sh release
        """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("headsup-self-update-\(UUID().uuidString).sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            // A plain child process: it is reparented to launchd when this
            // app quits mid-script (build_app.sh quits the running instance
            // by app/binary name, which never matches bash), so the rebuild
            // and reinstall finish after we are gone.
            try process.run()
            FileDiag.log("self-update launched for \(version), source \(sourceDir.path)")
        } catch {
            FileDiag.log("self-update failed to launch: \(error)")
            NSWorkspace.shared.open(Self.repoPageURL)
        }
    }
}
