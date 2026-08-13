import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import SwiftProtobuf

/// Actor to safely hold and merge system stats across async updates
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
/// One frame's worth of updates to `SystemStats`. Every field is optional so
/// a merge only overwrites what this particular `SubscribeStoreResponse`
/// frame actually carried, never clobbering an already-known value with a
/// default zero.
struct SystemStatsPatch {
    var cpuPercent: Float?
    var ramPercent: Float?
    var temperature: Float?
    var loadAverage1: Float?
    var loadAverage5: Float?
    var loadAverage15: Float?
    var bootTime: Float?
    var diskTotalBytes: Int64?
    var diskUsedBytes: Int64?
    var diskPercent: Float?
    var networkUploadBps: Float?
    var networkDownloadBps: Float?
    var clock: String?
    var date: String?
    var weather: WeatherCondition?
    var locationCity: String?
    var locationCountry: String?
    var dockerApps: [DockerAppStatus]?
    var sensorDevices: [SensorDeviceState]?
    var playbackVolume: Float?
    var isPlaybackMute: Bool?
    var isCaptureMute: Bool?
}

private actor StatsHolder {
    private var stats = SystemStats()

    func update(_ patch: SystemStatsPatch) -> SystemStats {
        if let v = patch.cpuPercent { stats.cpuPercent = v }
        if let v = patch.ramPercent { stats.ramPercent = v }
        if let v = patch.temperature { stats.temperature = v }
        if let v = patch.loadAverage1 { stats.loadAverage1 = v }
        if let v = patch.loadAverage5 { stats.loadAverage5 = v }
        if let v = patch.loadAverage15 { stats.loadAverage15 = v }
        if let v = patch.bootTime { stats.bootTime = v }
        if let v = patch.diskTotalBytes { stats.diskTotalBytes = v }
        if let v = patch.diskUsedBytes { stats.diskUsedBytes = v }
        if let v = patch.diskPercent { stats.diskPercent = v }
        if let v = patch.networkUploadBps { stats.networkUploadBps = v }
        if let v = patch.networkDownloadBps { stats.networkDownloadBps = v }
        if let v = patch.clock { stats.clock = v }
        if let v = patch.date { stats.date = v }
        if let v = patch.weather { stats.weather = v }
        if let v = patch.locationCity { stats.locationCity = v }
        if let v = patch.locationCountry { stats.locationCountry = v }
        if let v = patch.dockerApps { stats.dockerApps = v }
        if let v = patch.sensorDevices { stats.sensorDevices = v }
        if let v = patch.playbackVolume { stats.playbackVolume = v }
        if let v = patch.isPlaybackMute { stats.isPlaybackMute = v }
        if let v = patch.isCaptureMute { stats.isCaptureMute = v }
        return stats
    }
}

/// Manages gRPC connection to an Ubo device
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public actor UboConnection {
    /// The gRPC client
    private var grpcClient: GRPCClient<HTTP2ClientTransport.Posix>?

    /// The store service client
    private var storeClient: Store_V1_StoreService.Client<HTTP2ClientTransport.Posix>?

    /// Current connection state
    public private(set) var state: ConnectionState = .disconnected

    /// Host address
    private var host: String?

    /// Port number
    private var port: Int?

    /// Background task for running the client
    private var clientTask: Task<Void, any Error>?

    /// Backoff schedule applied when long-lived subscriptions error out.
    public var reconnectPolicy: ReconnectPolicy = .default

    public init() {}

    /// Update the reconnect policy used by future subscription retries.
    public func setReconnectPolicy(_ policy: ReconnectPolicy) {
        self.reconnectPolicy = policy
    }

    /// Mark the connection as `reconnecting` (called from the retry loop).
    fileprivate func markReconnecting() {
        if state == .connected { state = .reconnecting }
    }

    /// Mark the connection as `connected` again (called after a retry succeeds).
    fileprivate func markConnected() {
        if state == .reconnecting { state = .connected }
    }

    /// Repeat `body` with exponential backoff (`reconnectPolicy`) on errors
    /// or graceful stream termination, until the consumer cancels or
    /// `maxRetries` is exhausted. Used by every long-lived subscription.
    fileprivate func runWithRetry(
        body: @escaping @Sendable () async throws -> Void,
        onFinalError: @escaping @Sendable (Error) -> Void,
        onCancelled: @escaping @Sendable () -> Void
    ) async {
        let policy = self.reconnectPolicy
        var attempt = 0
        let clock = ContinuousClock()
        // A body that streamed healthily for this long resets the backoff.
        // Without the reset, sporadic blips over a long-lived session
        // accumulate towards maxRetries and permanently kill the
        // subscription even though every individual outage recovered.
        let healthyRunThreshold: Duration = .seconds(30)

        while !Task.isCancelled {
            let started = clock.now
            do {
                try await body()
                // Body returned without error: server closed the stream.
                // Treat as a soft retry — back off then re-subscribe.
                if clock.now - started >= healthyRunThreshold { attempt = 0 }
                attempt += 1
                if attempt >= policy.maxRetries {
                    UboLog.subscription.error("Giving up after \(attempt) consecutive short-lived streams")
                    onFinalError(UboError.subscriptionFailed(UboError.timeout))
                    return
                }
            } catch is CancellationError {
                onCancelled()
                return
            } catch {
                if clock.now - started >= healthyRunThreshold { attempt = 0 }
                attempt += 1
                if attempt >= policy.maxRetries {
                    UboLog.subscription.error("Giving up after \(attempt) attempts: \(error)")
                    onFinalError(error)
                    return
                }
                self.markReconnecting()
            }

            // ±20% jitter de-synchronises the parallel subscriptions'
            // reconnect attempts. A 0.2 s floor stops a server that closes
            // streams immediately from driving a hot re-subscribe loop.
            let delaySeconds = max(
                policy.delaySeconds(forAttempt: attempt) * Double.random(in: 0.8...1.2),
                0.2
            )
            do {
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            } catch {
                onCancelled()
                return
            }
        }
        onCancelled()
    }

    // MARK: - Connection Management

    /// Connect to an Ubo device
    /// - Parameters:
    ///   - host: Device hostname or IP address
    ///   - port: gRPC port (default: 50051)
    ///   - security: Transport security to use. Defaults to `.plaintext` to
    ///     match the Pi-side default; pass `.tls` (or `.tls(...)`) once the
    ///     device-side server advertises a TLS endpoint.
    public func connect(
        host: String,
        port: Int = 50051,
        security: HTTP2ClientTransport.Posix.TransportSecurity = .plaintext
    ) async throws {
        // Tear down any previous transport first (connect-after-connect
        // without an explicit disconnect) so the old `runConnections()`
        // task and transport don't leak.
        teardownTransport()
        self.host = host
        self.port = port
        state = .connecting

        do {
            // Create the transport
            // Use DNS resolution which handles both IPv4 and IPv6 (important for .local mDNS names)
            let transport = try HTTP2ClientTransport.Posix(
                target: .dns(host: host, port: port),
                transportSecurity: security
            )

            // Create the gRPC client
            let client = GRPCClient(transport: transport)
            self.grpcClient = client

            // Create the store service client
            self.storeClient = Store_V1_StoreService.Client(wrapping: client)

            // Start the client in the background
            clientTask = Task {
                try await client.runConnections()
            }

            // Probe with lightweight RPCs until the transport verifies or
            // the deadline passes. Worst case ≈ deadline + one in-flight
            // verify attempt (~2 s).
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(10)
            var connectionVerified = false
            var lastError: Error?

            while clock.now < deadline {
                // Give the transport time to establish
                try await Task.sleep(nanoseconds: 500_000_000) // 500ms

                // Try a simple dispatch to verify connectivity
                let verifyResult = await verifyConnection()
                switch verifyResult {
                case .success:
                    connectionVerified = true
                case .notReady(let error):
                    lastError = error
                    // Continue waiting
                case .failed(let error):
                    // This is a real connection error (like "connection refused"), not just "not ready"
                    throw UboError.connectionFailed(error)
                }

                if connectionVerified {
                    break
                }
            }

            if !connectionVerified {
                throw UboError.connectionFailed(lastError ?? UboError.timeout)
            }

            state = .connected
        } catch let error as UboError {
            teardownTransport()
            state = .disconnected
            throw error
        } catch {
            teardownTransport()
            state = .disconnected
            throw UboError.connectionFailed(error)
        }
    }

    /// Shut down the transport and cancel the background `runConnections()`
    /// task. Safe to call when nothing is connected.
    private func teardownTransport() {
        grpcClient?.beginGracefulShutdown()
        clientTask?.cancel()
        clientTask = nil
        grpcClient = nil
        storeClient = nil
    }

    /// Result of connection verification
    private enum ConnectionVerifyResult {
        case success
        case notReady(Error)
        case failed(Error)
    }

    /// Verify the connection is ready by attempting a lightweight RPC
    private func verifyConnection() async -> ConnectionVerifyResult {
        guard let client = storeClient else {
            return .failed(UboError.notConnected)
        }

        // Try to get the current store state with empty selectors as a connectivity test
        var testRequest = Store_V1_SubscribeStoreRequest()
        testRequest.selectors = []

        do {
            // Use a task with timeout
            try await withThrowingTaskGroup(of: Void.self) { group in
                let clientToUse = client
                let request = testRequest

                group.addTask {
                    try await clientToUse.subscribeStore(request) { response in
                        // We just need to verify we can connect, immediately return
                        switch response.accepted {
                        case .success(_):
                            return  // Connection works!
                        case .failure(let error):
                            throw error
                        }
                    }
                }

                group.addTask {
                    try await Task.sleep(nanoseconds: 2_000_000_000) // 2 second timeout
                    throw UboError.timeout
                }

                // Wait for first to complete
                try await group.next()
                group.cancelAll()
            }

            return .success
        } catch {
            return classifyVerifyError(error)
        }
    }

    /// Classify a verification failure: transient "transport not ready yet"
    /// (keep probing) vs a real failure (abort the connect). Inspects typed
    /// `RPCError` codes rather than matching on error descriptions.
    private func classifyVerifyError(_ error: Error) -> ConnectionVerifyResult {
        if case UboError.timeout = error {
            // The probe RPC hung — the server may still be coming up.
            return .notReady(error)
        }
        if let rpcError = error as? RPCError {
            switch rpcError.code {
            case .unavailable, .deadlineExceeded, .aborted:
                return .notReady(rpcError)
            default:
                return .failed(rpcError)
            }
        }
        return .failed(error)
    }

    /// Disconnect from the device
    public func disconnect() async {
        teardownTransport()
        state = .disconnected
        host = nil
        port = nil
    }

    /// Check if connected
    public var isConnected: Bool {
        state == .connected && storeClient != nil
    }

    // MARK: - Action Dispatch

    /// Dispatch an action to the device
    public func dispatchAction(_ action: UboAction) async throws {
        guard let client = storeClient else {
            throw UboError.notConnected
        }

        // Build the proto action
        let protoAction = buildProtoAction(action)

        // Create request
        var requestBuilder = Store_V1_DispatchActionRequest()
        requestBuilder.action = protoAction
        let request = requestBuilder

        do {
            _ = try await client.dispatchAction(request)
        } catch {
            throw UboError.dispatchFailed(error)
        }
    }

    // MARK: - Store Subscription

    /// Subscribe to store state changes for view data and status bar
    /// - Parameter selectors: List of state selectors (e.g., ["state.main.current_view", "state.main.status_bar"])
    /// - Returns: An async stream of (ViewData, StatusBarData?) tuples
    public func subscribeToStoreChanges(selectors: [String] = ["state.main.current_view", "state.main.status_bar"]) -> AsyncThrowingStream<(ViewData, StatusBarData?), Error> {
        // All streams are bounded (`bufferingNewest`): a stalled consumer
        // drops the oldest updates instead of growing memory without limit.
        // State snapshots are newest-wins, so a small buffer is safe.
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            let task = Task {
                await self.runWithRetry { [selectors] in
                    try await self.streamStoreChanges(selectors: selectors, continuation: continuation)
                } onFinalError: { error in
                    continuation.finish(throwing: UboError.subscriptionFailed(error))
                } onCancelled: {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamStoreChanges(
        selectors: [String],
        continuation: AsyncThrowingStream<(ViewData, StatusBarData?), Error>.Continuation
    ) async throws {
        guard let client = self.storeClient else {
            throw UboError.notConnected
        }

        var request = Store_V1_SubscribeStoreRequest()
        request.selectors = selectors

        try await client.subscribeStore(request) { response in
            switch response.accepted {
            case .success(let contents):
                for try await message in contents.bodyParts {
                    if case .message(let subscribeResponse) = message {
                        // First message after a retry — restore connected state.
                        await self.markConnected()

                        let results = subscribeResponse.results

                        var viewData: ViewData?
                        var statusBarData: StatusBarData?

                        if results.count > 0 {
                            viewData = self.unpackViewData(from: results[0])
                        }
                        if results.count > 1 {
                            statusBarData = self.unpackStatusBarData(from: results[1])
                        }

                        if let view = viewData {
                            continuation.yield((view, statusBarData))
                        }
                    }
                }
            case .failure(let error):
                throw error
            }
        }
    }

    /// Subscribe to navigation-stack changes (`StackChangedEvent`). Yields the
    /// full stack as breadcrumb-ready items each time the user navigates.
    public func subscribeToStackChanges() -> AsyncThrowingStream<[UboStackItem], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.runWithRetry {
                    try await self.streamStackChanges(continuation: continuation)
                } onFinalError: { error in
                    continuation.finish(throwing: UboError.subscriptionFailed(error))
                } onCancelled: {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamStackChanges(
        continuation: AsyncThrowingStream<[UboStackItem], Error>.Continuation
    ) async throws {
        guard let client = self.storeClient else {
            throw UboError.notConnected
        }

        var requestBuilder = Store_V1_SubscribeEventRequest()
        var eventBuilder = Ubo_V1_Event()
        eventBuilder.stackChangedEvent = Ubo_V1_StackChangedEvent()
        requestBuilder.events = [eventBuilder]
        let request = requestBuilder

        try await client.subscribeEvent(request) { response in
            switch response.accepted {
            case .success(let contents):
                for try await message in contents.bodyParts {
                    if case .message(let subscribeResponse) = message {
                        await self.markConnected()
                        if case .stackChangedEvent(let stackEvent) = subscribeResponse.event.event {
                            let items = stackEvent.stack.compactMap { self.convertStackItem($0) }
                            continuation.yield(items)
                        }
                    }
                }
            case .failure(let error):
                throw error
            }
        }
    }

    /// Map a proto stack entry to a breadcrumb item, mirroring the Web UI's
    /// `getStackItemLabel`.
    nonisolated func convertStackItem(_ item: Ubo_V1_StackItemType) -> UboStackItem? {
        switch item.stackItemType {
        case .menuStackItem(let menu):
            return UboStackItem(id: menu.id, label: Self.formatStackLabel(menu.menuKey))
        case .applicationStackItem(let app):
            return UboStackItem(id: app.id, label: "Application")
        case .renderStackItem(let render):
            let label = !render.title.isEmpty
                ? render.title
                : (!render.kind.isEmpty ? render.kind : "View")
            return UboStackItem(id: render.id, label: label)
        case .notificationStackItem(let notification):
            return UboStackItem(id: notification.id, label: "Notification")
        case .chatStackItem(let chat):
            return UboStackItem(id: chat.id, label: "Assistant")
        case .instructionStackItem(let instruction):
            return UboStackItem(id: instruction.id, label: "Instruction")
        case .promptStackItem(let prompt):
            return UboStackItem(id: prompt.id, label: "Prompt")
        case .none:
            return nil
        }
    }

    /// "wifi_settings" / "wifi-settings" -> "Wifi Settings".
    private nonisolated static func formatStackLabel(_ raw: String) -> String {
        raw.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == ":" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Subscribe to system stats (CPU, RAM, clock, temperature) - updates continuously regardless of current view
    /// - Returns: An async stream of SystemStats
    public func subscribeToSystemStats() -> AsyncThrowingStream<SystemStats, Error> {
        // Stats accumulator survives across retries so partial updates (e.g.
        // a SensorsState that only carries temperature) keep the previous
        // CPU/RAM values.
        let statsHolder = StatsHolder()
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            let task = Task {
                await self.runWithRetry {
                    try await self.streamSystemStats(
                        statsHolder: statsHolder,
                        continuation: continuation
                    )
                } onFinalError: { error in
                    continuation.finish(throwing: UboError.subscriptionFailed(error))
                } onCancelled: {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamSystemStats(
        statsHolder: StatsHolder,
        continuation: AsyncThrowingStream<SystemStats, Error>.Continuation
    ) async throws {
        guard let client = self.storeClient else {
            throw UboError.notConnected
        }

        var request = Store_V1_SubscribeStoreRequest()
        // `state.audio` brings the device's playback volume + mute state in
        // sync with the app, matching what the Web UI subscribes to in
        // `state-manager.ts`. `state.docker.service` (not the parent
        // `state.docker`) matches the same selector the Web UI uses, to
        // avoid an Any-packing issue on the parent DockerState.
        request.selectors = [
            "state.system", "state.sensors", "state.audio", "state.localization", "state.docker.service",
        ]

        try await client.subscribeStore(request) { response in
            switch response.accepted {
            case .success(let contents):
                for try await message in contents.bodyParts {
                    if case .message(let subscribeResponse) = message {
                        await self.markConnected()

                        var patch = SystemStatsPatch()
                        for result in subscribeResponse.results {
                            self.applySystemStatsResult(result, to: &patch)
                        }

                        let mergedStats = await statsHolder.update(patch)
                        continuation.yield(mergedStats)
                    }
                }
            case .failure(let error):
                throw error
            }
        }
    }

    // MARK: - Proto Unpacking

    /// Unpack a google.protobuf.Any message to ViewData
    internal nonisolated func unpackViewData(from any: SwiftProtobuf.Google_Protobuf_Any) -> ViewData? {
        let typeURL = any.typeURL

        // Check the type URL to determine which ViewData type to unpack
        if typeURL.hasSuffix("HomeViewData") {
            if let proto = try? Ubo_V1_HomeViewData(serializedBytes: any.value) {
                return .home(convertHomeViewData(proto))
            }
        } else if typeURL.hasSuffix("MenuViewData") {
            if let proto = try? Ubo_V1_MenuViewData(serializedBytes: any.value) {
                return .menu(convertMenuViewData(proto))
            }
        } else if typeURL.hasSuffix("NotificationViewData") {
            if let proto = try? Ubo_V1_NotificationViewData(serializedBytes: any.value) {
                return .notification(convertNotificationViewData(proto))
            }
        } else if typeURL.hasSuffix("ApplicationViewData") {
            if let proto = try? Ubo_V1_ApplicationViewData(serializedBytes: any.value) {
                return .application(convertApplicationViewData(proto))
            }
        } else if typeURL.hasSuffix("InstructionViewData") {
            if let proto = try? Ubo_V1_InstructionViewData(serializedBytes: any.value) {
                return .instruction(convertInstructionViewData(proto))
            }
        } else if typeURL.hasSuffix("PromptViewData") {
            if let proto = try? Ubo_V1_PromptViewData(serializedBytes: any.value) {
                return .prompt(convertPromptViewData(proto))
            }
        } else if typeURL.hasSuffix("RenderViewData") {
            if let proto = try? Ubo_V1_RenderViewData(serializedBytes: any.value) {
                return .render(convertRenderViewData(proto))
            }
        } else if typeURL.hasSuffix("ChatViewData") {
            if let proto = try? Ubo_V1_ChatViewData(serializedBytes: any.value) {
                return .chat(convertChatViewData(proto))
            }
        }

        return nil
    }

    /// Unpack a google.protobuf.Any message to StatusBarData
    private nonisolated func unpackStatusBarData(from any: SwiftProtobuf.Google_Protobuf_Any) -> StatusBarData? {
        let typeURL = any.typeURL

        if typeURL.hasSuffix("StatusBarData") {
            if let proto = try? Ubo_V1_StatusBarData(serializedBytes: any.value) {
                return convertStatusBarData(proto)
            }
        }

        return nil
    }

    /// Dispatch one `SubscribeStoreResponse` result into the in-progress
    /// `SystemStatsPatch` by its type URL. Each result carries at most one
    /// state slice (`SystemState`, `LocalizationState`, `DockerServiceState`,
    /// `SensorsState`, or `AudioState`); unrecognized/unset fields are left
    /// untouched so a frame with a subset of selectors never clobbers
    /// already-known values with defaults.
    private nonisolated func applySystemStatsResult(
        _ any: SwiftProtobuf.Google_Protobuf_Any,
        to patch: inout SystemStatsPatch
    ) {
        let typeURL = any.typeURL

        if typeURL.hasSuffix("SystemState"), let proto = try? Ubo_V1_SystemState(serializedBytes: any.value) {
            if proto.hasCpuPercent { patch.cpuPercent = proto.cpuPercent }
            if proto.hasRamPercent { patch.ramPercent = proto.ramPercent }
            if proto.hasCpuTemperatureCelsius { patch.temperature = proto.cpuTemperatureCelsius }
            if proto.hasLoadAverage1 { patch.loadAverage1 = proto.loadAverage1 }
            if proto.hasLoadAverage5 { patch.loadAverage5 = proto.loadAverage5 }
            if proto.hasLoadAverage15 { patch.loadAverage15 = proto.loadAverage15 }
            if proto.hasBootTime { patch.bootTime = proto.bootTime }
            if proto.hasDiskTotalBytes { patch.diskTotalBytes = proto.diskTotalBytes }
            if proto.hasDiskUsedBytes { patch.diskUsedBytes = proto.diskUsedBytes }
            if proto.hasDiskPercent { patch.diskPercent = proto.diskPercent }
            if proto.hasNetworkUploadBps { patch.networkUploadBps = proto.networkUploadBps }
            if proto.hasNetworkDownloadBps { patch.networkDownloadBps = proto.networkDownloadBps }
        } else if typeURL.hasSuffix("LocalizationState"),
                  let proto = try? Ubo_V1_LocalizationState(serializedBytes: any.value) {
            if proto.hasClock { patch.clock = proto.clock }
            if proto.hasDate { patch.date = proto.date }
            if proto.hasLocation {
                if proto.location.hasCity { patch.locationCity = proto.location.city }
                if proto.location.hasCountry { patch.locationCountry = proto.location.country }
            }
            if proto.hasWeather {
                patch.weather = WeatherCondition(
                    symbolCode: proto.weather.symbolCode,
                    temperatureCelsius: proto.weather.temperatureCelsius,
                    windSpeedMps: proto.weather.hasWindSpeedMps ? proto.weather.windSpeedMps : nil
                )
            }
        } else if typeURL.hasSuffix("DockerServiceState"),
                  let proto = try? Ubo_V1_DockerServiceState(serializedBytes: any.value) {
            patch.dockerApps = proto.apps.items.values.map(convertDockerAppStatus)
        } else if typeURL.hasSuffix("SensorsState"),
                  let proto = try? Ubo_V1_SensorsState(serializedBytes: any.value) {
            patch.sensorDevices = proto.devices.items.values.map(convertSensorDeviceState)
        } else if typeURL.hasSuffix("AudioState"), let proto = try? Ubo_V1_AudioState(serializedBytes: any.value) {
            if proto.hasPlaybackVolume { patch.playbackVolume = proto.playbackVolume }
            if proto.hasIsPlaybackMute { patch.isPlaybackMute = proto.isPlaybackMute }
            if proto.hasIsCaptureMute { patch.isCaptureMute = proto.isCaptureMute }
        }
    }

    private nonisolated func convertDockerAppStatus(_ proto: Ubo_V1_DockerAppStatus) -> DockerAppStatus {
        DockerAppStatus(
            id: proto.id,
            label: proto.label,
            icon: proto.icon,
            status: convertDockerItemStatus(proto.status),
            health: convertDockerItemHealth(proto.health)
        )
    }

    private nonisolated func convertDockerItemStatus(_ proto: Ubo_V1_DockerItemStatus) -> DockerItemStatus {
        switch proto {
        case .notAvailable: .notAvailable
        case .fetching: .fetching
        case .available: .available
        case .created: .created
        case .starting: .starting
        case .running: .running
        case .error: .error
        case .processing: .processing
        case .uboAppDotStoreDotServicesDotDockerUnspecified, .UNRECOGNIZED: .unspecified
        }
    }

    private nonisolated func convertDockerItemHealth(_ proto: Ubo_V1_DockerItemHealth) -> DockerItemHealth {
        switch proto {
        case .ok: .ok
        case .recovered: .recovered
        case .crashLooping: .crashLooping
        case .uboAppDotStoreDotServicesDotDockerUnspecified, .UNRECOGNIZED: .unspecified
        }
    }

    private nonisolated func convertSensorDeviceState(_ proto: Ubo_V1_SensorDeviceState) -> SensorDeviceState {
        SensorDeviceState(
            id: proto.id,
            label: proto.label,
            status: convertSensorDeviceStatus(proto.status),
            entities: proto.entities.items.map(convertSensorEntityReading)
        )
    }

    private nonisolated func convertSensorDeviceStatus(_ proto: Ubo_V1_SensorStatus) -> SensorDeviceStatus {
        switch proto {
        case .active: .active
        case .error: .error
        case .unsupported: .unsupported
        case .ambiguous: .ambiguous
        case .uboAppDotStoreDotServicesDotSensorsUnspecified, .UNRECOGNIZED: .unspecified
        }
    }

    private nonisolated func convertSensorEntityReading(_ proto: Ubo_V1_SensorEntityReading) -> SensorEntityReading {
        SensorEntityReading(
            key: proto.key,
            value: proto.hasValue ? proto.value : nil,
            name: proto.hasName ? proto.name : nil,
            unit: proto.hasUnit ? proto.unit : nil,
            deviceClass: proto.hasDeviceClass ? proto.deviceClass : nil,
            precision: proto.hasPrecision ? proto.precision : nil
        )
    }

    // MARK: - Proto Conversion (to Swift models)

    private nonisolated func convertMenuItemData(_ proto: Ubo_V1_MenuItemData) -> MenuItemData {
        MenuItemData(
            key: proto.key,
            label: proto.label,
            icon: proto.icon,
            color: proto.hasColor ? proto.color : "#ffffff",
            backgroundColor: proto.hasBackgroundColor ? proto.backgroundColor : nil,
            isShort: proto.hasIsShort ? proto.isShort : false,
            actionId: proto.hasActionID ? proto.actionID : nil
        )
    }

    private nonisolated func convertHomeViewData(_ proto: Ubo_V1_HomeViewData) -> HomeViewData {
        var menuItems: [MenuItemData] = []
        if proto.hasMenuItems {
            menuItems = proto.menuItems.items.map { convertMenuItemData($0) }
        }

        return HomeViewData(
            type: proto.hasType ? proto.type : "home",
            showStatusBar: proto.hasShowStatusBar ? proto.showStatusBar : true,
            menuItems: menuItems,
            cpuPercent: proto.hasCpuPercent ? proto.cpuPercent : 0,
            ramPercent: proto.hasRamPercent ? proto.ramPercent : 0,
            volumeLevel: proto.hasVolumeLevel ? proto.volumeLevel : 0
        )
    }

    private nonisolated func convertMenuViewData(_ proto: Ubo_V1_MenuViewData) -> MenuViewData {
        var items: [MenuItemData?] = []
        if proto.hasItems {
            items = proto.items.items.map { itemWrapper in
                if itemWrapper.hasItems {
                    return convertMenuItemData(itemWrapper.items)
                }
                return nil
            }
        }

        return MenuViewData(
            type: proto.hasType ? proto.type : "menu",
            showStatusBar: proto.hasShowStatusBar ? proto.showStatusBar : true,
            title: proto.hasTitle ? proto.title : "",
            heading: proto.hasHeading ? proto.heading : nil,
            subHeading: proto.hasSubHeading ? proto.subHeading : nil,
            items: items,
            pageIndex: proto.hasPageIndex ? Int(proto.pageIndex) : 0,
            totalPages: proto.hasTotalPages ? Int(proto.totalPages) : 1
        )
    }

    private nonisolated func convertNotificationViewData(_ proto: Ubo_V1_NotificationViewData) -> NotificationViewData {
        var items: [MenuItemData?] = []
        if proto.hasItems {
            items = proto.items.items.map { itemWrapper in
                if itemWrapper.hasItems {
                    return convertMenuItemData(itemWrapper.items)
                }
                return nil
            }
        }

        return NotificationViewData(
            type: proto.hasType ? proto.type : "notification",
            showStatusBar: proto.hasShowStatusBar ? proto.showStatusBar : false,
            notificationId: proto.hasNotificationID ? proto.notificationID : "",
            title: proto.hasTitle ? proto.title : "",
            content: proto.hasContent ? proto.content : "",
            icon: proto.hasIcon ? proto.icon : "",
            color: proto.hasColor ? proto.color : "#ffffff",
            items: items,
            extraInformation: proto.hasExtraInformation ? proto.extraInformation : ""
        )
    }

    private nonisolated func convertApplicationViewData(_ proto: Ubo_V1_ApplicationViewData) -> ApplicationViewData {
        var extraData: [String: String] = [:]
        if proto.hasExtraData {
            extraData = proto.extraData.items.mapValues(convertApplicationExtraDataValue)
        }

        return ApplicationViewData(
            type: proto.hasType ? proto.type : "application",
            showStatusBar: proto.hasShowStatusBar ? proto.showStatusBar : false,
            applicationId: proto.hasApplicationID ? proto.applicationID : "",
            extraData: extraData
        )
    }

    private nonisolated func convertApplicationExtraDataValue(
        _ value: Ubo_V1_ApplicationViewData.ExtraDataValue
    ) -> String {
        switch value.extraDataValue {
        case .basicType(let basicType):
            return convertBasicType(basicType)
        case .list(let list):
            return list.items.map(convertBasicType).joined(separator: ",")
        case nil:
            return ""
        }
    }

    private nonisolated func convertBasicType(_ value: Ubo_V1_BasicType) -> String {
        switch value.basicType {
        case .bool(let bool):
            return String(bool)
        case .bytes(let data):
            return data.base64EncodedString()
        case .float(let float):
            return String(float)
        case .int64(let int64):
            return String(int64)
        case .string(let string):
            return string
        case nil:
            return ""
        }
    }

    private nonisolated func convertBasicTypeTyped(_ value: Ubo_V1_BasicType) -> RenderPropValue {
        switch value.basicType {
        case .bool(let bool):
            return .bool(bool)
        case .bytes(let data):
            return .bytes(data)
        case .float(let float):
            return .float(float)
        case .int64(let int64):
            return .int(int64)
        case .string(let string):
            return .string(string)
        case nil:
            return .string("")
        }
    }

    private nonisolated func convertInstructionViewData(_ proto: Ubo_V1_InstructionViewData) -> InstructionViewData {
        InstructionViewData(
            type: proto.hasType ? proto.type : "instruction",
            showStatusBar: proto.hasShowStatusBar ? proto.showStatusBar : false,
            title: proto.hasTitle ? proto.title : "",
            instruction: proto.hasInstruction ? proto.instruction : "",
            icon: proto.hasIcon ? proto.icon : "",
            spinner: proto.hasSpinner ? proto.spinner : false,
            timeoutSeconds: proto.hasTimeoutSeconds ? Int(proto.timeoutSeconds) : 0,
            progressText: proto.hasProgressText ? proto.progressText : "",
            footerText: proto.hasFooterText ? proto.footerText : ""
        )
    }

    private nonisolated func convertPromptViewData(_ proto: Ubo_V1_PromptViewData) -> PromptViewData {
        var items: [MenuItemData] = []
        if proto.hasItems {
            items = proto.items.items.map { convertMenuItemData($0) }
        }

        return PromptViewData(
            type: proto.hasType ? proto.type : "prompt",
            showStatusBar: proto.hasShowStatusBar ? proto.showStatusBar : false,
            title: proto.hasTitle ? proto.title : "",
            prompt: proto.hasPrompt ? proto.prompt : "",
            icon: proto.hasIcon ? proto.icon : "",
            items: items
        )
    }

    private nonisolated func convertRenderViewData(_ proto: Ubo_V1_RenderViewData) -> RenderViewData {
        var props: [String: RenderPropValue] = [:]
        if proto.hasProps {
            for (key, value) in proto.props.items {
                props[key] = convertRenderPropValue(value)
            }
        }

        var items: [MenuItemData] = []
        if proto.hasItems {
            items = proto.items.items.map { convertMenuItemData($0) }
        }

        return RenderViewData(
            type: proto.hasType ? proto.type : "render",
            showStatusBar: proto.hasShowStatusBar ? proto.showStatusBar : false,
            kind: RenderKind(rawValue: proto.hasKind ? proto.kind : ""),
            title: proto.hasTitle ? proto.title : "",
            props: props,
            items: items,
            streamId: proto.hasStreamID ? proto.streamID : ""
        )
    }

    private nonisolated func convertChatBubbleData(_ proto: Ubo_V1_ChatBubbleData) -> ChatBubbleData {
        ChatBubbleData(
            messageId: proto.hasMessageID ? proto.messageID : "",
            role: proto.hasRole ? proto.role : "assistant",
            alignment: proto.hasAlignment ? proto.alignment : "left",
            kind: proto.hasKind ? proto.kind : "text",
            text: proto.hasText ? proto.text : "",
            color: proto.hasColor ? proto.color : "#ffffff",
            backgroundColor: proto.hasBackgroundColor ? proto.backgroundColor : "#2b2f38",
            pointerKey: proto.hasPointerKey ? proto.pointerKey : "",
            isPlaying: proto.hasIsPlaying ? proto.isPlaying : false,
            waveform: proto.hasWaveform ? proto.waveform.items : []
        )
    }

    private nonisolated func convertChatViewData(_ proto: Ubo_V1_ChatViewData) -> ChatViewData {
        var bubbles: [ChatBubbleData] = []
        if proto.hasBubbles {
            bubbles = proto.bubbles.items.map { convertChatBubbleData($0) }
        }

        var items: [MenuItemData] = []
        if proto.hasItems {
            items = proto.items.items.map { convertMenuItemData($0) }
        }

        return ChatViewData(
            type: proto.hasType ? proto.type : "chat",
            showStatusBar: proto.hasShowStatusBar ? proto.showStatusBar : false,
            bubbles: bubbles,
            items: items,
            scrollOffset: proto.hasScrollOffset ? Int(proto.scrollOffset) : 0,
            totalBubbles: proto.hasTotalBubbles ? Int(proto.totalBubbles) : 0,
            stackDepth: proto.hasStackDepth ? Int(proto.stackDepth) : 1
        )
    }

    private nonisolated func convertRenderPropValue(_ value: Ubo_V1_RenderViewData.PropsValue) -> RenderPropValue {
        switch value.propsValue {
        case .basicType(let basicType):
            return convertBasicTypeTyped(basicType)
        case .list(let list):
            return .list(list.items.map { convertBasicTypeTyped($0) })
        case nil:
            return .string("")
        }
    }

    private nonisolated func convertStatusBarData(_ proto: Ubo_V1_StatusBarData) -> StatusBarData {
        var progressNotifications: [ProgressNotificationData] = []
        if proto.hasProgressNotifications {
            progressNotifications = proto.progressNotifications.items.map { item in
                ProgressNotificationData(
                    id: item.id,
                    progress: item.hasProgress ? item.progress : nil,
                    color: item.color
                )
            }
        }

        var icons: [StatusIconData] = []
        if proto.hasIcons {
            icons = proto.icons.items.map { item in
                StatusIconData(symbol: item.symbol, color: item.color)
            }
        }

        return StatusBarData(
            title: proto.hasTitle ? proto.title : "",
            isRecording: proto.hasIsRecording ? proto.isRecording : false,
            isReplaying: proto.hasIsReplaying ? proto.isReplaying : false,
            isRecordingAudio: proto.hasIsRecordingAudio ? proto.isRecordingAudio : false,
            progressNotifications: progressNotifications,
            clock: proto.hasClock ? proto.clock : "",
            temperature: proto.hasTemperature ? proto.temperature : nil,
            lightLevel: proto.hasLightLevel ? proto.lightLevel : nil,
            icons: icons
        )
    }

    // MARK: - Event Subscription

    /// Subscribe to display render events
    public func subscribeToDisplayRenderEvents() -> AsyncThrowingStream<DisplayRenderData, Error> {
        // Render events are partial-rect updates, so the buffer is generous —
        // dropping one leaves a stale region until the next paint. It only
        // trims when the consumer has stalled for dozens of frames.
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let task = Task {
                await self.runWithRetry {
                    try await self.streamDisplayRenderEvents(continuation: continuation)
                } onFinalError: { error in
                    continuation.finish(throwing: UboError.subscriptionFailed(error))
                } onCancelled: {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamDisplayRenderEvents(
        continuation: AsyncThrowingStream<DisplayRenderData, Error>.Continuation
    ) async throws {
        guard let client = self.storeClient else {
            throw UboError.notConnected
        }

        var requestBuilder = Store_V1_SubscribeEventRequest()
        var eventBuilder = Ubo_V1_Event()
        eventBuilder.displayRenderEvent = Ubo_V1_DisplayRenderEvent()
        requestBuilder.events = [eventBuilder]
        let request = requestBuilder

        try await client.subscribeEvent(request) { response in
            switch response.accepted {
            case .success(let contents):
                for try await message in contents.bodyParts {
                    if case .message(let subscribeResponse) = message {
                        await self.markConnected()
                        if case .displayRenderEvent(let renderEvent) = subscribeResponse.event.event {
                            let data = DisplayRenderData(
                                timestamp: 0,
                                data: renderEvent.data,
                                rectangle: (
                                    y1: Int(renderEvent.rectangle[safe: 0] ?? 0),
                                    x1: Int(renderEvent.rectangle[safe: 1] ?? 0),
                                    y2: Int(renderEvent.rectangle[safe: 2] ?? 0),
                                    x2: Int(renderEvent.rectangle[safe: 3] ?? 0)
                                ),
                                density: 1.0
                            )
                            continuation.yield(data)
                        }
                    }
                }
            case .failure(let error):
                throw error
            }
        }
    }

    // MARK: - Audio Playback Subscription

    /// Subscribe to the device's playback event stream — one-shot samples,
    /// indexed sequence chunks (TTS / file playback), and stop signals — so
    /// the connected client can route audio to its own speaker. Mirrors the
    /// three events the Web UI handles in `audio.ts`.
    public func subscribeToPlaybackEvents() -> AsyncThrowingStream<PlaybackEvent, Error> {
        // Audio chunks: large enough to absorb bursts without dropping
        // audible samples, bounded so a stalled consumer can't grow memory.
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            let task = Task {
                await self.runWithRetry {
                    try await self.streamPlaybackEvents(continuation: continuation)
                } onFinalError: { error in
                    continuation.finish(throwing: UboError.subscriptionFailed(error))
                } onCancelled: {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamPlaybackEvents(
        continuation: AsyncThrowingStream<PlaybackEvent, Error>.Continuation
    ) async throws {
        guard let client = self.storeClient else {
            throw UboError.notConnected
        }

        var requestBuilder = Store_V1_SubscribeEventRequest()

        var sampleEvent = Ubo_V1_Event()
        sampleEvent.audioPlayAudioSampleEvent = Ubo_V1_AudioPlayAudioSampleEvent()

        var sequenceEvent = Ubo_V1_Event()
        sequenceEvent.audioPlayAudioSequenceEvent = Ubo_V1_AudioPlayAudioSequenceEvent()

        var stopEvent = Ubo_V1_Event()
        stopEvent.audioStopPlaybackEvent = Ubo_V1_AudioStopPlaybackEvent()

        requestBuilder.events = [sampleEvent, sequenceEvent, stopEvent]
        let request = requestBuilder

        try await client.subscribeEvent(request) { response in
            switch response.accepted {
            case .success(let contents):
                for try await message in contents.bodyParts {
                    if case .message(let subscribeResponse) = message {
                        await self.markConnected()
                        switch subscribeResponse.event.event {
                        case .audioPlayAudioSampleEvent(let event):
                            let sample = event.sample
                            continuation.yield(.sample(
                                sample: AudioSampleData(
                                    data: sample.data,
                                    channels: Int(sample.channels),
                                    rate: Int(sample.rate),
                                    width: Int(sample.width)
                                ),
                                volume: event.volume
                            ))
                        case .audioPlayAudioSequenceEvent(let event):
                            let payload: AudioSampleData? = event.hasSample
                                ? AudioSampleData(
                                    data: event.sample.data,
                                    channels: Int(event.sample.channels),
                                    rate: Int(event.sample.rate),
                                    width: Int(event.sample.width)
                                )
                                : nil
                            continuation.yield(.sequence(
                                id: event.id,
                                index: Int(event.index),
                                sample: payload,
                                volume: event.volume
                            ))
                        case .audioStopPlaybackEvent:
                            continuation.yield(.stop)
                        default:
                            break
                        }
                    }
                }
            case .failure(let error):
                throw error
            }
        }
    }

    // MARK: - Active Inputs Subscription

    /// Subscribe to the current set of pending `WebUIInputDescription`s
    /// stored in `state.web_ui.active_inputs`. Each yielded array is a full
    /// snapshot — newly demanded forms appear as additions, resolved/cancelled
    /// ones disappear.
    public func subscribeToActiveInputs() -> AsyncThrowingStream<[WebUIInputDescription], Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            let task = Task {
                await self.runWithRetry {
                    try await self.streamActiveInputs(continuation: continuation)
                } onFinalError: { error in
                    continuation.finish(throwing: UboError.subscriptionFailed(error))
                } onCancelled: {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamActiveInputs(
        continuation: AsyncThrowingStream<[WebUIInputDescription], Error>.Continuation
    ) async throws {
        guard let client = self.storeClient else {
            throw UboError.notConnected
        }

        // The Python gRPC server rejects selectors that return Sequences
        // (`store_service.py::_pack_to_any`), so we subscribe to the parent
        // `state.web_ui` slice and unpack the `active_inputs` field on the
        // Swift side. See `unpackActiveInputs(from:)`.
        var request = Store_V1_SubscribeStoreRequest()
        request.selectors = ["state.web_ui"]

        UboLog.input.debug("subscribing to state.web_ui")
        try await client.subscribeStore(request) { response in
            switch response.accepted {
            case .success(let contents):
                UboLog.input.debug("subscribeStore accepted")
                for try await message in contents.bodyParts {
                    if case .message(let subscribeResponse) = message {
                        await self.markConnected()
                        let inputs = self.unpackActiveInputs(from: subscribeResponse.results)
                        if UboLog.level <= .debug {
                            let typeURLs = subscribeResponse.results.map(\.typeURL)
                            UboLog.input.debug(
                                "got message: typeURLs=\(typeURLs) -> "
                                + "\(inputs.count) input(s) (\(inputs.map(\.id)))"
                            )
                        }
                        continuation.yield(inputs)
                    }
                }
                UboLog.input.debug("stream ended")
            case .failure(let error):
                UboLog.input.error("subscribeStore failed: \(String(describing: error))")
                throw error
            }
        }
    }

    internal nonisolated func unpackActiveInputs(
        from results: [SwiftProtobuf.Google_Protobuf_Any]
    ) -> [WebUIInputDescription] {
        var output: [WebUIInputDescription] = []
        for any in results {
            // Python betterproto renames `WebUIState`/`WebUIInputDescription`
            // to `WebUiState`/`WebUiInputDescription` (lowercase `i`) for
            // the type URL, while swift-protobuf keeps the original casing
            // for the type itself. Compare case-insensitively so the suffix
            // check survives that quirk.
            let suffix = any.typeURL.lowercased()
            if suffix.hasSuffix("webuistate") {
                if let proto = try? Ubo_V1_WebUIState(serializedBytes: any.value) {
                    output.append(contentsOf: proto.activeInputs.map(convertWebUIInputDescription))
                }
            } else if suffix.hasSuffix("webuiinputdescription") {
                if let proto = try? Ubo_V1_WebUIInputDescription(serializedBytes: any.value) {
                    output.append(convertWebUIInputDescription(proto))
                }
            }
        }
        return output
    }

    private nonisolated func convertWebUIInputDescription(
        _ proto: Ubo_V1_WebUIInputDescription
    ) -> WebUIInputDescription {
        var fields: [InputFieldDescription] = []
        if proto.hasFields {
            fields = proto.fields.items.map { f in
                InputFieldDescription(
                    name: f.name,
                    label: f.label,
                    type: InputFieldType(protoValue: f.type.rawValue),
                    description: f.hasDescription_p ? f.description_p : nil,
                    title: f.hasTitle ? f.title : nil,
                    fileMimetype: f.hasFileMimetype ? f.fileMimetype : nil,
                    pattern: f.hasPattern ? f.pattern : nil,
                    defaultValue: f.hasDefaultValue ? f.defaultValue : nil,
                    options: f.hasOptions ? f.options.items : [],
                    required: f.hasRequired ? f.required : false
                )
            }
        }
        return WebUIInputDescription(
            id: proto.hasID ? proto.id : "",
            title: proto.hasTitle ? proto.title : nil,
            prompt: proto.hasPrompt ? proto.prompt : nil,
            fields: fields
        )
    }

    // MARK: - Frame Stream Subscription

    /// A single frame from a `frame_stream` `RenderViewData`.
    public struct FrameStreamFrame: Sendable {
        public let streamId: String
        public let data: Data
        public let width: Int
        public let height: Int
    }

    /// Subscribe to `FrameStreamDataEvent` frames. If `streamId` is non-empty,
    /// only frames belonging to that stream are yielded; otherwise every
    /// frame is yielded.
    public func subscribeToFrameStream(streamId: String = "") -> AsyncThrowingStream<FrameStreamFrame, Error> {
        // Each frame is a complete image — newest-wins with a small buffer.
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let task = Task {
                await self.runWithRetry { [streamId] in
                    try await self.streamFrameStream(filter: streamId, continuation: continuation)
                } onFinalError: { error in
                    continuation.finish(throwing: UboError.subscriptionFailed(error))
                } onCancelled: {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamFrameStream(
        filter: String,
        continuation: AsyncThrowingStream<FrameStreamFrame, Error>.Continuation
    ) async throws {
        guard let client = self.storeClient else {
            throw UboError.notConnected
        }

        var requestBuilder = Store_V1_SubscribeEventRequest()
        var eventBuilder = Ubo_V1_Event()
        eventBuilder.frameStreamDataEvent = Ubo_V1_FrameStreamDataEvent()
        requestBuilder.events = [eventBuilder]
        let request = requestBuilder

        try await client.subscribeEvent(request) { response in
            switch response.accepted {
            case .success(let contents):
                for try await message in contents.bodyParts {
                    if case .message(let subscribeResponse) = message {
                        await self.markConnected()
                        if case .frameStreamDataEvent(let frameEvent) = subscribeResponse.event.event {
                            if !filter.isEmpty && frameEvent.streamID != filter {
                                continue
                            }
                            let frame = FrameStreamFrame(
                                streamId: frameEvent.streamID,
                                data: frameEvent.data,
                                width: Int(frameEvent.width),
                                height: Int(frameEvent.height)
                            )
                            continuation.yield(frame)
                        }
                    }
                }
            case .failure(let error):
                throw error
            }
        }
    }

    // MARK: - Camera Event Subscription

    /// Camera event types received from the device
    public enum CameraEventType: Sendable {
        /// Pi has decided this source should start capturing. `sourceId` is
        /// the registered id of the chosen source — clients should ignore
        /// the event unless it matches their own (or the field is empty,
        /// which means "any source", for backwards compat with old devices).
        case startViewfinder(pattern: String?, sourceId: String)
        case stopViewfinder
        /// Pi tapped "Detect Cameras". Subscribed clients should respond
        /// with `cameraRegisterRemote` to be listed in the picker.
        case detectAdvertise
    }

    /// Subscribe to camera viewfinder events (start/stop)
    public func subscribeToCameraEvents() -> AsyncThrowingStream<CameraEventType, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            let task = Task {
                await self.runWithRetry {
                    try await self.streamCameraEvents(continuation: continuation)
                } onFinalError: { error in
                    continuation.finish(throwing: UboError.subscriptionFailed(error))
                } onCancelled: {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamCameraEvents(
        continuation: AsyncThrowingStream<CameraEventType, Error>.Continuation
    ) async throws {
        guard let client = self.storeClient else {
            throw UboError.notConnected
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            // CameraStartViewfinderEvent
            group.addTask {
                var requestBuilder = Store_V1_SubscribeEventRequest()
                var eventBuilder = Ubo_V1_Event()
                eventBuilder.cameraStartViewfinderEvent = Ubo_V1_CameraStartViewfinderEvent()
                requestBuilder.events = [eventBuilder]
                let request = requestBuilder

                try await client.subscribeEvent(request) { response in
                    switch response.accepted {
                    case .success(let contents):
                        for try await message in contents.bodyParts {
                            if case .message(let subscribeResponse) = message {
                                await self.markConnected()
                                if case .cameraStartViewfinderEvent(let startEvent) = subscribeResponse.event.event {
                                    let pattern: String? = startEvent.hasPattern ? startEvent.pattern : nil
                                    continuation.yield(.startViewfinder(pattern: pattern, sourceId: startEvent.sourceID))
                                }
                            }
                        }
                    case .failure(let error):
                        throw error
                    }
                }
            }

            // CameraStopViewfinderEvent
            group.addTask {
                var requestBuilder = Store_V1_SubscribeEventRequest()
                var eventBuilder = Ubo_V1_Event()
                eventBuilder.cameraStopViewfinderEvent = Ubo_V1_CameraStopViewfinderEvent()
                requestBuilder.events = [eventBuilder]
                let request = requestBuilder

                try await client.subscribeEvent(request) { response in
                    switch response.accepted {
                    case .success(let contents):
                        for try await message in contents.bodyParts {
                            if case .message(let subscribeResponse) = message {
                                await self.markConnected()
                                if case .cameraStopViewfinderEvent(_) = subscribeResponse.event.event {
                                    continuation.yield(.stopViewfinder)
                                }
                            }
                        }
                    case .failure(let error):
                        throw error
                    }
                }
            }

            // CameraDetectAdvertiseEvent — Pi tapped "Detect Cameras";
            // each yield prompts subscribers to (re-)register themselves.
            group.addTask {
                var requestBuilder = Store_V1_SubscribeEventRequest()
                var eventBuilder = Ubo_V1_Event()
                eventBuilder.cameraDetectAdvertiseEvent = Ubo_V1_CameraDetectAdvertiseEvent()
                requestBuilder.events = [eventBuilder]
                let request = requestBuilder

                try await client.subscribeEvent(request) { response in
                    switch response.accepted {
                    case .success(let contents):
                        for try await message in contents.bodyParts {
                            if case .message(let subscribeResponse) = message {
                                await self.markConnected()
                                if case .cameraDetectAdvertiseEvent(_) = subscribeResponse.event.event {
                                    continuation.yield(.detectAdvertise)
                                }
                            }
                        }
                    case .failure(let error):
                        throw error
                    }
                }
            }

            try await group.waitForAll()
        }
    }

    // MARK: - Proto Building

    internal func buildProtoAction(_ action: UboAction) -> Ubo_V1_Action {
        var protoAction = Ubo_V1_Action()

        switch action {
        // The keypad reducer pattern-matches the full pressed set, not just
        // `key` (a bare press is `pressed_keys == {key}`, a combo is
        // `pressed_keys == {key, modifier}`, a release is `pressed_keys == ()`)
        // — mirror the canonical shapes the core's own GUI client sends.
        case .keypadKeyPress(let key, let time):
            var keyPress = Ubo_V1_KeypadKeyPressAction()
            keyPress.key = protoKey(key)
            keyPress.pressedKeys = [protoKey(key)]
            keyPress.time = Float(time)
            protoAction.keypadKeyPressAction = keyPress

        case .keypadKeyPressMultiple(let key, let modifiers, let time):
            var keyPress = Ubo_V1_KeypadKeyPressAction()
            keyPress.key = protoKey(key)
            keyPress.pressedKeys = ([key] + modifiers.subtracting([key]).sorted { $0.rawValue < $1.rawValue }).map(protoKey)
            keyPress.time = Float(time)
            protoAction.keypadKeyPressAction = keyPress

        case .keypadKeyRelease(let key, let time):
            var keyRelease = Ubo_V1_KeypadKeyReleaseAction()
            keyRelease.key = protoKey(key)
            keyRelease.time = Float(time)
            protoAction.keypadKeyReleaseAction = keyRelease

        case .keypadKeyHold(let key, let time):
            var keyHold = Ubo_V1_KeypadKeyHoldAction()
            keyHold.key = protoKey(key)
            keyHold.pressedKeys = [protoKey(key)]
            var heldKeys = Ubo_V1_KeypadKeyHoldAction.HeldKeys()
            heldKeys.items = [protoKey(key)]
            keyHold.heldKeys = heldKeys
            keyHold.time = Float(time)
            protoAction.keypadKeyHoldAction = keyHold

        case .keypadKeyUnhold(let key, let time):
            var keyUnhold = Ubo_V1_KeypadKeyUnholdAction()
            keyUnhold.key = protoKey(key)
            keyUnhold.time = Float(time)
            protoAction.keypadKeyUnholdAction = keyUnhold

        case .audioSetVolume(let level, let device):
            var setVolume = Ubo_V1_AudioSetVolumeAction()
            setVolume.volume = level
            setVolume.device = Ubo_V1_AudioDevice(rawValue: Int(device.protoValue)) ?? .uboAppDotStoreDotServicesDotAudioUnspecified
            protoAction.audioSetVolumeAction = setVolume

        case .audioChangeVolume(let change, let device):
            var changeVolume = Ubo_V1_AudioChangeVolumeAction()
            changeVolume.amount = change
            changeVolume.device = Ubo_V1_AudioDevice(rawValue: Int(device.protoValue)) ?? .uboAppDotStoreDotServicesDotAudioUnspecified
            protoAction.audioChangeVolumeAction = changeVolume

        case .audioSetMute(let muted, let device):
            var setMute = Ubo_V1_AudioSetMuteStatusAction()
            setMute.isMute = muted
            setMute.device = Ubo_V1_AudioDevice(rawValue: Int(device.protoValue)) ?? .uboAppDotStoreDotServicesDotAudioUnspecified
            protoAction.audioSetMuteStatusAction = setMute

        case .audioToggleMute(let device):
            var toggleMute = Ubo_V1_AudioToggleMuteStatusAction()
            toggleMute.device = Ubo_V1_AudioDevice(rawValue: Int(device.protoValue)) ?? .uboAppDotStoreDotServicesDotAudioUnspecified
            protoAction.audioToggleMuteStatusAction = toggleMute

        case .audioPlayChime(let chime):
            var playChime = Ubo_V1_AudioPlayChimeAction()
            playChime.name = chime.rawValue
            protoAction.audioPlayChimeAction = playChime

        case .audioReportSample(let timestamp, let sample, let audioSource):
            var reportSample = Ubo_V1_AudioReportSampleAction()
            reportSample.timestamp = timestamp
            // The assistant pipeline consumes `sample_speech_recognition` (raw
            // PCM16 bytes), NOT the `sample` AudioSample (that feeds the audio
            // recording path). The Web UI sets this; we must too, or the core
            // pushes empty frames and nothing reaches the assistant.
            reportSample.sampleSpeechRecognition = sample.data
            var protoSample = Ubo_V1_AudioSample()
            protoSample.data = sample.data
            protoSample.channels = Int64(sample.channels)
            protoSample.rate = Int64(sample.rate)
            protoSample.width = Int64(sample.width)
            reportSample.sample = protoSample
            reportSample.audioSource = audioSource
            protoAction.audioReportSampleAction = reportSample

        case .audioStartRecording:
            protoAction.audioStartRecordingAction = Ubo_V1_AudioStartRecordingAction()

        case .audioStopRecording:
            protoAction.audioStopRecordingAction = Ubo_V1_AudioStopRecordingAction()

        case .audioPlayRecording:
            protoAction.audioPlayRecordingAction = Ubo_V1_AudioPlayRecordingAction()

        case .inputProvide(let id, let value, let data):
            var provide = Ubo_V1_InputProvideAction()
            provide.id = id
            provide.value = value
            // Always attach a result, even for single-field forms: server
            // handlers for multi-field WebUIInputDescription forms read
            // result.data, not value (mirrors the Web UI's inputs.tsx).
            var result = Ubo_V1_InputResult()
            result.data = data
            result.method = .webDashboard
            provide.result = result
            protoAction.inputProvideAction = provide

        case .inputCancel(let id):
            var cancel = Ubo_V1_InputCancelAction()
            cancel.id = id
            protoAction.inputCancelAction = cancel

        case .fileUploadStart(let uploadId, let filename, let totalSize, let totalChunks, let chunkSize):
            var start = Ubo_V1_FileUploadStartAction()
            start.uploadID = uploadId
            start.filename = filename
            start.totalSize = Int64(totalSize)
            start.totalChunks = Int64(totalChunks)
            start.chunkSize = Int64(chunkSize)
            protoAction.fileUploadStartAction = start

        case .fileUploadChunk(let uploadId, let chunkIndex, let data):
            var chunk = Ubo_V1_FileUploadChunkAction()
            chunk.uploadID = uploadId
            chunk.chunkIndex = Int64(chunkIndex)
            chunk.data = data
            protoAction.fileUploadChunkAction = chunk

        case .fileUploadComplete(let uploadId):
            var complete = Ubo_V1_FileUploadCompleteAction()
            complete.uploadID = uploadId
            protoAction.fileUploadCompleteAction = complete

        case .stackPushMenu(let menuKey):
            var pushMenu = Ubo_V1_StackPushMenuAction()
            pushMenu.menuKey = menuKey
            protoAction.stackPushMenuAction = pushMenu

        case .stackPop(let count):
            var pop = Ubo_V1_StackPopAction()
            pop.count = Int64(count)
            protoAction.stackPopAction = pop

        case .stackPopToRoot:
            protoAction.stackPopToRootAction = Ubo_V1_StackPopToRootAction()

        case .displayPause:
            protoAction.displayPauseAction = Ubo_V1_DisplayPauseAction()

        case .displayResume:
            protoAction.displayResumeAction = Ubo_V1_DisplayResumeAction()

        case .rgbRingSetAll(let color):
            var setAll = Ubo_V1_RgbRingSetAllAction()
            setAll.color = buildProtoColor(color)
            protoAction.rgbRingSetAllAction = setAll

        case .rgbRingBlank:
            protoAction.rgbRingBlankAction = Ubo_V1_RgbRingBlankAction()

        case .rgbRingSetBrightness(let level):
            var setBrightness = Ubo_V1_RgbRingSetBrightnessAction()
            setBrightness.brightness = level
            protoAction.rgbRingSetBrightnessAction = setBrightness

        case .rgbRingRainbow(let rounds, let wait):
            var rainbow = Ubo_V1_RgbRingRainbowAction()
            rainbow.rounds = Int64(rounds)
            rainbow.wait = Int64(wait)
            protoAction.rgbRingRainbowAction = rainbow

        case .notificationAdd(let notification):
            var addAction = Ubo_V1_NotificationsAddAction()
            addAction.notification = buildProtoNotification(notification)
            protoAction.notificationsAddAction = addAction

        case .notificationRemove(let id):
            var clearById = Ubo_V1_NotificationsClearByIdAction()
            clearById.id = id
            protoAction.notificationsClearByIDAction = clearById

        case .notificationClearAll:
            protoAction.notificationsClearAllAction = Ubo_V1_NotificationsClearAllAction()

        case .notificationDisplay(let notification):
            var displayAction = Ubo_V1_NotificationsDisplayAction()
            displayAction.notification = buildProtoNotification(notification)
            protoAction.notificationsDisplayAction = displayAction

        // MARK: Menu Navigation Actions
        case .menuGoBack:
            protoAction.menuGoBackAction = Ubo_V1_MenuGoBackAction()

        case .menuGoHome:
            protoAction.menuGoHomeAction = Ubo_V1_MenuGoHomeAction()

        case .menuChooseByIndex(let index):
            var chooseByIndex = Ubo_V1_MenuChooseByIndexAction()
            chooseByIndex.index = Int64(index)
            protoAction.menuChooseByIndexAction = chooseByIndex

        case .menuChooseByLabel(let label):
            var chooseByLabel = Ubo_V1_MenuChooseByLabelAction()
            chooseByLabel.label = label
            protoAction.menuChooseByLabelAction = chooseByLabel

        case .menuChooseByIcon(let icon):
            var chooseByIcon = Ubo_V1_MenuChooseByIconAction()
            chooseByIcon.icon = icon
            protoAction.menuChooseByIconAction = chooseByIcon

        case .executeMenuAction(let actionId, let menuKey):
            var executeAction = Ubo_V1_ExecuteMenuActionAction()
            executeAction.actionID = actionId
            if let menuKey {
                executeAction.menuKey = menuKey
            }
            protoAction.executeMenuActionAction = executeAction

        case .menuScrollUp:
            var scroll = Ubo_V1_MenuScrollAction()
            scroll.direction = .up
            protoAction.menuScrollAction = scroll

        case .menuScrollDown:
            var scroll = Ubo_V1_MenuScrollAction()
            scroll.direction = .down
            protoAction.menuScrollAction = scroll

        case .displayBlank:
            protoAction.displayBlankAction = Ubo_V1_DisplayBlankAction()

        case .displayUnblank:
            protoAction.displayUnblankAction = Ubo_V1_DisplayUnblankAction()

        case .displayRedraw:
            protoAction.displayRedrawAction = Ubo_V1_DisplayRedrawAction()

        case .displaySetBlankTimeout(let timeout):
            var setTimeout = Ubo_V1_DisplaySetBlankTimeoutAction()
            setTimeout.timeout = Ubo_V1_DisplayBlankTimeout(rawValue: Int(timeout.protoValue)) ?? .uboAppDotStoreDotServicesDotDisplayUnspecified
            protoAction.displaySetBlankTimeoutAction = setTimeout

        case .assistantStartListening(let audioSource):
            var startListening = Ubo_V1_AssistantStartListeningAction()
            startListening.audioSource = audioSource
            protoAction.assistantStartListeningAction = startListening

        case .assistantStopListening:
            protoAction.assistantStopListeningAction = Ubo_V1_AssistantStopListeningAction()

        case .assistantToggleListening(let audioSource):
            var toggleListening = Ubo_V1_AssistantToggleListeningAction()
            toggleListening.audioSource = audioSource
            protoAction.assistantToggleListeningAction = toggleListening

        case .rgbRingPulse(let color, let repetitions, let wait):
            var pulse = Ubo_V1_RgbRingPulseAction()
            pulse.color = buildProtoColor(color)
            pulse.repetitions = Int64(repetitions)
            pulse.wait = Int64(wait * 1000)  // Convert seconds to milliseconds
            protoAction.rgbRingPulseAction = pulse

        case .rgbRingBlink(let color, let repetitions, let wait):
            var blink = Ubo_V1_RgbRingBlinkAction()
            blink.color = buildProtoColor(color)
            blink.repetitions = Int64(repetitions)
            blink.wait = Int64(wait * 1000)  // Convert seconds to milliseconds
            protoAction.rgbRingBlinkAction = blink

        case .rgbRingSpinningWheel(let color, let rounds, let length, let wait):
            var spinningWheel = Ubo_V1_RgbRingSpinningWheelAction()
            spinningWheel.color = buildProtoColor(color)
            spinningWheel.repetitions = Int64(rounds)
            spinningWheel.length = Int64(length)
            spinningWheel.wait = Int64(wait * 1000)  // Convert seconds to milliseconds
            protoAction.rgbRingSpinningWheelAction = spinningWheel

        case .rgbRingProgressWheel(let color, let percentage):
            var progressWheel = Ubo_V1_RgbRingProgressWheelAction()
            progressWheel.color = buildProtoColor(color)
            progressWheel.percentage = Float(percentage)
            protoAction.rgbRingProgressWheelAction = progressWheel

        case .rgbRingSetEnabled(let enabled):
            var setEnabled = Ubo_V1_RgbRingSetEnabledAction()
            setEnabled.enabled = enabled
            protoAction.rgbRingSetEnabledAction = setEnabled

        case .powerOff:
            protoAction.powerOffAction = Ubo_V1_PowerOffAction()

        case .reboot:
            protoAction.rebootAction = Ubo_V1_RebootAction()

        case .cameraRegisterRemote(let sourceId, let label):
            var register = Ubo_V1_CameraRegisterRemoteAction()
            register.sourceID = sourceId
            register.label = label
            protoAction.cameraRegisterRemoteAction = register

        case .cameraReportImage(let timestamp, let data, let width, let height, let sourceId):
            var reportImage = Ubo_V1_CameraReportImageAction()
            reportImage.timestamp = timestamp
            reportImage.data = data
            reportImage.width = Int64(width)
            reportImage.height = Int64(height)
            reportImage.sourceID = sourceId
            protoAction.cameraReportImageAction = reportImage

        case .chatToggleAudioPlayback(let messageId):
            var toggle = Ubo_V1_ChatToggleAudioPlaybackAction()
            toggle.messageID = messageId
            protoAction.chatToggleAudioPlaybackAction = toggle
        }
        // No `default:` — the switch is deliberately exhaustive so adding a
        // `UboAction` case without a proto mapping is a compile error instead
        // of a silently-dispatched empty action.

        return protoAction
    }

    private func protoKey(_ key: Key) -> Ubo_V1_Key {
        Ubo_V1_Key(rawValue: Int(key.protoValue)) ?? .uboAppDotStoreDotServicesDotKeypadUnspecified
    }

    private func buildProtoColor(_ color: UboColor) -> Ubo_V1_RgbColor {
        var protoColor = Ubo_V1_RgbColor()
        var redElement = Ubo_V1_RgbColorElement()
        redElement.int64 = Int64(color.red)
        var greenElement = Ubo_V1_RgbColorElement()
        greenElement.int64 = Int64(color.green)
        var blueElement = Ubo_V1_RgbColorElement()
        blueElement.int64 = Int64(color.blue)
        protoColor.items = [redElement, greenElement, blueElement]
        return protoColor
    }

    private func buildProtoNotification(_ notification: UboNotification) -> Ubo_V1_Notification {
        var proto = Ubo_V1_Notification()
        proto.id = notification.id
        proto.title = notification.title
        proto.content = notification.content
        if let icon = notification.icon {
            proto.icon = icon
        }
        if let color = notification.color {
            proto.color = color.hexString
        }
        if let chime = notification.chime {
            proto.chime = Ubo_V1_Chime(rawValue: Int(chime.protoValue)) ?? .uboAppDotStoreDotServicesDotNotificationsUnspecified
        }
        proto.showDismissAction = notification.dismissable
        proto.importance = Ubo_V1_Importance(rawValue: Int(notification.importance.protoValue)) ?? .uboAppDotStoreDotServicesDotNotificationsUnspecified
        proto.displayType = Ubo_V1_NotificationDisplayType(rawValue: Int(notification.displayType.protoValue)) ?? .uboAppDotStoreDotServicesDotNotificationsUnspecified
        return proto
    }
}

// MARK: - Array Safe Subscript

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
