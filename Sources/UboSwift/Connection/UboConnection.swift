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

    public init() {}

    // MARK: - Connection Management

    /// Connect to an Ubo device
    /// - Parameters:
    ///   - host: Device hostname or IP address
    ///   - port: gRPC port (default: 50051)
    public func connect(host: String, port: Int = 50051) async throws {
        self.host = host
        self.port = port
        state = .connecting

        do {
            // Create the transport
            // Use DNS resolution which handles both IPv4 and IPv6 (important for .local mDNS names)
            let transport = try HTTP2ClientTransport.Posix(
                target: .dns(host: host, port: port),
                transportSecurity: .plaintext
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

    // MARK: - Store Subscription

    /// Subscribe to store state changes for view data and status bar
    /// - Parameter selectors: List of state selectors (e.g., ["state.main.current_view", "state.main.status_bar"])
    /// - Returns: An async stream of (ViewData, StatusBarData?) tuples
    public func subscribeToStoreChanges(selectors: [String] = ["state.main.current_view", "state.main.status_bar"]) -> AsyncThrowingStream<(ViewData, StatusBarData?), Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard let client = self.storeClient else {
                    continuation.finish(throwing: UboError.notConnected)
                    return
                }

                // Create subscription request
                var request = Store_V1_SubscribeStoreRequest()
                request.selectors = selectors

                do {
                    try await client.subscribeStore(request) { response in
                        switch response.accepted {
                        case .success(let contents):
                            for try await message in contents.bodyParts {
                                if case .message(let subscribeResponse) = message {
                                    // Unpack the results from google.protobuf.Any
                                    let results = subscribeResponse.results

                                    // First result should be ViewData, second should be StatusBarData
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
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: UboError.subscriptionFailed(error))
                }
            }
        }
    }

    /// Subscribe to system stats (CPU, RAM, clock, temperature) - updates continuously regardless of current view
    /// - Returns: An async stream of SystemStats
    public func subscribeToSystemStats() -> AsyncThrowingStream<SystemStats, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard let client = self.storeClient else {
                    continuation.finish(throwing: UboError.notConnected)
                    return
                }

                // Create subscription request for system state and sensors
                var request = Store_V1_SubscribeStoreRequest()
                request.selectors = ["state.system", "state.sensors"]

                // Use actor-isolated state holder to safely track stats across updates
                let statsHolder = StatsHolder()

                do {
                    try await client.subscribeStore(request) { response in
                        switch response.accepted {
                        case .success(let contents):
                            for try await message in contents.bodyParts {
                                if case .message(let subscribeResponse) = message {
                                    let results = subscribeResponse.results

                                    var cpuPercent: Float?
                                    var ramPercent: Float?
                                    var clock: String?
                                    var temperature: Float?

                                    for result in results {
                                        // Try to parse as SystemState
                                        if let stats = self.unpackSystemStats(from: result) {
                                            cpuPercent = stats.cpuPercent
                                            ramPercent = stats.ramPercent
                                            clock = stats.clock
                                        }
                                        // Try to parse as SensorsState for temperature
                                        if let temp = self.unpackTemperature(from: result) {
                                            temperature = temp
                                        }
                                    }

                                    // Update and get merged stats
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
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: UboError.subscriptionFailed(error))
                }
            }
        }
    }

    // MARK: - Proto Unpacking

    /// Unpack a google.protobuf.Any message to ViewData
    private nonisolated func unpackViewData(from any: SwiftProtobuf.Google_Protobuf_Any) -> ViewData? {
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
            extraData = proto.extraData.items
        }

        return ApplicationViewData(
            type: proto.hasType ? proto.type : "application",
            showStatusBar: proto.hasShowStatusBar ? proto.showStatusBar : false,
            applicationId: proto.hasApplicationID ? proto.applicationID : "",
            extraData: extraData
        )
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
            Task {
                guard let client = self.storeClient else {
                    continuation.finish(throwing: UboError.notConnected)
                    return
                }

                // Create subscription request for DisplayRenderEvent
                var requestBuilder = Store_V1_SubscribeEventRequest()
                var eventBuilder = Ubo_V1_Event()
                eventBuilder.displayRenderEvent = Ubo_V1_DisplayRenderEvent()
                requestBuilder.event = eventBuilder
                let request = requestBuilder

                do {
                    try await client.subscribeEvent(request) { response in
                        switch response.accepted {
                        case .success(let contents):
                            for try await message in contents.bodyParts {
                                if case .message(let subscribeResponse) = message {
                                    // Check if this is a display render event
                                    if case .displayRenderEvent(let renderEvent) = subscribeResponse.event.event {
                                        let data = DisplayRenderData(
                                            timestamp: 0, // Not available in proto
                                            data: renderEvent.data,
                                            rectangle: (
                                                y1: Int(renderEvent.rectangle[safe: 0] ?? 0),
                                                x1: Int(renderEvent.rectangle[safe: 1] ?? 0),
                                                y2: Int(renderEvent.rectangle[safe: 2] ?? 0),
                                                x2: Int(renderEvent.rectangle[safe: 3] ?? 0)
                                            ),
                                            density: 1.0 // Default density
                                        )
                                        continuation.yield(data)
                                    }
                                }
                            }
                        case .failure(let error):
                            throw error
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: UboError.subscriptionFailed(error))
                }
            }
        }
    }

    // MARK: - Proto Building

    private func buildProtoAction(_ action: UboAction) -> Ubo_V1_Action {
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
