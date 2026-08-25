// Wire-format tests for the grpc-web binary framing used by the watchOS
// transport. Mirrors the framing the Web UI's `fetch-stream.ts` already
// exercises in production against the same Envoy `grpc_web` bridge.

#if canImport(XCTest)
import XCTest
@testable import UboSwift

final class GRPCWebFramingTests: XCTestCase {
    func testFrameRequestEncodesHeaderAndPayload() {
        let payload: [UInt8] = [0x01, 0x02, 0x03]
        let frame = grpcWebFrameRequest(payload)

        XCTAssertEqual(frame.count, 5 + 3)
        XCTAssertEqual(frame[frame.startIndex], 0) // data frame, not trailer
        let length = frame.subdata(in: frame.index(frame.startIndex, offsetBy: 1)..<frame.index(frame.startIndex, offsetBy: 5))
            .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        XCTAssertEqual(length, 3)
        XCTAssertEqual(Array(frame.suffix(3)), payload)
    }

    func testDecoderParsesSingleMessageFrame() throws {
        var decoder = GRPCWebFrameDecoder()
        let payload = Data([0xAA, 0xBB])
        let frame = grpcWebFrameRequest(Array(payload))

        let decoded = try decoder.decode(frame)

        XCTAssertEqual(decoded.count, 1)
        guard case .message(let data) = decoded[0] else {
            return XCTFail("expected a message frame")
        }
        XCTAssertEqual(data, payload)
    }

    func testDecoderHandlesFrameSplitAcrossChunks() throws {
        var decoder = GRPCWebFrameDecoder()
        let payload = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let frame = grpcWebFrameRequest(Array(payload))

        // Split mid-header and mid-payload, as a real URLSession byte
        // stream would deliver arbitrary chunk boundaries.
        let firstChunk = frame.prefix(3)
        let secondChunk = frame.dropFirst(3)

        let firstDecoded = try decoder.decode(Data(firstChunk))
        XCTAssertTrue(firstDecoded.isEmpty, "no whole frame yet")

        let secondDecoded = try decoder.decode(Data(secondChunk))
        XCTAssertEqual(secondDecoded.count, 1)
        guard case .message(let data) = secondDecoded[0] else {
            return XCTFail("expected a message frame")
        }
        XCTAssertEqual(data, payload)
    }

    func testDecoderReassemblesFrameAcrossManySmallChunks() throws {
        // Exercises the multi-chunk `ChunkQueue.take` path (spanning more
        // than two pushed chunks, some smaller than a single byte's worth
        // of header) — mirrors how a real camera-viewfinder frame arrives:
        // many small `URLSessionDataDelegate` `didReceive data:` calls.
        var decoder = GRPCWebFrameDecoder()
        let payload = Data((0..<50).map { UInt8($0) })
        let frame = grpcWebFrameRequest(Array(payload))

        var decoded: [GRPCWebDecodedFrame] = []
        var index = frame.startIndex
        while index < frame.endIndex {
            let end = frame.index(index, offsetBy: 3, limitedBy: frame.endIndex) ?? frame.endIndex
            decoded += try decoder.decode(Data(frame[index..<end]))
            index = end
        }

        XCTAssertEqual(decoded.count, 1)
        guard case .message(let data) = decoded[0] else {
            return XCTFail("expected a message frame")
        }
        XCTAssertEqual(data, payload)
    }

    func testDecoderParsesMultipleFramesInOneChunk() throws {
        var decoder = GRPCWebFrameDecoder()
        let first = Data([0x01])
        let second = Data([0x02, 0x03])
        var combined = grpcWebFrameRequest(Array(first))
        combined.append(grpcWebFrameRequest(Array(second)))

        let decoded = try decoder.decode(combined)

        XCTAssertEqual(decoded.count, 2)
        guard case .message(let firstData) = decoded[0], case .message(let secondData) = decoded[1] else {
            return XCTFail("expected two message frames")
        }
        XCTAssertEqual(firstData, first)
        XCTAssertEqual(secondData, second)
    }

    func testDecoderParsesTrailerFrameWithStatusAndMessage() throws {
        var decoder = GRPCWebFrameDecoder()
        let trailerText = "grpc-status: 5\r\ngrpc-message: not found\r\n"
        let trailerPayload = Data(trailerText.utf8)

        var frame = Data([GRPCWebFrame.trailerFlag])
        var length = UInt32(trailerPayload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(trailerPayload)

        let decoded = try decoder.decode(frame)

        XCTAssertEqual(decoded.count, 1)
        guard case .trailer(let trailers) = decoded[0] else {
            return XCTFail("expected a trailer frame")
        }
        XCTAssertEqual(trailers.status, 5)
        XCTAssertEqual(trailers.message, "not found")
    }

    func testDecoderParsesTrailersOnlyZeroStatus() throws {
        var decoder = GRPCWebFrameDecoder()
        let trailerPayload = Data("grpc-status: 0\r\n".utf8)

        var frame = Data([GRPCWebFrame.trailerFlag])
        var length = UInt32(trailerPayload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(trailerPayload)

        let decoded = try decoder.decode(frame)

        guard case .trailer(let trailers) = decoded[0] else {
            return XCTFail("expected a trailer frame")
        }
        XCTAssertEqual(trailers.status, 0)
        XCTAssertNil(trailers.message)
    }

    func testDecoderRejectsOversizedDeclaredLength() {
        var decoder = GRPCWebFrameDecoder()
        var header = Data([0])
        var length = UInt32(GRPCWebFrame.maxFrameLength + 1).bigEndian
        withUnsafeBytes(of: &length) { header.append(contentsOf: $0) }

        XCTAssertThrowsError(try decoder.decode(header)) { error in
            guard case GRPCWebFramingError.frameTooLarge(let declaredLength) = error else {
                return XCTFail("expected frameTooLarge, got \(error)")
            }
            XCTAssertEqual(declaredLength, GRPCWebFrame.maxFrameLength + 1)
        }
    }

    func testDecoderHandlesZeroLengthFrame() throws {
        var decoder = GRPCWebFrameDecoder()
        let frame = grpcWebFrameRequest([UInt8]())

        let decoded = try decoder.decode(frame)

        XCTAssertEqual(decoded.count, 1)
        guard case .message(let data) = decoded[0] else {
            return XCTFail("expected a message frame")
        }
        XCTAssertTrue(data.isEmpty)
    }

    func testTrailerToleratesInvalidUTF8() {
        // 0xFF is not valid UTF-8 anywhere; decoding substitutes U+FFFD
        // rather than throwing, and the malformed line has no colon so it's
        // just skipped — `status`/`message` stay nil instead of crashing.
        let trailers = GRPCWebTrailers(payload: Data([0xFF, 0xFE, 0x00]))
        XCTAssertNil(trailers.status)
        XCTAssertNil(trailers.message)
    }

    func testTrailerWithoutGrpcStatusLeavesStatusNil() {
        let trailers = GRPCWebTrailers(payload: Data("grpc-message: oops\r\n".utf8))
        XCTAssertNil(trailers.status)
        XCTAssertEqual(trailers.message, "oops")
    }

    func testTrailerWithNonNumericStatusLeavesStatusNil() {
        let trailers = GRPCWebTrailers(payload: Data("grpc-status: not-a-number\r\n".utf8))
        XCTAssertNil(trailers.status)
    }
}
#endif
