import Foundation

/// Errors that can occur when interacting with Ubo devices
public enum UboError: Error, Sendable, LocalizedError {
    /// Not connected to any device
    case notConnected

    /// Connection to device failed
    case connectionFailed(Error)

    /// Event subscription failed
    case subscriptionFailed(Error)

    /// Action dispatch failed
    case dispatchFailed(Error)

    /// Invalid response from device
    case invalidResponse(String)

    /// Connection timed out
    case timeout

    /// Channel is not available
    case channelUnavailable

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to any Ubo device"
        case .connectionFailed(let error):
            return "Connection failed: \(error.localizedDescription)"
        case .subscriptionFailed(let error):
            return "Event subscription failed: \(error.localizedDescription)"
        case .dispatchFailed(let error):
            return "Action dispatch failed: \(error.localizedDescription)"
        case .invalidResponse(let message):
            return "Invalid response: \(message)"
        case .timeout:
            return "Connection timed out"
        case .channelUnavailable:
            return "gRPC channel is not available"
        }
    }
}
