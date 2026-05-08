// ViewData round-trip tests
//
// For each of the seven ViewData types defined in
// ubo_app/store/core/types/view_data.py, this suite builds the corresponding
// proto message, wraps it in google.protobuf.Any, and asserts that
// `UboConnection.unpackViewData` produces the matching Swift `ViewData` case
// with non-empty fields. Catches any proto-vs-Swift mismatch introduced by
// future regenerations.

#if canImport(XCTest)
import XCTest
import SwiftProtobuf
@testable import UboSwift

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class ViewDataRoundTripTests: XCTestCase {

    private func anyFrom<M: SwiftProtobuf.Message>(_ msg: M) throws -> Google_Protobuf_Any {
        return try Google_Protobuf_Any(message: msg)
    }

    func testHomeViewDataRoundTrip() throws {
        let connection = UboConnection()
        var proto = Ubo_V1_HomeViewData()
        proto.type = "home"
        proto.showStatusBar = true
        proto.cpuPercent = 42
        proto.ramPercent = 17
        proto.volumeLevel = 0.5

        let any = try anyFrom(proto)
        guard case .home(let data) = connection.unpackViewData(from: any) else {
            return XCTFail("Expected .home case")
        }
        XCTAssertEqual(data.cpuPercent, 42)
        XCTAssertEqual(data.ramPercent, 17)
        XCTAssertEqual(data.volumeLevel, 0.5)
    }

    func testMenuViewDataRoundTrip() throws {
        let connection = UboConnection()
        var proto = Ubo_V1_MenuViewData()
        proto.type = "menu"
        proto.title = "Settings"
        proto.heading = "WiFi"
        proto.pageIndex = 1
        proto.totalPages = 3

        let any = try anyFrom(proto)
        guard case .menu(let data) = connection.unpackViewData(from: any) else {
            return XCTFail("Expected .menu case")
        }
        XCTAssertEqual(data.title, "Settings")
        XCTAssertEqual(data.heading, "WiFi")
        XCTAssertEqual(data.pageIndex, 1)
        XCTAssertEqual(data.totalPages, 3)
    }

    func testNotificationViewDataRoundTrip() throws {
        let connection = UboConnection()
        var proto = Ubo_V1_NotificationViewData()
        proto.type = "notification"
        proto.notificationID = "n-1"
        proto.title = "Hello"
        proto.content = "World"
        proto.icon = "󰂜"

        let any = try anyFrom(proto)
        guard case .notification(let data) = connection.unpackViewData(from: any) else {
            return XCTFail("Expected .notification case")
        }
        XCTAssertEqual(data.notificationId, "n-1")
        XCTAssertEqual(data.title, "Hello")
        XCTAssertEqual(data.content, "World")
    }

    func testApplicationViewDataRoundTrip() throws {
        let connection = UboConnection()
        var proto = Ubo_V1_ApplicationViewData()
        proto.type = "application"
        proto.applicationID = "wifi:setup"

        let any = try anyFrom(proto)
        guard case .application(let data) = connection.unpackViewData(from: any) else {
            return XCTFail("Expected .application case")
        }
        XCTAssertEqual(data.applicationId, "wifi:setup")
    }

    func testInstructionViewDataRoundTrip() throws {
        let connection = UboConnection()
        var proto = Ubo_V1_InstructionViewData()
        proto.type = "instruction"
        proto.title = "Pair"
        proto.instruction = "Press the button"
        proto.spinner = true
        proto.timeoutSeconds = 30

        let any = try anyFrom(proto)
        guard case .instruction(let data) = connection.unpackViewData(from: any) else {
            return XCTFail("Expected .instruction case")
        }
        XCTAssertEqual(data.title, "Pair")
        XCTAssertEqual(data.instruction, "Press the button")
        XCTAssertTrue(data.spinner)
        XCTAssertEqual(data.timeoutSeconds, 30)
    }

    func testPromptViewDataRoundTrip() throws {
        let connection = UboConnection()
        var proto = Ubo_V1_PromptViewData()
        proto.type = "prompt"
        proto.title = "Confirm"
        proto.prompt = "Reboot device?"

        var item = Ubo_V1_MenuItemData()
        item.key = "yes"
        item.label = "Yes"
        item.icon = "✅"
        var items = Ubo_V1_PromptViewData.Items()
        items.items = [item]
        proto.items = items

        let any = try anyFrom(proto)
        guard case .prompt(let data) = connection.unpackViewData(from: any) else {
            return XCTFail("Expected .prompt case")
        }
        XCTAssertEqual(data.prompt, "Reboot device?")
        XCTAssertEqual(data.items.count, 1)
        XCTAssertEqual(data.items.first?.label, "Yes")
    }

    func testRenderViewDataRoundTrip() throws {
        let connection = UboConnection()
        var proto = Ubo_V1_RenderViewData()
        proto.type = "render"
        proto.kind = "qr_code"
        proto.title = "Scan to pair"
        proto.streamID = ""

        // props: { "data": "https://example.com" }
        var basic = Ubo_V1_BasicType()
        basic.string = "https://example.com"
        var propValue = Ubo_V1_RenderViewData.PropsValue()
        propValue.basicType = basic
        var propsDict = Ubo_V1_RenderViewData.PropsDict()
        propsDict.items = ["data": propValue]
        proto.props = propsDict

        let any = try anyFrom(proto)
        guard case .render(let data) = connection.unpackViewData(from: any) else {
            return XCTFail("Expected .render case")
        }
        XCTAssertEqual(data.kind, .qrCode)
        XCTAssertEqual(data.title, "Scan to pair")
        if case .string(let s) = data.props["data"] {
            XCTAssertEqual(s, "https://example.com")
        } else {
            XCTFail("Expected props['data'] to be string")
        }
    }

    func testRenderKindFallsBackToUnknown() {
        let kind = RenderKind(rawValue: "future_kind_42")
        if case .unknown(let raw) = kind {
            XCTAssertEqual(raw, "future_kind_42")
        } else {
            XCTFail("Expected .unknown case for unrecognised kind")
        }
    }
}
#endif
