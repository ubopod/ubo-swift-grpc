import Foundation

/// Status bar icon data for rendering
public struct StatusIconData: Sendable, Hashable {
    public var symbol: String
    public var color: String

    public init(symbol: String, color: String) {
        self.symbol = symbol
        self.color = color
    }
}

/// Progress notification for status bar rendering
public struct ProgressNotificationData: Sendable, Hashable {
    public var id: String
    public var progress: Float?  // nil = indeterminate (spinner), 0-1 = progress ring
    public var color: String

    public init(id: String, progress: Float? = nil, color: String) {
        self.id = id
        self.progress = progress
        self.color = color
    }
}

/// All data needed to render the status bar (header + footer)
public struct StatusBarData: Sendable {
    // Header
    public var title: String = ""
    public var isRecording: Bool = false
    public var isReplaying: Bool = false
    public var isRecordingAudio: Bool = false
    public var progressNotifications: [ProgressNotificationData] = []

    // Footer
    public var clock: String = ""
    public var temperature: Float?
    public var lightLevel: Float?
    public var icons: [StatusIconData] = []

    public init(
        title: String = "",
        isRecording: Bool = false,
        isReplaying: Bool = false,
        isRecordingAudio: Bool = false,
        progressNotifications: [ProgressNotificationData] = [],
        clock: String = "",
        temperature: Float? = nil,
        lightLevel: Float? = nil,
        icons: [StatusIconData] = []
    ) {
        self.title = title
        self.isRecording = isRecording
        self.isReplaying = isReplaying
        self.isRecordingAudio = isRecordingAudio
        self.progressNotifications = progressNotifications
        self.clock = clock
        self.temperature = temperature
        self.lightLevel = lightLevel
        self.icons = icons
    }
}

extension StatusBarData: CustomStringConvertible {
    public var description: String {
        var parts: [String] = []
        if !title.isEmpty { parts.append("title: \"\(title)\"") }
        if !clock.isEmpty { parts.append("clock: \(clock)") }
        if let temp = temperature { parts.append("temp: \(Int(temp))C") }
        if !icons.isEmpty { parts.append("icons: \(icons.count)") }
        if !progressNotifications.isEmpty { parts.append("progress: \(progressNotifications.count)") }
        return "StatusBar(\(parts.joined(separator: ", ")))"
    }
}
