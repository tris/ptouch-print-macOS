//
//  RasterCommands.swift
//  PTouchBridge
//
//  Brother raster protocol for the PT-P900 series (PT-P900W, PT-P950NW,
//  PT-P910BT), ported from libptouch.c / ptouch-print.c on the pt-p910bt
//  branch, which was verified against a real PT-P910BT. The command order
//  follows Brother's "Raster Command Reference PT-P900/P900W/P950NW".
//

import Foundation

/// A 1-bit label image. `length` runs along the tape (one raster line per
/// column), `height` runs across the tape. Row 0 is the top of the label as
/// it reads.
struct LabelBitmap {
    let length: Int
    let height: Int
    /// Row-major, `true` = black.
    var pixels: [Bool]

    init(length: Int, height: Int, pixels: [Bool]) {
        precondition(pixels.count == length * height)
        self.length = length
        self.height = height
        self.pixels = pixels
    }

    subscript(x: Int, y: Int) -> Bool {
        pixels[y * length + x]
    }
}

enum Tape {
    /// Printable pixels across the tape at 360 dpi, by tape width in mm.
    /// Brother's documented values for the PT-P900 series.
    static func printablePixels(mm: Int) -> Int? {
        switch mm {
        case 4: return 48     // 3.5 mm
        case 6: return 64
        case 9: return 106
        case 12: return 150
        case 18: return 234
        case 24: return 320
        case 36: return 454
        default: return nil
        }
    }
}

/// The 32 byte status reply to ESC i S.
struct PrinterStatus {
    let raw: [UInt8]

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count == 32, bytes[0] == 0x80, bytes[1] == 0x20 else {
            return nil
        }
        raw = bytes
    }

    var mediaWidthMM: Int { Int(raw[10]) }
    var errorInfo1: UInt8 { raw[8] }
    var errorInfo2: UInt8 { raw[9] }
    var statusType: UInt8 { raw[18] }

    var isError: Bool { statusType == 0x02 }
    /// Unsolicited notifications (0x05) and phase changes (0x06), as opposed
    /// to a reply to a status request.
    var isNotification: Bool { statusType == 0x05 || statusType == 0x06 }

    var errorDescription: String {
        var parts: [String] = []
        if errorInfo1 & 0x01 != 0 { parts.append("no tape") }
        if errorInfo1 & 0x04 != 0 { parts.append("cutter jam") }
        if errorInfo1 & 0x08 != 0 { parts.append("weak battery") }
        if errorInfo2 & 0x01 != 0 { parts.append("wrong tape") }
        if errorInfo2 & 0x10 != 0 { parts.append("cover open") }
        if errorInfo2 & 0x20 != 0 { parts.append("overheating") }
        if parts.isEmpty {
            parts.append(String(format: "printer error 0x%02x%02x", errorInfo2, errorInfo1))
        }
        return parts.joined(separator: ", ")
    }
}

enum RasterCommands {
    /// Printhead pins of the PT-P900 series (70 bytes per raster line).
    static let headPins = 560
    /// The print area is centered at pin 272, not at the head center.
    static let pinOffset = -8
    static var lineBytes: Int { headPins / 8 }

    /// 200 bytes of 0x00 (invalidate, clears any half-received job), then ESC @.
    static let reset = Data(count: 200) + Data([0x1b, 0x40])
    /// ESC i S
    static let statusRequest = Data([0x1b, 0x69, 0x53])
    /// ESC i a 01: switch to raster mode. The printer answers with a status reply.
    static let rasterMode = Data([0x1b, 0x69, 0x61, 0x01])

    /// Everything that follows raster mode for one label: print information,
    /// mode settings, compression, raster lines and the print command.
    /// `last` is the final label of the job, `cut` whether to cut after it.
    /// Labels before the last are always cut apart.
    static func label(_ bitmap: LabelBitmap, mediaWidthMM: Int, last: Bool, cut: Bool) -> Data {
        var d = Data()
        // ESC i z: print information, media width valid
        let lines = UInt32(bitmap.length)
        let info: [UInt8] = [0x1b, 0x69, 0x7a, 0x04, 0x00, UInt8(clamping: mediaWidthMM), 0x00,
                             UInt8(lines & 0xff), UInt8((lines >> 8) & 0xff),
                             UInt8((lines >> 16) & 0xff), UInt8((lines >> 24) & 0xff), 0x00, 0x00]
        d += info
        // ESC i M: auto cut on (cuts before the label and between labels)
        d += [0x1b, 0x69, 0x4d, 0x40] as [UInt8]
        // ESC i K: chain printing off on the last label, so it is fed and cut
        let noChain = last && cut
        d += [0x1b, 0x69, 0x4b, noChain ? 0x08 : 0x00] as [UInt8]
        // M 02: PackBits compression, selected after raster mode
        d += [0x4d, 0x02] as [UInt8]
        d += rasterLines(bitmap)
        // 1A = print and feed/cut, 0C = print without feeding
        d.append(last && cut ? 0x1a : 0x0c)
        return d
    }

    /// One `G` raster line per bitmap column, sent as a single PackBits
    /// literal run. The bottom row of the bitmap goes to the lowest pin.
    static func rasterLines(_ bitmap: LabelBitmap) -> Data {
        let n = lineBytes
        let offset = headPins / 2 - bitmap.height / 2 + pinOffset
        var d = Data(capacity: bitmap.length * (n + 4))
        var line = [UInt8](repeating: 0, count: n)
        for x in 0..<bitmap.length {
            for i in 0..<n { line[i] = 0 }
            for i in 0..<bitmap.height where bitmap[x, bitmap.height - 1 - i] {
                let pin = offset + i
                if pin >= 0 && pin < headPins {
                    line[(n - 1) - pin / 8] |= UInt8(1 << (pin % 8))
                }
            }
            d += [0x47, UInt8(n + 1), 0x00, UInt8(n - 1)] as [UInt8]
            d += line
        }
        return d
    }
}
