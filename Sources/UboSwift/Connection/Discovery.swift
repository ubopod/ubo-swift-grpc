import Foundation
import Network

/// A device discovered on the local network via Bonjour/mDNS.
public struct DiscoveredDevice: Sendable, Hashable {
    public let name: String
    public let host: String
    public let port: Int

    public init(name: String, host: String, port: Int) {
        self.name = name
        self.host = host
        self.port = port
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
    /// the latest list directly.
    public static func browse(
        serviceType: String = defaultServiceType,
        domain: String = "local."
    ) -> AsyncStream<Set<DiscoveredDevice>> {
        AsyncStream { continuation in
            let descriptor = NWBrowser.Descriptor.bonjour(type: serviceType, domain: domain)
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = false
            let browser = NWBrowser(for: descriptor, using: parameters)

            let state = BrowserState()

            browser.browseResultsChangedHandler = { results, _ in
                Task {
                    let token = await state.nextUpdateToken()
                    var snapshot: Set<DiscoveredDevice> = []
                    await withTaskGroup(of: DiscoveredDevice?.self) { group in
                        for result in results {
                            group.addTask {
                                await Self.resolveWithTimeout(result: result)
                            }
                        }
                        for await device in group {
                            if let device { snapshot.insert(device) }
                        }
                    }
                    await state.setSnapshot(snapshot)
                    // Only yield if this is still the latest update
                    if await state.isLatestUpdate(token) {
                        continuation.yield(snapshot)
                    }
                }
            }

            browser.stateUpdateHandler = { newState in
                if case .failed = newState {
                    continuation.finish()
                }
            }

            continuation.onTermination = { _ in
                browser.cancel()
            }

            browser.start(queue: .global(qos: .utility))
        }
    }

    /// Resolve a single Bonjour result with a timeout.
    private static func resolveWithTimeout(result: NWBrowser.Result, timeout: UInt64 = 5_000_000_000) async -> DiscoveredDevice? {
        await withTaskGroup(of: DiscoveredDevice?.self) { group in
            group.addTask {
                await Self.resolve(result: result)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeout)
                return nil
            }
            // Return first completed task (either resolve or timeout)
            let firstResult = await group.next()
            group.cancelAll()
            return firstResult ?? nil
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
                            port: Int(port.rawValue)
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
        case .ipv4(let addr): return addr.debugDescription
        case .ipv6(let addr): return addr.debugDescription
        @unknown default: return "\(host)"
        }
    }
}

private actor BrowserState {
    private var snapshot: Set<DiscoveredDevice> = []
    private var browseUpdateToken: Int = 0

    func setSnapshot(_ s: Set<DiscoveredDevice>) { snapshot = s }

    func nextUpdateToken() -> Int {
        browseUpdateToken += 1
        return browseUpdateToken
    }

    func isLatestUpdate(_ token: Int) -> Bool {
        return token == browseUpdateToken
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
