import Foundation

/// Actions that can be dispatched to an Ubo device
public enum UboAction: Sendable {
    // MARK: - Keypad Actions

    /// Press a single key
    case keypadKeyPress(key: Key, time: Double = 0)

    /// Press multiple keys simultaneously
    case keypadKeyPressMultiple(keys: Set<Key>, time: Double = 0)

    /// Release a key
    case keypadKeyRelease(key: Key, time: Double = 0)

    /// Hold a key
    case keypadKeyHold(key: Key, time: Double = 0)

    /// Unhold a key
    case keypadKeyUnhold(key: Key, time: Double = 0)

    // MARK: - Audio Actions

    /// Set volume level (0.0 to 1.0)
    case audioSetVolume(level: Float, device: AudioDevice)

    /// Change volume by relative amount
    case audioChangeVolume(change: Float, device: AudioDevice)

    /// Set mute status
    case audioSetMute(muted: Bool, device: AudioDevice)

    /// Toggle mute status
    case audioToggleMute(device: AudioDevice)

    /// Play a chime sound
    case audioPlayChime(Chime)

    /// Report a captured microphone sample to the device. Mirrors
    /// `AudioReportSampleAction` on the Python side. Used to stream PCM
    /// audio from a connected client (iPhone/Watch/Mac) to the device's
    /// assistant pipeline.
    case audioReportSample(timestamp: Float, sample: AudioSampleData)

    /// Start recording audio
    case audioStartRecording

    /// Stop recording audio
    case audioStopRecording

    /// Play recorded audio
    case audioPlayRecording

    // MARK: - Display Actions

    /// Blank/sleep the display
    case displayBlank

    /// Unblank/wake the display
    case displayUnblank

    /// Pause display updates
    case displayPause

    /// Resume display updates
    case displayResume

    /// Request display redraw
    case displayRedraw

    /// Set display blank timeout
    case displaySetBlankTimeout(DisplayBlankTimeout)

    // MARK: - RGB Ring Actions

    /// Set all LEDs to one color
    case rgbRingSetAll(color: UboColor)

    /// Blank/clear all LEDs
    case rgbRingBlank

    /// Set LED brightness (0.0 to 1.0)
    case rgbRingSetBrightness(Float)

    /// Enable/disable RGB ring
    case rgbRingSetEnabled(Bool)

    /// Pulse effect
    case rgbRingPulse(color: UboColor, repetitions: Int, wait: Double)

    /// Blink effect
    case rgbRingBlink(color: UboColor, repetitions: Int, wait: Double)

    /// Rainbow effect
    case rgbRingRainbow(rounds: Int, wait: Double)

    /// Spinning wheel effect
    case rgbRingSpinningWheel(color: UboColor, rounds: Int, length: Int, wait: Double)

    /// Progress wheel effect
    case rgbRingProgressWheel(color: UboColor, percentage: Int)

    // MARK: - Power Actions

    /// Power off the device
    case powerOff

    /// Reboot the device
    case reboot

    // MARK: - Notification Actions

    /// Add a notification
    case notificationAdd(UboNotification)

    /// Remove a notification by ID
    case notificationRemove(id: String)

    /// Clear all notifications
    case notificationClearAll

    /// Display a notification immediately
    case notificationDisplay(UboNotification)

    // MARK: - Navigation Actions

    /// Navigate back
    case menuGoBack

    /// Navigate to home
    case menuGoHome

    /// Scroll up in menu
    case menuScrollUp

    /// Scroll down in menu
    case menuScrollDown

    /// Choose menu item by index
    case menuChooseByIndex(Int)

    /// Choose menu item by label
    case menuChooseByLabel(String)

    /// Choose menu item by icon
    case menuChooseByIcon(String)

    /// Push a registered menu onto the navigation stack by its menu key.
    case stackPushMenu(menuKey: String)

    /// Pop one or more items off the navigation stack.
    case stackPop(count: Int = 1)

    /// Pop the navigation stack back to the root (home).
    case stackPopToRoot

    // MARK: - Input Actions

    /// Provide the user's response to an active `InputDescription` request.
    /// `value` is the primary scalar response (e.g. text typed into the
    /// field). For multi-field forms the richer `InputResult` payload should
    /// be supplied by `audioReportSampleWithResult`/dedicated helpers when
    /// they're added; the common case (single-field text/password) is
    /// handled here.
    case inputProvide(id: String, value: String)

    /// Cancel an active `InputDescription` request without providing a value.
    case inputCancel(id: String)

    // MARK: - Assistant Actions

    /// Start assistant listening
    case assistantStartListening

    /// Stop assistant listening
    case assistantStopListening

    /// Toggle assistant listening
    case assistantToggleListening

    // MARK: - Camera Actions

    /// Register this client as a remote camera source. Dispatched in
    /// response to a `CameraDetectAdvertiseEvent` so the device's camera
    /// picker lists this client alongside local USB / picamera devices.
    case cameraRegisterRemote(sourceId: String, label: String)
}

extension UboAction: CustomStringConvertible {
    public var description: String {
        switch self {
        case .keypadKeyPress(let key, _): return "KeyPress(\(key))"
        case .keypadKeyPressMultiple(let keys, _): return "KeyPressMultiple(\(keys))"
        case .keypadKeyRelease(let key, _): return "KeyRelease(\(key))"
        case .keypadKeyHold(let key, _): return "KeyHold(\(key))"
        case .keypadKeyUnhold(let key, _): return "KeyUnhold(\(key))"
        case .audioSetVolume(let level, let device): return "SetVolume(\(level), \(device))"
        case .audioChangeVolume(let change, let device): return "ChangeVolume(\(change), \(device))"
        case .audioSetMute(let muted, let device): return "SetMute(\(muted), \(device))"
        case .audioToggleMute(let device): return "ToggleMute(\(device))"
        case .audioPlayChime(let chime): return "PlayChime(\(chime))"
        case .audioReportSample(let t, let s): return "ReportSample(t=\(t), bytes=\(s.data.count))"
        case .audioStartRecording: return "StartRecording"
        case .audioStopRecording: return "StopRecording"
        case .audioPlayRecording: return "PlayRecording"
        case .displayBlank: return "DisplayBlank"
        case .displayUnblank: return "DisplayUnblank"
        case .displayPause: return "DisplayPause"
        case .displayResume: return "DisplayResume"
        case .displayRedraw: return "DisplayRedraw"
        case .displaySetBlankTimeout(let timeout): return "SetBlankTimeout(\(timeout))"
        case .rgbRingSetAll(let color): return "RgbSetAll(\(color.hexString))"
        case .rgbRingBlank: return "RgbBlank"
        case .rgbRingSetBrightness(let level): return "RgbSetBrightness(\(level))"
        case .rgbRingSetEnabled(let enabled): return "RgbSetEnabled(\(enabled))"
        case .rgbRingPulse: return "RgbPulse"
        case .rgbRingBlink: return "RgbBlink"
        case .rgbRingRainbow: return "RgbRainbow"
        case .rgbRingSpinningWheel: return "RgbSpinningWheel"
        case .rgbRingProgressWheel: return "RgbProgressWheel"
        case .powerOff: return "PowerOff"
        case .reboot: return "Reboot"
        case .notificationAdd(let n): return "NotificationAdd(\(n.title))"
        case .notificationRemove(let id): return "NotificationRemove(\(id))"
        case .notificationClearAll: return "NotificationClearAll"
        case .notificationDisplay(let n): return "NotificationDisplay(\(n.title))"
        case .menuGoBack: return "MenuGoBack"
        case .menuGoHome: return "MenuGoHome"
        case .menuScrollUp: return "MenuScrollUp"
        case .menuScrollDown: return "MenuScrollDown"
        case .menuChooseByIndex(let i): return "MenuChooseByIndex(\(i))"
        case .menuChooseByLabel(let l): return "MenuChooseByLabel(\(l))"
        case .menuChooseByIcon(let i): return "MenuChooseByIcon(\(i))"
        case .stackPushMenu(let key): return "StackPushMenu(\(key))"
        case .stackPop(let count): return "StackPop(\(count))"
        case .stackPopToRoot: return "StackPopToRoot"
        case .inputProvide(let id, _): return "InputProvide(\(id))"
        case .inputCancel(let id): return "InputCancel(\(id))"
        case .assistantStartListening: return "AssistantStartListening"
        case .assistantStopListening: return "AssistantStopListening"
        case .assistantToggleListening: return "AssistantToggleListening"
        case .cameraRegisterRemote(let id, let label): return "CameraRegisterRemote(\(id), \(label))"
        }
    }
}
