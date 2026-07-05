// Action build tests
//
// Verifies that each `UboAction` case produces a non-empty `Ubo_V1_Action`
// proto (i.e. the corresponding `oneof action` field is populated). Catches
// regressions where a new enum case is added without a matching
// `buildProtoAction` arm. Focus is on the input-form / audio-sample / stack
// / menu-by-label/icon actions added in Phase 1, plus the major existing
// cases.

#if canImport(XCTest)
import XCTest
@testable import UboSwift

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class ActionBuildTests: XCTestCase {

    private func build(_ action: UboAction) async -> Ubo_V1_Action {
        let connection = UboConnection()
        return await connection.buildProtoAction(action)
    }

    func testInputProvideBuildsProto() async {
        let proto = await build(.inputProvide(id: "abc", value: "secret"))
        guard case .inputProvideAction(let payload) = proto.action else {
            return XCTFail("Expected inputProvideAction oneof")
        }
        XCTAssertEqual(payload.id, "abc")
        XCTAssertEqual(payload.value, "secret")
    }

    func testInputCancelBuildsProto() async {
        let proto = await build(.inputCancel(id: "abc"))
        guard case .inputCancelAction(let payload) = proto.action else {
            return XCTFail("Expected inputCancelAction oneof")
        }
        XCTAssertEqual(payload.id, "abc")
    }

    func testAudioReportSampleBuildsProto() async {
        let bytes = Data([0x01, 0x02, 0x03, 0x04])
        let sample = AudioSampleData(data: bytes, channels: 1, rate: 16000, width: 2)
        let proto = await build(.audioReportSample(timestamp: 1.5, sample: sample, audioSource: "ios:test"))
        guard case .audioReportSampleAction(let payload) = proto.action else {
            return XCTFail("Expected audioReportSampleAction oneof")
        }
        XCTAssertEqual(payload.timestamp, 1.5)
        XCTAssertEqual(payload.sample.data, bytes)
        XCTAssertEqual(payload.sample.channels, 1)
        XCTAssertEqual(payload.sample.rate, 16000)
        XCTAssertEqual(payload.sample.width, 2)
    }

    func testStackPushMenuBuildsProto() async {
        let proto = await build(.stackPushMenu(menuKey: "wifi"))
        guard case .stackPushMenuAction(let payload) = proto.action else {
            return XCTFail("Expected stackPushMenuAction oneof")
        }
        XCTAssertEqual(payload.menuKey, "wifi")
    }

    func testStackPopBuildsProto() async {
        let proto = await build(.stackPop(count: 2))
        guard case .stackPopAction(let payload) = proto.action else {
            return XCTFail("Expected stackPopAction oneof")
        }
        XCTAssertEqual(payload.count, 2)
    }

    func testStackPopToRootBuildsProto() async {
        let proto = await build(.stackPopToRoot)
        guard case .stackPopToRootAction = proto.action else {
            return XCTFail("Expected stackPopToRootAction oneof")
        }
    }

    func testMenuChooseByLabelBuildsProto() async {
        let proto = await build(.menuChooseByLabel("Settings"))
        guard case .menuChooseByLabelAction(let payload) = proto.action else {
            return XCTFail("Expected menuChooseByLabelAction oneof")
        }
        XCTAssertEqual(payload.label, "Settings")
    }

    func testMenuChooseByIconBuildsProto() async {
        let proto = await build(.menuChooseByIcon("🔧"))
        guard case .menuChooseByIconAction(let payload) = proto.action else {
            return XCTFail("Expected menuChooseByIconAction oneof")
        }
        XCTAssertEqual(payload.icon, "🔧")
    }

    func testPowerOffBuildsProto() async {
        let proto = await build(.powerOff)
        guard case .powerOffAction = proto.action else {
            return XCTFail("Expected powerOffAction oneof")
        }
    }

    func testRebootBuildsProto() async {
        let proto = await build(.reboot)
        guard case .rebootAction = proto.action else {
            return XCTFail("Expected rebootAction oneof")
        }
    }

    func testKeypadKeyPressBuildsProto() async {
        let proto = await build(.keypadKeyPress(key: .l1))
        guard case .keypadKeyPressAction(let payload) = proto.action else {
            return XCTFail("Expected keypadKeyPressAction oneof")
        }
        XCTAssertEqual(payload.key.rawValue, Int(Key.l1.protoValue))
        // The keypad reducer only matches a bare press when
        // pressed_keys == {key} — an empty pressed set is silently ignored.
        XCTAssertEqual(payload.pressedKeys, [.l1])
    }

    func testKeypadComboPressIncludesModifiers() async {
        let proto = await build(.keypadKeyPressMultiple(key: .l1, modifiers: [.home]))
        guard case .keypadKeyPressAction(let payload) = proto.action else {
            return XCTFail("Expected keypadKeyPressAction oneof")
        }
        XCTAssertEqual(payload.key, .l1)
        XCTAssertEqual(Set(payload.pressedKeys), Set([Ubo_V1_Key.l1, .home]))
        XCTAssertEqual(payload.pressedKeys.first, .l1)
    }

    func testKeypadHoldBuildsProtoWithHeldKeys() async {
        let proto = await build(.keypadKeyHold(key: .home))
        guard case .keypadKeyHoldAction(let payload) = proto.action else {
            return XCTFail("Expected keypadKeyHoldAction oneof")
        }
        XCTAssertEqual(payload.key, .home)
        XCTAssertEqual(payload.pressedKeys, [.home])
        XCTAssertEqual(payload.heldKeys.items, [.home])
    }

    func testKeypadUnholdBuildsProto() async {
        let proto = await build(.keypadKeyUnhold(key: .home))
        guard case .keypadKeyUnholdAction(let payload) = proto.action else {
            return XCTFail("Expected keypadKeyUnholdAction oneof")
        }
        XCTAssertEqual(payload.key, .home)
    }

    func testKeypadReleaseSendsEmptyPressedKeys() async {
        let proto = await build(.keypadKeyRelease(key: .back))
        guard case .keypadKeyReleaseAction(let payload) = proto.action else {
            return XCTFail("Expected keypadKeyReleaseAction oneof")
        }
        XCTAssertEqual(payload.key, .back)
        XCTAssertEqual(payload.pressedKeys, [])
    }

    func testRecordingActionsBuildProto() async {
        guard case .audioStartRecordingAction = await build(.audioStartRecording).action else {
            return XCTFail("Expected audioStartRecordingAction oneof")
        }
        guard case .audioStopRecordingAction = await build(.audioStopRecording).action else {
            return XCTFail("Expected audioStopRecordingAction oneof")
        }
        guard case .audioPlayRecordingAction = await build(.audioPlayRecording).action else {
            return XCTFail("Expected audioPlayRecordingAction oneof")
        }
    }

    func testDisplaySetBlankTimeoutBuildsProto() async {
        let proto = await build(.displaySetBlankTimeout(.fiveMinutes))
        guard case .displaySetBlankTimeoutAction(let payload) = proto.action else {
            return XCTFail("Expected displaySetBlankTimeoutAction oneof")
        }
        XCTAssertEqual(payload.timeout, .fiveMinutes)
    }

    func testNotificationDisplayBuildsProto() async {
        let notification = UboNotification(id: "n1", title: "Title", content: "Body")
        let proto = await build(.notificationDisplay(notification))
        guard case .notificationsDisplayAction(let payload) = proto.action else {
            return XCTFail("Expected notificationsDisplayAction oneof")
        }
        XCTAssertEqual(payload.notification.id, "n1")
        XCTAssertEqual(payload.notification.title, "Title")
    }

    /// One sample per `UboAction` case. `buildProtoAction`'s switch is
    /// exhaustive (compile-time guard); this asserts at runtime that every
    /// case also populates the `oneof action` field — an empty action is a
    /// silent no-op on the core.
    func testEveryActionCasePopulatesOneof() async {
        let sample = AudioSampleData(data: Data([0x01]), channels: 1, rate: 16000, width: 2)
        let notification = UboNotification(title: "t", content: "c")
        let allCases: [UboAction] = [
            .keypadKeyPress(key: .up),
            .keypadKeyPressMultiple(key: .l1, modifiers: [.home]),
            .keypadKeyRelease(key: .back),
            .keypadKeyHold(key: .home),
            .keypadKeyUnhold(key: .home),
            .audioSetVolume(level: 0.5, device: .output),
            .audioChangeVolume(change: 0.1, device: .output),
            .audioSetMute(muted: true, device: .output),
            .audioToggleMute(device: .output),
            .audioPlayChime(.done),
            .audioReportSample(timestamp: 0, sample: sample, audioSource: "src"),
            .audioStartRecording,
            .audioStopRecording,
            .audioPlayRecording,
            .displayBlank,
            .displayUnblank,
            .displayPause,
            .displayResume,
            .displayRedraw,
            .displaySetBlankTimeout(.off),
            .rgbRingSetAll(color: UboColor(red: 1, green: 2, blue: 3)),
            .rgbRingBlank,
            .rgbRingSetBrightness(0.5),
            .rgbRingSetEnabled(true),
            .rgbRingPulse(color: UboColor(red: 1, green: 2, blue: 3), repetitions: 1, wait: 0.1),
            .rgbRingBlink(color: UboColor(red: 1, green: 2, blue: 3), repetitions: 1, wait: 0.1),
            .rgbRingRainbow(rounds: 1, wait: 1),
            .rgbRingSpinningWheel(color: UboColor(red: 1, green: 2, blue: 3), rounds: 1, length: 3, wait: 0.1),
            .rgbRingProgressWheel(color: UboColor(red: 1, green: 2, blue: 3), percentage: 50),
            .powerOff,
            .reboot,
            .notificationAdd(notification),
            .notificationRemove(id: "n"),
            .notificationClearAll,
            .notificationDisplay(notification),
            .menuGoBack,
            .menuGoHome,
            .menuScrollUp,
            .menuScrollDown,
            .menuChooseByIndex(0),
            .menuChooseByLabel("x"),
            .menuChooseByIcon("y"),
            .stackPushMenu(menuKey: "k"),
            .stackPop(count: 1),
            .stackPopToRoot,
            .inputProvide(id: "i", value: "v"),
            .inputCancel(id: "i"),
            .assistantStartListening(audioSource: "s"),
            .assistantStopListening,
            .assistantToggleListening(audioSource: "s"),
            .cameraRegisterRemote(sourceId: "cam", label: "Cam"),
            .cameraReportImage(timestamp: 0, data: Data([0x01]), width: 1, height: 1, sourceId: "cam"),
            .chatToggleAudioPlayback(messageId: "m"),
        ]
        for action in allCases {
            let proto = await build(action)
            XCTAssertNotNil(proto.action, "\(action) built an empty Ubo_V1_Action — missing buildProtoAction arm")
        }
    }
}
#endif
