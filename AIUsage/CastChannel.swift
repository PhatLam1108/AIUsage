// CastChannel.swift: a minimal Google Cast (CASTV2) sender, enough to launch the AIUsage
// receiver on a Nest Hub and push JSON to it. Google ships no sender SDK for macOS, so this
// speaks the wire protocol directly:
//   TLS to <device>:8009 (the device certificate is self-signed, so it is not verified),
//   each frame = 4-byte big-endian length + protobuf `CastMessage` with a UTF-8 JSON payload.
// Namespaces used: tp.connection (CONNECT/CLOSE), tp.heartbeat (PING/PONG),
// receiver (GET_STATUS/LAUNCH/STOP) and the receiver page's own namespace.

import Foundation
import Network

enum CastNamespace {
    static let connection = "urn:x-cast:com.google.cast.tp.connection"
    static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
    static let receiver = "urn:x-cast:com.google.cast.receiver"
    static let aiusage = "urn:x-cast:net.phatdev.aiusage"
}

/// One `CastMessage` (cast_channel.proto). Only string payloads are used.
struct CastMessage {
    var source: String
    var destination: String
    var namespace: String
    var payload: String

    var json: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any]
    }

    // MARK: Protobuf encoding (proto2, all fields written)

    func encoded() -> Data {
        var body = Data()
        func varint(_ v: UInt64) {
            var v = v
            repeat {
                var byte = UInt8(v & 0x7F)
                v >>= 7
                if v != 0 { byte |= 0x80 }
                body.append(byte)
            } while v != 0
        }
        func string(_ field: UInt64, _ s: String) {
            let bytes = Data(s.utf8)
            varint(field << 3 | 2)
            varint(UInt64(bytes.count))
            body.append(bytes)
        }
        varint(1 << 3 | 0); varint(0)         // protocol_version = CASTV2_1_0
        string(2, source)
        string(3, destination)
        string(4, namespace)
        varint(5 << 3 | 0); varint(0)         // payload_type = STRING
        string(6, payload)

        var frame = Data()
        var len = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &len) { frame.append(contentsOf: $0) }
        frame.append(body)
        return frame
    }

    /// Decodes a frame body (without the length prefix). Unknown fields are skipped.
    static func decode(_ data: Data) -> CastMessage? {
        let b = [UInt8](data)
        var i = 0
        // Bounds are checked before any conversion: the peer is not authenticated, and a
        // length near UInt64.max must fail the decode, not trap the app.
        func varint() -> UInt64? {
            var result: UInt64 = 0, shift: UInt64 = 0
            while i < b.count, shift < 64 {
                let byte = b[i]; i += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }
        func skip(_ n: Int) -> Bool {
            guard b.count - i >= n else { return false }
            i += n
            return true
        }
        var m = CastMessage(source: "", destination: "", namespace: "", payload: "")
        while i < b.count {
            guard let key = varint() else { return nil }
            let field = key >> 3, wire = key & 7
            switch wire {
            case 0:
                guard varint() != nil else { return nil }
            case 2:
                guard let n = varint(), n <= UInt64(b.count - i) else { return nil }
                let len = Int(n)
                let bytes = Data(b[i ..< i + len]); i += len
                let s = String(decoding: bytes, as: UTF8.self)
                switch field {
                case 2: m.source = s
                case 3: m.destination = s
                case 4: m.namespace = s
                case 6: m.payload = s
                default: break
                }
            case 1: guard skip(8) else { return nil }
            case 5: guard skip(4) else { return nil }
            default: return nil
            }
        }
        return m
    }
}

/// One TLS connection to a Cast device. Callbacks arrive on the main queue.
final class CastChannel {
    enum Event { case ready, message(CastMessage), closed(String?) }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "AIUsage.CastChannel")
    private let onEvent: (Event) -> Void
    private var finished = false

    init(endpoint: NWEndpoint, onEvent: @escaping (Event) -> Void) {
        self.onEvent = onEvent
        let tls = NWProtocolTLS.Options()
        // Cast devices present a self-signed certificate; there is nothing to verify it against.
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.connectionTimeout = 10
        connection = NWConnection(to: endpoint, using: NWParameters(tls: tls, tcp: tcp))
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.emit(.ready)
                self.readFrame()
            case .failed(let error):
                self.finish(error.localizedDescription)
            case .waiting(let error):
                // Unreachable for now (device off, Wi-Fi down): give up, the owner retries later.
                self.finish(error.localizedDescription)
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ message: CastMessage) {
        connection.send(content: message.encoded(), completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(error.localizedDescription) }
        })
    }

    func send(from source: String, to destination: String, namespace: String, _ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        send(CastMessage(source: source, destination: destination, namespace: namespace, payload: text))
    }

    func cancel() {
        connection.cancel()
    }

    private func emit(_ event: Event) {
        DispatchQueue.main.async { self.onEvent(event) }
    }

    /// Reports the end once, then drops the connection.
    private func finish(_ reason: String?) {
        queue.async {
            guard !self.finished else { return }
            self.finished = true
            self.connection.cancel()
            self.emit(.closed(reason))
        }
    }

    private func readFrame() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, complete, error in
            guard let self else { return }
            guard error == nil, let header, header.count == 4 else {
                self.finish(error?.localizedDescription ?? (complete ? nil : "short read"))
                return
            }
            let length = header.reduce(0) { $0 << 8 | Int($1) }
            guard length > 0, length < 1 << 20 else { self.finish("bad frame length \(length)"); return }
            self.connection.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, error in
                guard error == nil, let body, body.count == length else {
                    self.finish(error?.localizedDescription ?? "short read")
                    return
                }
                if let message = CastMessage.decode(body) { self.emit(.message(message)) }
                self.readFrame()
            }
        }
    }
}
