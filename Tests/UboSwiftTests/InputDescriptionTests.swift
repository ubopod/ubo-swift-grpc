// Input description round-trip + field-type mapping tests.
//
// Phase 2 wires `state.web_ui.active_inputs` into the Swift app. This file
// exercises the proto -> Swift conversion path (`unpackActiveInputs`) and
// the field-type enum mapping. If a new InputFieldType lands on the
// Python side, the field-type mapping test fails until the Swift enum is
// extended.

#if canImport(XCTest)
import XCTest
import SwiftProtobuf
@testable import UboSwift

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class InputDescriptionTests: XCTestCase {

    func testInputFieldTypeProtoMapping() {
        XCTAssertEqual(InputFieldType(protoValue: 1), .long)
        XCTAssertEqual(InputFieldType(protoValue: 2), .text)
        XCTAssertEqual(InputFieldType(protoValue: 3), .password)
        XCTAssertEqual(InputFieldType(protoValue: 4), .number)
        XCTAssertEqual(InputFieldType(protoValue: 5), .checkbox)
        XCTAssertEqual(InputFieldType(protoValue: 6), .color)
        XCTAssertEqual(InputFieldType(protoValue: 7), .select)
        XCTAssertEqual(InputFieldType(protoValue: 8), .file)
        XCTAssertEqual(InputFieldType(protoValue: 9), .date)
        XCTAssertEqual(InputFieldType(protoValue: 10), .time)
    }

    func testInputFieldTypeUnknownDefaultsToText() {
        XCTAssertEqual(InputFieldType(protoValue: 999), .text)
        XCTAssertEqual(InputFieldType(protoValue: 0), .text)
    }

    func testWebUIStateRoundTripCarriesActiveInputs() throws {
        let connection = UboConnection()

        var field = Ubo_V1_InputFieldDescription()
        field.name = "ssid"
        field.label = "Wi-Fi SSID"
        field.type = .text
        field.required = true
        field.defaultValue = "MyNetwork"

        var passwordField = Ubo_V1_InputFieldDescription()
        passwordField.name = "password"
        passwordField.label = "Password"
        passwordField.type = .password

        var fields = Ubo_V1_WebUIInputDescription.Fields()
        fields.items = [field, passwordField]

        var description = Ubo_V1_WebUIInputDescription()
        description.id = "wifi-1"
        description.title = "Connect Wi-Fi"
        description.prompt = "Pick a network and enter the password"
        description.fields = fields

        var state = Ubo_V1_WebUIState()
        state.activeInputs = [description]

        let any = try Google_Protobuf_Any(message: state)
        let inputs = connection.unpackActiveInputs(from: [any])

        XCTAssertEqual(inputs.count, 1)
        let input = try XCTUnwrap(inputs.first)
        XCTAssertEqual(input.id, "wifi-1")
        XCTAssertEqual(input.title, "Connect Wi-Fi")
        XCTAssertEqual(input.prompt, "Pick a network and enter the password")
        XCTAssertEqual(input.fields.count, 2)

        let ssid = input.fields[0]
        XCTAssertEqual(ssid.name, "ssid")
        XCTAssertEqual(ssid.label, "Wi-Fi SSID")
        XCTAssertEqual(ssid.type, .text)
        XCTAssertTrue(ssid.required)
        XCTAssertEqual(ssid.defaultValue, "MyNetwork")

        let password = input.fields[1]
        XCTAssertEqual(password.name, "password")
        XCTAssertEqual(password.type, .password)
        XCTAssertFalse(password.required)
    }

    func testServerCasingQuirkRoundTrip() throws {
        // Python betterproto rewrites `WebUIState` -> `WebUiState` (and
        // similarly for `WebUIInputDescription`) in the type URL. Verify
        // unpackActiveInputs still recognises both casings.
        let connection = UboConnection()

        var description = Ubo_V1_WebUIInputDescription()
        description.id = "casing-1"
        description.title = "T"

        var state = Ubo_V1_WebUIState()
        state.activeInputs = [description]

        let bytes = try state.serializedData()

        for typeURL in [
            "type.googleapis.com/ubo_bindings.ubo.v1.WebUiState",   // betterproto casing
            "type.googleapis.com/ubo.v1.WebUIState",                // canonical casing
        ] {
            var any = Google_Protobuf_Any()
            any.typeURL = typeURL
            any.value = bytes
            let inputs = connection.unpackActiveInputs(from: [any])
            XCTAssertEqual(inputs.count, 1, "type URL \(typeURL)")
            XCTAssertEqual(inputs.first?.id, "casing-1", "type URL \(typeURL)")
        }
    }

    func testEmptyActiveInputsArrayDecodes() throws {
        let connection = UboConnection()
        let state = Ubo_V1_WebUIState()
        let any = try Google_Protobuf_Any(message: state)
        XCTAssertEqual(connection.unpackActiveInputs(from: [any]).count, 0)
    }

    func testReconnectPolicyStateCanBeUpdated() async {
        let connection = UboConnection()
        await connection.setReconnectPolicy(ReconnectPolicy.none)
        let policy = await connection.reconnectPolicy
        XCTAssertEqual(policy.maxRetries, 0)
    }
}
#endif
