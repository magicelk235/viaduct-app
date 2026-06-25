// Draws the DMG window background (layout B, dark): a deep frosted slate canvas
// with the colorful Viaduct arches as a bridge along the bottom. The app and
// /Applications drop icons float in the space above, the two ends the viaduct
// connects. Output: dmg-bg.png (2x). ponytail: one-shot asset gen, run by hand.
//
// Dark-only by choice: macOS 27 Finder does NOT live-swap a multi-rep DMG
// background by appearance, so a single dark frosted bg is the honest call.
import AppKit

let W = 620.0, H = 420.0           // DMG window content size (points)
let ARCH = "AppIcon.icon/Assets/Gemini_Generated_Image_7plsfi7plsfi7pls.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W*2), pixelsHigh: Int(H*2),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!

// Deep slate frosted gradient.
let top = NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.17, alpha: 1)
let bot = NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.24, alpha: 1)
NSGradient(starting: bot, ending: top)!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 90)

// Colorful arches pinned to the bottom as the bridge (dimmed so it doesn't glare).
if let img = NSImage(contentsOfFile: ARCH) {
    let aw = 620.0, ah = aw * 506.0 / 1228.0
    img.draw(in: NSRect(x: (W-aw)/2, y: -40, width: aw, height: ah),
             from: .zero, operation: .sourceOver, fraction: 0.9)
}

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "dmg/dmg-bg.png"))
print("wrote dmg/dmg-bg.png")
