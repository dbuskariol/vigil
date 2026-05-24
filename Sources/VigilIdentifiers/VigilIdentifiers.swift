import Foundation

public enum VigilIdentifiers {
    public static let bundleID = "com.vigil.app"
    public static let assertionAgentLabel = "\(bundleID).assertions"
    public static let privilegedHelperPath = "/Library/PrivilegedHelperTools/\(bundleID).helper"

    public static var sudoersPath: String {
        "/etc/sudoers.d/vigil-\(getuid())"
    }
}
