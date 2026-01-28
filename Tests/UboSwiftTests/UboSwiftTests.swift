// UboSwift Tests
// Run these tests in Xcode or with `xcodebuild test`
//
// These tests verify the core functionality of the UboSwift package.
// The tests use XCTest which requires Xcode or a compatible testing environment.

#if canImport(XCTest)
import XCTest
@testable import UboSwift

final class UboSwiftTests: XCTestCase {

    func testKeyProtoValues() {
        XCTAssertEqual(Key.back.protoValue, 1)
        XCTAssertEqual(Key.home.protoValue, 2)
        XCTAssertEqual(Key.up.protoValue, 3)
        XCTAssertEqual(Key.down.protoValue, 4)
        XCTAssertEqual(Key.l1.protoValue, 5)
        XCTAssertEqual(Key.l2.protoValue, 6)
        XCTAssertEqual(Key.l3.protoValue, 7)
    }

    func testKeyFromProtoValue() {
        XCTAssertEqual(Key(protoValue: 1), .back)
        XCTAssertEqual(Key(protoValue: 2), .home)
        XCTAssertNil(Key(protoValue: 0))
    }

    func testChimeProtoValues() {
        XCTAssertEqual(Chime.add.protoValue, 1)
        XCTAssertEqual(Chime.done.protoValue, 2)
        XCTAssertEqual(Chime.failure.protoValue, 3)
    }

    func testColorFromHex() {
        let red = UboColor(hex: "#ff0000")
        XCTAssertNotNil(red)
        XCTAssertEqual(red?.red, 255)
        XCTAssertEqual(red?.green, 0)
        XCTAssertEqual(red?.blue, 0)
    }

    func testColorToHex() {
        let color = UboColor(red: 255, green: 128, blue: 64)
        XCTAssertEqual(color.hexString, "#ff8040")
    }

    func testPredefinedColors() {
        XCTAssertEqual(UboColor.black.hexString, "#000000")
        XCTAssertEqual(UboColor.white.hexString, "#ffffff")
        XCTAssertEqual(UboColor.red.hexString, "#ff0000")
    }

    func testMenuItemCreation() {
        let item = MenuItem(
            key: "test-key",
            label: "Test Label",
            icon: "🔧",
            color: "#ff0000"
        )
        XCTAssertEqual(item.key, "test-key")
        XCTAssertEqual(item.label, "Test Label")
    }

    func testNotificationCreation() {
        let notification = UboNotification(
            title: "Test",
            content: "Content",
            chime: .done
        )
        XCTAssertEqual(notification.title, "Test")
        XCTAssertEqual(notification.chime, .done)
    }

    func testConnectionStateProperties() {
        XCTAssertTrue(ConnectionState.connected.isConnected)
        XCTAssertFalse(ConnectionState.disconnected.isConnected)
        XCTAssertTrue(ConnectionState.connecting.isConnecting)
    }

    func testVersion() {
        XCTAssertEqual(UboSwiftVersion.major, 0)
        XCTAssertEqual(UboSwiftVersion.minor, 1)
        XCTAssertEqual(UboSwiftVersion.string, "0.1.0")
    }
}
#else
// Placeholder when XCTest is not available
@main
struct TestRunner {
    static func main() {
        print("Tests require XCTest framework. Run in Xcode or with xcodebuild test.")
    }
}
#endif
