import AppKit
import CoreText

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make_icon <output.png>\n".utf8))
    exit(1)
}
let outPath = CommandLine.arguments[1]

let size: CGFloat = 1024
let bg = NSColor(red: 0x1a/255.0, green: 0x1a/255.0, blue: 0x1a/255.0, alpha: 1)
let fg = NSColor(red: 0xe0/255.0, green: 0xa0/255.0, blue: 0x60/255.0, alpha: 1)

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size),
    pixelsHigh: Int(size),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx

bg.setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()

let font = NSFont.monospacedSystemFont(ofSize: size * 0.78, weight: .bold)
let ctFont = font as CTFont

var unichars: [UniChar] = Array("k".utf16)
var glyphs = [CGGlyph](repeating: 0, count: unichars.count)
CTFontGetGlyphsForCharacters(ctFont, &unichars, &glyphs, unichars.count)

var bbox = CGRect.zero
CTFontGetBoundingRectsForGlyphs(ctFont, .horizontal, glyphs, &bbox, glyphs.count)

let cg = ctx.cgContext
cg.setFillColor(fg.cgColor)
cg.translateBy(x: size/2 - bbox.midX, y: size/2 - bbox.midY)

let positions = [CGPoint(x: 0, y: 0)]
CTFontDrawGlyphs(ctFont, glyphs, positions, glyphs.count, cg)

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("failed to encode png\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outPath))
