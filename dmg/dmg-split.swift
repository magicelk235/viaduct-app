// Concept #2 "Split-world": vertical seam divides Chrome (left) from Safari
// (right). Same extension puzzle-piece appears dim/wireframe on the Chrome side
// and solid mint on the Safari side — the product story (Chrome ext -> native
// Safari) told in one glance. App icon (left) drags to /Applications (right).
// Output: dmg-split.png (2x). One-shot asset gen, run by hand.
import AppKit

let W = 620.0, H = 420.0
let ICON = "icon.png"
let MINT = NSColor(calibratedRed: 0.42, green: 0.78, blue: 0.76, alpha: 1)   // brand teal-ish
let INK  = NSColor(calibratedRed: 0.62, green: 0.67, blue: 0.72, alpha: 1)   // dim chrome-side

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W*2), pixelsHigh: Int(H*2),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
let c = ctx.cgContext

// ---- backgrounds: cooler dim slate (left/Chrome), warmer teal-slate (right/Safari)
let leftTop  = NSColor(calibratedRed: 0.13, green: 0.15, blue: 0.18, alpha: 1)
let leftBot  = NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.15, alpha: 1)
let rightTop = NSColor(calibratedRed: 0.12, green: 0.19, blue: 0.22, alpha: 1)
let rightBot = NSColor(calibratedRed: 0.09, green: 0.15, blue: 0.18, alpha: 1)
NSGradient(starting: leftBot,  ending: leftTop )!.draw(in: NSRect(x: 0,   y: 0, width: W/2, height: H), angle: 90)
NSGradient(starting: rightBot, ending: rightTop)!.draw(in: NSRect(x: W/2, y: 0, width: W/2, height: H), angle: 90)

// ---- seam: soft mint glow line down the middle (the "crossing" point)
let seam = NSGradient(colors: [.clear, MINT.withAlphaComponent(0.35), .clear])!
c.saveGState()
NSBezierPath(rect: NSRect(x: W/2 - 18, y: 0, width: 36, height: H)).setClip()
seam.draw(in: NSRect(x: W/2 - 18, y: 0, width: 36, height: H), angle: 0)
c.restoreGState()
MINT.withAlphaComponent(0.55).setFill()
NSBezierPath(rect: NSRect(x: W/2 - 0.5, y: 0, width: 1, height: H)).fill()

// ---- headline
func draw(_ s: String, _ font: NSFont, _ color: NSColor, x: Double, y: Double, center: Bool = false) {
    let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let str = NSAttributedString(string: s, attributes: a)
    let sz = str.size()
    str.draw(at: NSPoint(x: center ? x - sz.width/2 : x, y: y))
}
let hl = NSFont.systemFont(ofSize: 26, weight: .bold)
// "Chrome extensions," dim ; "running in Safari." mint — draw as two runs, centered as one line
let a1: [NSAttributedString.Key: Any] = [.font: hl, .foregroundColor: INK.withAlphaComponent(0.9)]
let a2: [NSAttributedString.Key: Any] = [.font: hl, .foregroundColor: MINT]
let s1 = NSAttributedString(string: "Chrome extensions, ", attributes: a1)
let s2 = NSAttributedString(string: "running in Safari.", attributes: a2)
let totalW = s1.size().width + s2.size().width
let hx = (W - totalW) / 2, hy = H - 66
s1.draw(at: NSPoint(x: hx, y: hy))
s2.draw(at: NSPoint(x: hx + s1.size().width, y: hy))

// ---- puzzle piece glyph (drawn twice: wireframe left, solid mint right)
func puzzlePath(cx: Double, cy: Double, s: Double) -> NSBezierPath {
    // rounded square with one bump (right) and one notch (bottom) — reads "extension"
    let p = NSBezierPath()
    let h = s/2, k = s*0.22       // k = knob radius
    p.move(to: NSPoint(x: cx-h, y: cy-h))
    p.line(to: NSPoint(x: cx+h, y: cy-h))                                  // bottom
    p.line(to: NSPoint(x: cx+h, y: cy-k*0.6))
    p.appendArc(withCenter: NSPoint(x: cx+h+k*0.55, y: cy), radius: k,     // right knob (out)
                startAngle: 200, endAngle: 160, clockwise: true)
    p.line(to: NSPoint(x: cx+h, y: cy+h))                                  // up to top-right
    p.line(to: NSPoint(x: cx-h, y: cy+h))                                  // top
    p.line(to: NSPoint(x: cx-h, y: cy+k*0.6))
    p.appendArc(withCenter: NSPoint(x: cx-h, y: cy), radius: k,            // left notch (in)
                startAngle: -70, endAngle: 70, clockwise: false)
    p.line(to: NSPoint(x: cx-h, y: cy-h))
    p.close()
    return p
}
let py = H - 150.0, ps = 62.0
// left: dim wireframe (Chrome, "just a file")
let lp = puzzlePath(cx: W*0.28, cy: py, s: ps)
lp.lineWidth = 2
INK.withAlphaComponent(0.55).setStroke()
lp.stroke()
// right: solid glowing mint (Safari, "now native")
let rp = puzzlePath(cx: W*0.72, cy: py, s: ps)
c.saveGState()
c.setShadow(offset: .zero, blur: 22, color: MINT.withAlphaComponent(0.7).cgColor)
MINT.setFill(); rp.fill()
c.restoreGState()

// arrow across the seam between the two pieces
let arr = NSBezierPath()
arr.move(to: NSPoint(x: W*0.28 + ps*0.75, y: py))
arr.line(to: NSPoint(x: W*0.72 - ps*0.75, y: py))
arr.lineWidth = 3
MINT.withAlphaComponent(0.85).setStroke(); arr.stroke()
let ah = NSBezierPath()   // arrowhead
let axx = W*0.72 - ps*0.75
ah.move(to: NSPoint(x: axx, y: py)); ah.line(to: NSPoint(x: axx-11, y: py+7)); ah.line(to: NSPoint(x: axx-11, y: py-7)); ah.close()
MINT.withAlphaComponent(0.85).setFill(); ah.fill()

// ---- drop targets label under the icons (Finder draws real icons on top)
draw("Viaduct.app", NSFont.systemFont(ofSize: 13, weight: .semibold), NSColor(white: 0.85, alpha: 1), x: 150, y: 40, center: true)
draw("Applications", NSFont.systemFont(ofSize: 13, weight: .semibold), NSColor(white: 0.85, alpha: 1), x: 470, y: 40, center: true)

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "dmg/dmg-split.png"))
print("wrote dmg/dmg-split.png")
