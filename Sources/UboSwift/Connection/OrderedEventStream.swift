import GRPCCore

/// Ordered events cannot use "newest wins": losing an audio chunk, a stop,
/// or RPC metadata corrupts the stream. Overflow ends the stream explicitly
/// so its owner can reset/reconnect instead of playing a silently damaged reply.
struct OrderedEventStream<Element: Sendable>: Sendable {
    let stream: AsyncThrowingStream<Element, Error>
    let continuation: AsyncThrowingStream<Element, Error>.Continuation

    init(capacity: Int) {
        (stream, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(capacity))
    }

    func yield(_ element: Element) throws {
        switch continuation.yield(element) {
        case .enqueued:
            break
        case .dropped:
            let error = RPCError(code: .resourceExhausted, message: "Ordered event consumer could not keep up.")
            continuation.finish(throwing: error)
            throw error
        case .terminated:
            throw CancellationError()
        @unknown default:
            throw CancellationError()
        }
    }
}
