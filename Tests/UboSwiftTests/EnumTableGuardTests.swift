// Enum table drift guards
//
// The hand-written model enums (`Key`, `Chime`, `AudioDevice`,
// `NotificationImportance`, `NotificationDisplayType`,
// `DisplayBlankTimeout`) carry hand-transcribed `protoValue` tables that
// must stay in sync with the generated proto enums. `ubo.proto` is itself
// regenerated from the core's Python types, so a renumber there silently
// degrades every mismatched value to `...Unspecified` (which the device
// ignores) with no compile error. These tests pin each table to the
// generated enum by BOTH value and case name, and pin the case counts so
// an added/removed proto case fails loudly after a bindings regen.

#if canImport(XCTest)
import SwiftProtobuf
import XCTest
@testable import UboSwift

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class EnumTableGuardTests: XCTestCase {

    /// Assert that a Swift model case maps to a generated proto case with
    /// the same numeric value AND the same (camelCase) case name.
    private func assertMapped<P: SwiftProtobuf.Enum>(
        _ swiftCaseName: String,
        _ protoValue: Int32,
        as protoType: P.Type,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let protoCase = P(rawValue: Int(protoValue)) else {
            return XCTFail("\(swiftCaseName): proto value \(protoValue) not a \(P.self) case — bindings renumbered?", file: file, line: line)
        }
        XCTAssertEqual(
            String(describing: protoCase), swiftCaseName,
            "\(P.self) value \(protoValue) is named \(protoCase), expected \(swiftCaseName) — protoValue table out of sync",
            file: file, line: line
        )
    }

    /// Proto enums have one extra `...Unspecified` case (0) that the Swift
    /// tables deliberately omit; `UNRECOGNIZED` is not in `allCases`.
    private func assertCount<S: CaseIterable, P: SwiftProtobuf.Enum & CaseIterable>(
        _ swiftType: S.Type, matches protoType: P.Type,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            S.allCases.count, P.allCases.count - 1,
            "\(S.self) has \(S.allCases.count) cases but \(P.self) has \(P.allCases.count - 1) (excl. unspecified) — a case was added/removed",
            file: file, line: line
        )
    }

    func testKeyTable() {
        for key in Key.allCases {
            assertMapped(swiftName(for: key), key.protoValue, as: Ubo_V1_Key.self)
        }
        assertCount(Key.self, matches: Ubo_V1_Key.self)
    }

    func testChimeTable() {
        for chime in Chime.allCases {
            assertMapped(swiftName(for: chime), chime.protoValue, as: Ubo_V1_Chime.self)
        }
        assertCount(Chime.self, matches: Ubo_V1_Chime.self)
    }

    func testAudioDeviceTable() {
        for device in AudioDevice.allCases {
            assertMapped(swiftName(for: device), device.protoValue, as: Ubo_V1_AudioDevice.self)
        }
        assertCount(AudioDevice.self, matches: Ubo_V1_AudioDevice.self)
    }

    func testNotificationImportanceTable() {
        for importance in NotificationImportance.allCases {
            assertMapped(swiftName(for: importance), importance.protoValue, as: Ubo_V1_Importance.self)
        }
        assertCount(NotificationImportance.self, matches: Ubo_V1_Importance.self)
    }

    func testNotificationDisplayTypeTable() {
        for displayType in NotificationDisplayType.allCases {
            assertMapped(swiftName(for: displayType), displayType.protoValue, as: Ubo_V1_NotificationDisplayType.self)
        }
        assertCount(NotificationDisplayType.self, matches: Ubo_V1_NotificationDisplayType.self)
    }

    func testDisplayBlankTimeoutTable() {
        for timeout in DisplayBlankTimeout.allCases {
            assertMapped(swiftName(for: timeout), timeout.protoValue, as: Ubo_V1_DisplayBlankTimeout.self)
        }
        assertCount(DisplayBlankTimeout.self, matches: Ubo_V1_DisplayBlankTimeout.self)
    }

    /// The Swift enum's case name (not its rawValue — several tables use
    /// wire strings like "volume_change"/"1min" as rawValue).
    private func swiftName<T>(for value: T) -> String {
        String(describing: value)
    }
}
#endif
