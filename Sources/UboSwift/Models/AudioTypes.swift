import Foundation

/// Audio chime sounds available on Ubo device
public enum Chime: String, CaseIterable, Sendable, Codable {
    case add = "add"
    case done = "done"
    case failure = "failure"
    case volumeChange = "volume_change"

    /// Proto field number for this chime
    public var protoValue: Int32 {
        switch self {
        case .add: return 1
        case .done: return 2
        case .failure: return 3
        case .volumeChange: return 4
        }
    }

    /// Initialize from proto value
    public init?(protoValue: Int32) {
        switch protoValue {
        case 1: self = .add
        case 2: self = .done
        case 3: self = .failure
        case 4: self = .volumeChange
        default: return nil
        }
    }
}

/// A raw audio sample captured by a connected client (or originating on
/// the device). Mirrors the `AudioSample` proto message.
public struct AudioSampleData: Sendable, Equatable {
    public var data: Data
    public var channels: Int
    public var rate: Int
    public var width: Int

    public init(data: Data, channels: Int = 1, rate: Int = 16000, width: Int = 2) {
        self.data = data
        self.channels = channels
        self.rate = rate
        self.width = width
    }
}

/// One playback event from the device's `000-audio` service. Mirrors the
/// three event variants the Web UI subscribes to in `audio.ts`.
public enum PlaybackEvent: Sendable {
    /// One-shot PCM sample (chimes, alerts, short clips).
    case sample(sample: AudioSampleData, volume: Float)
    /// One chunk of an indexed audio sequence (TTS, file playback). The
    /// device may emit a final chunk with `sample == nil` to mark the
    /// end of a stream — listeners should treat that as a no-op.
    case sequence(id: String, index: Int, sample: AudioSampleData?, volume: Float)
    /// Device asked all clients to halt playback (e.g. "stop" UI button).
    case stop
}

/// Audio device type (input/output)
public enum AudioDevice: String, CaseIterable, Sendable, Codable {
    case input
    case output

    /// Proto field number for this device type
    public var protoValue: Int32 {
        switch self {
        case .input: return 1
        case .output: return 2
        }
    }

    /// Initialize from proto value
    public init?(protoValue: Int32) {
        switch protoValue {
        case 1: self = .input
        case 2: self = .output
        default: return nil
        }
    }
}
