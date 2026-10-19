// Renders Resources/AppIcon.icns with CoreGraphics only (no third-party tools).
// Usage: swift scripts/make-icon.swift            (writes Resources/AppIcon.icns)
//        swift scripts/make-icon.swift preview.png (writes a single 1024 px PNG)
//
// Design: a light aluminium macOS squircle holding a top-down graphite MT760 — the
// right-handed ergonomic shell with its left thumb shelf, silver thumb panel and side
// wheel, chevron button seams and DPI button. The scroll wheel carries the system-blue
// accent the App uses for the current DPI gear. No text, legible from 16 px to 1024 px.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func linear(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [])
}

/// Straight edges with superellipse corners — continuous curvature like the macOS app
/// shape, instead of the visible tangent break of a circular rounded rect.
func squircle(_ r: CGRect, radius: CGFloat = 250, n: CGFloat = 4.4) -> CGPath {
    let p = CGMutablePath()
    let centres = [CGPoint(x: r.maxX - radius, y: r.maxY - radius), CGPoint(x: r.minX + radius, y: r.maxY - radius),
                   CGPoint(x: r.minX + radius, y: r.minY + radius), CGPoint(x: r.maxX - radius, y: r.minY + radius)]
    for (q, c) in centres.enumerated() {
        for i in 0...90 {
            let t = (CGFloat(q) + CGFloat(i) / 90) * .pi / 2
            let ct = cos(t), st = sin(t)
            let pt = CGPoint(x: c.x + radius * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n),
                             y: c.y + radius * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n))
            q == 0 && i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
    }
    p.closeSubpath()
    return p
}

func capsule(_ r: CGRect) -> CGPath {
    let radius = min(r.width, r.height) / 2
    return CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Closed Catmull-Rom spline through `pts` — a smooth organic outline from a few
/// hand-placed points, so the shape can follow the real mouse photo.
func smoothClosed(_ pts: [CGPoint]) -> CGPath {
    let p = CGMutablePath()
    let n = pts.count
    p.move(to: pts[0])
    for i in 0..<n {
        let p0 = pts[(i - 1 + n) % n], p1 = pts[i], p2 = pts[(i + 1) % n], p3 = pts[(i + 2) % n]
        p.addCurve(to: p2,
                   control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                   control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
    }
    p.closeSubpath()
    return p
}

/// Draws on a 1024-point canvas (y up), scaled to `size` pixels.
func render(size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)

    // 1. Squircle tile — Apple grid: 824 pt body inside a 1024 canvas, soft drop shadow.
    //    Light aluminium so the graphite mouse reads as a silhouette at 16 px.
    let tile = squircle(CGRect(x: 100, y: 100, width: 824, height: 824))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x000000, 0.30))
    ctx.addPath(tile); ctx.setFillColor(rgb(0xE6E9EE)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    linear(ctx, [rgb(0xFAFBFC), rgb(0xE3E6EB), rgb(0xC9CED6)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
    // Faint accent bloom behind the scroll wheel.
    let bloom = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                           colors: [rgb(0x0A84FF, 0.16), rgb(0x0A84FF, 0)] as CFArray, locations: nil)!
    ctx.drawRadialGradient(bloom, startCenter: CGPoint(x: 548, y: 700), startRadius: 0,
                           endCenter: CGPoint(x: 548, y: 700), endRadius: 400, options: [])
    ctx.restoreGState()

    // Hairline top highlight: light catching the tile's edge.
    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    ctx.addPath(tile); ctx.setLineWidth(4)
    ctx.replacePathWithStrokedPath(); ctx.clip()
    linear(ctx, [rgb(0xFFFFFF, 0.9), rgb(0xFFFFFF, 0)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 640))
    ctx.restoreGState()

    // 2. Mouse body — top-down MT760 outline traced from the device photo: right-handed
    //    ergonomic shell, narrow front, broad palm on the right, thumb shelf flaring left.
    let outline: [CGPoint] = [
        CGPoint(x: 450, y: 834), CGPoint(x: 548, y: 834), CGPoint(x: 646, y: 808),      // front edge
        CGPoint(x: 690, y: 770), CGPoint(x: 718, y: 650), CGPoint(x: 726, y: 500),      // right flank
        CGPoint(x: 710, y: 350), CGPoint(x: 662, y: 240), CGPoint(x: 566, y: 196),      // palm heel
        CGPoint(x: 440, y: 214), CGPoint(x: 342, y: 272), CGPoint(x: 302, y: 376),      // thumb shelf base
        CGPoint(x: 298, y: 520), CGPoint(x: 330, y: 570), CGPoint(x: 384, y: 598),      // shelf lip
        CGPoint(x: 392, y: 700), CGPoint(x: 400, y: 786), CGPoint(x: 418, y: 824),                               // left flank
    ]
    let bodyPath = smoothClosed(outline)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -24), blur: 44, color: rgb(0x000000, 0.45))
    ctx.addPath(bodyPath); ctx.setFillColor(rgb(0x24272D)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    linear(ctx, [rgb(0x3E434B), rgb(0x2A2E35), rgb(0x16181C)], from: CGPoint(x: 520, y: 830), to: CGPoint(x: 520, y: 196))
    // Dome highlight over the palm rest gives the shell volume.
    let dome = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [rgb(0xFFFFFF, 0.13), rgb(0xFFFFFF, 0)] as CFArray, locations: nil)!
    ctx.drawRadialGradient(dome, startCenter: CGPoint(x: 540, y: 520), startRadius: 0,
                           endCenter: CGPoint(x: 540, y: 520), endRadius: 230, options: [])

    // Silver thumb panel along the left flank, holding the side wheel.
    let panel = smoothClosed([
        CGPoint(x: 330, y: 572), CGPoint(x: 400, y: 590), CGPoint(x: 426, y: 520),
        CGPoint(x: 424, y: 400), CGPoint(x: 392, y: 330), CGPoint(x: 290, y: 360),
        CGPoint(x: 280, y: 480),
    ])
    ctx.addPath(panel)
    ctx.saveGState(); ctx.clip()
    linear(ctx, [rgb(0xA9AEB6), rgb(0x7D838C), rgb(0x5A5F67)], from: CGPoint(x: 300, y: 590), to: CGPoint(x: 420, y: 340))
    ctx.restoreGState()
    // Side (thumb) wheel with knurling.
    let side = CGRect(x: 330, y: 432, width: 54, height: 104)
    ctx.addPath(CGPath(roundedRect: side, cornerWidth: 16, cornerHeight: 16, transform: nil))
    ctx.saveGState(); ctx.clip()
    linear(ctx, [rgb(0x2C3036), rgb(0x4B5058), rgb(0x2C3036)], from: CGPoint(x: side.minX, y: 0), to: CGPoint(x: side.maxX, y: 0))
    ctx.setStrokeColor(rgb(0x15171A, 0.8)); ctx.setLineWidth(4)
    for x in stride(from: side.minX + 10, to: side.maxX, by: 11) {
        ctx.move(to: CGPoint(x: x, y: side.minY)); ctx.addLine(to: CGPoint(x: x, y: side.maxY))
    }
    ctx.strokePath()
    ctx.restoreGState()

    // Button seams: centre channel from the front, then the chevron that separates both
    // buttons from the palm. Dark groove plus a 1-step highlight below it.
    let seam = CGMutablePath()
    seam.move(to: CGPoint(x: 548, y: 840)); seam.addLine(to: CGPoint(x: 548, y: 660))
    seam.move(to: CGPoint(x: 370, y: 590)); seam.addLine(to: CGPoint(x: 548, y: 660))
    seam.addLine(to: CGPoint(x: 712, y: 588))
    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.addPath(seam); ctx.setStrokeColor(rgb(0x0B0C0E, 0.9)); ctx.setLineWidth(9); ctx.strokePath()
    ctx.saveGState(); ctx.translateBy(x: 0, y: -6)
    ctx.addPath(seam); ctx.setStrokeColor(rgb(0xFFFFFF, 0.10)); ctx.setLineWidth(3); ctx.strokePath()
    ctx.restoreGState()
    ctx.restoreGState()
    // Rim light along the shell edge.
    ctx.addPath(bodyPath); ctx.setLineWidth(6)
    ctx.replacePathWithStrokedPath(); ctx.clip()
    linear(ctx, [rgb(0xFFFFFF, 0.28), rgb(0xFFFFFF, 0.04)], from: CGPoint(x: 520, y: 830), to: CGPoint(x: 520, y: 196))
    ctx.restoreGState()

    // 3. Scroll wheel — the accent colour, same as the App's current DPI gear.
    let slot = CGRect(x: 548 - 30, y: 680, width: 60, height: 128)
    ctx.addPath(capsule(slot)); ctx.setFillColor(rgb(0x0B0C0E)); ctx.fillPath()
    let wheel = slot.insetBy(dx: 9, dy: 9)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 24, color: rgb(0x0A84FF, 0.85))
    ctx.addPath(capsule(wheel)); ctx.setFillColor(rgb(0x0A84FF)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(capsule(wheel)); ctx.clip()
    linear(ctx, [rgb(0x64B5FF), rgb(0x0A84FF), rgb(0x0060DF)], from: CGPoint(x: 548, y: wheel.maxY), to: CGPoint(x: 548, y: wheel.minY))
    ctx.setStrokeColor(rgb(0x003E99, 0.45)); ctx.setLineWidth(3)
    for y in stride(from: wheel.minY + 12, to: wheel.maxY - 6, by: 12) {
        ctx.move(to: CGPoint(x: wheel.minX, y: y)); ctx.addLine(to: CGPoint(x: wheel.maxX, y: y))
    }
    ctx.strokePath()
    ctx.restoreGState()

    // 4. DPI button below the chevron apex — a small metallic pill.
    let dpi = CGRect(x: 548 - 11, y: 576, width: 22, height: 50)
    ctx.addPath(capsule(dpi.insetBy(dx: -4, dy: -4))); ctx.setFillColor(rgb(0x0B0C0E)); ctx.fillPath()
    ctx.addPath(capsule(dpi))
    ctx.saveGState(); ctx.clip()
    linear(ctx, [rgb(0xE8EAED), rgb(0x9BA0A8)], from: CGPoint(x: 548, y: dpi.maxY), to: CGPoint(x: 548, y: dpi.minY))
    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    precondition(CGImageDestinationFinalize(dest), "failed to write \(url.path)")
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let args = CommandLine.arguments.dropFirst()
if let preview = args.first {
    writePNG(render(size: 1024), to: URL(fileURLWithPath: preview))
    print("Preview: \(preview)")
    exit(0)
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    writePNG(render(size: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(render(size: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let output = root.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run(); task.waitUntilExit()
precondition(task.terminationStatus == 0, "iconutil failed")
print("Built: \(output.path)")
