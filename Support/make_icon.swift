import AppKit
// Draws the app icon: a dark rounded square with an orange "clip" body and a lens.
let out = CommandLine.arguments[1]
for px in [16, 32, 64, 128, 256, 512, 1024] {
    let s = CGFloat(px)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let inset = s * 0.09
    let bg = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset), xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.2, alpha: 1), ending: NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.08, alpha: 1))!.draw(in: bg, angle: -90)
    let body = NSBezierPath(roundedRect: NSRect(x: s * 0.3, y: s * 0.22, width: s * 0.4, height: s * 0.56), xRadius: s * 0.08, yRadius: s * 0.08)
    NSColor(calibratedRed: 0.98, green: 0.55, blue: 0.2, alpha: 1).setFill(); body.fill()
    let lens = NSBezierPath(ovalIn: NSRect(x: s * 0.39, y: s * 0.5, width: s * 0.22, height: s * 0.22))
    NSColor(calibratedWhite: 0.08, alpha: 1).setFill(); lens.fill()
    let glint = NSBezierPath(ovalIn: NSRect(x: s * 0.44, y: s * 0.6, width: s * 0.06, height: s * 0.06))
    NSColor(calibratedWhite: 1, alpha: 0.7).setFill(); glint.fill()
    let led = NSBezierPath(ovalIn: NSRect(x: s * 0.47, y: s * 0.32, width: s * 0.06, height: s * 0.06))
    NSColor(calibratedWhite: 1, alpha: 0.85).setFill(); led.fill()
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    let png = rep.representation(using: .png, properties: [:])!
    for (name, size) in [("icon_\(px)x\(px).png", px), ("icon_\(px / 2)x\(px / 2)@2x.png", px / 2)] where size >= 16 && size <= 512 {
        try! png.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
    }
}
