import AppKit

@main
private enum RenderBrand {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "MooringBrand", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pass an output iconset directory."])
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for pointSize in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = pointSize * scale
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                bitmap.size = NSSize(width: pixels, height: pixels)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                MooringBrand.image(size: CGFloat(pixels)).draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
                NSGraphicsContext.restoreGraphicsState()
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw NSError(domain: "MooringBrand", code: 2)
                }
                let suffix = scale == 2 ? "@2x" : ""
                try png.write(to: directory.appendingPathComponent("icon_\(pointSize)x\(pointSize)\(suffix).png"))
            }
        }
    }
}
