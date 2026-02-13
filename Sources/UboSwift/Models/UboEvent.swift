import Foundation

/// Events that can be received from an Ubo device
public enum UboEvent: Sendable {
    /// Display render event with pixel data
    case displayRender(DisplayRenderData)

    /// Display compressed render event
    case displayCompressedRender(timestamp: Double, compressedData: Data, rectangle: (y1: Int, x1: Int, y2: Int, x2: Int), density: Float)

    /// Display was blanked
    case displayBlanked

    /// Display was unblanked
    case displayUnblanked

    /// Display redraw requested
    case displayRedraw

    /// Audio sample reported
    case audioSample(timestamp: Double, data: Data)

    /// Audio playback completed
    case audioPlaybackDone

    /// Notification cleared
    case notificationCleared(id: String?)

    /// Notification displayed
    case notificationDisplayed(id: String)

    /// Power off initiated
    case powerOff

    /// Reboot initiated
    case reboot

    /// Camera viewfinder started (device wants frames)
    case cameraStartViewfinder(pattern: String?)

    /// Camera viewfinder stopped (device no longer needs frames)
    case cameraStopViewfinder

    /// Generic/unknown event
    case unknown(type: String)
}

extension UboEvent: CustomStringConvertible {
    public var description: String {
        switch self {
        case .displayRender(let data):
            return "DisplayRender(\(data.width)x\(data.height))"
        case .displayCompressedRender(_, _, let rect, _):
            return "DisplayCompressedRender(\(rect.x2 - rect.x1)x\(rect.y2 - rect.y1))"
        case .displayBlanked:
            return "DisplayBlanked"
        case .displayUnblanked:
            return "DisplayUnblanked"
        case .displayRedraw:
            return "DisplayRedraw"
        case .audioSample(let timestamp, let data):
            return "AudioSample(t=\(timestamp), bytes=\(data.count))"
        case .audioPlaybackDone:
            return "AudioPlaybackDone"
        case .notificationCleared(let id):
            return "NotificationCleared(\(id ?? "all"))"
        case .notificationDisplayed(let id):
            return "NotificationDisplayed(\(id))"
        case .powerOff:
            return "PowerOff"
        case .reboot:
            return "Reboot"
        case .cameraStartViewfinder(let pattern):
            return "CameraStartViewfinder(pattern=\(pattern ?? "nil"))"
        case .cameraStopViewfinder:
            return "CameraStopViewfinder"
        case .unknown(let type):
            return "Unknown(\(type))"
        }
    }
}
