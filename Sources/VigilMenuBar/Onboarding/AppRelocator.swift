import AppKit
import Foundation
import Security
import VigilCore
import VigilIdentifiers

/// `SecTranslocateCreateOriginalPathForURL` exists in `Security.framework`
/// (public since macOS 10.12) but isn't auto-bridged into Swift through
/// `import Security`. Declare it by symbol name so we can call it
/// directly. Returns the user-visible source URL for a translocated
/// bundle; passes the input through unchanged when not translocated.
@_silgen_name("SecTranslocateCreateOriginalPathForURL")
private func _SecTranslocateCreateOriginalPathForURL(
    _ translocatedURL: CFURL,
    _ error: UnsafeMutablePointer<Unmanaged<CFError>?>?
) -> Unmanaged<CFURL>?

/// Detect translocation, copy the user-visible source bundle into
/// /Applications, strip the quarantine attribute, persist a resume marker,
/// relaunch from the new location, and terminate the current (translocated)
/// process.
enum AppRelocator {

    enum RelocationError: Error, CustomStringConvertible, Equatable {
        case alreadyExists
        case copyFailed(String)
        case sourceUnreadable
        var description: String {
            switch self {
            case .alreadyExists:
                return "Another copy of Vigil.app already exists at /Applications. Replace it to continue."
            case .copyFailed(let m):
                return "Move failed: \(m)"
            case .sourceUnreadable:
                return "Could not read the current Vigil.app bundle."
            }
        }
    }

    static var currentBundleURL: URL { Bundle.main.bundleURL }
    static var targetURL: URL { URL(fileURLWithPath: "/Applications/Vigil.app") }

    static var isAlreadyInApplications: Bool {
        currentBundleURL.standardizedFileURL.path
            == targetURL.standardizedFileURL.path
    }

    /// `Bundle.main.bundlePath` returns the read-only translocation mount
    /// path when Gatekeeper has quarantined the launch. The actual on-disk
    /// source is in ~/Downloads or wherever the user dropped the .app.
    /// `SecTranslocateCreateOriginalPathForURL` (Security.framework, public
    /// since macOS 10.12) returns the user-visible source URL.
    static func originalBundleURL() -> URL {
        var err: Unmanaged<CFError>?
        if let resolved = _SecTranslocateCreateOriginalPathForURL(
            currentBundleURL as CFURL, &err
        )?.takeRetainedValue() {
            return resolved as URL
        }
        return currentBundleURL
    }

    static func existingApplicationsCopyIsVigil() -> Bool {
        guard FileManager.default.fileExists(atPath: targetURL.path) else { return false }
        return Bundle(url: targetURL)?.bundleIdentifier == VigilIdentifiers.bundleID
    }

    /// Idempotent: returns immediately if already in /Applications.
    /// On success, schedules an asynchronous relaunch and terminates the
    /// current process.
    static func moveAndRelaunch(replaceExisting: Bool) async throws {
        if isAlreadyInApplications { return }

        let source = originalBundleURL()
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else {
            throw RelocationError.sourceUnreadable
        }

        if fm.fileExists(atPath: targetURL.path) {
            guard replaceExisting else { throw RelocationError.alreadyExists }
            do { try fm.removeItem(at: targetURL) }
            catch { try await runPrivilegedRemove(targetURL) }
        }

        do { try fm.copyItem(at: source, to: targetURL) }
        catch { try await runPrivilegedCopy(from: source, to: targetURL) }

        // Strip the quarantine xattr so Gatekeeper doesn't re-translocate
        // the moved copy. Safe because the codesigning signature is still
        // validated on launch.
        _ = try? await runShell(
            "/usr/bin/xattr",
            ["-d", "-r", "com.apple.quarantine", targetURL.path]
        )

        // Persist the resume step as a file (not UserDefaults — the
        // relaunched process needs to read this synchronously on launch,
        // and cfprefsd writes can lag a deliberate terminate).
        try Paths.ensureAppSupportDirectoryExists()
        try OnboardingStep.approveAdmin.rawValue.write(
            to: Paths.onboardingResumeMarker,
            atomically: true,
            encoding: .utf8
        )

        // Relaunch from /Applications, then exit. NSWorkspace's async
        // openApplication completes once the new process has been launched.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: targetURL, configuration: config)

        // Give the new process a brief head-start before we exit.
        try? await Task.sleep(for: .milliseconds(250))
        await MainActor.run { NSApp.terminate(nil) }
    }

    // MARK: - Privileged fallbacks (used only when unprivileged copy fails)

    private static func runPrivilegedCopy(from src: URL, to dst: URL) async throws {
        let script = "/bin/cp -R \(shellQuote(src.path)) \(shellQuote(dst.path))"
        try await runAdminScript(script)
    }

    private static func runPrivilegedRemove(_ url: URL) async throws {
        try await runAdminScript("/bin/rm -rf \(shellQuote(url.path))")
    }

    private static func runAdminScript(_ command: String) async throws {
        let source = "do shell script \(appleScriptString(command)) with administrator privileges"
        try await Task.detached {
            var err: NSDictionary?
            _ = NSAppleScript(source: source)?.executeAndReturnError(&err)
            if let err {
                throw RelocationError.copyFailed("\(err)")
            }
        }.value
    }

    @discardableResult
    private static func runShell(_ path: String, _ args: [String]) async throws -> String {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            try p.run()
            p.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }.value
    }

    private static func shellQuote(_ s: String) -> String {
        "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func appleScriptString(_ s: String) -> String {
        "\"\(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
