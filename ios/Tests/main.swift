// Checks of the platform independent parts (URL parsing, raster encoding).
// Run: swiftc ios/PTouchBridge/Sources/{RasterCommands,PrintRequest}.swift ios/Tests/main.swift -o /tmp/t && /tmp/t

import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok {
        print("FAIL line \(line): \(what)")
        failures += 1
    }
}

// URL parsing
do {
    let r = try PrintRequest(url: URL(string: "ptouchbridge://print?text=Hello+world&text=Line%202&copies=2&cut=0&x-success=https%3A%2F%2Fexample.com%2Fok")!)
    if case .text(let lines) = r.content {
        check(lines == ["Hello world", "Line 2"], "text lines \(lines)")
    } else {
        check(false, "text content")
    }
    check(r.copies == 2, "copies")
    check(r.cut == false, "cut")
    check(r.callbacks.success?.absoluteString == "https://example.com/ok", "x-success")

    let x = try PrintRequest(url: URL(string: "ptouchbridge://x-callback-url/print?text=a%0Ab")!)
    if case .text(let lines) = x.content { check(lines == ["a", "b"], "newline split \(lines)") }

    let u = try PrintRequest(url: URL(string: "https://labels.example.com/ptouch/print?text=hi")!)
    if case .text(let lines) = u.content { check(lines == ["hi"], "universal link") }

    let png = Data([0x89, 0x50, 0x4e, 0x47, 0xfb, 0xff])
    let b64url = png.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    let i = try PrintRequest(url: URL(string: "ptouchbridge://print?image=\(b64url)")!)
    if case .image(let d) = i.content { check(d == png, "base64url image") } else { check(false, "image content") }
    check(PrintRequest.decodeBase64("data:image/png;base64," + png.base64EncodedString()) == png, "data: URI")

    check((try? PrintRequest(url: URL(string: "ptouchbridge://print")!)) == nil, "no content rejected")
    check((try? PrintRequest(url: URL(string: "ptouchbridge://print?text=a&copies=0")!)) == nil, "bad copies rejected")
    check((try? PrintRequest(url: URL(string: "ptouchbridge://scan?text=a")!)) == nil, "bad action rejected")

    let e = Callbacks(url: URL(string: "ptouchbridge://print?x-error=https%3A%2F%2Fexample.com%2Ferr%3Fid%3D7")!)
    check(e.errorURL(code: 1, message: "no tape")?.absoluteString == "https://example.com/err?id=7&errorCode=1&errorMessage=no%20tape", "x-error")
} catch {
    check(false, "unexpected \(error)")
}

// Raster encoding: 36 mm tape, 454 px, print area starts at pin 280 - 227 - 8 = 45
do {
    var pixels = [Bool](repeating: false, count: 2 * 454)
    pixels[453 * 2 + 0] = true      // bottom row, column 0 -> pin 45
    pixels[0 * 2 + 1] = true        // top row, column 1 -> pin 45 + 453 = 498
    let bitmap = LabelBitmap(length: 2, height: 454, pixels: pixels)
    let d = [UInt8](RasterCommands.rasterLines(bitmap))
    check(d.count == 2 * 74, "raster size \(d.count)")
    check(Array(d[0..<4]) == [0x47, 71, 0x00, 69], "raster header")
    let line0 = Array(d[4..<74]), line1 = Array(d[78..<148])
    check(line0[69 - 45 / 8] == 1 << (45 % 8) && line0.filter { $0 != 0 }.count == 1, "pin 45")
    check(line1[69 - 498 / 8] == 1 << (498 % 8) && line1.filter { $0 != 0 }.count == 1, "pin 498")

    let job = [UInt8](RasterCommands.label(bitmap, mediaWidthMM: 36, last: true, cut: true))
    check(Array(job[0..<13]) == [0x1b, 0x69, 0x7a, 0x04, 0x00, 36, 0x00, 2, 0, 0, 0, 0, 0], "print info")
    check(Array(job[13..<23]) == [0x1b, 0x69, 0x4d, 0x40, 0x1b, 0x69, 0x4b, 0x08, 0x4d, 0x02], "mode, advanced, packbits")
    check(job.last == 0x1a, "eject on last label")
    let mid = [UInt8](RasterCommands.label(bitmap, mediaWidthMM: 36, last: false, cut: true))
    check(mid[20] == 0x00 && mid.last == 0x0c, "chain and feed between labels")

    var status = [UInt8](repeating: 0, count: 32)
    status[0] = 0x80; status[1] = 0x20; status[10] = 24
    check(PrinterStatus(Data(status))?.mediaWidthMM == 24, "status width")
    status[18] = 0x02; status[9] = 0x10
    check(PrinterStatus(Data(status))?.errorDescription == "cover open", "status error")
    check(Tape.printablePixels(mm: 24) == 320, "tape table")
}

if failures > 0 {
    print("\(failures) check(s) failed")
    exit(1)
}
print("all checks passed")
