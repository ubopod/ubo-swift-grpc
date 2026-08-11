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

    public init(
        symbolCode: String = "",
        temperatureCelsius: Float = 0,
        windSpeedMps: Float? = nil
    ) {
        self.symbolCode = symbolCode
        self.temperatureCelsius = temperatureCelsius
        self.windSpeedMps = windSpeedMps
    }
}
