import AppKit
let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.16, alpha: 1),
                    NSColor(calibratedRed: 0.02, green: 0.02, blue: 0.04, alpha: 1)])!.draw(in: path, angle: -90)
// glow
NSGraphicsContext.current!.saveGraphicsState()
path.addClip()
NSGradient(colors: [NSColor(calibratedRed: 0.55, green: 0.75, blue: 1, alpha: 0.55), .clear])!
    .draw(fromCenter: NSPoint(x: 512, y: 470), radius: 0, toCenter: NSPoint(x: 512, y: 470), radius: 420, options: [])
NSGraphicsContext.current!.restoreGraphicsState()
let cfg = NSImage.SymbolConfiguration(pointSize: 420, weight: .regular).applying(.init(paletteColors: [.white]))
let sym = NSImage(systemSymbolName: "keyboard.fill", accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
let s = sym.size
let shadow = NSShadow(); shadow.shadowColor = NSColor(calibratedRed: 0.7, green: 0.85, blue: 1, alpha: 1); shadow.shadowBlurRadius = 60; shadow.set()
sym.draw(in: NSRect(x: 512 - s.width/2, y: 490 - s.height/2, width: s.width, height: s.height))
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
