import Foundation
import GRPCCore

// watchOS-only `ClientTransport` conformance speaking grpc-web
// (`application/grpc-web+proto`) over `URLSession` instead of a raw
// HTTP/2 socket. Real Apple Watch hardware blocks low-level networking
// (raw sockets, HTTP/2, Network.framework connections) outside three
// narrow app categories per Apple's TN3135 technote — high-level
// `URLSession` requests are exempt, and the Pi's Envoy proxy already runs
// an unconditional grpc-web bridge (`/grpc/<Service>/<Method>`) that the
// Web UI uses unmodified. Conforming to `ClientTransport` directly (rather
// than reimplementing every RPC by hand) means `GRPCClient`, the generated
// `Store_V1_StoreService.Client`, and all of `UboConnection`/`UboClient`
// work unchanged — only the `UboClientTransport` typealias picks this type
// on watchOS.
//
// Framing matches the reference implementation in
// `ubo_app/services/090-web-ui/web-app/src/store/fetch-stream.ts`:
// `[flags:1][length:4 BE][payload]`, decoded incrementally by
// `GRPCWebFrameDecoder` so a long-lived `subscribeStore`/`subscribeEvent`
// stream never buffers more than the frame currently being assembled.
//
// grpc-web over plain HTTP has no persistent connection to maintain, so
// `connect()` does no networking itself — it just blocks (as the
// `ClientTransport` contract requires) until `beginGracefulShutdown()` or
// task cancellation. Each `withStream` call makes its own independent
// `URLSession` request; per-call cancellation falls out of `URLSession`
// respecting the calling `Task`'s cancellation, so no separate
// stream-tracking registry is needed the way a persistent-connection
// transport (e.g. `HTTP2ClientTransport`) requires.
#if os(watchOS)
@available(watchOS 11.0, *)
public final class GRPCWebClientTransport: ClientTransport, Sendable {
    public typealias Bytes = [UInt8]

    /// grpc-web bridge is plaintext-only today (same as the native proxy's
    /// default). Kept only so `UboConnection.connect`'s `security:`
    /// parameter — typed as `UboClientTransport.TransportSecurity` — stays
    /// source-compatible across the watchOS/non-watchOS branches.
    public enum TransportSecurity: Sendable {
        case plaintext
    }

    public let retryThrottle: RetryThrottle? = nil

    private let baseURL: URL
    private let session: URLSession
    private let state = ShutdownState()

    public init(host: String, port: Int, transportSecurity: TransportSecurity = .plaintext) throws {
        _ = transportSecurity
        guard let url = URL(string: "http://\(host):\(port)/grpc") else {
            throw RPCError(code: .invalidArgument, message: "Invalid grpc-web host/port: \(host):\(port).")
        }
        self.baseURL = url
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        // `timeoutIntervalForRequest`'s 60s default is an *inactivity*
        // timeout applied to `session.bytes()` streams too — but
        // subscribeStore/subscribeEvent are long-lived and routinely idle
        // between updates for minutes, so the default would tear down a
        // healthy subscription as if it were a stalled request. Actual
        // lifecycle is governed by gRPC-level cancellation/deadlines
        // instead, not this transport-level timeout.
        configuration.timeoutIntervalForRequest = 86400
        self.session = URLSession(configuration: configuration)
    }

    public func connect() async throws {
        await state.waitUntilShutdown()
    }

    public func beginGracefulShutdown() {
        // `finishTasksAndInvalidate`, not `invalidateAndCancel` — the
        // contract is "no *new* streams", existing in-flight calls must
        // still run to completion naturally. Forceful cancellation belongs
        // to the caller cancelling the task running `connect()`.
        session.finishTasksAndInvalidate()
        Task { await state.shutdown() }
    }

    public func withStream<T: Sendable>(
        descriptor: MethodDescriptor,
        options: CallOptions,
        _ closure: (RPCStream<Inbound, Outbound>, ClientContext) async throws -> T
    ) async throws -> T {
        if await state.isShutdown {
            throw RPCError(code: .failedPrecondition, message: "The client transport is closed.")
        }

        let requestWriter = CollectingRequestWriter<Bytes>()
        let (inboundStream, inboundContinuation) = AsyncThrowingStream<RPCResponsePart<Bytes>, any Error>.makeStream()

        let stream = RPCStream(
            descriptor: descriptor,
            inbound: RPCAsyncSequence(wrapping: inboundStream),
            outbound: RPCWriter.Closable(wrapping: requestWriter)
        )

        let context = ClientContext(
            descriptor: descriptor,
            remotePeer: "http:\(baseURL.host ?? "unknown"):\(baseURL.port ?? 0)",
            localPeer: "http:watchos-grpc-web"
        )

        let session = self.session
        let baseURL = self.baseURL
        let callTask = Task {
            await Self.performCall(
                descriptor: descriptor,
                requestWriter: requestWriter,
                continuation: inboundContinuation,
                baseURL: baseURL,
                session: session,
                timeout: options.timeout
            )
        }
        // The opened stream is only meant to live for the duration of the
        // closure — cancel the in-flight network call once it returns so a
        // unary caller that got its answer doesn't leave a streaming GET
        // hanging (a no-op if `performCall` already finished).
        defer { callTask.cancel() }

        return try await closure(stream, context)
    }

    public func config(forMethod descriptor: MethodDescriptor) -> MethodConfig? {
        nil
    }

    /// Perform one grpc-web HTTP call end-to-end: wait for the request
    /// message(s) the generated client wrote to `Outbound`, POST them
    /// framed, then decode the streamed response into `Inbound` parts.
    private static func performCall(
        descriptor: MethodDescriptor,
        requestWriter: CollectingRequestWriter<Bytes>,
        continuation: AsyncThrowingStream<RPCResponsePart<Bytes>, any Error>.Continuation,
        baseURL: URL,
        session: URLSession,
        timeout: Duration?
    ) async {
        do {
            let messages = try await requestWriter.waitForMessages()
            var body = Data()
            for message in messages {
                body.append(grpcWebFrameRequest(message))
            }

            var request = URLRequest(url: baseURL.appendingPathComponent(descriptor.fullyQualifiedMethod))
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/grpc-web+proto", forHTTPHeaderField: "content-type")
            request.setValue("application/grpc-web+proto", forHTTPHeaderField: "accept")
            request.setValue("1", forHTTPHeaderField: "x-grpc-web")
            if let timeout {
                let components = timeout.components
                request.timeoutInterval = TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
            }

            let (chunkStream, chunkContinuation) = AsyncThrowingStream<Data, any Error>.makeStream()
            let responseBox = SingleContinuation<HTTPURLResponse>()
            let dataTask = session.dataTask(with: request)
            dataTask.delegate = ChunkedResponseDelegate(chunks: chunkContinuation, response: responseBox)

            try await withTaskCancellationHandler {
                dataTask.resume()

                let httpResponse = try await responseBox.wait()
                guard (200..<300).contains(httpResponse.statusCode) else {
                    throw RPCError(
                        code: .unavailable,
                        message: "grpc-web request failed with HTTP \(httpResponse.statusCode)."
                    )
                }

                // Trailers-only response: the server rejected the call
                // before any message, so the status rides on the HTTP
                // headers instead of a trailer frame in the body — the
                // exact shape `ClientStreamExecutor` expects as a
                // first-and-only `.status` part (see `fetch-stream.ts`'s
                // identical header check).
                if let headerStatus = httpResponse.value(forHTTPHeaderField: "grpc-status") {
                    let code = Int(headerStatus).flatMap(Status.Code.init(rawValue:)) ?? .unknown
                    let message = httpResponse.value(forHTTPHeaderField: "grpc-message") ?? ""
                    continuation.yield(.status(Status(code: code, message: message), Metadata()))
                    continuation.finish()
                    return
                }

                continuation.yield(.metadata(Metadata()))

                var decoder = GRPCWebFrameDecoder()
                var sawTrailer = false

                // Decode each chunk as `URLSession` delivers it — its
                // natural network-sized chunks (typically several KB),
                // not one byte at a time. `session.bytes(for:)`'s public
                // API only exposes a byte-by-byte `AsyncSequence`, and
                // looping + decoding one byte at a time multiplied the
                // number of `await` suspensions by the frame size, which
                // is what made a multi-KB camera viewfinder frame
                // (`FrameStreamDataEvent`) visibly laggy — this per-task
                // `URLSessionDataDelegate` matches the Web UI's
                // `response.body.getReader()` chunk-at-a-time pattern
                // instead (`fetch-stream.ts`).
                for try await chunk in chunkStream {
                    if sawTrailer { break }
                    for frame in try decoder.decode(chunk) {
                        switch frame {
                        case .message(let payload):
                            continuation.yield(.message(Bytes(payload)))
                        case .trailer(let trailers):
                            let code = trailers.status.flatMap(Status.Code.init(rawValue:)) ?? .unknown
                            continuation.yield(.status(Status(code: code, message: trailers.message ?? ""), Metadata()))
                            sawTrailer = true
                        }
                    }
                }

                if sawTrailer {
                    continuation.finish()
                } else {
                    throw RPCError(
                        code: .internalError,
                        message: "grpc-web response ended without a trailer frame."
                    )
                }
            } onCancel: {
                // Unlike `session.bytes(for:)`, a delegate-based
                // `URLSessionDataTask` doesn't cancel itself when the
                // awaiting `Task` is cancelled — has to be done explicitly.
                dataTask.cancel()
            }
        } catch {
            continuation.finish(throwing: error)
        }
    }
}

/// Bridges one `URLSessionDataTask`'s delegate callbacks — which arrive on
/// an arbitrary queue, not the calling `Task`'s isolation — into the
/// `async`/`await` values `performCall` needs: the `HTTPURLResponse` once
/// (via `SingleContinuation`) and the body as an `AsyncThrowingStream` of
/// `Data` chunks in their natural, network-delivered sizes.
///
/// Also refuses HTTP redirects. `URLSession` follows 307/308 redirects —
/// which preserve method and body — by default; without this, a rogue LAN
/// device answering on the grpc-web port could redirect a call (including
/// its framed protobuf body) to an arbitrary off-LAN host. The native
/// HTTP/2 transport has no redirect concept at all, so this keeps the
/// grpc-web path from being strictly weaker.
@available(watchOS 11.0, *)
private final class ChunkedResponseDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let chunks: AsyncThrowingStream<Data, any Error>.Continuation
    private let response: SingleContinuation<HTTPURLResponse>

    init(chunks: AsyncThrowingStream<Data, any Error>.Continuation, response: SingleContinuation<HTTPURLResponse>) {
        self.chunks = chunks
        self.response = response
    }

    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse
    ) async -> URLSession.ResponseDisposition {
        if let httpResponse = response as? HTTPURLResponse {
            self.response.resume(returning: httpResponse)
        } else {
            self.response.resume(throwing: RPCError(code: .unavailable, message: "grpc-web response was not an HTTP response."))
        }
        return .allow
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        chunks.yield(data)
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            // A no-op if `didReceive response:` already resumed it.
            response.resume(throwing: error)
            chunks.finish(throwing: error)
        } else {
            chunks.finish()
        }
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection: HTTPURLResponse,
        newRequest: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

/// Resumes a continuation exactly once from callback contexts that may
/// race each other (`URLSessionDataDelegate` methods can arrive on any
/// queue, not necessarily in the order you'd expect) — a plain
/// `CheckedContinuation` traps if resumed twice, which `didReceive
/// response:` racing `didCompleteWithError:` could otherwise trigger.
@available(watchOS 11.0, *)
private final class SingleContinuation<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, any Error>?
    private var continuation: CheckedContinuation<T, any Error>?

    func wait() async throws -> T {
        // `NSLock.lock()`/`.unlock()` are unavailable from `async`
        // functions (holding a lock across a suspension is unsafe) —
        // `withLock`'s closure is synchronous, so every critical section
        // here is a plain, non-suspending block; the continuation itself
        // is only ever resumed *outside* the lock.
        if let immediate = lock.withLock({ result }) {
            return try immediate.get()
        }

        return try await withCheckedThrowingContinuation { continuation in
            let alreadyResolved: Result<T, any Error>? = lock.withLock {
                if let result {
                    return result
                }
                self.continuation = continuation
                return nil
            }
            switch alreadyResolved {
            case .success(let value): continuation.resume(returning: value)
            case .failure(let error): continuation.resume(throwing: error)
            case nil: break
            }
        }
    }

    func resume(returning value: T) {
        complete(with: .success(value))
    }

    func resume(throwing error: any Error) {
        complete(with: .failure(error))
    }

    private func complete(with newResult: Result<T, any Error>) {
        let toResume: CheckedContinuation<T, any Error>? = lock.withLock {
            guard result == nil else { return nil }
            result = newResult
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        switch newResult {
        case .success(let value): toResume?.resume(returning: value)
        case .failure(let error): toResume?.resume(throwing: error)
        }
    }
}

/// Tracks `connect()`/`beginGracefulShutdown()` state. grpc-web over
/// `URLSession` has no persistent connection to hold open — this exists
/// purely so `connect()` honors the `ClientTransport` contract of blocking
/// until shutdown, and `withStream` rejects new calls afterward.
@available(watchOS 11.0, *)
private actor ShutdownState {
    private(set) var isShutdown = false
    // An array, not a single slot: `waitUntilShutdown()` is only ever
    // called once in practice (from `connect()`), but a single slot would
    // silently drop and leak an earlier waiter if it were ever called
    // again before the first resumed.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    // `connect()`'s contract is "exits when `beginGracefulShutdown()` is
    // called, *or by cancelling the task this function runs in*" — a plain
    // `withCheckedContinuation` ignores cancellation entirely, which would
    // leave a cancelled `GRPCClient.runConnections()` task (and this
    // transport) hung forever. `withTaskCancellationHandler` treats
    // cancellation as an alternate shutdown trigger.
    func waitUntilShutdown() async {
        if isShutdown { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiters.append($0) }
        } onCancel: {
            Task { await self.shutdown() }
        }
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

/// Collects the `RPCRequestPart`s the generated client writes to
/// `Outbound` (one `.metadata`, then the unary/server-streaming call's
/// single `.message`) and hands back the accumulated message bytes once
/// the writer is closed.
@available(watchOS 11.0, *)
private actor CollectingRequestWriter<Bytes: GRPCContiguousBytes & Sendable>: ClosableRPCWriterProtocol {
    typealias Element = RPCRequestPart<Bytes>

    private enum Completion {
        case pending
        case finished(Error?)
    }

    private var messages: [Bytes] = []
    private var completion: Completion = .pending
    private var continuation: CheckedContinuation<[Bytes], Error>?

    func write(_ element: RPCRequestPart<Bytes>) async throws {
        switch element {
        case .metadata:
            // grpc-web needs no outbound metadata frame — call-level
            // headers are set directly on the `URLRequest`.
            break
        case .message(let bytes):
            messages.append(bytes)
        }
    }

    // `nonisolated` so the protocol requirement's `some Sequence<Element>`
    // parameter (not itself `Sendable`, unlike its `Element`) never has to
    // cross the actor boundary — only the individual `Sendable` elements do,
    // one `write(_:)` hop at a time.
    nonisolated func write(contentsOf elements: some Sequence<RPCRequestPart<Bytes>>) async throws {
        for element in elements {
            try await write(element)
        }
    }

    func finish() async {
        complete(with: nil)
    }

    func finish(throwing error: any Error) async {
        complete(with: error)
    }

    func waitForMessages() async throws -> [Bytes] {
        switch completion {
        case .finished(let error):
            if let error { throw error }
            return messages
        case .pending:
            return try await withCheckedThrowingContinuation { self.continuation = $0 }
        }
    }

    private func complete(with error: Error?) {
        guard case .pending = completion else { return }
        completion = .finished(error)
        if let continuation {
            self.continuation = nil
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: messages)
            }
        }
    }
}
#endif
