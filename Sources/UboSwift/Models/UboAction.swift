import Foundation

/// Actions that can be dispatched to an Ubo device
public enum UboAction: Sendable {
    // MARK: - Keypad Actions

    /// Press a single key
    case keypadKeyPress(key: Key, time: Double = 0)

    /// Press a key while modifier keys are held (combo press). The core's
    /// keypad reducer matches on `key` plus the full pressed set, e.g.
    /// HOME+L1 = screenshot is `key: .l1, modifiers: [.home]`.
    case keypadKeyPressMultiple(key: Key, modifiers: Set<Key>, time: Double = 0)

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
    /// Report a captured mic sample. `audioSource` tags which mic the sample
    /// came from (empty = on-device system mic; a remote client sets a unique
    /// id so the core binds a listening session to that one source). It must
    /// match the `audioSource` on the `assistantStartListening` that opened
    /// the session, or the core drops the sample.
    case audioReportSample(timestamp: Float, sample: AudioSampleData, audioSource: String)

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

    /// Execute a menu item's registered action handler directly by its
    /// `action_id` (every `MenuItemData` carries one over the wire). This is
    /// the primary selection mechanism — mirrors the Web UI's
    /// `dispatchMenuAction`, and unlike `menuChooseByLabel`/`menuChooseByIcon`
    /// doesn't depend on the server's legacy label-lookup tracking staying in
    /// sync with what's actually on screen (which it isn't for prompts —
    /// see `PromptDeviceView`). `menuKey` lets the reducer push the result
    /// onto the stack when the handler returns a submenu.
    case executeMenuAction(actionId: String, menuKey: String? = nil)

    /// Push a registered menu onto the navigation stack by its menu key.
    case stackPushMenu(menuKey: String)

    /// Pop one or more items off the navigation stack.
    case stackPop(count: Int = 1)

    /// Pop the navigation stack back to the root (home).
    case stackPopToRoot

    // MARK: - Input Actions

    /// Provide the user's response to an active `InputDescription` request.
    /// `value` is the primary scalar response (e.g. text typed into a
    /// single-field form). `data` carries every field's name → value, the
    /// same map the Web UI sends (`inputs.tsx`) — server-side handlers for
    /// multi-field forms read `result.data`, not `value`, so omitting this
    /// silently no-ops any form with more than a lone scalar field.
    case inputProvide(id: String, value: String, data: [String: String] = [:])

    /// Cancel an active `InputDescription` request without providing a value.
    case inputCancel(id: String)

    // MARK: - File Upload Actions

    /// Begin a chunked upload session. Prefer the high-level
    /// `UboClient.uploadFile(id:filename:data:)`, which drives this plus the
    /// chunk/complete steps with retry — these three cases exist so
    /// `buildProtoAction` has something to match on.
    case fileUploadStart(uploadId: String, filename: String, totalSize: Int, totalChunks: Int, chunkSize: Int)

    /// Send one chunk of an in-progress upload. `chunkIndex` is 0-based;
    /// `data` must be exactly `chunkSize` bytes except for the final chunk.
    case fileUploadChunk(uploadId: String, chunkIndex: Int, data: Data)

    /// Signal that every chunk has been sent.
    case fileUploadComplete(uploadId: String)

    // MARK: - Assistant Actions

    /// Start assistant listening. `audioSource` selects which mic the session
    /// consumes (empty = on-device system mic; a remote client sets a unique
    /// id so the core listens only to that client's streamed samples and
    /// ignores the device's built-in mic).
    case assistantStartListening(audioSource: String)

    /// Stop assistant listening
    case assistantStopListening

    /// Toggle assistant listening. See `assistantStartListening` for `audioSource`.
    case assistantToggleListening(audioSource: String)

    // MARK: - Camera Actions

    /// Register this client as a remote camera source. Dispatched in
    /// response to a `CameraDetectAdvertiseEvent` so the device's camera
    /// picker lists this client alongside local USB / picamera devices.
    case cameraRegisterRemote(sourceId: String, label: String)

    /// Push a single camera frame to the device. Mirrors
    /// `CameraReportImageAction` on the Python side; the device's reducer
    /// translates it into a `CameraReportImageEvent` consumed by the QR
    /// decoder and viewfinder display. The `sourceId` tags the frame so the
    /// device drops it if a different source is currently selected.
    case cameraReportImage(timestamp: Float, data: Data, width: Int, height: Int, sourceId: String)

    /// Toggle playback of an audio chat bubble. Mirrors
    /// `ChatToggleAudioPlaybackAction` on the Python side; the device's chat
    /// reducer flips the bubble's `is_playing` flag and starts/stops audio.
    /// On hardware this is bound to the bubble's L1/L2/L3 button; touch
    /// clients dispatch it when the bubble is tapped.
    case chatToggleAudioPlayback(messageId: String)
}

extension UboAction: CustomStringConvertible {
    public var description: String {
        switch self {
        case .keypadKeyPress(let key, _): return "KeyPress(\(key))"
        case .keypadKeyPressMultiple(let key, let modifiers, _): return "KeyPressMultiple(\(key), modifiers=\(modifiers))"
        case .keypadKeyRelease(let key, _): return "KeyRelease(\(key))"
        case .keypadKeyHold(let key, _): return "KeyHold(\(key))"
        case .keypadKeyUnhold(let key, _): return "KeyUnhold(\(key))"
        case .audioSetVolume(let level, let device): return "SetVolume(\(level), \(device))"
        case .audioChangeVolume(let change, let device): return "ChangeVolume(\(change), \(device))"
        case .audioSetMute(let muted, let device): return "SetMute(\(muted), \(device))"
        case .audioToggleMute(let device): return "ToggleMute(\(device))"
        case .audioPlayChime(let chime): return "PlayChime(\(chime))"
        case .audioReportSample(let t, let s, let src): return "ReportSample(t=\(t), bytes=\(s.data.count), src=\(src))"
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
        case .executeMenuAction(let actionId, let menuKey): return "ExecuteMenuAction(\(actionId), menuKey=\(menuKey ?? "nil"))"
        case .stackPushMenu(let key): return "StackPushMenu(\(key))"
        case .stackPop(let count): return "StackPop(\(count))"
        case .stackPopToRoot: return "StackPopToRoot"
        case .inputProvide(let id, _, _): return "InputProvide(\(id))"
        case .inputCancel(let id): return "InputCancel(\(id))"
        case .fileUploadStart(let id, let filename, let size, _, _): return "FileUploadStart(\(id), \(filename), \(size)B)"
        case .fileUploadChunk(let id, let index, let data): return "FileUploadChunk(\(id), #\(index), \(data.count)B)"
        case .fileUploadComplete(let id): return "FileUploadComplete(\(id))"
        case .assistantStartListening(let src): return "AssistantStartListening(\(src))"
        case .assistantStopListening: return "AssistantStopListening"
        case .assistantToggleListening(let src): return "AssistantToggleListening(\(src))"
        case .cameraRegisterRemote(let id, let label): return "CameraRegisterRemote(\(id), \(label))"
        case .cameraReportImage(let t, _, let w, let h, let sid):
            return "CameraReportImage(t=\(t), \(w)x\(h), source=\(sid))"
        case .chatToggleAudioPlayback(let id): return "ChatToggleAudioPlayback(\(id))"
        }
    }
}
