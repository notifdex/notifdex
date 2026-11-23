#if os(macOS)
import AppKit
import CoreGraphics
import SwiftUI

enum MenuBarIconStyle: String, CaseIterable, Identifiable {
    case color
    case monochrome

    var id: Self { self }

    var title: String {
        switch self {
        case .color: "Color"
        case .monochrome: "Mono"
        }
    }
}

@MainActor
enum AppIconCatalog {
    private static var cachedAppIcon: NSImage?
    private static var cachedMenuBarImages: [MenuBarIconStyle: NSImage] = [:]

    static var appIconImage: NSImage? {
        if let cached = cachedAppIcon {
            return cached
        }
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            cachedAppIcon = image
            return image
        }
        return nil
    }

    static func applyDockIcon() {
        guard let image = appIconImage else { return }
        NSApp.applicationIconImage = image
    }

    static func menuBarImage(style: MenuBarIconStyle) -> NSImage {
        if let cached = cachedMenuBarImages[style] {
            return cached
        }

        // Render into a concrete 36x36 (@2x Retina) CGContext so MenuBarExtra always
        // receives a real raster CGImage rather than an NSCustomImageRep drawing handler.
        let pixelSize = 36
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: pixelSize * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return NSImage(systemSymbolName: "tray.full", accessibilityDescription: "Notifdex") ?? NSImage()
        }

        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.scaleBy(x: 2.0, y: 2.0)

        switch style {
        case .color:
            drawColorRolodex(in: ctx)
        case .monochrome:
            drawMonoRolodex(in: ctx)
        }

        guard let cgImage = ctx.makeImage() else {
            return NSImage(systemSymbolName: "tray.full", accessibilityDescription: "Notifdex") ?? NSImage()
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: 18, height: 18))
        image.isTemplate = (style == .monochrome)
        cachedMenuBarImages[style] = image
        return image
    }

    private static func fillRounded(_ ctx: CGContext, rect: CGRect, radius: CGFloat, color: CGColor) {
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(color)
        ctx.fillPath()
    }

    private static func strokeRounded(_ ctx: CGContext, rect: CGRect, radius: CGFloat, lineWidth: CGFloat, color: CGColor) {
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(path)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(lineWidth)
        ctx.strokePath()
    }

    private static func drawColorRolodex(in ctx: CGContext) {
        let layers: [(y: CGFloat, inset: CGFloat, h: CGFloat, color: CGColor)] = [
            (y: 13.6, inset: 1.8, h: 1.8, color: CGColor(srgbRed: 0.14, green: 0.36, blue: 0.90, alpha: 1.0)),
            (y: 11.4, inset: 1.4, h: 1.8, color: CGColor(srgbRed: 0.56, green: 0.78, blue: 0.98, alpha: 1.0)),
            (y: 9.2, inset: 1.0, h: 1.8, color: CGColor(srgbRed: 0.94, green: 0.48, blue: 0.36, alpha: 1.0)),
            (y: 6.9, inset: 1.0, h: 1.8, color: CGColor(srgbRed: 0.98, green: 0.86, blue: 0.62, alpha: 1.0)),
            (y: 4.7, inset: 1.4, h: 1.8, color: CGColor(srgbRed: 0.94, green: 0.48, blue: 0.36, alpha: 1.0)),
            (y: 2.5, inset: 1.8, h: 1.8, color: CGColor(srgbRed: 0.14, green: 0.36, blue: 0.90, alpha: 1.0))
        ]
        for layer in layers {
            let rect = CGRect(x: layer.inset, y: layer.y, width: 18.0 - layer.inset * 2.0, height: layer.h)
            fillRounded(ctx, rect: rect, radius: 0.65, color: layer.color)
            strokeRounded(ctx, rect: rect.insetBy(dx: 0.2, dy: 0.2), radius: 0.55, lineWidth: 0.35,
                          color: CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.35))
        }
    }

    private static func drawMonoRolodex(in ctx: CGContext) {
        // Template icons on macOS must draw in solid black; AppKit tints automatically.
        let ys: [(CGFloat, CGFloat, CGFloat)] = [
            (13.8, 2.2, 0.55),
            (11.4, 1.6, 0.80),
            (9.1, 1.2, 1.00),
            (6.8, 1.2, 1.00),
            (4.5, 1.6, 0.80),
            (2.2, 2.2, 0.55)
        ]
        for (y, inset, alpha) in ys {
            fillRounded(ctx, rect: CGRect(x: inset, y: y, width: 18.0 - inset * 2.0, height: 1.5),
                        radius: 0.55, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: alpha))
        }
    }
}
#endif
