// UboTest - Command-line tool to test gRPC connection to Ubo device
//
// Usage:
//   swift run ubo-test <host> [port]
//
// Examples:
//   swift run ubo-test 192.168.1.100
//   swift run ubo-test localhost 50051

import Foundation
import UboSwift

@available(macOS 15.0, *)
@main
struct UboTest {
    @MainActor
    static func main() async {
        let args = CommandLine.arguments

        // Parse arguments
        let host: String
        let port: Int

        if args.count < 2 {
            print("UboSwift Connection Test")
            print("========================")
            print("")
            print("Usage: swift run ubo-test <host> [port]")
            print("")
            print("Examples:")
            print("  swift run ubo-test 192.168.1.100")
            print("  swift run ubo-test localhost 50051")
            print("  swift run ubo-test ubo.local")
            print("")
            print("Environment variables:")
            print("  GRPC_HOST - Default host (default: localhost)")
            print("  GRPC_PORT - Default port (default: 50051)")
            print("")

            // Use environment variables as fallback
            host = ProcessInfo.processInfo.environment["GRPC_HOST"] ?? "localhost"
            port = Int(ProcessInfo.processInfo.environment["GRPC_PORT"] ?? "50051") ?? 50051
            print("Using defaults: \(host):\(port)")
            print("")
        } else {
            host = args[1]
            port = args.count > 2 ? Int(args[2]) ?? 50051 : 50051
        }

        print("Connecting to \(host):\(port)...")

        let client = UboClient()

        do {
            // Try to connect
            try await client.connect(host: host, port: port, subscribeToDisplay: false)
            print("Connected successfully!")
            print("")

            // Run interactive test menu
            await runInteractiveMenu(client: client)

        } catch {
            print("Connection failed: \(error)")
            print("")
            print("Make sure:")
            print("  1. The Ubo device is powered on")
            print("  2. The gRPC server is running on port \(port)")
            print("  3. The device is reachable at \(host)")
            exit(1)
        }
    }

    @available(macOS 15.0, *)
    @MainActor
    static func runInteractiveMenu(client: UboClient) async {
        print("Interactive Test Menu")
        print("=====================")
        print("")
        print("Commands:")
        print("  1-3     - Press L1/L2/L3 button")
        print("  u/d     - Press Up/Down")
        print("  b       - Press Back")
        print("  h       - Press Home")
        print("  n       - Send test notification")
        print("  c       - Play chime (done)")
        print("  r       - Rainbow LED effect")
        print("  l       - Set LEDs to red")
        print("  o       - Clear LEDs")
        print("  s       - Subscribe to display events")
        print("  q       - Quit")
        print("")

        while true {
            print("> ", terminator: "")
            fflush(stdout)

            guard let input = readLine()?.lowercased().trimmingCharacters(in: .whitespaces) else {
                continue
            }

            do {
                switch input {
                case "1":
                    try await client.pressKey(.l1)
                    print("Pressed L1")

                case "2":
                    try await client.pressKey(.l2)
                    print("Pressed L2")

                case "3":
                    try await client.pressKey(.l3)
                    print("Pressed L3")

                case "u":
                    try await client.pressKey(.up)
                    print("Pressed Up")

                case "d":
                    try await client.pressKey(.down)
                    print("Pressed Down")

                case "b":
                    try await client.pressKey(.back)
                    print("Pressed Back")

                case "h":
                    try await client.pressKey(.home)
                    print("Pressed Home")

                case "n":
                    try await client.notify(
                        title: "Test Notification",
                        content: "Hello from UboSwift!",
                        chime: .add
                    )
                    print("Sent notification")

                case "c":
                    try await client.playChime(.done)
                    print("Played chime")

                case "r":
                    try await client.rainbowLEDs(rounds: 2)
                    print("Rainbow effect started")

                case "l":
                    try await client.setLEDColor(.red)
                    print("LEDs set to red")

                case "o":
                    try await client.clearLEDs()
                    print("LEDs cleared")

                case "s":
                    print("Subscribing to display events (press Ctrl+C to stop)...")
                    client.startDisplaySubscription()
                    // Monitor for a few updates
                    for _ in 0..<10 {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                        if let display = client.currentDisplay {
                            print("  Received display update: \(display.width)x\(display.height)")
                        }
                    }
                    client.stopDisplaySubscription()
                    print("Stopped display subscription")

                case "q", "quit", "exit":
                    print("Disconnecting...")
                    await client.disconnect()
                    print("Goodbye!")
                    return

                case "":
                    continue

                default:
                    print("Unknown command: \(input)")
                }
            } catch {
                print("Error: \(error)")
            }
        }
    }
}
