//
//  LabelRenderer.swift
//  PTouchBridge
//
//  Turns the text or image of a request into a 1-bit bitmap as high as the
//  printable area of the loaded tape. Like ptouch-print, pixels are
//  thresholded at a gray value of 128.
//

import UIKit

enum RenderError: LocalizedError {
    case badImage
    case imageTooTall(Int, Int)
    case tooLong

    var errorDescription: String? {
        switch self {
        case .badImage: return "Could not decode the image."
        case .imageTooTall(let h, let max):
            return "The image is \(h) px high, the tape prints at most \(max) px (use scale=down or scale=fit)."
        case .tooLong: return "The label is too long."
        }
    }
}

enum LabelRenderer {
    /// About 1.4 m of tape at 360 dpi.
    static let maxLength = 20000

    static func render(_ request: PrintRequest, tapePixels: Int) throws -> LabelBitmap {
        switch request.content {
        case .text(let lines):
            return try renderText(lines, request: request, height: tapePixels)
        case .image(let data):
            return try renderImage(data, request: request, height: tapePixels)
        }
    }

    private static func font(_ name: String, size: CGFloat) -> UIFont {
        UIFont(name: name, size: size) ?? UIFont.systemFont(ofSize: size)
    }

    private static func renderText(_ lines: [String], request: PrintRequest, height: Int) throws -> LabelBitmap {
        let band = CGFloat(height) / CGFloat(lines.count)
        let size: CGFloat
        if let s = request.fontSize {
            size = CGFloat(s)
        } else {
            // largest size whose line box fits into each line's band
            let unit = font(request.font, size: 100)
            let perPoint = (unit.ascender - unit.descender) / 100
            size = max(1, floor(band / perPoint))
        }
        let f = font(request.font, size: size)
        let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: UIColor.black]
        let widths = lines.map { ceil(($0 as NSString).size(withAttributes: attrs).width) }
        let textWidth = Int(widths.max() ?? 0)
        let length = max(1, textWidth + 2 * request.pad)
        guard length <= maxLength else { throw RenderError.tooLong }

        let lineHeight = f.ascender - f.descender
        return draw(length: length, height: height, flipped: true) { _ in
            for (i, line) in lines.enumerated() {
                let w = widths[i]
                let x: CGFloat
                switch request.align {
                case .left: x = CGFloat(request.pad)
                case .center: x = CGFloat(request.pad) + (CGFloat(textWidth) - w) / 2
                case .right: x = CGFloat(request.pad) + CGFloat(textWidth) - w
                }
                let y = CGFloat(i) * band + (band - lineHeight) / 2
                (line as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
            }
        }
    }

    private static func renderImage(_ data: Data, request: PrintRequest, height: Int) throws -> LabelBitmap {
        guard let image = UIImage(data: data)?.cgImage else { throw RenderError.badImage }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        var scale: CGFloat = 1
        switch request.scale {
        case .fit: scale = CGFloat(height) / h
        case .down: scale = min(1, CGFloat(height) / h)
        case .none:
            if image.height > height { throw RenderError.imageTooTall(image.height, height) }
        }
        let drawW = max(1, (w * scale).rounded()), drawH = (h * scale).rounded()
        let length = Int(drawW) + 2 * request.pad
        guard length <= maxLength else { throw RenderError.tooLong }
        return draw(length: length, height: height, flipped: false) { ctx in
            ctx.interpolationQuality = scale < 1 ? .high : .none
            let y = (CGFloat(height) - drawH) / 2
            ctx.draw(image, in: CGRect(x: CGFloat(request.pad), y: y.rounded(), width: drawW, height: drawH))
        }
    }

    /// Draw on white into an 8-bit gray context, then threshold. With
    /// `flipped`, the context uses UIKit's top-left origin.
    private static func draw(length: Int, height: Int, flipped: Bool,
                             _ body: (CGContext) -> Void) -> LabelBitmap {
        var gray = [UInt8](repeating: 255, count: length * height)
        gray.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: length, height: height,
                                      bitsPerComponent: 8, bytesPerRow: length,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: length, height: height))
            if flipped {
                ctx.translateBy(x: 0, y: CGFloat(height))
                ctx.scaleBy(x: 1, y: -1)
            }
            UIGraphicsPushContext(ctx)
            body(ctx)
            UIGraphicsPopContext()
        }
        // row 0 of the buffer is the top of the label
        return LabelBitmap(length: length, height: height, pixels: gray.map { $0 < 128 })
    }

    /// A picture of the bitmap for the preview.
    static func preview(_ bitmap: LabelBitmap) -> UIImage? {
        let bytes = bitmap.pixels.map { $0 ? UInt8(0) : UInt8(255) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(width: bitmap.length, height: bitmap.height,
                               bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: bitmap.length,
                               space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
