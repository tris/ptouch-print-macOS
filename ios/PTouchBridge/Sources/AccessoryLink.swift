//
//  AccessoryLink.swift
//  PTouchBridge
//
//  Byte stream to the printer over Bluetooth Classic. iOS gives apps no
//  access to the printer's SPP service the macOS tool uses; the PT-P910BT is
//  an MFi accessory, so apps reach it through the ExternalAccessory framework
//  with Brother's protocol string, which carries the same raster commands.
//
//  The calls below block, like the ptbt_* functions in btMac.m; run them off
//  the main thread. The streams live on a thread of their own.
//

import ExternalAccessory
import Foundation

enum LinkError: LocalizedError {
    case sessionFailed
    case closed
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .sessionFailed: return "Could not open a session to the printer."
        case .closed: return "The printer closed the connection."
        case .timeout(let what): return "Timed out \(what)."
        }
    }
}

// Thread-safe: all shared state is guarded by `cond`, streams are only touched
// on the link thread.
final class AccessoryLink: NSObject, StreamDelegate, @unchecked Sendable {
    static let protocolString = "com.brother.ptcbp"

    private let session: EASession
    private let input: InputStream
    private let output: OutputStream
    private var thread: Thread?

    private let cond = NSCondition()
    private var rx = Data()
    private var tx = Data()
    private var txSent = 0
    private var closed = false
    private var stopping = false
    private var finished = false

    /// Create on the main thread.
    init(accessory: EAAccessory) throws {
        guard let s = EASession(accessory: accessory, forProtocol: Self.protocolString),
              let i = s.inputStream, let o = s.outputStream else {
            throw LinkError.sessionFailed
        }
        session = s
        input = i
        output = o
        super.init()
        let t = Thread { [weak self] in self?.run() }
        t.name = "PTouchBridge.AccessoryLink"
        thread = t
        t.start()
    }

    deinit {
        close()
    }

    private func run() {
        input.delegate = self
        output.delegate = self
        input.schedule(in: .current, forMode: .default)
        output.schedule(in: .current, forMode: .default)
        input.open()
        output.open()
        while true {
            cond.lock()
            let stop = stopping
            cond.unlock()
            if stop { break }
            pump()
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        input.close()
        output.close()
        input.remove(from: .current, forMode: .default)
        output.remove(from: .current, forMode: .default)
        input.delegate = nil
        output.delegate = nil
        cond.lock()
        closed = true
        finished = true
        cond.broadcast()
        cond.unlock()
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            var buf = [UInt8](repeating: 0, count: 1024)
            while input.hasBytesAvailable {
                let n = input.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                cond.lock()
                rx.append(buf, count: n)
                cond.broadcast()
                cond.unlock()
            }
        case .hasSpaceAvailable:
            pump()
        case .errorOccurred, .endEncountered:
            markClosed()
        default:
            break
        }
    }

    /// Write pending data while the stream takes it. Link thread only.
    private func pump() {
        cond.lock()
        defer { cond.unlock() }
        while txSent < tx.count && output.hasSpaceAvailable {
            let n = tx.withUnsafeBytes { raw -> Int in
                let p = raw.bindMemory(to: UInt8.self).baseAddress! + txSent
                return output.write(p, maxLength: min(tx.count - txSent, 4096))
            }
            if n <= 0 { break }
            txSent += n
        }
        if txSent == tx.count && txSent > 0 {
            tx.removeAll(keepingCapacity: true)
            txSent = 0
            cond.broadcast()
        }
    }

    private func markClosed() {
        cond.lock()
        closed = true
        cond.broadcast()
        cond.unlock()
    }

    /// Queue data for sending.
    func write(_ data: Data) throws {
        cond.lock()
        defer { cond.unlock() }
        if closed { throw LinkError.closed }
        tx.append(data)
    }

    /// Wait until everything queued was handed to the accessory.
    func flush(timeout: TimeInterval = 60) throws {
        let end = Date(timeIntervalSinceNow: timeout)
        cond.lock()
        defer { cond.unlock() }
        while txSent < tx.count {
            if closed { throw LinkError.closed }
            if !cond.wait(until: end) { throw LinkError.timeout("sending to the printer") }
        }
    }

    /// Send what is queued, then wait up to `timeout` for `count` bytes.
    /// Returns what arrived, which may be fewer bytes on a timeout.
    func read(count: Int, timeout: TimeInterval) throws -> Data {
        try flush()
        let end = Date(timeIntervalSinceNow: timeout)
        cond.lock()
        defer { cond.unlock() }
        while rx.count < count && !closed {
            if !cond.wait(until: end) { break }
        }
        if rx.count < count && closed { throw LinkError.closed }
        let n = min(count, rx.count)
        let out = rx.prefix(n)
        rx.removeFirst(n)
        return Data(out)
    }

    /// Drop anything received so far, e.g. stale status replies.
    func discardInput() {
        Thread.sleep(forTimeInterval: 0.05)
        cond.lock()
        rx.removeAll()
        cond.unlock()
    }

    /// Stop the link thread and wait until it closed the streams.
    func close() {
        let end = Date(timeIntervalSinceNow: 2)
        cond.lock()
        stopping = true
        while !finished && thread != nil && cond.wait(until: end) {}
        cond.unlock()
    }
}
