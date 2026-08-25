import Foundation
import GRPCCore

// grpc-web wire framing (binary `application/grpc-web+proto` mode), ported
// from the Web UI's reference implementation
// (`ubo_app/services/090-web-ui/web-app/src/store/fetch-stream.ts`) so this
// package's watchOS transport speaks the exact same protocol Envoy's
// `grpc_web` filter already serves unmodified.
//
// Frames are `[flags:1][length:4 big-endian][payload:length]`. A frame with
// `GRPCWebFrame.trailerFlag` set carries the trailing metadata
// (`grpc-status`/`grpc-message`) as CRLF-separated header lines rather than
// a message.

enum GRPCWebFrame {
    static let headerSize = 5
    static let trailerFlag: UInt8 = 0x80
    /// Matches the Envoy grpc_listener's `per_connection_buffer_limit_bytes`
    /// (`ubo_app/services/080-docker/assets/envoy.yaml.tmpl`) — a legitimate
    /// message can't exceed what Envoy itself will buffer for a connection.
    /// A rogue LAN device impersonating the bridge could otherwise declare a
    /// frame length up to `UInt32.max` and drip bytes, growing the
    /// decoder's buffer unbounded — this caps that at a fixed, known-safe
    /// size instead.
    static let maxFrameLength = 10 * 1024 * 1024
}

/// Thrown by `GRPCWebFrameDecoder.decode` for a malformed or hostile frame.
enum GRPCWebFramingError: Error, Sendable {
    case frameTooLarge(declaredLength: Int)
}

/// Frame a single outbound protobuf payload for a unary or server-streaming
/// grpc-web request body.
func grpcWebFrameRequest(_ payload: some GRPCContiguousBytes) -> Data {
    var payloadBytes = Data()
    payload.withUnsafeBytes { payloadBytes.append(contentsOf: $0) }

    var frame = Data(capacity: GRPCWebFrame.headerSize + payloadBytes.count)
    frame.append(0) // data frame, uncompressed
    var length = UInt32(payloadBytes.count).bigEndian
    withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
    frame.append(payloadBytes)
    return frame
}

/// Parsed grpc-web trailer frame: `grpc-status` (required) and
/// `grpc-message` (optional), read as CRLF-separated `key: value` lines.
struct GRPCWebTrailers: Sendable {
    var status: Int?
    var message: String?

    init(payload: Data) {
        let text = String(decoding: payload, as: UTF8.self)
        for line in text.split(separator: "\r\n", omittingEmptySubsequences: true) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "grpc-status": status = Int(value)
            case "grpc-message": message = value
            default: break
            }
        }
    }
}

/// One decoded frame off the wire: either a message payload or the
/// trailer frame.
enum GRPCWebDecodedFrame: Sendable {
    case message(Data)
    case trailer(GRPCWebTrailers)
}

/// A byte queue that retains only the frame being assembled — chunks are
/// dropped as they're fully consumed rather than copied into one growing
/// `Data` buffer that gets repeatedly sliced from the front. Ports the Web
/// UI's `ChunkQueue` (`fetch-stream.ts`) verbatim: that class exists there
/// for exactly this reason, replacing this format's `grpcwebtext`/XHR
/// mode's single-ever-growing-buffer approach, which caused an OOM in the
/// Web UI kiosk.
private struct ChunkQueue {
    private var chunks: [Data] = []
    private var offset = 0
    private var available = 0

    mutating func push(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        chunks.append(chunk)
        available += chunk.count
    }

    var count: Int { available }

    /// Remove and return exactly `count` bytes, or `nil` if fewer are
    /// buffered. `chunks.removeFirst()` is O(chunk count), not O(byte
    /// count) — the queue holds a handful of network-delivered chunks at
    /// a time, never one entry per byte, so this stays cheap regardless
    /// of how large the frame being assembled is.
    mutating func take(_ count: Int) -> Data? {
        guard available >= count else { return nil }
        guard count > 0 else { return Data() }

        var out = Data(capacity: count)
        var remaining = count
        while remaining > 0 {
            let head = chunks[0]
            let headStart = head.index(head.startIndex, offsetBy: offset)
            let takeFromHead = min(remaining, head.count - offset)
            out.append(head.subdata(in: headStart..<head.index(headStart, offsetBy: takeFromHead)))
            offset += takeFromHead
            remaining -= takeFromHead
            if offset == head.count {
                chunks.removeFirst()
                offset = 0
            }
        }
        available -= count
        return out
    }
}

/// Incrementally decodes a grpc-web binary frame stream from chunks handed
/// in as they arrive off the network, without ever buffering more than the
/// frame currently being assembled.
///
/// Feed this whole chunks as `URLSession` delivers them (see
/// `GRPCWebClientTransport`'s per-task `URLSessionDataDelegate`), not one
/// byte at a time — decoding byte-by-byte multiplies the number of calls
/// (and, before this transport switched off `URLSession.bytes(for:)`, the
/// number of `await` suspensions on the read side) by the frame size,
/// which is what made a multi-KB camera viewfinder frame visibly laggy.
struct GRPCWebFrameDecoder {
    private var queue = ChunkQueue()
    private var pendingHeader: (isTrailer: Bool, length: Int)?

    /// Feed newly-received bytes and drain every whole frame they complete.
    /// A partial frame at the end stays buffered until further bytes arrive.
    ///
    /// Throws `GRPCWebFramingError.frameTooLarge` if a header declares a
    /// length past `GRPCWebFrame.maxFrameLength` — without this a hostile
    /// peer could claim a multi-gigabyte frame and grow the queue unbounded
    /// as bytes trickle in.
    mutating func decode(_ chunk: Data) throws -> [GRPCWebDecodedFrame] {
        queue.push(chunk)
        var frames: [GRPCWebDecodedFrame] = []

        while true {
            if pendingHeader == nil {
                guard let header = queue.take(GRPCWebFrame.headerSize) else { break }
                let flags = header[header.startIndex]
                let lengthBytes = header.subdata(in: header.index(header.startIndex, offsetBy: 1)..<header.index(header.startIndex, offsetBy: GRPCWebFrame.headerSize))
                // `loadUnaligned`, not `load`: `lengthBytes` is a `Data`
                // subrange with no alignment guarantee, and `load(as:)`
                // requires 4-byte alignment for `UInt32` — undefined
                // behavior (a debug-build trap) on every frame header
                // otherwise.
                let length = lengthBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
                guard length <= GRPCWebFrame.maxFrameLength else {
                    throw GRPCWebFramingError.frameTooLarge(declaredLength: Int(length))
                }
                pendingHeader = (isTrailer: (flags & GRPCWebFrame.trailerFlag) != 0, length: Int(length))
            }

            guard let header = pendingHeader else { break }
            guard let payload = queue.take(header.length) else { break }
            pendingHeader = nil

            if header.isTrailer {
                frames.append(.trailer(GRPCWebTrailers(payload: payload)))
            } else {
                frames.append(.message(payload))
            }
        }

        return frames
    }
}
