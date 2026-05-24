import Foundation

public enum VigilIdentifiers {
    public static let bundleID = "com.vigil.app"

    // v0.2.0+ per-feature LaunchAgent labels. The CLI installs one plist per
    // feature; both share the same AssociatedBundleIdentifiers so that macOS
    // System Settings → General → Login Items shows a single "Vigil" entry
    // that toggles both background agents together.
    public static let lidAwakeAgentLabel = "\(bundleID).lid-awake"
    public static let caffeinateAgentLabel = "\(bundleID).caffeinate"

    // Legacy (v0.1.0-beta.1). Referenced only by LegacyMigration and the
    // defensive bootout branch in SparkleDelegate. Do not write new code
    // against this constant.
    public static let legacyAssertionAgentLabel = "\(bundleID).assertions"

    public static let privilegedHelperPath = "/Library/PrivilegedHelperTools/\(bundleID).helper"

    public static var sudoersPath: String {
        "/etc/sudoers.d/vigil-\(getuid())"
    }
}
