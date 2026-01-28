import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import SwiftProtobuf

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
            let transport = try HTTP2ClientTransport.Posix(
                target: .ipv4(host: host, port: port),
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

            state = .connected
        } catch {
            state = .disconnected
            throw UboError.connectionFailed(error)
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
        proto.dismissable = notification.dismissable
        if let progress = notification.progress {
            proto.progress = progress
        }
        return proto
    }
}

// MARK: - Array Safe Subscript

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
