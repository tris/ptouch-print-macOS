//
//  PTouchPrinter.swift
//  PTouchBridge
//
//  The print job sequence of ptouch-print over Bluetooth: reset, status,
//  then per label raster mode and raster data, then wait until the printer
//  has taken the whole job before disconnecting. Blocking; run it off the
//  main thread.
//

import Foundation

enum PrinterError: LocalizedError {
    case noStatus
    case printer(String)
    case unknownTape(Int)

    var errorDescription: String? {
        switch self {
        case .noStatus: return "The printer did not answer. Is it switched on?"
        case .printer(let what): return "Printer error: \(what)."
        case .unknownTape(let mm):
            return mm == 0 ? "No tape in the printer." : "Unsupported tape width \(mm) mm."
        }
    }
}

final class PTouchPrinter {
    private let link: AccessoryLink

    init(link: AccessoryLink) {
        self.link = link
    }

    /// Invalidate and initialize, then read the status.
    func start() throws -> PrinterStatus {
        try link.write(RasterCommands.reset)
        return try status()
    }

    func status() throws -> PrinterStatus {
        try link.flush()
        link.discardInput()
        try link.write(RasterCommands.statusRequest)
        let reply = try link.read(count: 32, timeout: 10)
        guard let status = PrinterStatus(reply) else { throw PrinterError.noStatus }
        if status.isError { throw PrinterError.printer(status.errorDescription) }
        return status
    }

    /// Print `labels`, cutting between them, and after the last one if `cut`.
    func print(_ labels: [LabelBitmap], mediaWidthMM: Int, cut: Bool) throws {
        for (i, label) in labels.enumerated() {
            try link.write(RasterCommands.rasterMode)
            // the PT-P900 series answers raster mode with a status reply
            _ = try link.read(count: 32, timeout: 1)
            try link.write(RasterCommands.label(label, mediaWidthMM: mediaWidthMM,
                                                last: i == labels.count - 1, cut: cut))
        }
        try waitUntilDone(timeout: 60)
    }

    /// The PT-P910BT sends no "printing completed" status by itself, so ask
    /// for a status: it answers once it processed everything sent before.
    private func waitUntilDone(timeout: TimeInterval) throws {
        try link.flush()
        link.discardInput()
        try link.write(RasterCommands.statusRequest)
        let end = Date(timeIntervalSinceNow: timeout)
        while end.timeIntervalSinceNow > 0 {
            let reply = try link.read(count: 32, timeout: end.timeIntervalSinceNow)
            guard let status = PrinterStatus(reply) else { continue }
            if status.isError { throw PrinterError.printer(status.errorDescription) }
            if status.isNotification { continue }
            return
        }
        throw LinkError.timeout("waiting for the printer to finish")
    }
}
