import Foundation

/// Importance level for notifications
public enum NotificationImportance: String, CaseIterable, Sendable, Codable {
    case critical
    case high
    case medium
    case low

    /// Proto field number for this importance level
    public var protoValue: Int32 {
        switch self {
        case .critical: return 1
        case .high: return 2
        case .medium: return 3
        case .low: return 4
        }
    }
}

/// Display type for notifications
public enum NotificationDisplayType: String, CaseIterable, Sendable, Codable {
    case notSet
    case background
    case flash
    case sticky

    /// Proto field number for this display type
    public var protoValue: Int32 {
        switch self {
        case .notSet: return 1
        case .background: return 2
        case .flash: return 3
        case .sticky: return 4
        }
    }
}

/// A notification to display on the Ubo device
public struct UboNotification: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let content: String
    public let icon: String?
    public let color: UboColor?
    public let importance: NotificationImportance
    public let displayType: NotificationDisplayType
    public let chime: Chime?
    public let dismissable: Bool
    public let progress: Float?

    public init(
        id: String = UUID().uuidString,
        title: String,
        content: String,
        icon: String? = nil,
        color: UboColor? = nil,
        importance: NotificationImportance = .medium,
        displayType: NotificationDisplayType = .flash,
        chime: Chime? = nil,
        dismissable: Bool = true,
        progress: Float? = nil
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.icon = icon
        self.color = color
        self.importance = importance
        self.displayType = displayType
        self.chime = chime
        self.dismissable = dismissable
        self.progress = progress
    }
}
