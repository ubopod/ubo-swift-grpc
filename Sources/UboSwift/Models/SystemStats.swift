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

    /// Device temperature in Celsius. Sourced from
    /// `SystemState.cpu_temperature_celsius` (previously read from the
    /// onboard ambient sensor in `SensorsState.temperature`, which didn't
    /// match what the Web UI's Processor card shows).
    public var temperature: Float?

    /// 1/5/15-minute load averages from `SystemState`.
    public var loadAverage1: Float?
    public var loadAverage5: Float?
    public var loadAverage15: Float?

    /// Device boot time (epoch seconds). Used to derive uptime.
    public var bootTime: Float?

    public var diskTotalBytes: Int64?
    public var diskUsedBytes: Int64?
    public var diskPercent: Float?

    public var networkUploadBps: Float?
    public var networkDownloadBps: Float?

    /// Current clock/time string ("HH:MM"), from `state.localization`.
    public var clock: String

    /// Current local date ("YYYY-MM-DD"), from `state.localization`.
    public var date: String

    /// Current weather condition, `nil` until the first sample arrives.
    public var weather: WeatherCondition?

    /// City/country the device's location resolved to, from
    /// `LocalizationState.location`. Shown alongside the weather tile.
    public var locationCity: String?
    public var locationCountry: String?

    /// Docker apps from `state.docker.service`, empty until first frame.
    public var dockerApps: [DockerAppStatus]

    /// Connected sensor devices from `state.sensors`, empty until first frame.
    public var sensorDevices: [SensorDeviceState]

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
        temperature: Float? = nil,
        loadAverage1: Float? = nil,
        loadAverage5: Float? = nil,
        loadAverage15: Float? = nil,
        bootTime: Float? = nil,
        diskTotalBytes: Int64? = nil,
        diskUsedBytes: Int64? = nil,
        diskPercent: Float? = nil,
        networkUploadBps: Float? = nil,
        networkDownloadBps: Float? = nil,
        clock: String = "",
        date: String = "",
        weather: WeatherCondition? = nil,
        locationCity: String? = nil,
        locationCountry: String? = nil,
        dockerApps: [DockerAppStatus] = [],
        sensorDevices: [SensorDeviceState] = [],
        playbackVolume: Float? = nil,
        isPlaybackMute: Bool? = nil,
        isCaptureMute: Bool? = nil
    ) {
        self.cpuPercent = cpuPercent
        self.ramPercent = ramPercent
        self.temperature = temperature
        self.loadAverage1 = loadAverage1
        self.loadAverage5 = loadAverage5
        self.loadAverage15 = loadAverage15
        self.bootTime = bootTime
        self.diskTotalBytes = diskTotalBytes
        self.diskUsedBytes = diskUsedBytes
        self.diskPercent = diskPercent
        self.networkUploadBps = networkUploadBps
        self.networkDownloadBps = networkDownloadBps
        self.clock = clock
        self.date = date
        self.weather = weather
        self.locationCity = locationCity
        self.locationCountry = locationCountry
        self.dockerApps = dockerApps
        self.sensorDevices = sensorDevices
        self.playbackVolume = playbackVolume
        self.isPlaybackMute = isPlaybackMute
        self.isCaptureMute = isCaptureMute
    }
}
