// Draws Unwalked's app icon: a closed loop in "new street" orange over a faint street grid.
// Regenerate with:
//   swift Tools/MakeAppIcon.swift Unwalked/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let side: CGFloat = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!

guard let ctx = CGContext(
    data: nil, width: Int(side), height: Int(side),
    bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { fatalError("could not make a bitmap") }
// noneSkipLast: App Store icons are rejected if they carry an alpha channel.

func colour(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

// Palette.ink, Palette.ground, Palette.fresh and Palette.watchFresh.
let ink: UInt32 = 0x14262B
let ground: UInt32 = 0xF1F2EE
let fresh: UInt32 = 0xEF5F0F
let freshLight: UInt32 = 0xFF8A45

ctx.setFillColor(colour(ink))
ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))

// The streets behind the loop. The route below runs along these same lines.
ctx.setStrokeColor(colour(ground, 0.05))
ctx.setLineWidth(7)
let gridOrigin: CGFloat = 50
let gridStep: CGFloat = 132
var offset = gridOrigin
while offset < side {
    ctx.move(to: CGPoint(x: offset, y: 0))
    ctx.addLine(to: CGPoint(x: offset, y: side))
    ctx.move(to: CGPoint(x: 0, y: offset))
    ctx.addLine(to: CGPoint(x: side, y: offset))
    offset += gridStep
}
ctx.strokePath()

// A walked loop: a closed, irregular circuit, the shape a real walk traces rather
// than a tidy polygon. Points are placed round the centre at varying radii and
// joined with a smooth closed curve.
let centre = CGPoint(x: side / 2, y: side / 2)
let spokes: [(angle: CGFloat, radius: CGFloat)] = [
    (0, 252), (48, 206), (92, 262), (138, 218),
    (186, 246), (230, 198), (272, 258), (318, 212),
]
let loop: [CGPoint] = spokes.map { spoke in
    let radians = spoke.angle * .pi / 180
    return CGPoint(
        x: centre.x + cos(radians) * spoke.radius,
        y: centre.y + sin(radians) * spoke.radius
    )
}

/// A closed Catmull-Rom curve through the points, as cubic segments.
func smoothClosedPath(_ points: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    let count = points.count
    path.move(to: points[0])
    for i in 0..<count {
        let p0 = points[(i - 1 + count) % count]
        let p1 = points[i]
        let p2 = points[(i + 1) % count]
        let p3 = points[(i + 2) % count]
        path.addCurve(
            to: p2,
            control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
            control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
        )
    }
    path.closeSubpath()
    return path
}

let path = smoothClosedPath(loop)

ctx.saveGState()
ctx.addPath(path)
ctx.setLineWidth(62)
ctx.setLineJoin(.round)
ctx.setLineCap(.round)
ctx.replacePathWithStrokedPath()
ctx.clip()
let gradient = CGGradient(
    colorsSpace: space,
    colors: [colour(freshLight), colour(fresh)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 200, y: 850),
    end: CGPoint(x: 850, y: 180),
    options: []
)
ctx.restoreGState()

ctx.setFillColor(colour(ground))
let start = loop[0]
ctx.fillEllipse(in: CGRect(x: start.x - 28, y: start.y - 28, width: 56, height: 56))

guard CommandLine.arguments.count > 1 else { fatalError("pass an output path") }
let out = URL(fileURLWithPath: CommandLine.arguments[1])
guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("could not write \(out.path)") }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not finish \(out.path)") }
print("wrote \(out.path)")
