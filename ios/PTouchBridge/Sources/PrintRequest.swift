//
//  PrintRequest.swift
//  PTouchBridge
//
//  A print job decoded from a URL, see ios/README.md for the format.
//

import Foundation

struct PrintRequest {
    enum Content {
        case text([String])
        case image(Data)
    }

    enum Alignment: String {
        case left, center, right
    }

    enum ImageScale: String {
        /// Scale the image down to the tape if it is taller, never up.
        case down
        /// Scale the image up or down to the full printable height.
        case fit
        /// Print pixels 1:1; fail if the image is taller than the tape.
        case none
    }

    var content: Content
    var font = "Helvetica"
    var fontSize: Double?
    var align = Alignment.left
    var scale = ImageScale.down
    var copies = 1
    var cut = true
    var pad = 0
    var printer: String?
    var callbacks = Callbacks()
}

/// x-callback-url style return addresses.
struct Callbacks {
    var success: URL?
    var error: URL?

    init() {}

    /// Callbacks from any URL, even one that is not a valid print request,
    /// so parse errors can be reported back too.
    init(url: URL) {
        let items = PrintRequest.queryItems(url)
        success = items.last { $0.name == "x-success" }?.value.flatMap(URL.init(string:))
        error = items.last { $0.name == "x-error" }?.value.flatMap(URL.init(string:))
    }

    func errorURL(code: Int, message: String) -> URL? {
        guard let error, var c = URLComponents(url: error, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var items = c.queryItems ?? []
        items.append(URLQueryItem(name: "errorCode", value: String(code)))
        items.append(URLQueryItem(name: "errorMessage", value: message))
        c.queryItems = items
        return c.url
    }
}

enum RequestError: LocalizedError {
    case unknownAction(String)
    case noContent
    case badImage
    case badValue(String, String)

    var errorDescription: String? {
        switch self {
        case .unknownAction(let a): return "Unknown action \"\(a)\", expected \"print\"."
        case .noContent: return "Nothing to print: pass text= or image=."
        case .badImage: return "image= is not a base64 encoded PNG or JPEG."
        case .badValue(let name, let value): return "Bad value \"\(value)\" for \(name)=."
        }
    }
}

extension PrintRequest {
    /// Accepts
    ///   ptouchbridge://print?...
    ///   ptouchbridge://x-callback-url/print?...
    ///   https://<your domain>/<anything>/print?...   (universal link)
    init(url: URL) throws {
        let action: String
        if url.scheme == "http" || url.scheme == "https" {
            action = url.lastPathComponent
        } else if url.host == "x-callback-url" {
            action = url.pathComponents.dropFirst().first ?? ""
        } else {
            action = url.host ?? ""
        }
        guard action.lowercased() == "print" else {
            throw RequestError.unknownAction(action)
        }

        let items = PrintRequest.queryItems(url)
        func value(_ name: String) -> String? {
            items.last { $0.name == name }?.value
        }
        func int(_ name: String, _ range: ClosedRange<Int>) throws -> Int? {
            guard let v = value(name) else { return nil }
            guard let n = Int(v), range.contains(n) else { throw RequestError.badValue(name, v) }
            return n
        }
        func bool(_ name: String) throws -> Bool? {
            guard let v = value(name)?.lowercased() else { return nil }
            switch v {
            case "1", "true", "yes", "on": return true
            case "0", "false", "no", "off": return false
            default: throw RequestError.badValue(name, v)
            }
        }

        if let image = value("image") {
            guard let data = PrintRequest.decodeBase64(image) else { throw RequestError.badImage }
            content = .image(data)
        } else {
            let lines = items.filter { $0.name == "text" }
                .compactMap { $0.value }
                .flatMap { $0.components(separatedBy: "\n") }
            guard !lines.isEmpty, lines.contains(where: { !$0.isEmpty }) else {
                throw RequestError.noContent
            }
            content = .text(lines)
        }

        if let f = value("font"), !f.isEmpty { font = f }
        if let s = value("fontsize") {
            guard let d = Double(s), d > 0, d < 1000 else { throw RequestError.badValue("fontsize", s) }
            fontSize = d
        }
        if let a = value("align") {
            guard let v = Alignment(rawValue: a.lowercased()) else { throw RequestError.badValue("align", a) }
            align = v
        }
        if let s = value("scale") {
            guard let v = ImageScale(rawValue: s.lowercased()) else { throw RequestError.badValue("scale", s) }
            scale = v
        }
        copies = try int("copies", 1...99) ?? 1
        cut = try bool("cut") ?? true
        pad = try int("pad", 0...2000) ?? 0
        printer = value("printer").flatMap { $0.isEmpty ? nil : $0 }
        callbacks = Callbacks(url: url)
    }

    /// Query items, with "+" read as a space the way HTML forms and
    /// URLSearchParams encode it.
    static func queryItems(_ url: URL) -> [URLQueryItem] {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [] }
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20")
        return c.queryItems ?? []
    }

    /// Standard or URL-safe base64, with or without padding or a data: prefix.
    static func decodeBase64(_ string: String) -> Data? {
        var s = string
        if s.hasPrefix("data:"), let comma = s.firstIndex(of: ",") {
            s = String(s[s.index(after: comma)...])
        }
        s = s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: " ", with: "+")   // an unescaped "+" read as a space
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}
