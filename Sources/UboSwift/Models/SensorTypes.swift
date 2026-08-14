import Foundation

/// Health of a connected sensor device, mirrors `Ubo_V1_SensorStatus`.
public enum SensorDeviceStatus: Sendable, Equatable {
    case active
    case error
    case unsupported
    case ambiguous
    case unspecified
}

/// One reading from a sensor device's `entities` list.
public struct SensorEntityReading: Sendable, Equatable, Identifiable {
    public var id: String { key }

    public var key: String
    public var value: Float?
    public var name: String?
    public var unit: String?
    public var deviceClass: String?
    public var precision: Int64?
    /// Already converted to the device's effective UnitSystem — see
    /// `ubo_app/utils/units.py`. Clients display these, not `value`/`unit`.
    public var displayValue: Float?
    public var displayUnit: String?

    public init(
        key: String,
        value: Float? = nil,
        name: String? = nil,
        unit: String? = nil,
        deviceClass: String? = nil,
        precision: Int64? = nil,
        displayValue: Float? = nil,
        displayUnit: String? = nil
    ) {
        self.key = key
        self.value = value
        self.name = name
        self.unit = unit
        self.deviceClass = deviceClass
        self.precision = precision
        self.displayValue = displayValue
        self.displayUnit = displayUnit
    }
}

/// One connected sensor device from `SensorsState.devices`.
public struct SensorDeviceState: Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var status: SensorDeviceStatus
    public var entities: [SensorEntityReading]

    public init(
        id: String,
        label: String,
        status: SensorDeviceStatus,
        entities: [SensorEntityReading]
    ) {
        self.id = id
        self.label = label
        self.status = status
        self.entities = entities
    }
}
