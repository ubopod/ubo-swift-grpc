import Foundation

/// Which wake slot a wake-phrase trigger matched. The core keys its
/// turn-completion policies off the mode rather than the literal phrase, so
/// this is what actually selects pipeline behaviour.
///
/// Mirrors the `WakeMode` proto enum.
public enum WakeMode: Sendable, Equatable {
    /// Arms the offline command listener rather than the assistant.
    case intents
    /// A single short turn, completed by the core after a brief silence.
    case quickChat
    /// A multi-turn conversation tolerating long mid-sentence pauses.
    case conversation
    /// Interrupts the assistant mid-utterance.
    case stopTalking
    /// Hands the utterance to Home Assistant's voice pipeline.
    case homeAssistant
}

/// Identifies *how* an assistant listening session was triggered.
///
/// The core resolves this against `AssistantState.policies` to decide how the
/// user's turn completes — after a window of silence, or push-to-talk that
/// flushes only when the session ends. Dispatching `AssistantStartListening`
/// without a source leaves the core with no policy at all and logs a warning
/// on the device, so prefer passing one.
///
/// Mirrors the `AssistantTriggerSourceUnion` proto; the keypad and infrared
/// arms are omitted because they describe triggers originating on the device.
public enum AssistantTriggerSource: Sendable, Equatable {
    /// Triggered programmatically by a connected client over gRPC. The core
    /// has no dedicated policy for this arm, so sessions fall through to the
    /// catch-all entry — which today means the pipeline's short fallback
    /// silence window rather than the longer quick-chat one.
    case grpc

    /// Presents the session to the core as a wake-phrase trigger in `mode`.
    ///
    /// Use this when a client wants a *named* pipeline behaviour rather than
    /// the catch-all: `.quickChat` selects the core's quick-chat policy, so the
    /// device ends the turn after its configured silence window. Note that a
    /// quick-chat session also arms the core's stage-1 voice-shortcut grammar
    /// against this session's audio source.
    ///
    /// `phrase` and `detector` are diagnostic only — nothing in the core
    /// branches on them — so pass values describing the real trigger rather
    /// than impersonating a spoken phrase.
    case wakePhrase(phrase: String, detector: String = "vosk", mode: WakeMode)
}
