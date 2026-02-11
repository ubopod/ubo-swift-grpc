//
//  SystemStats.swift
//  UboSwift
//
//  System statistics data model
//

import Foundation

/// System statistics from the Ubo device
public struct SystemStats: Sendable, Equatable {
    /// CPU usage percentage (0-100)
    public var cpuPercent: Float

    /// RAM usage percentage (0-100)
    public var ramPercent: Float

    /// Current clock/time string
    public var clock: String

    /// Temperature in Celsius
    public var temperature: Float?

    public init(cpuPercent: Float = 0, ramPercent: Float = 0, clock: String = "", temperature: Float? = nil) {
        self.cpuPercent = cpuPercent
        self.ramPercent = ramPercent
        self.clock = clock
        self.temperature = temperature
    }
}
