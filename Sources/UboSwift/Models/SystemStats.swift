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

    /// Device playback volume (0-1). `nil` until the first AudioState message
    /// arrives from `state.audio`.
    public var playbackVolume: Float?

    /// Device playback mute state. `nil` until the first AudioState message
    /// arrives from `state.audio`.
    public var isPlaybackMute: Bool?

    /// Device microphone (capture) mute state. `nil` until the first
    /// AudioState message arrives from `state.audio`.
    public var isCaptureMute: Bool?

    public init(
        cpuPercent: Float = 0,
        ramPercent: Float = 0,
        clock: String = "",
        temperature: Float? = nil,
        playbackVolume: Float? = nil,
        isPlaybackMute: Bool? = nil,
        isCaptureMute: Bool? = nil
    ) {
        self.cpuPercent = cpuPercent
        self.ramPercent = ramPercent
        self.clock = clock
        self.temperature = temperature
        self.playbackVolume = playbackVolume
        self.isPlaybackMute = isPlaybackMute
        self.isCaptureMute = isCaptureMute
    }
}
