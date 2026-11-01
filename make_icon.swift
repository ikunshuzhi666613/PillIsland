import Cocoa

// Renders the PillIsland app icon (1024x1024) with Core Graphics.

let S: CGFloat = 1024
let space = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S),
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("no context")
}

let full = CGRect(x: 0, y: 0, width: S, height: S)

// macOS-style rounded square (with breathing room around it)
let body = full.insetBy(dx: 38, dy: 38)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 208, cornerHeight: 208, transform: nil)
ctx.addPath(bodyPath)
ctx.clip()

// vivid gradient backdrop
let colors = [
    NSColor(srgbRed: 0.11, green: 0.24, blue: 0.92, alpha: 1).cgColor,
    NSColor(srgbRed: 0.42, green: 0.24, blue: 0.95, alpha: 1).cgColor,
    NSColor(srgbRed: 0.93, green: 0.32, blue: 0.62, alpha: 1).cgColor
] as CFArray
if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0.0, 0.55, 1.0]) {
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: S),
                           end: CGPoint(x: S, y: 0),
                           options: [])
}

// soft light falling from the top, no visible circular edge
if let light = CGGradient(colorsSpace: space,
                          colors: [NSColor(white: 1, alpha: 0.16).cgColor,
                                   NSColor(white: 1, alpha: 0.0).cgColor] as CFArray,
                          locations: [0, 1]) {
    ctx.drawLinearGradient(light,
                           start: CGPoint(x: 0, y: S),
                           end: CGPoint(x: 0, y: S * 0.55),
                           options: [])
}

// gentle darkening towards the bottom
if let shade = CGGradient(colorsSpace: space,
                          colors: [NSColor(white: 0, alpha: 0.22).cgColor,
                                   NSColor(white: 0, alpha: 0).cgColor] as CFArray,
                          locations: [0, 1]) {
    ctx.drawLinearGradient(shade,
                           start: CGPoint(x: 0, y: 0),
                           end: CGPoint(x: 0, y: S * 0.45),
                           options: [])
}

// the island: a black capsule floating in the middle
let pillW: CGFloat = 600
let pillH: CGFloat = 200
let pillRect = CGRect(x: (S - pillW) / 2, y: S / 2 - pillH / 2 + 30, width: pillW, height: pillH)
let pillPath = CGPath(roundedRect: pillRect, cornerWidth: pillH / 2, cornerHeight: pillH / 2, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 48,
              color: NSColor(white: 0, alpha: 0.45).cgColor)
ctx.addPath(pillPath)
ctx.setFillColor(NSColor(srgbRed: 0.02, green: 0.02, blue: 0.03, alpha: 1).cgColor)
ctx.fillPath()
ctx.restoreGState()

// hairline rim
ctx.addPath(pillPath)
ctx.setStrokeColor(NSColor(white: 1, alpha: 0.14).cgColor)
ctx.setLineWidth(3)
ctx.strokePath()

// equalizer bars inside the island
let heights: [CGFloat] = [46, 88, 128, 100, 64, 36]
let barW: CGFloat = 26
let gap: CGFloat = 30
let totalW = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
var x = (S - totalW) / 2
let centerY = pillRect.midY

for (index, h) in heights.enumerated() {
    let barRect = CGRect(x: x, y: centerY - h / 2, width: barW, height: h)
    let hue = 0.52 + CGFloat(index) * 0.055
    let color = NSColor(hue: hue, saturation: 0.62, brightness: 1.0, alpha: 1.0).cgColor
    ctx.addPath(CGPath(roundedRect: barRect, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
    ctx.setFillColor(color)
    ctx.fillPath()
    x += barW + gap
}

guard let image = ctx.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png")
try! png.write(to: out)
print("wrote \(out.path)")
