import Foundation

/// Physical button keys on the Ubo device
public enum Key: String, CaseIterable, Sendable, Codable {
    case back = "Back"
    case home = "Home"
    case up = "Up"
    case down = "Down"
    case l1 = "L1"
    case l2 = "L2"
    case l3 = "L3"

    /// Proto field number for this key
    public var protoValue: Int32 {
        switch self {
        case .back: return 1
        case .home: return 2
        case .up: return 3
        case .down: return 4
        case .l1: return 5
        case .l2: return 6
        case .l3: return 7
        }
    }

    /// Initialize from proto value
    public init?(protoValue: Int32) {
        switch protoValue {
        case 1: self = .back
        case 2: self = .home
        case 3: self = .up
        case 4: self = .down
        case 5: self = .l1
        case 6: self = .l2
        case 7: self = .l3
        default: return nil
        }
    }
}
