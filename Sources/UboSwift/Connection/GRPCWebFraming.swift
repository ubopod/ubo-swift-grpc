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

/// Incrementally decodes a grpc-web binary frame stream from chunks handed
/// in as they arrive off the network, without ever buffering more than the
/// frame currently being assembled — the fix for the unbounded-buffer OOM
/// this format's `grpcwebtext`/XHR mode causes in the Web UI kiosk (see
/// `ubo_app/services/090-web-ui/web-app/src/store/fetch-stream.ts`'s
/// `ChunkQueue`).
struct GRPCWebFrameDecoder {
    private var buffer = Data()
    private var pendingHeader: (isTrailer: Bool, length: Int)?

    /// Feed newly-received bytes and drain every whole frame they complete.
    /// A partial frame at the end stays buffered until further bytes arrive.
    ///
    /// Throws `GRPCWebFramingError.frameTooLarge` if a header declares a
    /// length past `GRPCWebFrame.maxFrameLength` — without this a hostile
    /// peer could claim a multi-gigabyte frame and grow `buffer` unbounded
    /// as bytes trickle in, one small chunk at a time.
    mutating func decode(_ chunk: Data) throws -> [GRPCWebDecodedFrame] {
        buffer.append(chunk)
        var frames: [GRPCWebDecodedFrame] = []

        while true {
            if pendingHeader == nil {
                guard buffer.count >= GRPCWebFrame.headerSize else { break }
                let flags = buffer[buffer.startIndex]
                let lengthBytes = buffer.subdata(in: buffer.index(buffer.startIndex, offsetBy: 1)..<buffer.index(buffer.startIndex, offsetBy: GRPCWebFrame.headerSize))
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
                buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: GRPCWebFrame.headerSize))
            }

            guard let header = pendingHeader else { break }
            guard buffer.count >= header.length else { break }

            let payload = buffer.subdata(in: buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: header.length))
            buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: header.length))
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
