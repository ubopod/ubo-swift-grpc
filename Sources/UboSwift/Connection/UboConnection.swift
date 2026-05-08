import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import SwiftProtobuf

/// Actor to safely hold and merge system stats across async updates
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
private actor StatsHolder {
    private var stats = SystemStats()

    func update(
        cpuPercent: Float?,
        ramPercent: Float?,
        clock: String?,
        temperature: Float?
    ) -> SystemStats {
        if let cpu = cpuPercent { stats.cpuPercent = cpu }
        if let ram = ramPercent { stats.ramPercent = ram }
        if let clk = clock { stats.clock = clk }
        if let temp = temperature { stats.temperature = temp }
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

        while !Task.isCancelled {
            do {
                try await body()
                // Body returned without error: server closed the stream.
                // Treat as a soft retry — back off then re-subscribe.
                attempt += 1
            } catch is CancellationError {
                onCancelled()
                return
            } catch {
                attempt += 1
                if attempt >= policy.maxRetries {
                    onFinalError(error)
                    return
                }
                self.markReconnecting()
            }

            let delaySeconds = policy.delaySeconds(forAttempt: attempt)
            if delaySeconds > 0 {
                let nanos = UInt64(delaySeconds * 1_000_000_000)
                do {
                    try await Task.sleep(nanoseconds: nanos)
                } catch {
                    onCancelled()
                    return
                }
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

            // Verify the connection is actually ready by attempting a lightweight probe
            // Try up to 10 times with 500ms intervals (5 seconds total)
            var connectionVerified = false
            var lastError: Error?

            for _ in 1...10 {
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
                state = .disconnected
                throw UboError.connectionFailed(lastError ?? NSError(domain: "UboConnection", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to verify connection after 5 seconds"]))
            }

            state = .connected
        } catch let error as UboError {
            state = .disconnected
            throw error
        } catch {
            state = .disconnected
            throw UboError.connectionFailed(error)
        }
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
                    throw UboError.connectionFailed(NSError(domain: "UboConnection", code: -1, userInfo: [NSLocalizedDescriptionKey: "Connection test timeout"]))
                }

                // Wait for first to complete
                try await group.next()
                group.cancelAll()
            }

            return .success
        } catch {
            let errorStr = String(describing: error).lowercased()
            let isNotReady = errorStr.contains("channel") ||
                             errorStr.contains("unavailable") ||
                             errorStr.contains("not ready") ||
                             errorStr.contains("transport")

            if isNotReady {
                return .notReady(error)
            } else {
                return .failed(error)
            }
        }
    }

    /// Disconnect from the device
    public func disconnect() async {
        grpcClient?.beginGracefulShutdown()
        clientTask?.cancel()
        clientTask = nil
        grpcClient = nil
        storeClient = nil
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

    // MARK: - Event Dispatch

    /// Dispatch an event to the device
    public func dispatchEvent(_ event: Ubo_V1_Event) async throws {
        guard let client = storeClient else {
            throw UboError.notConnected
        }

        var request = Store_V1_DispatchEventRequest()
        request.event = event

        do {
            _ = try await client.dispatchEvent(request)
        } catch {
            throw UboError.dispatchFailed(error)
        }
    }

    // MARK: - Store Subscription

    /// Subscribe to store state changes for view data and status bar
    /// - Parameter selectors: List of state selectors (e.g., ["state.main.current_view", "state.main.status_bar"])
    /// - Returns: An async stream of (ViewData, StatusBarData?) tuples
    public func subscribeToStoreChanges(selectors: [String] = ["state.main.current_view", "state.main.status_bar"]) -> AsyncThrowingStream<(ViewData, StatusBarData?), Error> {
        AsyncThrowingStream { continuation in
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

    /// Subscribe to system stats (CPU, RAM, clock, temperature) - updates continuously regardless of current view
    /// - Returns: An async stream of SystemStats
    public func subscribeToSystemStats() -> AsyncThrowingStream<SystemStats, Error> {
        // Stats accumulator survives across retries so partial updates (e.g.
        // a SensorsState that only carries temperature) keep the previous
        // CPU/RAM values.
        let statsHolder = StatsHolder()
        return AsyncThrowingStream { continuation in
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
        request.selectors = ["state.system", "state.sensors"]

        try await client.subscribeStore(request) { response in
            switch response.accepted {
            case .success(let contents):
                for try await message in contents.bodyParts {
                    if case .message(let subscribeResponse) = message {
                        await self.markConnected()
                        let results = subscribeResponse.results

                        var cpuPercent: Float?
                        var ramPercent: Float?
                        var clock: String?
                        var temperature: Float?

                        for result in results {
                            if let stats = self.unpackSystemStats(from: result) {
                                cpuPercent = stats.cpuPercent
                                ramPercent = stats.ramPercent
                                clock = stats.clock
                            }
                            if let temp = self.unpackTemperature(from: result) {
                                temperature = temp
                            }
                        }

                        let mergedStats = await statsHolder.update(
                            cpuPercent: cpuPercent,
                            ramPercent: ramPercent,
                            clock: clock,
                            temperature: temperature
                        )
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

    /// Unpack a google.protobuf.Any message to SystemStats
    private nonisolated func unpackSystemStats(from any: SwiftProtobuf.Google_Protobuf_Any) -> SystemStats? {
        let typeURL = any.typeURL

        if typeURL.hasSuffix("SystemState") {
            if let proto = try? Ubo_V1_SystemState(serializedBytes: any.value) {
                return SystemStats(
                    cpuPercent: proto.hasCpuPercent ? proto.cpuPercent : 0,
                    ramPercent: proto.hasRamPercent ? proto.ramPercent : 0,
                    clock: proto.hasClock ? proto.clock : ""
                )
            }
        }

        return nil
    }

    /// Unpack temperature from SensorsState
    private nonisolated func unpackTemperature(from any: SwiftProtobuf.Google_Protobuf_Any) -> Float? {
        let typeURL = any.typeURL

        if typeURL.hasSuffix("SensorsState") {
            if let proto = try? Ubo_V1_SensorsState(serializedBytes: any.value) {
                if proto.hasTemperature && proto.temperature.hasValue {
                    return proto.temperature.value
                }
            }
        }

        return nil
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
        AsyncThrowingStream { continuation in
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
        AsyncThrowingStream { continuation in
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
        AsyncThrowingStream { continuation in
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
        AsyncThrowingStream { continuation in
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
        case startViewfinder(pattern: String?)
        case stopViewfinder
    }

    /// Subscribe to camera viewfinder events (start/stop)
    public func subscribeToCameraEvents() -> AsyncThrowingStream<CameraEventType, Error> {
        AsyncThrowingStream { continuation in
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
                                    continuation.yield(.startViewfinder(pattern: pattern))
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

            try await group.waitForAll()
        }
    }

    // MARK: - Proto Building

    internal func buildProtoAction(_ action: UboAction) -> Ubo_V1_Action {
        var protoAction = Ubo_V1_Action()

        switch action {
        case .keypadKeyPress(let key, let time):
            var keyPress = Ubo_V1_KeypadKeyPressAction()
            keyPress.key = Ubo_V1_Key(rawValue: Int(key.protoValue)) ?? .uboAppDotStoreDotServicesDotKeypadUnspecified
            keyPress.time = Float(time)
            protoAction.keypadKeyPressAction = keyPress

        case .keypadKeyRelease(let key, let time):
            var keyRelease = Ubo_V1_KeypadKeyReleaseAction()
            keyRelease.key = Ubo_V1_Key(rawValue: Int(key.protoValue)) ?? .uboAppDotStoreDotServicesDotKeypadUnspecified
            keyRelease.time = Float(time)
            protoAction.keypadKeyReleaseAction = keyRelease

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

        case .audioReportSample(let timestamp, let sample):
            var reportSample = Ubo_V1_AudioReportSampleAction()
            reportSample.timestamp = timestamp
            var protoSample = Ubo_V1_AudioSample()
            protoSample.data = sample.data
            protoSample.channels = Int64(sample.channels)
            protoSample.rate = Int64(sample.rate)
            protoSample.width = Int64(sample.width)
            reportSample.sample = protoSample
            protoAction.audioReportSampleAction = reportSample

        case .inputProvide(let id, let value):
            var provide = Ubo_V1_InputProvideAction()
            provide.id = id
            provide.value = value
            protoAction.inputProvideAction = provide

        case .inputCancel(let id):
            var cancel = Ubo_V1_InputCancelAction()
            cancel.id = id
            protoAction.inputCancelAction = cancel

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

        case .assistantStartListening:
            protoAction.assistantStartListeningAction = Ubo_V1_AssistantStartListeningAction()

        case .assistantStopListening:
            protoAction.assistantStopListeningAction = Ubo_V1_AssistantStopListeningAction()

        case .assistantToggleListening:
            protoAction.assistantToggleListeningAction = Ubo_V1_AssistantToggleListeningAction()

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

        // Handle other action cases with minimal implementation
        default:
            // Unsupported actions will send an empty action
            break
        }

        return protoAction
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
