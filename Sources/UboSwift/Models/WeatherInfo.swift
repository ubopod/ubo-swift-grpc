import Foundation

/// Current weather condition, sourced from `LocalizationState.weather`.
///
/// `symbolCode` follows the MET Norway weather symbol vocabulary (e.g.
/// `partlycloudy_day`), matching what the device's own weather service
/// (`ubo_app/services/010-localization/weather.py`) fetches and what the
/// Web UI dashboard renders.
public struct WeatherCondition: Sendable, Equatable {
    public var symbolCode: String
    public var temperatureCelsius: Float
    public var windSpeedMps: Float?

    /// Already converted to the device's effective UnitSystem — see
    /// `ubo_app/utils/units.py`. Clients display these, not `temperatureCelsius`.
    public var temperatureDisplayValue: Float
    public var temperatureDisplayUnit: String
    public var windSpeedDisplayValue: Float?
    public var windSpeedDisplayUnit: String?

    public init(
        symbolCode: String = "",
        temperatureCelsius: Float = 0,
        windSpeedMps: Float? = nil,
        temperatureDisplayValue: Float = 0,
        temperatureDisplayUnit: String = "°C",
        windSpeedDisplayValue: Float? = nil,
        windSpeedDisplayUnit: String? = nil
    ) {
        self.symbolCode = symbolCode
        self.temperatureCelsius = temperatureCelsius
        self.windSpeedMps = windSpeedMps
        self.temperatureDisplayValue = temperatureDisplayValue
        self.temperatureDisplayUnit = temperatureDisplayUnit
        self.windSpeedDisplayValue = windSpeedDisplayValue
        self.windSpeedDisplayUnit = windSpeedDisplayUnit
    }
}
