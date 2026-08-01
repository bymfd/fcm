import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let rect = NSRect(x: 0, y: 0, width: size, height: size)
let path = NSBezierPath(roundedRect: rect, xRadius: 190, yRadius: 190)
let grad = NSGradient(colors: [
    NSColor(calibratedRed: 0.16, green: 0.30, blue: 0.55, alpha: 1),
    NSColor(calibratedRed: 0.02, green: 0.06, blue: 0.18, alpha: 1)
])!
grad.draw(in: path, angle: -90)

if let base = NSImage(systemSymbolName: "fan.fill", accessibilityDescription: nil) {
    let config = NSImage.SymbolConfiguration(pointSize: 560, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let fan = base.withSymbolConfiguration(config) {
        let s = 660.0
        let fRect = NSRect(x: (size - s) / 2, y: (size - s) / 2, width: s, height: s)
        fan.draw(in: fRect)
    }
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    exit(1)
}
let out = CommandLine.arguments[1]
try! png.write(to: URL(fileURLWithPath: out))
