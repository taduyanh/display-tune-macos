// Generates Resources/AppIcon.icns — flat "Metro" style: solid colour tile, white geometric monitor + sun.
// Usage: swiftc -O make_icon.swift -o /tmp/make_icon && /tmp/make_icon <output-dir>
import Cocoa

let tileColor = NSColor(srgbRed: 0x00/255.0, green: 0x78/255.0, blue: 0xD7/255.0, alpha: 1)   // Metro blue
let white = NSColor.white

func draw(in ctx: CGContext) {          // design space: 1024 x 1024, origin bottom-left
    // Tile (macOS icon grid: 824pt square centred in 1024)
    ctx.setFillColor(tileColor.cgColor)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 150, cornerHeight: 150, transform: nil))
    ctx.fillPath()

    ctx.setFillColor(white.cgColor)
    // Screen frame: outer rect minus inner rect (even-odd) -> flat outlined monitor
    let outer = CGRect(x: 222, y: 372, width: 580, height: 380)
    let inner = outer.insetBy(dx: 40, dy: 40)
    ctx.addRect(outer); ctx.addRect(inner)
    ctx.fillPath(using: .evenOdd)
    // Neck and base
    ctx.fill(CGRect(x: 472, y: 322, width: 80, height: 50))
    ctx.fill(CGRect(x: 372, y: 282, width: 280, height: 40))
    // Sun (brightness) in the middle of the screen
    let c = CGPoint(x: outer.midX, y: outer.midY)
    ctx.fillEllipse(in: CGRect(x: c.x - 50, y: c.y - 50, width: 100, height: 100))
    for i in 0..<8 {
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: CGFloat(i) * .pi / 4)
        ctx.fill(CGRect(x: -11, y: 78, width: 22, height: 38))
        ctx.restoreGState()
    }
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    draw(in: ctx)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = out.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let table: [(String, Int)] = [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                              ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
                              ("icon_512x512", 512), ("icon_512x512@2x", 1024)]
for (name, px) in table { try! png(size: px).write(to: iconset.appendingPathComponent(name + ".png")) }
try! png(size: 512).write(to: out.appendingPathComponent("AppIcon-preview.png"))
print("iconset written to \(iconset.path)")
