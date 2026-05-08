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
        let proto = await build(.audioReportSample(timestamp: 1.5, sample: sample))
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
    }
}
#endif
