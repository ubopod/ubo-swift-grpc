// UboSwift - Swift client for Ubo devices
//
// This package provides a clean API for iOS/watchOS/macOS apps to connect
// to Ubo devices via gRPC.
//
// Quick Start:
// ```swift
// import UboSwift
//
// let client = UboClient()
// try await client.connect(host: "192.168.1.100")
// try await client.pressKey(.up)
// ```

@_exported import Foundation

// Re-export main types
public typealias UboClientType = UboClient

// Version info
public enum UboSwiftVersion {
    public static let major = 0
    public static let minor = 1
    public static let patch = 0
    public static let string = "\(major).\(minor).\(patch)"
}
