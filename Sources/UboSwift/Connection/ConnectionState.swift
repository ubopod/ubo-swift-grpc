import Foundation

/// Connection state to an Ubo device
public enum ConnectionState: Sendable, Equatable {
    /// Not connected to any device
    case disconnected

    /// Currently attempting to connect
    case connecting

    /// Successfully connected to device
    case connected

    /// Connection was lost
    case reconnecting

    /// Whether the client is in a connected state
    public var isConnected: Bool {
        self == .connected
    }

    /// Whether the client is attempting to establish a connection
    public var isConnecting: Bool {
        self == .connecting || self == .reconnecting
    }
}
