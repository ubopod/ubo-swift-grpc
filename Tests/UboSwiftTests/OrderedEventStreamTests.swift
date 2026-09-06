import XCTest
import GRPCCore
@testable import UboSwift

final class OrderedEventStreamTests: XCTestCase {
    func testBurstPreservesMetadataAndEveryAudioMessage() async throws {
        let buffer = OrderedEventStream<String>(capacity: 32)
        let parts = ["metadata"] + (0..<12).map { "audio-\($0)" } + ["status"]
        for part in parts { try buffer.yield(part) }
        buffer.continuation.finish()
        var received: [String] = []
        for try await part in buffer.stream { received.append(part) }
        XCTAssertEqual(received, parts)
    }

    func testOverflowFailsInsteadOfSilentlyRemovingOldMessages() async throws {
        let buffer = OrderedEventStream<String>(capacity: 2)
        try buffer.yield("metadata")
        try buffer.yield("audio-0")
        XCTAssertThrowsError(try buffer.yield("audio-1")) { error in
            XCTAssertEqual((error as? RPCError)?.code, .resourceExhausted)
        }
        var received: [String] = []
        do {
            for try await part in buffer.stream { received.append(part) }
            XCTFail("Overflow must fail the consumer too")
        } catch {
            XCTAssertEqual((error as? RPCError)?.code, .resourceExhausted)
        }
        XCTAssertEqual(received, ["metadata", "audio-0"])
    }

    func testProducerStopsWhenConsumerHasTerminated() throws {
        let buffer = OrderedEventStream<Int>(capacity: 2)
        buffer.continuation.finish()
        XCTAssertThrowsError(try buffer.yield(1)) { XCTAssertTrue($0 is CancellationError) }
    }
}
