import Foundation
import ServiceManagement

/// Installs `ExtDisplayHost.app` into `/Applications` (so it appears in Applications and survives reboots)
/// and registers it in macOS Login Items (`SMAppService.mainApp` + `LSSharedFileList` + fallback LaunchAgent).
enum LaunchAtLoginManager {
    private static let label = "com.QHpersonalteam.ExtDisplay.Host"
    static let appName = "ExtDisplayHost.app"
    static let applicationsAppURL = URL(fileURLWithPath: "/Applications/\(appName)")

    private static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isInstalledInApplications: Bool {
        FileManager.default.fileExists(atPath: applicationsAppURL.path)
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
            || ExtDisplayOpenAtLoginContains(applicationsAppURL)
            || ExtDisplayOpenAtLoginContains(Bundle.main.bundleURL)
            || FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    /// Copies the running `.app` bundle into `/Applications/ExtDisplayHost.app` (or `~/Applications`)
    /// and registers it with LaunchServices so macOS recognizes it in Applications and Login Items.
    @discardableResult
    static func installToApplications() throws -> URL {
        let currentURL = Bundle.main.bundleURL.standardizedFileURL
        let fm = FileManager.default
        let userAppsDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        let userApps = userAppsDir.appendingPathComponent(appName)

        if currentURL.path == applicationsAppURL.path || currentURL.path == userApps.path {
            registerWithLaunchServices(currentURL)
            return currentURL
        }

        var lastError: Error?
        for target in [applicationsAppURL, userApps] {
            do {
                if target == userApps {
                    try fm.createDirectory(at: userAppsDir, withIntermediateDirectories: true)
                }
                if fm.fileExists(atPath: target.path) {
                    try fm.removeItem(at: target)
                }
                try fm.copyItem(at: currentURL, to: target)
                registerWithLaunchServices(target)
                return target
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        return currentURL
    }

    private static func registerWithLaunchServices(_ appURL: URL) {
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
        guard FileManager.default.isExecutableFile(atPath: lsregister) else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: lsregister)
        proc.arguments = ["-f", "-R", "-trusted", appURL.path]
        try? proc.run()
        proc.waitUntilExit()
    }

    /// Enables or disables automatic startup at Mac login.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Result<String, Error> {
        let fm = FileManager.default
        if enabled {
            let installedApp = (try? installToApplications()) ?? Bundle.main.bundleURL
            // 1. Modern macOS 13+ Login Items API (adds to System Settings → General → Login Items).
            try? SMAppService.mainApp.register()
            // 2. SharedFileList Open at Login list.
            _ = ExtDisplayOpenAtLoginSet(installedApp, true)
            // 3. Also maintain a LaunchAgent pointing to /Applications/ExtDisplayHost.app so even if
            // the app was launched from Xcode's temporary build folder, login always opens /Applications.
            do {
                let launchAgentsDir = launchAgentURL.deletingLastPathComponent()
                try fm.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
                let cmd = "pgrep -x ExtDisplayHost >/dev/null 2>&1 || /usr/bin/open -g -j -a '\(installedApp.path)' --args --background"
                let plist: [String: Any] = [
                    "Label": label,
                    "ProgramArguments": ["/bin/sh", "-c", cmd],
                    "RunAtLoad": true,
                    "ProcessType": "Background",
                ]
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: launchAgentURL, options: .atomic)
            } catch {
                return .failure(error)
            }
            return .success(installedApp.path)
        } else {
            try? fm.removeItem(at: launchAgentURL)
            _ = ExtDisplayOpenAtLoginSet(applicationsAppURL, false)
            _ = ExtDisplayOpenAtLoginSet(Bundle.main.bundleURL, false)
            if SMAppService.mainApp.status == .enabled {
                try? SMAppService.mainApp.unregister()
            }
            return .success("")
        }
    }
}
