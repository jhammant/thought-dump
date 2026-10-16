// Draws the app icon: the note fanning out to its thoughts, in the route colours.
// Usage: swift scripts/make-icon.swift <out.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}
let gradient = CGGradient(colorsSpace: space, colors: [color(0x3A2FD4), color(0x8A2BE2)] as CFArray, locations: [0, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(size)), end: CGPoint(x: CGFloat(size), y: 0), options: [])

let note = CGPoint(x: 330, y: 512)
let thoughts: [(CGPoint, UInt32)] = [(CGPoint(x: 760, y: 760), 0x4DA3FF), (CGPoint(x: 800, y: 512), 0xD08CFF), (CGPoint(x: 760, y: 264), 0xFFA53D)]
context.setLineCap(.round)
for (point, hex) in thoughts {
    context.setStrokeColor(color(hex, 0.95))
    context.setLineWidth(30)
    context.move(to: note)
    context.addCurve(to: point, control1: CGPoint(x: note.x + 230, y: note.y), control2: CGPoint(x: point.x - 230, y: point.y))
    context.strokePath()
}
for (point, hex) in thoughts {
    context.setFillColor(color(0xFFFFFF))
    context.fillEllipse(in: CGRect(x: point.x - 74, y: point.y - 74, width: 148, height: 148))
    context.setFillColor(color(hex))
    context.fillEllipse(in: CGRect(x: point.x - 50, y: point.y - 50, width: 100, height: 100))
}
// The note: a speech bubble with a tail.
context.setFillColor(color(0xFFFFFF))
context.fillEllipse(in: CGRect(x: note.x - 170, y: note.y - 150, width: 340, height: 300))
context.move(to: CGPoint(x: note.x - 120, y: note.y - 90))
context.addLine(to: CGPoint(x: note.x - 190, y: note.y - 200))
context.addLine(to: CGPoint(x: note.x - 30, y: note.y - 135))
context.closePath()
context.fillPath()
context.setFillColor(color(0x5B3FE0))
for dx in [-80.0, 0.0, 80.0] {
    context.fillEllipse(in: CGRect(x: note.x + dx - 26, y: note.y - 26, width: 52, height: 52))
}
let image = context.makeImage()!
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
CGImageDestinationFinalize(destination)
print("wrote \(out.path)")
