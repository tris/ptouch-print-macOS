//
//  PrintController.swift
//  PTouchBridge
//
//  Finds the printer, runs print jobs one at a time and reports back to the
//  caller through its x-success / x-error URLs.
//

import ExternalAccessory
import SwiftUI
import UIKit

@MainActor
final class PrintController: ObservableObject {
    enum State: Equatable {
        case idle
        case working(String)
        case done(String)
        case failed(String)
    }

    @Published private(set) var state = State.idle
    @Published private(set) var preview: UIImage?
    @Published private(set) var printers: [EAAccessory] = []

    private var queue: [PrintRequest] = []
    private var running = false

    init() {
        let manager = EAAccessoryManager.shared()
        manager.registerForLocalNotifications()
        for name in [Notification.Name.EAAccessoryDidConnect, .EAAccessoryDidDisconnect] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshPrinters() }
            }
        }
        refreshPrinters()
    }

    func refreshPrinters() {
        printers = EAAccessoryManager.shared().connectedAccessories.filter {
            $0.protocolStrings.contains(AccessoryLink.protocolString)
        }
    }

    /// Shows iOS's picker for pairing a Bluetooth accessory that is not paired yet.
    func pairPrinter() {
        EAAccessoryManager.shared().showBluetoothAccessoryPicker(withNameFilter: nil) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error = error as? EABluetoothAccessoryPickerError,
                   error.code != .alreadyConnected && error.code != .resultCancelled {
                    self.state = .failed(error.localizedDescription)
                }
                self.refreshPrinters()
            }
        }
    }

    func handle(url: URL) {
        do {
            submit(try PrintRequest(url: url))
        } catch {
            fail(error, callbacks: Callbacks(url: url))
        }
    }

    func submit(_ request: PrintRequest) {
        queue.append(request)
        if !running {
            Task { await runQueue() }
        }
    }

    private func runQueue() async {
        running = true
        while !queue.isEmpty {
            await run(queue.removeFirst())
        }
        running = false
    }

    private func run(_ request: PrintRequest) async {
        let app = UIApplication.shared
        let background = app.beginBackgroundTask(withName: "Print label")
        defer { app.endBackgroundTask(background) }

        state = .working("Looking for the printer…")
        preview = nil
        guard let accessory = await findPrinter(matching: request.printer, timeout: 10) else {
            let which = request.printer.map { "\"\($0)\"" } ?? "P-Touch printer"
            fail(PrinterError.printer("no \(which) is connected. Switch it on, or pair it in this app"),
                 callbacks: request.callbacks)
            return
        }
        state = .working("Printing on \(accessory.name)…")

        let link: AccessoryLink
        do {
            link = try AccessoryLink(accessory: accessory)
        } catch {
            fail(error, callbacks: request.callbacks)
            return
        }
        do {
            try await Self.printJob(request, link: link) { image in
                Task { @MainActor in self.preview = image }
            }
        } catch {
            fail(error, callbacks: request.callbacks)
            return
        }
        let copies = request.copies == 1 ? "Printed" : "Printed \(request.copies) copies"
        state = .done("\(copies) on \(accessory.name).")
        if let success = request.callbacks.success {
            try? await Task.sleep(nanoseconds: 500_000_000)
            _ = await app.open(success)
        }
    }

    /// The blocking part of a job, on a background queue.
    private nonisolated static func printJob(_ request: PrintRequest, link: AccessoryLink,
                                             preview: @escaping (UIImage?) -> Void) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                defer { link.close() }
                do {
                    let printer = PTouchPrinter(link: link)
                    let status = try printer.start()
                    guard let tape = Tape.printablePixels(mm: status.mediaWidthMM) else {
                        throw PrinterError.unknownTape(status.mediaWidthMM)
                    }
                    let bitmap = try LabelRenderer.render(request, tapePixels: tape)
                    preview(LabelRenderer.preview(bitmap))
                    try printer.print(Array(repeating: bitmap, count: request.copies),
                                      mediaWidthMM: status.mediaWidthMM, cut: request.cut)
                    done.resume()
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
    }

    /// A connected printer whose name, model or serial number contains
    /// `wanted`, or any printer. Waits a while for one to connect, as the
    /// printer may just have been switched on.
    private func findPrinter(matching wanted: String?, timeout: TimeInterval) async -> EAAccessory? {
        let end = Date(timeIntervalSinceNow: timeout)
        while true {
            refreshPrinters()
            let match = printers.first { a in
                guard let wanted else { return true }
                return [a.name, a.modelNumber, a.serialNumber].contains {
                    $0.range(of: wanted, options: .caseInsensitive) != nil
                }
            }
            if let match { return match }
            if end.timeIntervalSinceNow <= 0 { return nil }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func fail(_ error: Error, callbacks: Callbacks) {
        let message = error.localizedDescription
        state = .failed(message)
        if let url = callbacks.errorURL(code: 1, message: message) {
            UIApplication.shared.open(url)
        }
    }
}
