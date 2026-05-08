import Foundation
import Combine
import GRPCNIOTransportHTTP2

/// Main client for interacting with Ubo devices via gRPC.
///
/// Use this class to connect to an Ubo device, subscribe to display updates,
/// and dispatch actions like button presses, volume changes, and notifications.
///
/// Example usage:
/// ```swift
/// let client = UboClient()
/// try await client.connect(host: "192.168.1.100")
/// try await client.pressKey(.up)
/// ```
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
@MainActor
public final class UboClient: ObservableObject {

    // MARK: - Published State

    /// Current connection state
    @Published public private(set) var connectionState: ConnectionState = .disconnected

    /// Last error encountered
    @Published public private(set) var lastError: UboError?

    /// Current display render data (from DisplayRenderEvent)
    @Published public private(set) var currentDisplay: DisplayRenderData?

    /// Current view data (from SubscribeStore)
    @Published public private(set) var currentView: ViewData?

    /// Current status bar data (from SubscribeStore)
    @Published public private(set) var statusBar: StatusBarData?

    /// Whether the device is recording audio
    @Published public private(set) var isRecording: Bool = false

    /// Current system stats (CPU, RAM, clock) - updated continuously
    @Published public private(set) var systemStats: SystemStats?

    /// Whether the device camera viewfinder is active
    @Published public private(set) var isCameraViewfinderActive: Bool = false

    /// Current camera pattern (e.g. QR code pattern to scan for)
    @Published public private(set) var cameraPattern: String?

    /// Currently pending input demands (drives native InputFormView).
    @Published public private(set) var activeInputs: [WebUIInputDescription] = []

    // MARK: - Private Properties

    private let connection: UboConnection
    private var displaySubscriptionTask: Task<Void, Never>?
    private var viewSubscriptionTask: Task<Void, Never>?
    private var statsSubscriptionTask: Task<Void, Never>?
    private var cameraSubscriptionTask: Task<Void, Never>?
    private var inputsSubscriptionTask: Task<Void, Never>?

    // MARK: - Initialization

    public init() {
        self.connection = UboConnection()
    }

    // MARK: - Connection Management

    /// Connect to an Ubo device
    /// - Parameters:
    ///   - host: Device hostname or IP address
    ///   - port: gRPC port (default: 50051)
    ///   - security: Transport security to use (default: `.plaintext`).
    ///   - subscribeToDisplay: Whether to automatically subscribe to display events
    public func connect(
        host: String,
        port: Int = 50051,
        security: HTTP2ClientTransport.Posix.TransportSecurity = .plaintext,
        subscribeToDisplay: Bool = true
    ) async throws {
        connectionState = .connecting
        lastError = nil

        do {
            try await connection.connect(host: host, port: port, security: security)
            connectionState = .connected

            if subscribeToDisplay {
                startDisplaySubscription()
            }
        } catch {
            connectionState = .disconnected
            let uboError = UboError.connectionFailed(error)
            lastError = uboError
            throw uboError
        }
    }

    /// Disconnect from the device
    public func disconnect() async {
        displaySubscriptionTask?.cancel()
        displaySubscriptionTask = nil
        viewSubscriptionTask?.cancel()
        viewSubscriptionTask = nil
        statsSubscriptionTask?.cancel()
        statsSubscriptionTask = nil
        cameraSubscriptionTask?.cancel()
        cameraSubscriptionTask = nil
        inputsSubscriptionTask?.cancel()
        inputsSubscriptionTask = nil
        await connection.disconnect()
        connectionState = .disconnected
        currentDisplay = nil
        currentView = nil
        statusBar = nil
        systemStats = nil
        isCameraViewfinderActive = false
        cameraPattern = nil
        activeInputs = []
    }

    /// Whether currently connected to a device
    public var isConnected: Bool {
        connectionState == .connected
    }

    // MARK: - Display Subscription

    /// Start subscribing to display render events
    public func startDisplaySubscription() {
        displaySubscriptionTask?.cancel()
        displaySubscriptionTask = Task {
            do {
                for try await renderData in await connection.subscribeToDisplayRenderEvents() {
                    await MainActor.run {
                        self.currentDisplay = renderData
                    }
                }
            } catch {
                await MainActor.run {
                    if self.connectionState == .connected {
                        self.lastError = .subscriptionFailed(error)
                    }
                }
            }
        }
    }

    /// Stop subscribing to display events
    public func stopDisplaySubscription() {
        displaySubscriptionTask?.cancel()
        displaySubscriptionTask = nil
    }

    /// Request a display redraw from the device
    public func requestDisplayRedraw() async throws {
        try await dispatch(.displayRedraw)
    }

    // MARK: - View Subscription

    /// Start subscribing to view state changes (view data and status bar)
    /// This provides structured view data instead of raw display pixels.
    public func startViewSubscription() {
        viewSubscriptionTask?.cancel()
        viewSubscriptionTask = Task {
            do {
                for try await (view, status) in await connection.subscribeToStoreChanges() {
                    await MainActor.run {
                        self.currentView = view
                        self.statusBar = status
                    }
                }
            } catch {
                await MainActor.run {
                    if self.connectionState == .connected {
                        self.lastError = .subscriptionFailed(error)
                    }
                }
            }
        }
    }

    /// Stop subscribing to view state changes
    public func stopViewSubscription() {
        viewSubscriptionTask?.cancel()
        viewSubscriptionTask = nil
    }

    // MARK: - System Stats Subscription

    /// Start subscribing to system stats (CPU, RAM, clock)
    /// This provides continuous updates even when the device is not on the home screen.
    public func startStatsSubscription() {
        statsSubscriptionTask?.cancel()
        statsSubscriptionTask = Task {
            do {
                for try await stats in await connection.subscribeToSystemStats() {
                    await MainActor.run {
                        self.systemStats = stats
                    }
                }
            } catch {
                await MainActor.run {
                    if self.connectionState == .connected {
                        self.lastError = .subscriptionFailed(error)
                    }
                }
            }
        }
    }

    /// Stop subscribing to system stats
    public func stopStatsSubscription() {
        statsSubscriptionTask?.cancel()
        statsSubscriptionTask = nil
    }

    // MARK: - Active Inputs Subscription

    /// Start subscribing to `state.web_ui.active_inputs`. Updates
    /// `activeInputs` so the UI can render an `InputFormView` for any
    /// pending demand and dispatch `provideInput` / `cancelInput` against
    /// each item's `id`.
    public func startInputsSubscription() {
        UboLog.input.debug("startInputsSubscription called")
        inputsSubscriptionTask?.cancel()
        inputsSubscriptionTask = Task {
            do {
                for try await inputs in await connection.subscribeToActiveInputs() {
                    UboLog.input.debug("activeInputs updated: \(inputs.count) item(s)")
                    await MainActor.run {
                        self.activeInputs = inputs
                    }
                }
                UboLog.input.debug("inputs stream ended")
            } catch {
                UboLog.input.error("inputs stream errored: \(String(describing: error))")
                await MainActor.run {
                    if self.connectionState == .connected {
                        self.lastError = .subscriptionFailed(error)
                    }
                }
            }
        }
    }

    /// Stop subscribing to active input demands.
    public func stopInputsSubscription() {
        inputsSubscriptionTask?.cancel()
        inputsSubscriptionTask = nil
    }

    // MARK: - Camera Subscription

    /// Start subscribing to camera viewfinder events
    public func startCameraSubscription() {
        cameraSubscriptionTask?.cancel()
        cameraSubscriptionTask = Task {
            do {
                for try await event in await connection.subscribeToCameraEvents() {
                    await MainActor.run {
                        switch event {
                        case .startViewfinder(let pattern):
                            self.cameraPattern = pattern
                            self.isCameraViewfinderActive = true
                        case .stopViewfinder:
                            self.isCameraViewfinderActive = false
                            self.cameraPattern = nil
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    if self.connectionState == .connected {
                        self.lastError = .subscriptionFailed(error)
                    }
                }
            }
        }
    }

    /// Stop subscribing to camera viewfinder events
    public func stopCameraSubscription() {
        cameraSubscriptionTask?.cancel()
        cameraSubscriptionTask = nil
        isCameraViewfinderActive = false
        cameraPattern = nil
    }

    /// Send a camera frame to the device as a CameraReportImageEvent
    /// - Parameters:
    ///   - data: RGB pixel data (3 bytes per pixel)
    ///   - width: Frame width in pixels
    ///   - height: Frame height in pixels
    ///   - timestamp: Frame timestamp
    public func sendCameraFrame(data: Data, width: Int, height: Int, timestamp: Float) async throws {
        guard isConnected else {
            throw UboError.notConnected
        }

        var reportEvent = Ubo_V1_CameraReportImageEvent()
        reportEvent.data = data
        reportEvent.width = Int64(width)
        reportEvent.height = Int64(height)
        reportEvent.timestamp = timestamp

        var event = Ubo_V1_Event()
        event.cameraReportImageEvent = reportEvent

        do {
            try await connection.dispatchEvent(event)
        } catch let error as UboError {
            lastError = error
            throw error
        } catch {
            let uboError = UboError.dispatchFailed(error)
            lastError = uboError
            throw uboError
        }
    }

    // MARK: - Button/Key Actions

    /// Press a button on the device
    /// - Parameter key: The button to press
    public func pressKey(_ key: Key) async throws {
        try await dispatch(.keypadKeyPress(key: key))
    }

    /// Press multiple keys simultaneously (for combos)
    /// - Parameter keys: The buttons to press
    public func pressKeys(_ keys: Set<Key>) async throws {
        try await dispatch(.keypadKeyPressMultiple(keys: keys))
    }

    /// Release a button on the device
    /// - Parameter key: The button to release
    public func releaseKey(_ key: Key) async throws {
        try await dispatch(.keypadKeyRelease(key: key))
    }

    /// Navigate back in the menu
    public func goBack() async throws {
        try await dispatch(.menuGoBack)
    }

    /// Navigate to home screen
    public func goHome() async throws {
        try await dispatch(.menuGoHome)
    }

    /// Scroll up in the current menu
    public func scrollUp() async throws {
        try await dispatch(.menuScrollUp)
    }

    /// Scroll down in the current menu
    public func scrollDown() async throws {
        try await dispatch(.menuScrollDown)
    }

    /// Press L1 button
    public func pressL1() async throws {
        try await pressKey(.l1)
    }

    /// Press L2 button
    public func pressL2() async throws {
        try await pressKey(.l2)
    }

    /// Press L3 button
    public func pressL3() async throws {
        try await pressKey(.l3)
    }

    // MARK: - Audio Actions

    /// Set the playback volume
    /// - Parameters:
    ///   - level: Volume level (0.0 to 1.0)
    ///   - device: Audio device (default: output)
    public func setVolume(_ level: Float, device: AudioDevice = .output) async throws {
        try await dispatch(.audioSetVolume(level: level, device: device))
    }

    /// Change volume by relative amount
    /// - Parameters:
    ///   - change: Volume change (-1.0 to 1.0)
    ///   - device: Audio device (default: output)
    public func changeVolume(by change: Float, device: AudioDevice = .output) async throws {
        try await dispatch(.audioChangeVolume(change: change, device: device))
    }

    /// Toggle mute state
    /// - Parameter device: Audio device (default: output)
    public func toggleMute(device: AudioDevice = .output) async throws {
        try await dispatch(.audioToggleMute(device: device))
    }

    /// Set mute state
    /// - Parameters:
    ///   - muted: Whether to mute
    ///   - device: Audio device (default: output)
    public func setMute(_ muted: Bool, device: AudioDevice = .output) async throws {
        try await dispatch(.audioSetMute(muted: muted, device: device))
    }

    /// Play a chime sound
    /// - Parameter chime: The chime to play
    public func playChime(_ chime: Chime) async throws {
        try await dispatch(.audioPlayChime(chime))
    }

    /// Start recording audio
    public func startRecording() async throws {
        try await dispatch(.audioStartRecording)
        isRecording = true
    }

    /// Stop recording audio
    public func stopRecording() async throws {
        try await dispatch(.audioStopRecording)
        isRecording = false
    }

    /// Play recorded audio
    public func playRecording() async throws {
        try await dispatch(.audioPlayRecording)
    }

    // MARK: - Display Actions

    /// Blank the display (sleep)
    public func blankDisplay() async throws {
        try await dispatch(.displayBlank)
    }

    /// Wake the display
    public func unblankDisplay() async throws {
        try await dispatch(.displayUnblank)
    }

    /// Pause display updates
    public func pauseDisplay() async throws {
        try await dispatch(.displayPause)
    }

    /// Resume display updates
    public func resumeDisplay() async throws {
        try await dispatch(.displayResume)
    }

    /// Set display blank timeout
    /// - Parameter timeout: The timeout duration
    public func setDisplayTimeout(_ timeout: DisplayBlankTimeout) async throws {
        try await dispatch(.displaySetBlankTimeout(timeout))
    }

    // MARK: - RGB LED Ring Actions

    /// Set all RGB LEDs to a color
    /// - Parameter color: The color to set
    public func setLEDColor(_ color: UboColor) async throws {
        try await dispatch(.rgbRingSetAll(color: color))
    }

    /// Clear all RGB LEDs
    public func clearLEDs() async throws {
        try await dispatch(.rgbRingBlank)
    }

    /// Set LED brightness
    /// - Parameter brightness: Brightness level (0.0 to 1.0)
    public func setLEDBrightness(_ brightness: Float) async throws {
        try await dispatch(.rgbRingSetBrightness(brightness))
    }

    /// Enable or disable RGB ring
    /// - Parameter enabled: Whether to enable
    public func setLEDEnabled(_ enabled: Bool) async throws {
        try await dispatch(.rgbRingSetEnabled(enabled))
    }

    /// Pulse LED effect
    /// - Parameters:
    ///   - color: The color to pulse
    ///   - repetitions: Number of pulses
    ///   - wait: Wait time between pulses
    public func pulseLEDs(color: UboColor, repetitions: Int = 3, wait: Double = 0.5) async throws {
        try await dispatch(.rgbRingPulse(color: color, repetitions: repetitions, wait: wait))
    }

    /// Blink LED effect
    /// - Parameters:
    ///   - color: The color to blink
    ///   - repetitions: Number of blinks
    ///   - wait: Wait time between blinks
    public func blinkLEDs(color: UboColor, repetitions: Int = 3, wait: Double = 0.5) async throws {
        try await dispatch(.rgbRingBlink(color: color, repetitions: repetitions, wait: wait))
    }

    /// Rainbow LED effect
    /// - Parameters:
    ///   - rounds: Number of rainbow rotations
    ///   - wait: Wait time per step
    public func rainbowLEDs(rounds: Int = 1, wait: Double = 0.05) async throws {
        try await dispatch(.rgbRingRainbow(rounds: rounds, wait: wait))
    }

    /// Spinning wheel LED effect
    /// - Parameters:
    ///   - color: The color for the spinner
    ///   - rounds: Number of rotations
    ///   - length: Number of lit LEDs
    ///   - wait: Wait time per step
    public func spinningWheelLEDs(color: UboColor, rounds: Int = 1, length: Int = 3, wait: Double = 0.05) async throws {
        try await dispatch(.rgbRingSpinningWheel(color: color, rounds: rounds, length: length, wait: wait))
    }

    /// Progress wheel LED effect
    /// - Parameters:
    ///   - color: The color for the progress
    ///   - percentage: Progress percentage (0-100)
    public func progressWheelLEDs(color: UboColor, percentage: Int) async throws {
        try await dispatch(.rgbRingProgressWheel(color: color, percentage: percentage))
    }

    // MARK: - Power Actions

    /// Power off the device
    public func powerOff() async throws {
        try await dispatch(.powerOff)
    }

    /// Reboot the device
    public func reboot() async throws {
        try await dispatch(.reboot)
    }

    // MARK: - Notification Actions

    /// Add a notification to the device
    /// - Parameter notification: The notification to add
    public func addNotification(_ notification: UboNotification) async throws {
        try await dispatch(.notificationAdd(notification))
    }

    /// Show a quick notification
    /// - Parameters:
    ///   - title: Notification title
    ///   - content: Notification content
    ///   - chime: Optional chime to play
    public func notify(title: String, content: String, chime: Chime? = nil) async throws {
        let notification = UboNotification(
            title: title,
            content: content,
            chime: chime
        )
        try await addNotification(notification)
    }

    /// Remove a notification by ID
    /// - Parameter id: The notification ID
    public func removeNotification(id: String) async throws {
        try await dispatch(.notificationRemove(id: id))
    }

    /// Clear all notifications
    public func clearAllNotifications() async throws {
        try await dispatch(.notificationClearAll)
    }

    // MARK: - Assistant Actions

    /// Start assistant listening
    public func startAssistantListening() async throws {
        try await dispatch(.assistantStartListening)
    }

    /// Stop assistant listening
    public func stopAssistantListening() async throws {
        try await dispatch(.assistantStopListening)
    }

    /// Toggle assistant listening
    public func toggleAssistantListening() async throws {
        try await dispatch(.assistantToggleListening)
    }

    // MARK: - Input Actions

    /// Provide the user's response to an active `InputDescription` request.
    /// This is what a connected client (iPhone/Watch/Mac) dispatches after a
    /// native input form is filled in, instead of redirecting to the Web UI.
    public func provideInput(id: String, value: String) async throws {
        try await dispatch(.inputProvide(id: id, value: value))
    }

    /// Cancel an active `InputDescription` request.
    public func cancelInput(id: String) async throws {
        try await dispatch(.inputCancel(id: id))
    }

    // MARK: - Audio Capture (mic → device)

    /// Report a captured microphone sample to the device. Mirrors the Web
    /// UI's `reportAudioSample` flow used to feed the assistant pipeline.
    public func reportAudioSample(
        timestamp: Float,
        data: Data,
        channels: Int = 1,
        rate: Int = 16000,
        width: Int = 2
    ) async throws {
        let sample = AudioSampleData(data: data, channels: channels, rate: rate, width: width)
        try await dispatch(.audioReportSample(timestamp: timestamp, sample: sample))
    }

    // MARK: - Stack Navigation

    /// Push a registered menu onto the navigation stack by its menu key.
    public func pushMenu(menuKey: String) async throws {
        try await dispatch(.stackPushMenu(menuKey: menuKey))
    }

    /// Pop one or more items off the navigation stack.
    public func popStack(count: Int = 1) async throws {
        try await dispatch(.stackPop(count: count))
    }

    /// Pop the navigation stack back to the root (home).
    public func popToRoot() async throws {
        try await dispatch(.stackPopToRoot)
    }

    // MARK: - Frame Stream Subscription

    /// Subscribe to `frame_stream` render frames coming from the device.
    /// If `streamId` is provided, only frames for that stream are yielded.
    public func frameStream(streamId: String = "") async -> AsyncThrowingStream<UboConnection.FrameStreamFrame, Error> {
        await connection.subscribeToFrameStream(streamId: streamId)
    }

    // MARK: - Audio Playback Subscription

    /// Subscribe to PCM samples emitted by the device for the client to
    /// play through its speaker. Yields one `AudioSampleData` per
    /// `AudioPlayAudioSampleEvent`.
    public func playbackAudio() async -> AsyncThrowingStream<AudioSampleData, Error> {
        await connection.subscribeToPlaybackAudio()
    }

    // MARK: - Raw Action Dispatch

    /// Dispatch a raw action (for advanced use)
    /// - Parameter action: The action to dispatch
    public func dispatch(_ action: UboAction) async throws {
        guard isConnected else {
            throw UboError.notConnected
        }

        do {
            try await connection.dispatchAction(action)
        } catch let error as UboError {
            lastError = error
            throw error
        } catch {
            let uboError = UboError.dispatchFailed(error)
            lastError = uboError
            throw uboError
        }
    }
}

// MARK: - Convenience Extensions

extension UboClient {
    /// Connect to a local device on the default port
    public func connectLocal() async throws {
        try await connect(host: "localhost")
    }

    /// Navigate back in the menu
    public func navigateBack() async throws {
        try await dispatch(.menuGoBack)
    }

    /// Navigate to the home screen
    public func navigateHome() async throws {
        try await dispatch(.menuGoHome)
    }

    /// Select menu item by index
    public func selectMenuItem(at index: Int) async throws {
        try await dispatch(.menuChooseByIndex(index))
    }

    /// Select menu item by label
    public func selectMenuItem(label: String) async throws {
        try await dispatch(.menuChooseByLabel(label))
    }

    /// Select menu item by icon
    public func selectMenuItem(icon: String) async throws {
        try await dispatch(.menuChooseByIcon(icon))
    }

    /// Scroll the menu up
    public func scrollMenuUp() async throws {
        try await dispatch(.menuScrollUp)
    }

    /// Scroll the menu down
    public func scrollMenuDown() async throws {
        try await dispatch(.menuScrollDown)
    }
}
