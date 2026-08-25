import Foundation
import Network

/// A device discovered on the local network via Bonjour/mDNS.
public struct DiscoveredDevice: Sendable, Hashable {
    public let name: String
    public let host: String
    public let port: Int

    /// The grpc-web bridge port, read from the `grpcWebPort` TXT record
    /// when the advertising device publishes one. `nil` on older core
    /// versions that don't yet advertise it.
    ///
    /// Only watchOS should read this instead of `port` — a physical Watch
    /// can't reach `port` (the native raw-TCP proxy) at all per TN3135.
    /// Every other platform keeps reading `port` unchanged.
    public let grpcWebPort: Int?

    public init(name: String, host: String, port: Int, grpcWebPort: Int? = nil) {
        self.name = name
        self.host = host
        self.port = port
        self.grpcWebPort = grpcWebPort
    }
}

/// Errors emitted by ``UboDiscovery``.
public enum UboDiscoveryError: Error, Sendable {
    case browserFailed(NWError)
    case resolverFailed(NWError)
    case unsupportedPlatform
}

/// Bonjour/mDNS browser for Ubo devices on the local network.
///
/// The Python core does not (yet) publish a Bonjour record; once it does,
/// this browser will surface devices on `_uborpc._tcp` automatically.
/// Apps can fall back to manual host entry while discovery is unavailable.
@available(iOS 16.0, macOS 13.0, watchOS 9.0, tvOS 16.0, visionOS 1.0, *)
public final class UboDiscovery: Sendable {
    /// The Bonjour service type advertised by an Ubo device's gRPC server.
    public static let defaultServiceType = "_uborpc._tcp"

    /// Browse continuously for Ubo devices on the local network.
    ///
    /// Each yielded element is the current set of devices: appearances and
    /// disappearances both produce a new snapshot, so consumers can render
    /// the latest list directly. The underlying `NWBrowser` session
    /// restarts itself (with capped exponential backoff) if it enters
    /// `.failed` — without this, a single transient network hiccup
    /// silently ends discovery for the rest of the view's lifetime, with
    /// no way to recover short of leaving and re-entering the screen.
    public static func browse(
        serviceType: String = defaultServiceType,
        domain: String = "local."
    ) -> AsyncStream<Set<DiscoveredDevice>> {
        AsyncStream { continuation in
            let session = BrowserSession(serviceType: serviceType, domain: domain, continuation: continuation)
            Task { await session.start() }
            continuation.onTermination = { _ in
                Task { await session.stop() }
            }
        }
    }

    /// Resolve a single Bonjour result to a `DiscoveredDevice` with a timeout.
    fileprivate static func resolveWithTimeout(result: NWBrowser.Result, timeoutNanoseconds: UInt64) async -> DiscoveredDevice? {
        await withTaskGroup(of: DiscoveredDevice?.self) { group in
            group.addTask {
                await Self.resolve(result: result)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return nil
            }
            let first = await group.next()
            group.cancelAll()
            return first ?? nil
        }
    }

    /// Resolve a single Bonjour result to a `DiscoveredDevice`.
    private static func resolve(result: NWBrowser.Result) async -> DiscoveredDevice? {
        guard case .service(let name, _, _, _) = result.endpoint else {
            return nil
        }

        let endpoint = result.endpoint
        let parameters = NWParameters.tcp
        let connection = NWConnection(to: endpoint, using: parameters)
        let resolvedGrpcWebPort = grpcWebPort(from: result.metadata)

        return await withCheckedContinuation { (continuation: CheckedContinuation<DiscoveredDevice?, Never>) in
            let resolved = ResolveLatch()

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let device: DiscoveredDevice?
                    if case let .hostPort(host, port) = connection.currentPath?.remoteEndpoint {
                        device = DiscoveredDevice(
                            name: name,
                            host: hostString(from: host),
                            port: Int(port.rawValue),
                            grpcWebPort: resolvedGrpcWebPort
                        )
                    } else {
                        device = nil
                    }
                    Task { await resolved.fire(continuation, with: device) }
                    connection.cancel()
                case .failed, .cancelled:
                    Task { await resolved.fire(continuation, with: nil) }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
        }
    }

    private static func hostString(from host: NWEndpoint.Host) -> String {
        switch host {
        case .name(let name, _): return name
        // IPAddress.debugDescription appends a "%interface" zone-id suffix
        // for scoped addresses (e.g. "192.168.0.133%en0") — strip it, since
        // this string is used as the literal host to connect to, not just
        // for display, and callers don't expect/parse a zone id.
        case .ipv4(let addr): return addr.debugDescription.split(separator: "%", maxSplits: 1)[0].description
        case .ipv6(let addr): return addr.debugDescription.split(separator: "%", maxSplits: 1)[0].description
        @unknown default: return "\(host)"
        }
    }

    /// Reads the `grpcWebPort` TXT entry a browse result's Bonjour metadata
    /// may carry (see `ubo_app/services/080-docker/setup.py::_advertise_uborpc`).
    /// `nil` for non-Bonjour results or an older core that doesn't advertise it.
    private static func grpcWebPort(from metadata: NWBrowser.Result.Metadata) -> Int? {
        guard case .bonjour(let txtRecord) = metadata,
              case .string(let value)? = txtRecord.getEntry(for: "grpcWebPort")
        else {
            return nil
        }
        return Int(value)
    }
}

/// Owns one `NWBrowser`'s lifecycle: starts it, reconciles result changes
/// through `BrowserState`, and restarts (with capped exponential backoff)
/// if the session enters `.failed`, so a transient network hiccup doesn't
/// silently end discovery for good.
@available(iOS 16.0, macOS 13.0, watchOS 9.0, tvOS 16.0, visionOS 1.0, *)
private actor BrowserSession {
    private let serviceType: String
    private let domain: String
    private let continuation: AsyncStream<Set<DiscoveredDevice>>.Continuation
    private let state = BrowserState()

    private var browser: NWBrowser?
    private var stopped = false
    private var restartAttempt = 0

    init(serviceType: String, domain: String, continuation: AsyncStream<Set<DiscoveredDevice>>.Continuation) {
        self.serviceType = serviceType
        self.domain = domain
        self.continuation = continuation
    }

    func start() {
        guard !stopped else { return }

        // `.bonjour(type:domain:)` never populates `result.metadata` — TXT
        // records are opt-in via `.bonjourWithTXTRecord`, needed so
        // `grpcWebPort(from:)` below can read the `grpcWebPort` TXT entry
        // instead of every `DiscoveredDevice.grpcWebPort` staying silently
        // nil. But requesting TXT records is a real behavioral change to
        // how the browse resolves (an extra mDNS query type, observed to
        // break discovery entirely on a real iPhone on some networks) —
        // this file is shared by every platform, and only watchOS actually
        // needs the TXT field (it's the only platform that can't fall back
        // to `port`), so only watchOS pays for it.
        #if os(watchOS)
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: serviceType, domain: domain)
        #else
        let descriptor = NWBrowser.Descriptor.bonjour(type: serviceType, domain: domain)
        #endif
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let newBrowser = NWBrowser(for: descriptor, using: parameters)

        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            Task { await self.handleResultsChanged(results) }
        }

        newBrowser.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            switch newState {
            case .ready:
                Task { await self.markReady() }
            case .failed:
                Task { await self.handleFailure() }
            default:
                break
            }
        }

        browser = newBrowser
        newBrowser.start(queue: .global(qos: .utility))
    }

    func stop() {
        stopped = true
        browser?.cancel()
        browser = nil
    }

    private func markReady() {
        restartAttempt = 0
    }

    private func handleResultsChanged(_ results: Set<NWBrowser.Result>) async {
        let token = await state.nextUpdateToken()
        let snapshot = await state.reconcile(results: results)
        if await state.isCurrentToken(token) {
            continuation.yield(snapshot)
        }
    }

    private func handleFailure() async {
        guard !stopped else { return }
        browser?.cancel()
        browser = nil

        let delaySeconds = min(pow(2.0, Double(restartAttempt)), 30)
        restartAttempt += 1
        try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))

        guard !stopped else { return }
        start()
    }
}

/// Tracks resolved devices by service name across browse deltas so an
/// already-known device isn't re-resolved (opening a fresh `NWConnection`)
/// on every mDNS refresh — mirrors the caching fix in the Android
/// `NsdManager`-based `UboDiscovery`.
@available(iOS 16.0, macOS 13.0, watchOS 9.0, tvOS 16.0, visionOS 1.0, *)
private actor BrowserState {
    private var resolvedByName: [String: DiscoveredDevice] = [:]
    private var browseUpdateToken = 0

    func nextUpdateToken() -> Int {
        browseUpdateToken += 1
        return browseUpdateToken
    }

    func isCurrentToken(_ token: Int) -> Bool {
        token == browseUpdateToken
    }

    func reconcile(results: Set<NWBrowser.Result>) async -> Set<DiscoveredDevice> {
        var currentNames: Set<String> = []
        for result in results {
            if case .service(let name, _, _, _) = result.endpoint {
                currentNames.insert(name)
            }
        }
        resolvedByName = resolvedByName.filter { currentNames.contains($0.key) }

        await withTaskGroup(of: (String, DiscoveredDevice?).self) { group in
            for result in results {
                guard case .service(let name, _, _, _) = result.endpoint, resolvedByName[name] == nil else { continue }
                group.addTask {
                    let device = await UboDiscovery.resolveWithTimeout(result: result, timeoutNanoseconds: 5_000_000_000)
                    return (name, device)
                }
            }
            for await (name, device) in group {
                if let device { resolvedByName[name] = device }
            }
        }

        return Set(resolvedByName.values)
    }
}

private actor ResolveLatch {
    private var fired = false
    func fire(_ continuation: CheckedContinuation<DiscoveredDevice?, Never>, with value: DiscoveredDevice?) {
        guard !fired else { return }
        fired = true
        continuation.resume(returning: value)
    }
}
