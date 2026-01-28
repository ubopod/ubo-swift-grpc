import Foundation

/// Display blank timeout options
public enum DisplayBlankTimeout: String, CaseIterable, Sendable, Codable {
    case oneMinute = "1min"
    case fiveMinutes = "5min"
    case tenMinutes = "10min"
    case thirtyMinutes = "30min"
    case oneHour = "1hour"
    case off = "off"

    /// Proto field number for this timeout
    public var protoValue: Int32 {
        switch self {
        case .oneMinute: return 1
        case .fiveMinutes: return 2
        case .tenMinutes: return 3
        case .thirtyMinutes: return 4
        case .oneHour: return 5
        case .off: return 6
        }
    }

    /// Initialize from proto value
    public init?(protoValue: Int32) {
        switch protoValue {
        case 1: self = .oneMinute
        case 2: self = .fiveMinutes
        case 3: self = .tenMinutes
        case 4: self = .thirtyMinutes
        case 5: self = .oneHour
        case 6: self = .off
        default: return nil
        }
    }
}

/// Display render event data
public struct DisplayRenderData: Sendable {
    /// Timestamp of the render
    public let timestamp: Double

    /// Raw RGBA pixel data
    public let data: Data

    /// Rectangle defining the rendered area [y1, x1, y2, x2]
    public let rectangle: (y1: Int, x1: Int, y2: Int, x2: Int)

    /// Display density multiplier
    public let density: Float

    /// Width of the rendered region
    public var width: Int {
        rectangle.x2 - rectangle.x1
    }

    /// Height of the rendered region
    public var height: Int {
        rectangle.y2 - rectangle.y1
    }

    public init(timestamp: Double, data: Data, rectangle: (y1: Int, x1: Int, y2: Int, x2: Int), density: Float) {
        self.timestamp = timestamp
        self.data = data
        self.rectangle = rectangle
        self.density = density
    }
}
