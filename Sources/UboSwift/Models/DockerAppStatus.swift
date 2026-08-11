import Foundation

/// Status/health of one Docker item, mirrors `Ubo_V1_DockerItemStatus`.
public enum DockerItemStatus: Sendable, Equatable {
    case notAvailable
    case fetching
    case available
    case created
    case starting
    case running
    case error
    case processing
    case unspecified
}

/// Health of one Docker item, mirrors `Ubo_V1_DockerItemHealth`.
public enum DockerItemHealth: Sendable, Equatable {
    case ok
    case recovered
    case crashLooping
    case unspecified
}

/// One entry from `DockerServiceState.apps`, sourced from `state.docker.service`.
public struct DockerAppStatus: Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var icon: String
    public var status: DockerItemStatus
    public var health: DockerItemHealth

    public init(
        id: String,
        label: String,
        icon: String,
        status: DockerItemStatus,
        health: DockerItemHealth
    ) {
        self.id = id
        self.label = label
        self.icon = icon
        self.status = status
        self.health = health
    }
}
