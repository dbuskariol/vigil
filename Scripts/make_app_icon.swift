import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("App/AppIcon.iconset", isDirectory: true)
let output = root.appendingPathComponent("App/AppIcon.icns")

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let specs: [(name: String, size: Int, scale: Int)] = [
    ("icon_16x16.png", 16, 1),
    ("icon_16x16@2x.png", 16, 2),
    ("icon_32x32.png", 32, 1),
    ("icon_32x32@2x.png", 32, 2),
    ("icon_128x128.png", 128, 1),
    ("icon_128x128@2x.png", 128, 2),
    ("icon_256x256.png", 256, 1),
    ("icon_256x256@2x.png", 256, 2),
    ("icon_512x512.png", 512, 1),
    ("icon_512x512@2x.png", 512, 2)
]

func drawIcon(side: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: side, height: side)
    NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
    NSBezierPath(roundedRect: rect, xRadius: side * 0.22, yRadius: side * 0.22).fill()

    let circleRect = rect.insetBy(dx: side * 0.14, dy: side * 0.14)
    NSColor(calibratedRed: 0.15, green: 0.84, blue: 0.29, alpha: 1).setFill()
    NSBezierPath(ovalIn: circleRect).fill()

    let bolt = NSBezierPath()
    bolt.move(to: NSPoint(x: side * 0.55, y: side * 0.78))
    bolt.line(to: NSPoint(x: side * 0.35, y: side * 0.47))
    bolt.line(to: NSPoint(x: side * 0.50, y: side * 0.47))
    bolt.line(to: NSPoint(x: side * 0.43, y: side * 0.22))
    bolt.line(to: NSPoint(x: side * 0.67, y: side * 0.56))
    bolt.line(to: NSPoint(x: side * 0.51, y: side * 0.56))
    bolt.close()
    NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
    bolt.fill()

    image.unlockFocus()
    return image
}

for spec in specs {
    let pixels = spec.size * spec.scale
    let image = drawIcon(side: CGFloat(pixels))
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Unable to render \(spec.name)")
    }
    try png.write(to: iconset.appendingPathComponent(spec.name))
}

try? FileManager.default.removeItem(at: output)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    fatalError("iconutil failed")
}
