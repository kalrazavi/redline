// Copyright (c) 2026 Ali Razavi. All rights reserved. Owned and controlled solely by Ali Razavi: no licence check, no remote control, no backdoor. Terms: see the LICENSE file.
// Glowstrip: redraws the MacBook Touch Bar in the Redline look. Same controls as Apple's strip, nothing removed.
import AppKit
import CoreAudio
import AudioToolbox
import QuartzCore
import ServiceManagement

// ---------- Look (matches Redline) ----------
enum Ink {
    // Eight underglows plus NOS, the same colours as Redline. Each has a partner it fades into, like colour-shift paint.
    static let glows: [NSColor] = [(0.25, 0.90, 1.0), (0.72, 0.45, 1.0), (0.45, 1.0, 0.35), (1.0, 0.55, 0.15), (1.0, 0.36, 0.78), (0.40, 0.60, 1.0), (1.0, 0.84, 0.22), (0.90, 0.94, 1.0), (1.0, 0.14, 0.24)]
        .map { NSColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1) }
    static let partners: [NSColor] = [(1.0, 0.18, 0.62), (0.20, 0.92, 1.0), (1.0, 0.92, 0.10), (1.0, 0.16, 0.50), (0.25, 0.95, 1.0), (0.78, 0.42, 1.0), (0.20, 0.90, 1.0), (0.55, 0.75, 1.0), (0.66, 0.30, 1.0)]
        .map { NSColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1) }
    /// Which look is on: always the underglow picked in Redline (0-7); NOS is 8 and beats everything. Redline's VIBE switch only turns the movement on or off.
    static var theme = Ink.savedTheme()
    static func look(glow: Int, vibe: Bool, nos: Bool) -> Int { nos ? 8 : max(0, min(7, glow)) }     // VIBE only decides whether it moves, never the colour
    static func savedTheme() -> Int {
        let d = UserDefaults(suiteName: "local.redline")
        return look(glow: d?.integer(forKey: "glow") ?? 0, vibe: d?.bool(forKey: "vibe") ?? false, nos: d?.bool(forKey: "nos") ?? false)
    }
    static var index: Int { theme }
    static var glow: NSColor { glows[index] }
    static var partner: NSColor { partners[index] }
    /// The neon colour at a point along the strip (0 = left end, 1 = right end).
    /// It travels around the colour wheel rather than straight across, so the middle stays vivid instead of going grey.
    static func neon(_ f: CGFloat) -> NSColor {
        let t = min(1, max(0, f)), a = glow, b = partner
        var dh = b.hueComponent - a.hueComponent; if dh > 0.5 { dh -= 1 } else if dh < -0.5 { dh += 1 }
        let h = (a.hueComponent + dh * t + 1).truncatingRemainder(dividingBy: 1)
        return NSColor(hue: h, saturation: a.saturationComponent + (b.saturationComponent - a.saturationComponent) * t,
                       brightness: a.brightnessComponent + (b.brightnessComponent - a.brightnessComponent) * t, alpha: 1)
    }
    static let red = NSColor(srgbRed: 1.0, green: 0.16, blue: 0.14, alpha: 1)
    static var skin: Skin { Skin.all[index] }
    static let amber = NSColor(srgbRed: 1.0, green: 0.74, blue: 0.16, alpha: 1)
    // Tile paint: midnight purple on top falling to deep blue-black.
    static let tileTop = NSColor(srgbRed: 0.215, green: 0.195, blue: 0.300, alpha: 1), tileBot = NSColor(srgbRed: 0.080, green: 0.095, blue: 0.135, alpha: 1)
    static let line = NSColor.white.withAlphaComponent(0.16)
    static let mid = NSColor.white.withAlphaComponent(0.94), dim = NSColor.white.withAlphaComponent(0.45)
}

// ---------- Each look has its own bodywork, not just its own paint ----------
// shape:  0 rounded · 1 all corners cut · 2 two opposite corners cut · 3 pill · 4 crisp · 5 soft · 6 square wireframe · 7 slanted
// weave:  0 none · 1 carbon twill · 2 hazard stripes · 3 fine grid · 4 star dust · 5 chevrons
// seg:    0 leaning bars · 1 laser lines · 2 LED blocks · 3 beads · 4 upright chrome bars · 5 diamonds · 6 rainbow bars · 7 hollow ticks · 8 steep tall bars
struct Skin {
    var shape = 0; var top: (CGFloat, CGFloat, CGFloat) = (0.215, 0.195, 0.300); var bot: (CGFloat, CGFloat, CGFloat) = (0.080, 0.095, 0.135)
    var weave = 1; var seg = 0; var italic = true; var gloss = true; var outline: CGFloat = 0.16
    // icons: 0 solid · 1 outline · 2 in a disc.  tint: 0 white core · 1 the neon colour itself · 2 rainbow along the bar
    var icon = 0; var weight: NSFont.Weight = .semibold; var design: NSFontDescriptor.SystemDesign = .default; var tint = 0; var halo = true
    var esc = "ESC"; var escTrack: CGFloat = 2.0; var labels: (String, String) = ("輝度", "音量"); var textWeight: NSFont.Weight? = nil
    static let all: [Skin] = [
        Skin(),                                                                                                             // ICE · CDJ: smoked glass, carbon, leaning bars
        Skin(shape: 1, top: (0.16, 0.10, 0.28), bot: (0.05, 0.04, 0.12), weave: 0, seg: 1, outline: 0.30, icon: 1, weight: .light, design: .monospaced, tint: 1, labels: ("LUM", "VOL")),                  // NITROUS · LASER: cut corners, laser lines
        Skin(shape: 2, top: (0.13, 0.19, 0.10), bot: (0.05, 0.08, 0.05), weave: 2, seg: 2, italic: false, weight: .black, escTrack: 3.2, labels: ("BRT", "VOL")),                  // TOXIC · RADAR: hazard plates, LED blocks
        Skin(shape: 3, top: (0.30, 0.14, 0.14), bot: (0.12, 0.06, 0.09), weave: 0, seg: 3, italic: false, icon: 2, weight: .medium, design: .rounded, tint: 1, esc: "esc", labels: ("sun", "vol"), textWeight: .bold),                  // SUNSET · SUNRISE: warm pills, beads
        Skin(shape: 4, top: (0.20, 0.11, 0.30), bot: (0.07, 0.06, 0.16), weave: 3, seg: 4, icon: 1, weight: .bold, tint: 1, esc: "ＥＳＣ", escTrack: 0.5, labels: ("ヒカリ", "オト")),                                 // VAPOR · GRID: crisp panels with a grid, chrome bars
        Skin(shape: 5, top: (0.09, 0.12, 0.26), bot: (0.03, 0.04, 0.11), weave: 4, seg: 5, italic: false, weight: .regular, design: .rounded, tint: 1, escTrack: 4.5, labels: ("LUX", "VOL"), textWeight: .medium),                  // GALAXY · WARP: soft navy, star dust, diamonds
        Skin(shape: 0, top: (0.17, 0.17, 0.19), bot: (0.07, 0.07, 0.08), weave: 0, seg: 6, tint: 2, labels: ("BRT", "VOL")),                                 // PRISM · SPECTRUM: neutral glass, rainbow bars
        Skin(shape: 6, top: (0.03, 0.03, 0.04), bot: (0.01, 0.01, 0.02), weave: 0, seg: 7, italic: false, gloss: false, outline: 0.60, icon: 1, weight: .light, design: .monospaced, halo: false, esc: "esc", labels: ("brt", "vol"), textWeight: .regular),   // MONO · SCOPE: black wireframe, hollow ticks
        Skin(shape: 7, top: (0.30, 0.06, 0.09), bot: (0.10, 0.02, 0.05), weave: 5, seg: 8, outline: 0.34, weight: .black, escTrack: 1.0, labels: ("PWR", "REV")),                  // NOS: slanted red plates, chevrons, steep bars
    ]
    /// Each look also has its own icon designs. Keys are the standard icon of a control; values are what that look draws instead
    /// (the first one this version of macOS has; if none, the standard icon). Order: sleep, lock, key light down/up, brightness down/up,
    /// Night Shift, previous, play/pause, next, volume down/up, mute, show desktop, app controls.
    static let order = ["moon.zzz.fill", "lock.fill", "light.min", "light.max", "sun.min.fill", "sun.max.fill", "sun.horizon.fill", "backward.fill", "playpause.fill", "forward.fill",
                        "speaker.wave.1.fill", "speaker.wave.3.fill", "speaker.slash.fill", "menubar.dock.rectangle", "square.grid.2x2.fill"]
    static let glyphs: [[String]] = [
        [],                                                                                                                              // ICE · CDJ: the standard set
        ["powersleep", "key.horizontal.fill", "light.beacon.min", "light.beacon.max", "sun.min.fill", "sun.max.fill", "moon.stars.fill", "backward.end.fill", "playpause.fill", "forward.end.fill",
         "speaker.minus.fill", "speaker.plus.fill", "bell.slash.fill", "macwindow", "square.grid.3x3.fill"],                              // NITROUS · LASER
        ["power", "lock.shield.fill", "lightbulb", "lightbulb.fill", "sun.dust.fill", "sun.max.fill", "moon.haze.fill", "backward.frame.fill", "playpause.fill", "forward.frame.fill",
         "speaker.fill", "speaker.wave.2.fill", "nosign", "rectangle.3.group.fill", "circle.hexagongrid.fill"],                               // TOXIC · RADAR
        ["moon.fill", "lock.fill", "minus", "plus", "minus", "plus", "sunset.fill", "backward.end.fill", "playpause.fill", "forward.end.fill",
         "minus", "plus", "bell.slash.fill", "house.fill", "ellipsis"],                                                                  // SUNSET · SUNRISE (all in discs)
        ["zzz", "key.fill", "flashlight.off.fill", "flashlight.on.fill", "sunrise.fill", "sun.max.fill", "sparkles", "arrowtriangle.left.fill", "playpause.fill", "arrowtriangle.right.fill",
         "music.note", "music.note.list", "speaker.zzz.fill", "rectangle.on.rectangle", "command"],                                      // VAPOR · GRID
        ["moon.stars.fill", "lock.rectangle.fill", "lamp.desk", "lamp.desk.fill", "sparkle", "sparkles", "moonphase.waxing.crescent", "backward.end.alt.fill", "playpause.fill", "forward.end.alt.fill",
         "waveform.path", "waveform", "xmark.circle.fill", "square.stack.3d.up.fill", "star.fill"],                                      // GALAXY · WARP
        ["bed.double.fill", "lock.square.fill", "lightbulb.min", "lightbulb.max", "sun.min.fill", "lightspectrum.horizontal", "rainbow", "gobackward", "playpause.fill", "goforward",
         "hifispeaker.fill", "hifispeaker.2.fill", "speaker.slash.fill", "eye.fill", "paintpalette.fill"],                                // PRISM · SPECTRUM
        ["moon", "lock", "light.min", "light.max", "sun.min", "sun.max", "sunset", "chevron.left.2", "playpause", "chevron.right.2",
         "minus", "plus", "speaker.slash", "rectangle.dashed", "line.3.horizontal"],                                                      // MONO · SCOPE
        ["power", "lock.fill", "bolt", "bolt.fill", "flame", "flame.fill", "moon.fill", "backward.end.fill", "playpause.fill", "forward.end.fill",
         "megaphone", "megaphone.fill", "nosign", "macwindow", "flag.checkered"],                                                         // NOS
    ]
    /// The icon this look uses for a control, followed by the standard ones as a fallback.
    static func glyph(_ names: [String]) -> [String] {
        guard let first = names.first, let i = order.firstIndex(of: first), Ink.index < glyphs.count, glyphs[Ink.index].count > i else { return names }
        return [glyphs[Ink.index][i]] + names
    }
    var tileTop: NSColor { NSColor(srgbRed: top.0, green: top.1, blue: top.2, alpha: 1) }
    var tileBot: NSColor { NSColor(srgbRed: bot.0, green: bot.1, blue: bot.2, alpha: 1) }
}

// ---------- What the bar shows ----------
struct BarState: Equatable {
    var volume = 0.5, brightness = 0.8, keys = 0.0
    var muted = false, night = false
    var pressed = -1
    var zone = 0            // on a gauge: -1 the down button, 1 the up button, 0 the bar itself
    var glowIndex = 0
    var vibe = false
}

// The strip is painted in two sheets: `base` (tiles, icons, unlit parts) and `glow` (everything that emits light).
// Only the glow sheet is dimmed and brightened with the music, which costs next to nothing.
enum Pass { case all, base, glow }
var pass = Pass.all
var wantsBase: Bool { pass != .glow }
var wantsGlow: Bool { pass != .base }

enum Kind { case esc, sleep, lock, keys, brightness, night, prev, play, next, volume, mute, desk, app }
struct Tile { let kind: Kind; var rect: CGRect }

// Buttons keep a fixed width; the two big gauges share whatever is left.
func stripLayout(_ w: CGFloat, _ h: CGFloat) -> [Tile] {
    let spec: [(Kind, CGFloat, CGFloat)] = [   // kind, width (0 = stretch), gap after
        (.esc, 68, 12), (.sleep, 48, 4), (.lock, 48, 12), (.keys, 126, 4), (.brightness, 0, 4), (.night, 48, 12),
        (.prev, 48, 0), (.play, 56, 0), (.next, 48, 12), (.volume, 0, 4), (.mute, 48, 12), (.desk, 48, 4), (.app, 48, 0)]
    let fixed = spec.reduce(CGFloat(0)) { $0 + $1.1 + $1.2 }
    let stretch = max(120, (w - fixed) / 2)
    var x: CGFloat = 0; var out: [Tile] = []
    for s in spec { let tw = s.1 == 0 ? stretch : s.1; out.append(Tile(kind: s.0, rect: CGRect(x: x, y: 0, width: tw, height: h))); x += tw + s.2 }
    return out
}

/// The same control drawn the way the current look wants it: solid, outlined, or sitting in a disc (falling back to the solid one where Apple has no such variant).
func styled(_ names: [String]) -> [String] {
    let disc = ["moon.zzz.fill": "moon.circle.fill", "sun.horizon.fill": "sunset.circle.fill", "square.grid.2x2.fill": "circle.grid.2x2.fill",
                "speaker.wave.1.fill": "speaker.circle.fill", "speaker.wave.3.fill": "speaker.wave.2.circle.fill", "sun.max.fill": "sun.max.circle.fill"]
    switch Ink.skin.icon {
    case 1: return names.flatMap { [$0.replacingOccurrences(of: ".fill", with: ""), $0] }
    case 2: return names.flatMap { [disc[$0] ?? ($0.replacingOccurrences(of: ".fill", with: "") + ".circle.fill"), $0] }
    default: return names
    }
}
func symbol(_ names: [String], _ size: CGFloat, _ color: NSColor, _ weight: NSFont.Weight? = nil) -> NSImage? {
    for n in styled(Skin.glyph(names)) {
        // In a disc icon the first colour is the picture and the second is the disc, so the picture is punched out dark.
        let colours = n.hasSuffix(".circle.fill") ? [Ink.skin.tileBot.blended(withFraction: 0.35, of: .black)!.withAlphaComponent(color.alphaComponent), color] : [color]
        // Icons made of several parts (a lock on a shield, a speaker with a cone) keep their inner detail by drawing the parts in shades of one colour.
        let paint = colours.count > 1 ? NSImage.SymbolConfiguration(paletteColors: colours) : NSImage.SymbolConfiguration(hierarchicalColor: color)
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight ?? Ink.skin.weight).applying(paint)
        if let i = NSImage(systemSymbolName: n, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) { return i }
    }
    return nil
}
func drawSymbol(_ names: [String], center: CGPoint, size: CGFloat, color: NSColor, glow: NSColor? = nil) {
    guard let img = symbol(names, size, color) else { return }
    let r = CGRect(x: (center.x - img.size.width / 2).rounded(), y: center.y - img.size.height / 2, width: img.size.width, height: img.size.height)
    NSGraphicsContext.saveGraphicsState()
    if let g = glow { let s = NSShadow(); s.shadowColor = g.withAlphaComponent(0.85); s.shadowBlurRadius = 5; s.shadowOffset = .zero; s.set() }
    img.draw(in: r); NSGraphicsContext.restoreGraphicsState()
}
func drawText(_ t: String, center: CGPoint, size: CGFloat, color: NSColor, weight: NSFont.Weight = .semibold, tracking: CGFloat = 0, right: CGFloat? = nil, italic: Bool = true, halo: NSColor? = nil) {
    var font = NSFont.systemFont(ofSize: size, weight: Ink.skin.textWeight ?? weight)
    if Ink.skin.design != .default, let d = font.fontDescriptor.withDesign(Ink.skin.design), let f = NSFont(descriptor: d, size: size) { font = f }
    if italic && Ink.skin.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }   // slanted numerals, as on a race dash
    var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: tracking]
    if let h = halo, Ink.skin.halo { let sh = NSShadow(); sh.shadowColor = h; sh.shadowBlurRadius = 5; sh.shadowOffset = .zero; attrs[.shadow] = sh }
    let s = NSAttributedString(string: t, attributes: attrs)
    let sz = NSAttributedString(string: t, attributes: [.font: font, .kern: tracking]).size()
    let x = right.map { $0 - sz.width } ?? center.x - (sz.width - tracking) / 2
    s.draw(at: CGPoint(x: x, y: center.y - sz.height / 2))
}
var barWidth: CGFloat = 1085

func tilePath(_ r0: CGRect) -> NSBezierPath {
    let r = r0.insetBy(dx: 0.5, dy: 0.5)
    func poly(_ pts: [CGPoint]) -> NSBezierPath { let p = NSBezierPath(); p.move(to: pts[0]); pts.dropFirst().forEach { p.line(to: $0) }; p.close(); p.lineJoinStyle = .round; return p }
    func cut(_ bl: CGFloat, _ br: CGFloat, _ tr: CGFloat, _ tl: CGFloat) -> NSBezierPath {      // a rectangle with each corner cut by the given amount
        poly([CGPoint(x: r.minX + bl, y: r.minY), CGPoint(x: r.maxX - br, y: r.minY), CGPoint(x: r.maxX, y: r.minY + br), CGPoint(x: r.maxX, y: r.maxY - tr),
              CGPoint(x: r.maxX - tr, y: r.maxY), CGPoint(x: r.minX + tl, y: r.maxY), CGPoint(x: r.minX, y: r.maxY - tl), CGPoint(x: r.minX, y: r.minY + bl)])
    }
    switch Ink.skin.shape {
    case 1: return cut(6, 6, 6, 6)
    case 2: return cut(1.5, 9, 1.5, 9)
    case 3: return NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
    case 4: return NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2)
    case 5: return NSBezierPath(roundedRect: r, xRadius: 11, yRadius: 11)
    case 6: return NSBezierPath(roundedRect: r, xRadius: 0.5, yRadius: 0.5)
    case 7: return poly([CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX - 7, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX + 7, y: r.maxY)])
    default: return NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
    }
}

// Soft coloured light along the bottom lip of a tile, like underglow on a car.
func drawUnderglow(_ r: CGRect, _ color: NSColor? = nil, strength: CGFloat = 1) {
    guard wantsGlow else { return }
    NSGraphicsContext.saveGraphicsState(); tilePath(r).addClip()
    // Colour follows the position along the strip, so the whole bar shifts from one neon to its partner.
    let a = color ?? Ink.neon(r.minX / barWidth), b = color ?? Ink.neon(r.maxX / barWidth)
    let k = min(1, 0.62 * strength)
    NSGradient(colors: [a.withAlphaComponent(0), a.withAlphaComponent(k), b.withAlphaComponent(k), b.withAlphaComponent(0)], atLocations: [0, 0.25, 0.75, 1], colorSpace: .sRGB)!
        .draw(in: CGRect(x: r.minX + 5, y: r.minY, width: r.width - 10, height: 1.5), angle: 0)
    let w = min(0.5, 0.17 * strength)
    for (c, x0, x1) in [(a, r.minX, r.midX), (b, r.midX, r.maxX)] {
        NSGradient(colors: [c.withAlphaComponent(w), c.withAlphaComponent(0)])!.draw(in: CGRect(x: x0, y: r.minY, width: x1 - x0, height: 11), angle: 90)
    }
    NSGraphicsContext.restoreGraphicsState()
}

func drawTile(_ r: CGRect, pressed: Bool, tint: NSColor? = nil, underglow: Bool = true) {
    let path = tilePath(r)
    if wantsBase {
        let lift: CGFloat = pressed ? 0.12 : 0
        let skin = Ink.skin
        NSGradient(colors: [skin.tileTop.blended(withFraction: lift * 2, of: .white)!.withAlphaComponent(0.74), skin.tileBot.blended(withFraction: lift, of: .white)!.withAlphaComponent(0.80), skin.tileBot.blended(withFraction: 0.3, of: .black)!.withAlphaComponent(0.70)],
                   atLocations: [0, 0.70, 1], colorSpace: .sRGB)!.draw(in: path, angle: -90)
        if let t = tint { t.withAlphaComponent(pressed ? 0.26 : 0.16).setFill(); path.fill() }
        NSGraphicsContext.saveGraphicsState(); path.addClip()
        // Smoked glass: a soft gloss over the upper half.
        if skin.gloss { NSGradient(colors: [NSColor.white.withAlphaComponent(0.075), NSColor.white.withAlphaComponent(0.0)])!.draw(in: CGRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2), angle: -90) }
        let weave = NSBezierPath(); weave.lineWidth = 0.5
        switch skin.weave {
        case 1:      // carbon twill, kept faint: fine diagonal threads you notice only up close
            var x = r.minX - r.height
            while x < r.maxX { weave.move(to: CGPoint(x: x, y: r.minY)); weave.line(to: CGPoint(x: x + r.height, y: r.maxY)); x += 2.5 }
            NSColor.white.withAlphaComponent(0.045).setStroke(); weave.stroke()
        case 2:      // hazard stripes
            weave.lineWidth = 3.5; var x = r.minX - r.height
            while x < r.maxX { weave.move(to: CGPoint(x: x, y: r.minY)); weave.line(to: CGPoint(x: x + r.height, y: r.maxY)); x += 10 }
            Ink.glow.withAlphaComponent(0.07).setStroke(); weave.stroke()
        case 3:      // fine grid
            var x = r.minX + 3; while x < r.maxX { weave.move(to: CGPoint(x: x, y: r.minY)); weave.line(to: CGPoint(x: x, y: r.maxY)); x += 6 }
            var y = r.minY + 3; while y < r.maxY { weave.move(to: CGPoint(x: r.minX, y: y)); weave.line(to: CGPoint(x: r.maxX, y: y)); y += 6 }
            Ink.glow.withAlphaComponent(0.10).setStroke(); weave.stroke()
        case 4:      // star dust: the same few points every time, so nothing flickers
            var seed = UInt32(truncatingIfNeeded: Int(r.minX) &* 2654435761)
            for _ in 0..<Int(r.width / 5) {
                seed = seed &* 1664525 &+ 1013904223; let fx = CGFloat(seed >> 8 & 0xFFFF) / 65535
                seed = seed &* 1664525 &+ 1013904223; let fy = CGFloat(seed >> 8 & 0xFFFF) / 65535
                NSColor.white.withAlphaComponent(0.10 + 0.30 * fy).setFill()
                NSBezierPath(ovalIn: CGRect(x: r.minX + fx * r.width, y: r.minY + fy * r.height, width: 0.9, height: 0.9)).fill()
            }
        case 5:      // chevrons pointing forwards
            weave.lineWidth = 2; var x = r.minX - 6
            while x < r.maxX { weave.move(to: CGPoint(x: x, y: r.minY)); weave.line(to: CGPoint(x: x + r.height / 2, y: r.midY)); weave.line(to: CGPoint(x: x, y: r.maxY)); x += 9 }
            Ink.glow.withAlphaComponent(0.09).setStroke(); weave.stroke()
        default: break
        }
        // Machined bezel: a bright lip along the top edge.
        if skin.gloss { NSGradient(colors: [NSColor.white.withAlphaComponent(0), NSColor.white.withAlphaComponent(0.30), NSColor.white.withAlphaComponent(0)])!
            .draw(in: CGRect(x: r.minX + 4, y: r.maxY - 1.5, width: r.width - 8, height: 1), angle: 0) }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(skin.outline).setStroke(); path.lineWidth = 1; path.stroke()
    }
    if wantsGlow {
        if pressed { (tint ?? Ink.neon(r.midX / barWidth)).setStroke(); path.lineWidth = 1.2; path.stroke() }
        else if let t = tint { t.withAlphaComponent(0.7).setStroke(); path.lineWidth = 1; path.stroke() }
    }
    if underglow { drawUnderglow(r, tint, strength: pressed ? 2.4 : (tint != nil ? 1.7 : 1)) }
}
// Every icon is a little neon tube: a white core on the base sheet and a coloured halo on the glow sheet. Switched-off icons stay unlit.
func icon(_ names: [String], _ c: CGPoint, _ size: CGFloat, _ color: NSColor) {
    let lit = color.alphaComponent > 0.6, sk = Ink.skin, here = Ink.neon(c.x / barWidth)
    // The lit core is white, the look's own neon, or a place on the rainbow, depending on the look.
    let core: NSColor = sk.tint == 1 ? here.blended(withFraction: 0.30, of: .white)! : (sk.tint == 2 ? NSColor(hue: 0.83 * c.x / barWidth, saturation: 0.70, brightness: 1, alpha: 1) : .white)
    if wantsBase { drawSymbol(names, center: c, size: size, color: lit ? (sk.tint == 0 ? color : core).withAlphaComponent(0.78) : color) }
    if wantsGlow, lit { drawSymbol(names, center: c, size: size, color: core, glow: sk.halo ? here : nil); if sk.halo { drawSymbol(names, center: c, size: size, color: core, glow: here) } }
}
func litIcon(_ names: [String], _ c: CGPoint, _ size: CGFloat, _ color: NSColor) {
    if wantsBase { drawSymbol(names, center: c, size: size, color: color.withAlphaComponent(0.72)) }
    if wantsGlow { drawSymbol(names, center: c, size: size, color: color, glow: color) }
}

// Where the parts of a gauge sit: a down button, the bar, an optional number, an up button.
struct GaugeGeo { let down: CGRect, up: CGRect, left: CGFloat, right: CGFloat, count: Int }
func gaugeGeo(_ r: CGRect, number: Bool) -> GaugeGeo {
    let z: CGFloat = number ? 32 : 27
    return GaugeGeo(down: CGRect(x: r.minX, y: r.minY, width: z, height: r.height), up: CGRect(x: r.maxX - z, y: r.minY, width: z, height: r.height),
                    left: r.minX + z + 5, right: r.maxX - z - (number ? 33 : 5), count: number ? 16 : 12)
}

// A rev-bar gauge with a button at each end. `hot` is where the red zone starts (1 = none).
func drawGauge(_ r: CGRect, value: Double, down: [String], up: [String], pressed: Bool, zone: Int, hot: Double = 1, label: String? = nil, off: Bool = false) {
    let number = label != nil, g = gaugeGeo(r, number: number)
    drawTile(r, pressed: pressed && zone == 0)
    for (z, box) in [(-1, g.down), (1, g.up)] {
        let hit = pressed && zone == z
        if hit {
            NSGraphicsContext.saveGraphicsState(); tilePath(r).addClip()
            if wantsBase { NSColor.white.withAlphaComponent(0.13).setFill(); box.fill() }
            NSGraphicsContext.restoreGraphicsState()
            drawUnderglow(box.insetBy(dx: -5, dy: 0).intersection(r), nil, strength: 2.6)
        }
        if wantsBase { NSColor.white.withAlphaComponent(0.10).setFill(); CGRect(x: (z < 0 ? box.maxX : box.minX) - 0.5, y: r.minY + 7, width: 1, height: r.height - 14).fill() }
        icon(z < 0 ? down : up, CGPoint(x: box.midX + (z < 0 ? 1 : -1), y: r.midY), 12, off && z < 0 ? Ink.dim : (hit ? .white : Ink.mid))
    }
    let kind = Ink.skin.seg
    let n = g.count, step = (g.right - g.left) / CGFloat(n), hgt: CGFloat = kind == 8 ? 17 : 14, lean: CGFloat = kind == 8 ? 6 : ((kind == 0 || kind == 6) ? 2.6 : 0)
    let lit = off ? 0 : Int((value * Double(n)).rounded())
    for i in 0..<n {
        let isHot = Double(i) / Double(n) >= hot, on = i < lit
        let x = g.left + CGFloat(i) * step - lean / 2, w = step - 2.0, y = r.midY - hgt / 2, mid = CGPoint(x: x + w / 2 + lean / 2, y: r.midY)
        let seg: NSBezierPath
        switch kind {
        case 1: seg = NSBezierPath(rect: CGRect(x: mid.x - 0.9, y: y - 1, width: 1.8, height: hgt + 2))                               // laser lines
        case 2: seg = NSBezierPath(roundedRect: CGRect(x: x, y: y + 2, width: w, height: hgt - 4), xRadius: 1, yRadius: 1)          // LED blocks
        case 3: let d = min(w, 8.5); seg = NSBezierPath(ovalIn: CGRect(x: mid.x - d / 2, y: mid.y - d / 2, width: d, height: d))    // beads
        case 4: seg = NSBezierPath(rect: CGRect(x: x, y: y, width: w, height: hgt))                                                  // upright bars
        case 5: seg = NSBezierPath(); seg.move(to: CGPoint(x: mid.x, y: y)); seg.line(to: CGPoint(x: mid.x + w / 2, y: mid.y))      // diamonds
            seg.line(to: CGPoint(x: mid.x, y: y + hgt)); seg.line(to: CGPoint(x: mid.x - w / 2, y: mid.y)); seg.close()
        case 7: seg = NSBezierPath(rect: CGRect(x: x + 0.5, y: y, width: max(2, w - 2), height: hgt))                                // ticks
        default:     // bars that lean forward like a shift light
            seg = NSBezierPath(); seg.move(to: CGPoint(x: x, y: y)); seg.line(to: CGPoint(x: x + w, y: y))
            seg.line(to: CGPoint(x: x + w + lean, y: y + hgt)); seg.line(to: CGPoint(x: x + lean, y: y + hgt)); seg.close()
        }
        let c = isHot ? Ink.red : (kind == 6 ? NSColor(hue: 0.83 * CGFloat(i) / CGFloat(n), saturation: 0.9, brightness: 1, alpha: 1) : Ink.neon(pow(CGFloat(i) / CGFloat(n - 1), 1.25)))
        if wantsBase {
            if kind == 7, !on { NSColor.white.withAlphaComponent(0.30).setStroke(); seg.lineWidth = 0.8; seg.stroke() }     // hollow when off
            else { (on ? c.withAlphaComponent(0.42) : (isHot ? Ink.red.withAlphaComponent(0.26) : NSColor.white.withAlphaComponent(0.13))).setFill(); seg.fill() }
        }
        guard on, wantsGlow else { continue }
        let tip = i == lit - 1
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow(); sh.shadowColor = c; sh.shadowBlurRadius = tip ? 8 : 5; sh.shadowOffset = .zero; sh.set()
        (tip ? c.blended(withFraction: 0.6, of: .white)! : c).setFill(); seg.fill(); if tip { seg.fill() }
        NSGraphicsContext.restoreGraphicsState()
        // A lighter upper half gives each segment a glassy, lit-from-inside look.
        NSGraphicsContext.saveGraphicsState(); seg.addClip()
        NSColor.white.withAlphaComponent(tip ? 0.38 : 0.22).setFill(); CGRect(x: x, y: r.midY, width: w + lean, height: hgt / 2 + 2).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    if let label = label {
        let text = off ? "--" : "\(Int((value * 100).rounded()))", at = CGPoint(x: 0, y: r.midY - 3.5), edge = g.up.minX - 6, big: CGFloat = text.count > 2 ? 11.5 : 13
        if wantsBase { drawText(label == "輝度" ? Ink.skin.labels.0 : Ink.skin.labels.1, center: CGPoint(x: 0, y: r.midY + 8), size: 6.5, color: NSColor.white.withAlphaComponent(0.55), weight: .bold, tracking: 0.6, right: edge, italic: false) }
        if pressed && zone == 0 && !off { if wantsGlow { drawText(text, center: at, size: big, color: Ink.neon(1).blended(withFraction: 0.45, of: .white)!, weight: .heavy, right: edge) } }
        else {
            if wantsBase { drawText(text, center: at, size: big, color: off ? Ink.dim : NSColor.white.withAlphaComponent(0.82), weight: .heavy, right: edge) }
            if wantsGlow, !off { drawText(text, center: at, size: big, color: .white, weight: .heavy, right: edge, halo: Ink.neon(edge / barWidth)) }
        }
    }
}

func drawBar(_ bounds: CGRect, _ s: BarState) {
    barWidth = bounds.width
    let tiles = stripLayout(bounds.width, bounds.height)
    for (i, t) in tiles.enumerated() {
        let r = t.rect, p = s.pressed == i, c = CGPoint(x: r.midX, y: r.midY)
        switch t.kind {
        case .esc:
            drawTile(r, pressed: p)
            if wantsBase { drawText(Ink.skin.esc, center: c, size: 12, color: NSColor.white.withAlphaComponent(0.8), weight: .heavy, tracking: Ink.skin.escTrack) }
            if wantsGlow { for _ in 0..<(Ink.skin.halo ? 2 : 1) { drawText(Ink.skin.esc, center: c, size: 12, color: .white, weight: .heavy, tracking: Ink.skin.escTrack, halo: Ink.neon(c.x / barWidth)) } }
        case .sleep: drawTile(r, pressed: p); icon(["moon.zzz.fill", "powersleep"], c, 13.5, p ? .white : Ink.mid)
        case .lock: drawTile(r, pressed: p); icon(["lock.fill"], c, 13, p ? .white : Ink.mid)
        case .keys: drawGauge(r, value: s.keys, down: ["light.min"], up: ["light.max"], pressed: p, zone: s.zone)
        case .brightness: drawGauge(r, value: s.brightness, down: ["sun.min.fill"], up: ["sun.max.fill"], pressed: p, zone: s.zone, label: "輝度")
        case .night:
            drawTile(r, pressed: p, tint: s.night ? Ink.amber : nil)
            if s.night { litIcon(["sun.horizon.fill", "sunset.fill", "moon.stars.fill"], c, 13, Ink.amber) } else { icon(["sun.horizon.fill", "sunset.fill", "moon.stars.fill"], c, 13, p ? .white : Ink.mid) }
        case .prev:
            // Previous, play and next share one long tile, split by hairlines, like a transport deck.
            let deck = r.union(tiles[i + 2].rect); drawTile(deck, pressed: false)
            for k in 0..<3 where s.pressed == i + k {
                NSGraphicsContext.saveGraphicsState(); tilePath(deck).addClip()
                if wantsBase { NSColor.white.withAlphaComponent(0.10).setFill(); tiles[i + k].rect.fill() }
                NSGraphicsContext.restoreGraphicsState()
                drawUnderglow(tiles[i + k].rect.insetBy(dx: -6, dy: 0).intersection(deck), nil, strength: 2.6)
            }
            if wantsBase { for k in 1...2 { NSColor.white.withAlphaComponent(0.08).setFill(); CGRect(x: tiles[i + k].rect.minX - 0.5, y: r.minY + 7, width: 1, height: r.height - 14).fill() } }
            icon(["backward.fill"], c, 12.5, p ? .white : Ink.mid)
        case .play:
            litIcon(["playpause.fill"], c, 13.5, p ? Ink.glow.blended(withFraction: 0.6, of: .white)! : Ink.glow)
            // A small pilot light shows that the strip is listening to the music.
            if s.vibe && wantsGlow { Ink.glow.setFill(); NSBezierPath(ovalIn: CGRect(x: c.x - 1.25, y: r.minY + 3.2, width: 2.5, height: 2.5)).fill() }
        case .next: icon(["forward.fill"], c, 12.5, p ? .white : Ink.mid)
        case .volume: drawGauge(r, value: s.volume, down: ["speaker.wave.1.fill"], up: ["speaker.wave.3.fill"], pressed: p, zone: s.zone, hot: 0.85, label: "音量", off: s.muted)
        case .mute:
            drawTile(r, pressed: p, tint: s.muted ? Ink.red : nil)
            if s.muted { litIcon(["speaker.slash.fill"], c, 13, Ink.red) } else { icon(["speaker.slash.fill"], c, 13, p ? .white : Ink.mid) }
        case .desk: drawTile(r, pressed: p); icon(["menubar.dock.rectangle", "macwindow"], c, 13.5, p ? .white : Ink.mid)
        case .app: drawTile(r, pressed: p); icon(["square.grid.2x2.fill", "square.grid.2x2"], c, 12.5, p ? .white : Ink.mid)
        }
    }
}

// The neon that lives behind the glass: one full colour cycle per strip width, pooled toward the bottom edge.
func backdropColors(periods: Int) -> [NSColor] { (0...(periods * 4)).map { Ink.neon($0 % 4 == 0 ? 0 : $0 % 4 == 2 ? 1 : 0.5) } }
func drawBackdrop(_ b: CGRect, _ strength: CGFloat) {
    NSColor.black.setFill(); b.fill()
    NSGradient(colors: backdropColors(periods: 1))!.draw(in: b, angle: 0)
    NSGradient(colors: [NSColor.black.withAlphaComponent(1 - strength), NSColor.black.withAlphaComponent(1 - 0.30 * strength)])!.draw(in: b, angle: 90)
}

func barImage(_ s: BarState, _ which: Pass, size: CGSize = CGSize(width: 1085, height: 30)) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    pass = which; drawBar(CGRect(origin: .zero, size: size), s); pass = .all
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// ---------- Listening to the music (loudness only) ----------
// A read-only tap on what the Mac is playing. The sound is not touched, recorded or sent anywhere:
// each block is boiled down to one loudness number, weighted toward the bass so the glow breathes on the beat.
final class Pulse {
    private var tapID = AudioObjectID(kAudioObjectUnknown), aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let q = DispatchQueue(label: "glowstrip.audio", qos: .userInteractive), lock = NSLock()
    private var low: Float = 0, env: Float = 0, peak: Float = 0.02, lastSound = Date.distantPast
    var running: Bool { procID != nil }

    private static func addr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    static var outputDevice: AudioObjectID {
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice); var dev = AudioObjectID(0); var sz = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &dev); return dev
    }
    /// True while some app has the speakers open, so the tap only runs when there may be something to hear.
    static var somethingPlaying: Bool {
        var a = addr(kAudioDevicePropertyDeviceIsRunningSomewhere); var on: UInt32 = 0; var sz = UInt32(4)
        return AudioObjectGetPropertyData(outputDevice, &a, 0, nil, &sz, &on) == noErr && on != 0
    }
    /// Returns nil when it started, otherwise a short reason.
    func start() -> String? {
        guard !running else { return nil }
        let dev = Pulse.outputDevice
        var a = Pulse.addr(kAudioDevicePropertyDeviceUID); var uidRef: Unmanaged<CFString>?; var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &uidRef) == noErr, let uid = uidRef?.takeRetainedValue() as String? else { return "No output device" }
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID(); desc.name = "Glowstrip"; desc.isPrivate = true; desc.muteBehavior = .unmuted
        guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr else { tapID = AudioObjectID(kAudioObjectUnknown); return "macOS did not allow listening to system audio" }
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Glowstrip", kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: uid, kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID) == noErr else { stop(); return "Could not open the audio tap" }
        let st = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, q) { [weak self] _, inData, _, _, _ in self?.feed(inData) }
        guard st == noErr, let pid = procID, AudioDeviceStart(aggID, pid) == noErr else { stop(); return "Could not start the audio tap" }
        return nil
    }
    func stop() {
        if aggID != kAudioObjectUnknown {
            if let p = procID { AudioDeviceStop(aggID, p); AudioDeviceDestroyIOProcID(aggID, p) }
            AudioHardwareDestroyAggregateDevice(aggID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil; aggID = AudioObjectID(kAudioObjectUnknown); tapID = AudioObjectID(kAudioObjectUnknown)
        lock.lock(); env = 0; low = 0; lock.unlock()
    }
    private func feed(_ inData: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        guard let buf = list.last, let raw = buf.mData else { return }
        let ch = max(1, Int(buf.mNumberChannels)), frames = Int(buf.mDataByteSize) / (4 * ch)
        guard frames > 0 else { return }
        let p = raw.assumingMemoryBound(to: Float.self)
        var bass: Float = 0, all: Float = 0, l = low
        for i in 0..<frames { let x = p[i * ch]; l += 0.02 * (x - l); bass += l * l; all += x * x }   // 0.02 is a gentle low-pass near 150 Hz
        bass = (bass / Float(frames)).squareRoot(); all = (all / Float(frames)).squareRoot()
        let v = bass * 1.6 + all * 0.4
        let hold = powf(0.93, Float(frames) / 512)                 // same fall-off whatever block size the Mac hands over
        lock.lock()
        low = l
        peak = max(0.02, max(peak * powf(0.9995, Float(frames) / 512), v))   // follows the song, never amplifies silence
        let n = powf(min(1, v / peak), 1.5)
        env = n > env ? n : env * hold + n * (1 - hold)
        if all > 0.0008 { lastSound = Date() }
        lock.unlock()
    }
    /// Loudness 0...1 and how long it has been quiet, in seconds.
    func read() -> (level: Float, quiet: TimeInterval) { lock.lock(); defer { lock.unlock() }; return (env, -lastSound.timeIntervalSinceNow) }
}

// ---------- The Mac's controls ----------
enum Mac {
    static let keysClient = KeyboardBrightnessClient(), nightClient = CBBlueLightClient()
    static var keysID: UInt64 = { (keysClient.copyKeyboardBacklightIDs()?.first as? NSNumber)?.uint64Value ?? 1 }()
    static var screen: CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8); var n: UInt32 = 0
        CGGetOnlineDisplayList(8, &ids, &n)
        return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
    }
    static var brightness: Double {
        get { var b: Float = 0; return DisplayServicesGetBrightness(screen, &b) == 0 ? Double(b) : 0.8 }
        set { _ = DisplayServicesSetBrightness(screen, Float(min(1, max(0, newValue)))) }
    }
    static var keys: Double {
        get { Double(keysClient.brightness(forKeyboard: keysID)) }
        set { _ = keysClient.setBrightness(Float(min(1, max(0, newValue))), forKeyboard: keysID) }
    }
    static var night: Bool {
        get { var s = CBBlueLightStatus(); return nightClient.getBlueLightStatus(&s) && s.enabled.boolValue }
        set { _ = nightClient.setEnabled(newValue) }
    }
    static var speaker: AudioDeviceID {
        var id = AudioDeviceID(0); var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &id); return id
    }
    static let volumeSel: AudioObjectPropertySelector = 0x766d7663 // 'vmvc', the overall output volume
    static var volume: Double {
        get { var v: Float32 = 0; var sz = UInt32(4); var a = AudioObjectPropertyAddress(mSelector: volumeSel, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            return AudioObjectGetPropertyData(speaker, &a, 0, nil, &sz, &v) == 0 ? Double(v) : 0 }
        set { var v = Float32(min(1, max(0, newValue))); var a = AudioObjectPropertyAddress(mSelector: volumeSel, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            AudioObjectSetPropertyData(speaker, &a, 0, nil, 4, &v) }
    }
    static var muted: Bool {
        get { var m: UInt32 = 0; var sz = UInt32(4); var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            return AudioObjectGetPropertyData(speaker, &a, 0, nil, &sz, &m) == 0 && m != 0 }
        set { var m: UInt32 = newValue ? 1 : 0; var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            AudioObjectSetPropertyData(speaker, &a, 0, nil, 4, &m) }
    }
    static var canType: Bool { CGPreflightPostEventAccess() }
    /// Asks macOS for the Accessibility switch (needed for Esc) at most ONCE per installed copy, ever: Redline starts this part
    /// every time the engine starts, and it must not nag each time. Only a rebuilt copy (which macOS treats as a new app) may ask again.
    static func askOnce() {
        guard !canType else { return }
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let stamp = ((try? FileManager.default.attributesOfItem(atPath: exe))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "accessibilityAskedFor"
        guard UserDefaults.standard.double(forKey: key) != stamp else { return }
        UserDefaults.standard.set(stamp, forKey: key)
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
    static func escape() {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] { CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: down)?.post(tap: .cghidEventTap) }
    }
    static func mediaKey(_ key: Int) {  // 16 play/pause, 17 next, 18 previous: the same signal the real keys send
        for down in [true, false] {
            let e = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00), timestamp: 0,
                                       windowNumber: 0, context: nil, subtype: 8, data1: (key << 16) | ((down ? 0xa : 0xb) << 8), data2: -1)
            e?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
    static func media(_ key: Int, _ command: UInt32) { if canType { mediaKey(key) } else { _ = MRMediaRemoteSendCommand(command, nil) } }
    static func sleep() { let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); p.arguments = ["sleepnow"]; try? p.run() }
    static func read(into s: inout BarState) {
        s.volume = volume; s.muted = muted; s.brightness = brightness; s.keys = keys; s.night = night
        s.glowIndex = Ink.theme
    }
}

// ---------- The strip itself ----------
final class StripView: NSView {
    var state = BarState() { didSet { if state != oldValue { repaint() } } }
    var onTap: ((Kind) -> Void)?, onHold: ((Kind) -> Void)?
    private var tiles: [Tile] { stripLayout(bounds.width, bounds.height) }
    private var active: (index: Int, touch: NSObjectProtocol & NSCopying, began: Date)?
    var dragging: Bool { active != nil }
    private let baseLayer = CALayer(), glowLayer = CALayer()
    private let backdrop = CALayer(), flow = CAGradientLayer(), fall = CAGradientLayer(), sheen = CAGradientLayer()
    private var flowing = false, paintedTheme = -1
    private let runners = CALayer(), sparks = CALayer()
    private var sweep: Timer?, sweepStart = Date()

    override init(frame: NSRect) {
        super.init(frame: frame); allowedTouchTypes = [.direct]; wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        let still: [String: CAAction] = ["contents": NSNull(), "opacity": NSNull(), "bounds": NSNull(), "position": NSNull(), "colors": NSNull()]
        // Back to front: neon backdrop, glass tiles, everything that emits light, and a travelling sheen.
        backdrop.masksToBounds = true; backdrop.opacity = 1; backdrop.addSublayer(flow); backdrop.mask = fall
        flow.startPoint = CGPoint(x: 0, y: 0.5); flow.endPoint = CGPoint(x: 1, y: 0.5)
        fall.startPoint = CGPoint(x: 0.5, y: 0); fall.endPoint = CGPoint(x: 0.5, y: 1)
        fall.colors = [NSColor.white.cgColor, NSColor.white.withAlphaComponent(0.30).cgColor]
        sheen.startPoint = CGPoint(x: 0, y: 0.5); sheen.endPoint = CGPoint(x: 1, y: 0.5)
        sheen.colors = [NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0.17).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        sheen.setAffineTransform(CGAffineTransform(a: 1, b: 0, c: 0.55, d: 1, tx: 0, ty: 0))
        for l in [backdrop, flow, fall, baseLayer, glowLayer, sheen] { l.actions = still }
        for l in [baseLayer, glowLayer] { l.contentsScale = 2; l.contentsGravity = .resize }
        runners.actions = still; runners.opacity = 0; sparks.actions = still
        for l in [backdrop, baseLayer, glowLayer, runners, sparks, sheen] { layer?.addSublayer(l) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 1085, height: 30) }
    override func layout() {
        super.layout()
        baseLayer.frame = bounds; glowLayer.frame = bounds; backdrop.frame = bounds; fall.frame = bounds
        flow.frame = CGRect(x: 0, y: 0, width: bounds.width * 2, height: bounds.height)   // two colour cycles, so sliding by one cycle loops without a seam
        sheen.bounds = CGRect(x: 0, y: 0, width: 110, height: bounds.height + 4); sheen.position = CGPoint(x: -120, y: bounds.midY)
        runners.frame = bounds; sparks.frame = bounds; buildRunners()
        paintedTheme = -1; repaint()
        if flowing { flowing = false; setFlowing(true) }
    }
    /// The outline of each tile, with the three media buttons counted as one deck.
    private var outlines: [CGRect] {
        var out: [CGRect] = []; let t = tiles
        for (i, tile) in t.enumerated() { if tile.kind == .prev { out.append(tile.rect.union(t[i + 2].rect)) } else if tile.kind != .play && tile.kind != .next { out.append(tile.rect) } }
        return out
    }
    // Two short streaks of light chase each other around every tile's edge. They are drawn once here and moved by the graphics system.
    private func buildRunners() {
        runners.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard bounds.width > 10 else { return }
        for r in outlines {
            let box = r.insetBy(dx: 0.5, dy: 0.5), rad: CGFloat = 7
            let l = CAShapeLayer(); l.frame = bounds; l.path = tilePath(r).cgPath
            let c = Ink.neon(r.midX / bounds.width)
            l.fillColor = nil; l.strokeColor = c.blended(withFraction: 0.65, of: .white)!.cgColor; l.lineWidth = 1.5; l.lineCap = .round
            // The halo is a second, wider and fainter streak rather than a blur: a moving blur made the Touch Bar's own process work several times harder.
            let haze = CAShapeLayer(); haze.frame = bounds; haze.path = l.path; haze.fillColor = nil; haze.strokeColor = c.withAlphaComponent(0.30).cgColor; haze.lineWidth = 4.5; haze.lineCap = .round
            let half = (2 * (box.width + box.height) - 8 * rad + 2 * .pi * rad) / 2
            // Each look moves differently: ice = two streaks chasing; nitrous = one long laser sweep; toxic = a crawl of short dashes;
            // sunset = the whole edge glows, nothing runs; NOS = four short, fast, white-hot streaks (the newer looks are noted on their lines).
            var pattern: [CGFloat]? = [min(22, half * 0.4), half - min(22, half * 0.4)], period = half, pace: CGFloat = 70
            switch Ink.index {
            case 1: pattern = [half * 0.9, half * 1.1]; period = 2 * half; pace = 110
            case 2: pattern = [5, 5]; period = 10; pace = 14
            case 3: pattern = nil
            case 4: pattern = [min(30, half * 0.5), half - min(30, half * 0.5)]; pace = -55          // vapor: slow, the other way round
            case 5: pattern = [1.5, 9]; period = 10.5; pace = 46                                    // galaxy: a string of star points
            case 6: pattern = [min(14, half * 0.2), half * 2 / 3 - min(14, half * 0.2)]; period = half * 2 / 3; pace = 85   // prism: three streaks
            case 7: pattern = nil; l.lineWidth = 1                                                  // mono: one thin clean outline
            case 8: pattern = [min(12, half * 0.2), half / 2 - min(12, half * 0.2)]; period = half / 2; pace = 150
                l.strokeColor = NSColor.white.cgColor
            default: break
            }
            l.lineDashPattern = pattern?.map { NSNumber(value: Double($0)) }
            let a = CABasicAnimation(keyPath: "lineDashPhase"); a.fromValue = 0; a.toValue = pace < 0 ? period : -period; a.duration = Double(period / abs(pace)); a.repeatCount = .infinity
            haze.lineDashPattern = l.lineDashPattern
            for x in [haze, l] { x.add(a, forKey: "run"); runners.addSublayer(x) }
        }
    }
    /// Brightness 0...1 of the runner lights and how fast they travel (1 = normal). Speed changes keep each streak where it is, so nothing jumps.
    func setRunners(brightness: CGFloat, speed: Float) {
        if abs(CGFloat(runners.opacity) - brightness) > 0.004 { runners.opacity = Float(brightness) }
        guard abs(runners.speed - speed) > 0.08 else { return }
        let now = CACurrentMediaTime(), local = runners.convertTime(now, from: nil)
        runners.beginTime = layer?.convertTime(now, from: nil) ?? now; runners.timeOffset = local; runners.speed = speed
    }
    /// A few four-point glints flash near random icons and fade within half a second.
    func sparkle(_ count: Int) {
        guard bounds.width > 10 else { return }
        let boxes = tiles.filter { !isSlider($0.kind) }.map { $0.rect }
        for _ in 0..<count {
            guard let r = boxes.randomElement() else { return }
            let size = CGFloat.random(in: 3.2...5.6), thin = size * 0.22
            let star = CGMutablePath()
            for k in 0..<8 { let ang = CGFloat(k) * .pi / 4, rad = k % 2 == 0 ? size : thin
                let p = CGPoint(x: cos(ang) * rad, y: sin(ang) * rad); if k == 0 { star.move(to: p) } else { star.addLine(to: p) } }
            star.closeSubpath()
            let l = CAShapeLayer(); l.path = star; l.fillColor = NSColor.white.cgColor; l.opacity = 0
            l.shadowColor = Ink.neon(r.midX / bounds.width).cgColor; l.shadowRadius = 3; l.shadowOpacity = 1; l.shadowOffset = .zero
            // Glints sit off the icon's shoulder, toward a corner of the tile.
            l.position = CGPoint(x: r.midX + (Bool.random() ? 1 : -1) * CGFloat.random(in: 8...min(15, r.width / 2 - 6)), y: r.midY + (Bool.random() ? 1 : -1) * CGFloat.random(in: 4...8))
            sparks.addSublayer(l)
            let fade = CAKeyframeAnimation(keyPath: "opacity"); fade.values = [0, 1, 0]; fade.keyTimes = [0, 0.3, 1]
            let grow = CAKeyframeAnimation(keyPath: "transform.scale"); grow.values = [0.2, 1, 0.4]; grow.keyTimes = [0, 0.3, 1]
            let turn = CABasicAnimation(keyPath: "transform.rotation.z"); turn.fromValue = 0; turn.toValue = CGFloat.pi / 4
            let g = CAAnimationGroup(); g.animations = [fade, grow, turn]; g.duration = 0.46
            CATransaction.begin(); CATransaction.setCompletionBlock { l.removeFromSuperlayer() }; l.add(g, forKey: "glint"); CATransaction.commit()
        }
    }
    /// The backdrop colours drift sideways while music plays and hold still in silence. The drift runs in the graphics system, not in this app.
    func setFlowing(_ on: Bool) {
        guard on != flowing, bounds.width > 10 else { return }
        flowing = on
        if on {
            let a = CABasicAnimation(keyPath: "position.x"); a.fromValue = bounds.width; a.toValue = 0; a.duration = 16; a.repeatCount = .infinity
            flow.add(a, forKey: "drift")
        } else { flow.removeAnimation(forKey: "drift") }
    }
    /// NOS: the backdrop throbs hard and fast on its own, music or not.
    func setUrgent(_ on: Bool) {
        flow.removeAnimation(forKey: "urgent")
        guard on else { return }
        let a = CAKeyframeAnimation(keyPath: "opacity"); a.values = [1, 0.25, 1, 0.25, 1]; a.keyTimes = [0, 0.12, 0.24, 0.6, 1]; a.duration = 0.86; a.repeatCount = .infinity
        flow.add(a, forKey: "urgent")
    }
    /// How strongly the backdrop shines, 0...1.
    func setBackdrop(_ v: CGFloat) { if abs(CGFloat(backdrop.opacity) - v) > 0.004 { backdrop.opacity = Float(v) } }
    /// A band of light glides across the glass once, like a streetlight passing over paint.
    func shine() {
        guard bounds.width > 10 else { return }
        let a = CABasicAnimation(keyPath: "position.x"); a.fromValue = -120; a.toValue = bounds.width + 120; a.duration = 1.5
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut); sheen.add(a, forKey: "shine")
    }

    private func repaint() {
        guard bounds.width > 10 else { return }
        var s = state
        // Engine start: the gauges rev with Redline's needles (blip, blip, redline) and then settle on the real values.
        if sweep != nil {
            let t = -sweepStart.timeIntervalSinceNow, r = StripView.rev(t)
            func swept(_ v: Double) -> Double { t < StripView.revHold ? r : 1 + (v - 1) * (1 - pow(1 - min(1, (t - StripView.revHold) / (StripView.revEnd - StripView.revHold)), 3)) }
            s.volume = swept(s.volume); s.brightness = swept(s.brightness); s.keys = swept(s.keys); s.muted = false
        }
        if paintedTheme != Ink.index { if paintedTheme != -1 { buildRunners() }; paintedTheme = Ink.index; flow.colors = backdropColors(periods: 2).map { $0.cgColor } }
        baseLayer.contents = barImage(s, .base, size: bounds.size).cgImage
        glowLayer.contents = barImage(s, .glow, size: bounds.size).cgImage
    }
    // The rev, in seconds from the push: (time, how far up). Redline's card needles follow the same blips.
    static let revKeys: [(Double, Double)] = [(0, 0), (0.15, 0.42), (0.45, 0.10), (0.73, 0.70), (1.05, 0.22), (1.40, 1.0), (2.0, 1.0)]
    static let revHold = 2.0, revEnd = 2.6
    static func rev(_ t: Double) -> Double {
        let k = revKeys
        guard t > 0 else { return 0 }
        for i in 1..<k.count where t <= k[i].0 {
            let f = (t - k[i - 1].0) / (k[i].0 - k[i - 1].0), e = f * f * (3 - 2 * f)       // eased between blips
            return k[i - 1].1 + (k[i].1 - k[i - 1].1) * e
        }
        return 1
    }
    var revving: Bool { sweep != nil }
    /// Engine start: the gauges rev, and the whole bar dims and flares with each blip, then stays at full brightness.
    func ignite() {
        sweep?.invalidate(); sweepStart = Date()
        sweep = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let s = self else { t.invalidate(); return }
            let e = -s.sweepStart.timeIntervalSinceNow
            let light = CGFloat(e < StripView.revHold ? 0.12 + 0.88 * StripView.rev(e) : 1)
            s.setGlow(light); s.setBackdrop(light)
            if e >= StripView.revEnd { t.invalidate(); s.sweep = nil; s.setGlow(1); s.setBackdrop(1); s.shine() }
            s.repaint()
        }
    }
    /// How brightly the glow sheet burns, 0...1. Called many times a second while music plays.
    func setGlow(_ v: CGFloat) { if abs(CGFloat(glowLayer.opacity) - v) > 0.004 { glowLayer.opacity = Float(v) } }

    // A tap leaves a short afterglow that fades on its own.
    private func afterglow(_ r: CGRect) {
        let f = CALayer(); f.frame = r.insetBy(dx: 0.5, dy: 0.5); f.cornerRadius = 7
        f.backgroundColor = Ink.neon(r.midX / max(1, bounds.width)).withAlphaComponent(0.34).cgColor; f.opacity = 0
        layer?.addSublayer(f)
        let a = CABasicAnimation(keyPath: "opacity"); a.fromValue = 1; a.toValue = 0; a.duration = 0.38; a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin(); CATransaction.setCompletionBlock { f.removeFromSuperlayer() }; f.add(a, forKey: "fade"); CATransaction.commit()
    }

    private func isSlider(_ k: Kind) -> Bool { k == .volume || k == .brightness || k == .keys }
    private func value(_ k: Kind) -> Double { k == .volume ? state.volume : k == .brightness ? state.brightness : state.keys }
    private func set(_ k: Kind, _ raw: Double) {
        let v = min(1, max(0, raw))
        switch k {
        case .volume: Mac.volume = v; if v > 0 && state.muted { Mac.muted = false; state.muted = false }; state.volume = v
        case .brightness: Mac.brightness = v; state.brightness = v
        case .keys: Mac.keys = v; state.keys = v
        default: break
        }
    }
    /// One notch up or down, in sixteenths like the real keys.
    private func step(_ k: Kind, _ dir: Double) { set(k, ((value(k) * 16).rounded() + dir) / 16) }
    private var repeater: Timer?, dragFrom: (x: CGFloat, value: Double) = (0, 0)

    override func touchesBegan(with event: NSEvent) {
        guard active == nil, let t = event.touches(matching: .began, in: self).first(where: { $0.type == .direct }) else { return }
        let p = t.location(in: self)
        // Gaps between tiles count as the nearest tile, so there are no dead spots.
        guard let i = tiles.enumerated().min(by: { abs($0.element.rect.midX - p.x) - $0.element.rect.width / 2 < abs($1.element.rect.midX - p.x) - $1.element.rect.width / 2 })?.offset else { return }
        active = (i, t.identity, Date())
        let kind = tiles[i].kind
        guard isSlider(kind) else { state.zone = 0; state.pressed = i; return }
        let g = gaugeGeo(tiles[i].rect, number: kind != .keys)
        let zone = p.x <= g.down.maxX ? -1 : p.x >= g.up.minX ? 1 : 0
        var s = state; s.zone = zone; s.pressed = i; state = s
        if zone == 0 { dragFrom = (p.x, value(kind)); return }   // touching the bar changes nothing; only dragging does
        step(kind, Double(zone))
        // Holding a button keeps stepping, like holding the real key.
        repeater = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            self?.repeater = Timer.scheduledTimer(withTimeInterval: 0.11, repeats: true) { [weak self] _ in self?.step(kind, Double(zone)) }
        }
    }
    override func touchesMoved(with event: NSEvent) {
        guard let a = active, let t = event.touches(matching: .moved, in: self).first(where: { $0.identity.isEqual(a.touch) }) else { return }
        let tile = tiles[a.index], p = t.location(in: self)
        if isSlider(tile.kind) {
            guard state.zone == 0 else { return }
            let g = gaugeGeo(tile.rect, number: tile.kind != .keys)
            set(tile.kind, dragFrom.value + Double((p.x - dragFrom.x) / (g.right - g.left)))   // moves by how far the finger travels, never jumps to it
        } else { state.pressed = tile.rect.insetBy(dx: -8, dy: -20).contains(p) ? a.index : -1 }
    }
    override func touchesEnded(with event: NSEvent) {
        guard let a = active, event.touches(matching: .ended, in: self).contains(where: { $0.identity.isEqual(a.touch) }) else { return }
        let tile = tiles[a.index], fire = state.pressed == a.index && !isSlider(tile.kind)
        var glowBox = tile.rect
        if isSlider(tile.kind), state.zone != 0 { let g = gaugeGeo(tile.rect, number: tile.kind != .keys); glowBox = state.zone < 0 ? g.down : g.up }
        repeater?.invalidate(); repeater = nil; active = nil; state.pressed = -1
        if !isSlider(tile.kind) || state.zone != 0 { afterglow(glowBox) }
        if fire { if -a.began.timeIntervalSinceNow > 0.6, tile.kind == .play { onHold?(tile.kind) } else { onTap?(tile.kind) } }
    }
    override func touchesCancelled(with event: NSEvent) { repeater?.invalidate(); repeater = nil; active = nil; state.pressed = -1 }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTouchBarDelegate {
    static let mainID = NSTouchBarItem.Identifier("local.glowstrip.main"), trayID = NSTouchBarItem.Identifier("local.glowstrip.tray")
    let bar = NSTouchBar(), strip = StripView(frame: NSRect(x: 0, y: 0, width: 1085, height: 30))
    var tray: NSCustomTouchBarItem?
    var shown = false
    let pulse = Pulse()
    var vibe = UserDefaults(suiteName: "local.redline")?.object(forKey: "vibe") as? Bool ?? (UserDefaults.standard.object(forKey: "vibe") as? Bool ?? true)   // glow moves with the music; follows Redline's VIBE switch
    var glowNow: CGFloat = 1, backNow: CGFloat = 1, slow: Float = 0, lastSpark = Date(), beat: Timer?, restAfter = Date.distantPast, lastShine = Date()

    func applicationDidFinishLaunching(_ n: Notification) {
        bar.delegate = self; bar.defaultItemIdentifiers = [Self.mainID]
        strip.onTap = { [weak self] in self?.tap($0) }
        // Holding play/pause switches the music glow on or off.
        strip.onHold = { [weak self] _ in guard let s = self else { return }; s.vibe.toggle(); UserDefaults.standard.set(s.vibe, forKey: "vibe"); s.restAfter = .distantPast; s.refresh() }
        // A small needle button in Apple's own strip brings Glowstrip back after "app controls".
        let t = NSCustomTouchBarItem(identifier: Self.trayID)
        let img = NSImage(systemSymbolName: "speedometer", accessibilityDescription: "Glowstrip")?.withSymbolConfiguration(.init(pointSize: 15, weight: .semibold)) ?? NSImage()
        let button = NSButton(image: img, target: self, action: #selector(show)); button.contentTintColor = Ink.glow
        t.view = button; tray = t
        NSTouchBarItem.addSystemTrayItem(t); DFRElementSetControlStripPresenceForIdentifier(Self.trayID, true)
        show()
        // Sending the Esc key needs the Accessibility switch; macOS shows its own request once.
        Mac.askOnce()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
        // Redline says which look is on (its underglow, VIBE and NOS switches). Local to this Mac.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("local.redline.theme"), object: nil, queue: .main) { [weak self] n in
            let u = n.userInfo ?? [:]
            let on = (u["vibe"] as? Bool) ?? false
            Ink.theme = Ink.look(glow: (u["glow"] as? Int) ?? 0, vibe: on, nos: (u["nos"] as? Bool) ?? false)
            // Redline's VIBE switch is also the music switch here: off = the still ice look, on = it moves with the music again.
            if let s = self, s.vibe != on { s.vibe = on; UserDefaults.standard.set(on, forKey: "vibe"); s.restAfter = .distantPast }
            self?.themed()
        }
        themed()
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(woke), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        signal(SIGUSR1, SIG_IGN)   // `kill -USR1` flips between Glowstrip and Apple's bar, for testing without touching
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        src.setEventHandler { [weak self] in guard let s = self else { return }; if s.shown { s.hide() } else { s.show() } }
        src.resume(); sigSource = src
    }
    var sigSource: DispatchSourceSignal?
    /// Applies the current look: colours repaint on their own; this sets what moves while no music is driving it.
    func themed() {
        (tray?.view as? NSButton)?.contentTintColor = Ink.glow
        strip.setUrgent(false)      // NOS is still and red: nothing blinks
        refresh()
        if beat == nil { strip.setRunners(brightness: restRunners, speed: Ink.theme == 8 ? 2.6 : 1) }
        if shown, Ink.theme != 8 { strip.shine(); lastShine = Date() }
    }
    /// Runner lights at rest: off in the standard look, a steady edge glow for sunset, full speed for NOS.
    var restRunners: CGFloat { Ink.theme == 8 ? 0 : (Ink.theme == 3 ? 0.55 : (Ink.theme == 7 ? 0.4 : 0)) }

    func refresh() {
        tend()
        guard shown, !strip.dragging else { return }
        var s = strip.state; Mac.read(into: &s); s.vibe = vibe; strip.state = s
    }
    // Starts listening only while the strip is up and some app has the speakers open; lets go after 20 quiet seconds.
    func tend() {
        let want = vibe && shown && Ink.theme != 8      // NOS: no listening, no moving glow
        if want, !pulse.running, Date() > restAfter, Pulse.somethingPlaying {
            if pulse.start() != nil { restAfter = Date().addingTimeInterval(60) } else { listenSince = Date() }
        } else if pulse.running, !want || (pulse.read().quiet > 20 && -listenSince.timeIntervalSinceNow > 20) {
            pulse.stop(); restAfter = Date().addingTimeInterval(want ? 15 : 0)
        }
        if pulse.running, beat == nil {
            beat = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.breathe() }
            strip.setFlowing(true)
        } else if !pulse.running, beat != nil, glowNow > 0.995 { beat?.invalidate(); beat = nil; strip.setGlow(1); strip.setBackdrop(1); backNow = 1; strip.setFlowing(false); strip.setRunners(brightness: restRunners, speed: Ink.theme == 8 ? 2.6 : 1) }
        if shown, Ink.theme != 8, -lastShine.timeIntervalSinceNow > 14 { lastShine = Date(); strip.shine() }
    }
    // With music the glow sits low and swells on the beat; in silence it rests at full brightness.
    func breathe() {
        guard !strip.revving else { return }      // the engine-start rev owns the brightness for its two and a half seconds
        let r = pulse.running ? pulse.read() : (level: Float(0), quiet: 99)
        let target: CGFloat = r.quiet < 0.7 ? 0.22 + 0.78 * CGFloat(r.level) : 1
        glowNow += (target - glowNow) * (target > glowNow ? 0.6 : 0.25)
        strip.setGlow(glowNow)
        // The backdrop goes nearly dark between beats and floods on the hit; it falls a little slower than the glow, so it breathes.
        let back: CGFloat = r.quiet < 0.7 ? 0.10 + 0.90 * CGFloat(r.level) : 1
        backNow += (back - backNow) * (back > backNow ? 0.65 : 0.16)
        strip.setBackdrop(backNow)
        // Runner lights flare and speed up with the music; a clear hit on the beat throws a few sparks.
        strip.setRunners(brightness: r.quiet < 0.7 ? 0.25 + 0.75 * CGFloat(r.level) : restRunners, speed: (Ink.theme == 8 ? 1.6 : 0.45) + 2.4 * r.level)
        slow += (r.level - slow) * 0.08
        if r.quiet < 0.7, r.level > 0.5, r.level - slow > 0.16, -lastSpark.timeIntervalSinceNow > 0.2 { lastSpark = Date(); strip.sparkle(3) }
    }
    var listenSince = Date()
    @objc func show() {
        let fresh = !shown
        refresh(); NSTouchBar.presentSystemModalTouchBar(bar, placement: 1, systemTrayItemIdentifier: Self.trayID); shown = true; refresh()
        // Only once per start, and only when Redline's push-to-start button was pressed: coming back from "app controls"
        // or from sleep never revs again. Redline passes --norev when it starts the engine by itself.
        if fresh, !revved { revved = true; if !CommandLine.arguments.contains("--norev") {
            strip.ignite()
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("local.glowstrip.ignite"), object: nil, userInfo: nil, deliverImmediately: true)
        } }
    }
    var revved = false
    func hide() { NSTouchBar.minimizeSystemModalTouchBar(bar); shown = false; tend(); DFRElementSetControlStripPresenceForIdentifier(Self.trayID, true) }
    @objc func woke() { if shown { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.show() } } }

    func tap(_ k: Kind) {
        switch k {
        case .esc:
            if Mac.canType { Mac.escape() }
            else {
                // Without permission to press keys, step aside so Apple's own Esc is there, and ask once.
                hide()
                Mac.askOnce()
            }
        case .sleep: Mac.sleep()
        case .lock: SACLockScreenImmediate()
        case .night: Mac.night.toggle()
        case .prev: Mac.media(18, 5)
        case .play: Mac.media(16, 2)
        case .next: Mac.media(17, 4)
        case .mute: Mac.muted.toggle()
        case .desk: CoreDockSendNotification("com.apple.showdesktop.awake" as CFString, nil)
        case .app: hide()
        default: break
        }
        refresh()
    }
    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier id: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard id == Self.mainID else { return nil }
        let item = NSCustomTouchBarItem(identifier: id); item.view = strip; return item
    }
    func applicationWillTerminate(_ n: Notification) {
        pulse.stop(); NSTouchBar.dismissSystemModalTouchBar(bar)
        if let t = tray { DFRElementSetControlStripPresenceForIdentifier(Self.trayID, false); NSTouchBarItem.removeSystemTrayItem(t) }
    }
}

// ---------- Command line helpers ----------
func renderPNG(_ s: BarState, _ path: String, glow: CGFloat = 1, backdrop: CGFloat = 1) {
    // Composes the sheets the same way the Touch Bar does: backdrop, glass tiles, then the glow sheet at the given brightness.
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2170, pixelsHigh: 60, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    out.size = NSSize(width: 1085, height: 30); let box = CGRect(x: 0, y: 0, width: 1085, height: 30)
    let base = barImage(s, .base), light = barImage(s, .glow)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    drawBackdrop(box, backdrop)
    base.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
    light.draw(in: box, from: .zero, operation: .sourceOver, fraction: glow, respectFlipped: false, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
    try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--render"), args.count > i + 1 {
    let i0 = i
    var a = BarState(); a.volume = 0.62; a.brightness = 0.8; a.keys = 0.5
    renderPNG(a, args[i + 1] + "/strip.png")
    var b = a; b.volume = 0.95; b.night = true; b.pressed = 9; b.zone = 1; renderPNG(b, args[i + 1] + "/strip_loud_night.png")
    var c = a; c.muted = true; renderPNG(c, args[i + 1] + "/strip_muted.png")
    for i in 0..<9 { Ink.theme = i; renderPNG(a, args[i0 + 1] + "/skin_\(i).png") }; Ink.theme = 0
    var d = a; d.vibe = true; renderPNG(d, args[i + 1] + "/strip_music_low.png", glow: 0.22, backdrop: 0.10); renderPNG(d, args[i + 1] + "/strip_music_beat.png", glow: 0.95, backdrop: 0.95)
    exit(0)
}
if args.contains("--pulsetest") {   // listens for 4 seconds and prints the loudness it hears
    let p = Pulse(); print("speakers in use:", Pulse.somethingPlaying)
    if let why = p.start() { print("could not start:", why); exit(1) }
    for _ in 0..<8 { Thread.sleep(forTimeInterval: 0.5); let r = p.read(); print(String(format: "level %.2f  quiet %.1fs", r.level, min(r.quiet, 999))) }
    p.stop(); exit(0)
}
if args.contains("--probe") {   // reads every control and writes the same value back, to prove both directions work without changing anything
    var s = BarState(); Mac.read(into: &s); print(s)
    Mac.volume = s.volume; Mac.muted = s.muted; Mac.brightness = s.brightness; Mac.keys = s.keys; Mac.night = s.night
    var t = BarState(); Mac.read(into: &t); print(t, "unchanged:", s == t, "can press keys:", Mac.canType); exit(0)
}
if let i = args.firstIndex(of: "--login"), args.count > i + 1 {
    do { if args[i + 1] == "on" { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; print("start at login:", args[i + 1]) }
    catch { print("could not change start at login:", error.localizedDescription) }
    exit(0)
}
// On a Mac without a Touch Bar there is nothing for Glowstrip to draw on, so it simply ends, without touching anything.
func macHasTouchBar() -> Bool {
    if ProcessInfo.processInfo.environment["GLOWSTRIP_NO_BAR"] != nil { return false }     // for testing that path on a Mac that has one
    guard let lib = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW), let sym = dlsym(lib, "DFRGetScreenSize") else { return false }
    typealias SizeCall = @convention(c) () -> CGSize
    return unsafeBitCast(sym, to: SizeCall.self)().width > 0
}
if !macHasTouchBar() { print("This Mac has no Touch Bar: Glowstrip has nothing to do and is closing."); exit(0) }
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
