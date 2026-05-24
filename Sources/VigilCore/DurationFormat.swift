import Foundation

/// Compact duration formatting shared by CLI and menu app. Used in
/// `vigil status` and in popover stats rows.
///
/// Output examples:
///   45s · 5m · 5m 12s · 1h · 1h 23m · 2d · 2d 4h
public enum DurationFormat {
    public static func compact(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let m = seconds / 60
        let s = seconds % 60
        if m < 60 { return s == 0 ? "\(m)m" : "\(m)m \(s)s" }
        let h = m / 60
        let mr = m % 60
        if h < 24 { return mr == 0 ? "\(h)h" : "\(h)h \(mr)m" }
        let d = h / 24
        let hr = h % 24
        return hr == 0 ? "\(d)d" : "\(d)d \(hr)h"
    }
}
