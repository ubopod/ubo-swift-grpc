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

@MainActor
func runTest() async {
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

@MainActor
func runInteractiveMenu(client: UboClient) async {
    print("Interactive Test Menu")
    print("=====================")
    print("")
    print("Commands:")
    print("  1-3     - Press L1/L2/L3 button (or select menu item by index)")
    print("  u/d     - Scroll Up/Down in menu")
    print("  b       - Go Back in menu")
    print("  h       - Go Home")
    print("  n       - Send test notification")
    print("  c       - Play chime (done)")
    print("  r       - Rainbow LED effect")
    print("  l       - Set LEDs to red")
    print("  o       - Clear LEDs")
    print("  s       - Subscribe to display events (raw pixels)")
    print("  v       - Subscribe to view events (runs in background)")
    print("  vs      - Stop view subscription")
    print("  i       - Show current view info")
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
                // Select based on current view type
                if let view = client.currentView {
                    switch view {
                    case .home(let data) where data.menuItems.count > 0:
                        let icon = data.menuItems[0].icon
                        try await client.selectMenuItem(icon: icon)
                        print("Selected home item 0 by icon: \(icon)")
                    case .menu(let data) where data.items.count > 0:
                        if let item = data.items[0], !item.label.isEmpty {
                            try await client.selectMenuItem(label: item.label)
                            print("Selected menu item 0 by label: \(item.label)")
                        } else {
                            try await client.selectMenuItem(at: 0)
                            print("Selected menu item 0 by index")
                        }
                    default:
                        try await client.selectMenuItem(at: 0)
                        print("Selected item 0 by index")
                    }
                } else {
                    try await client.selectMenuItem(at: 0)
                    print("Selected menu item 0 (L1)")
                }

            case "2":
                if let view = client.currentView {
                    switch view {
                    case .home(let data) where data.menuItems.count > 1:
                        let icon = data.menuItems[1].icon
                        try await client.selectMenuItem(icon: icon)
                        print("Selected home item 1 by icon: \(icon)")
                    case .menu(let data) where data.items.count > 1:
                        if let item = data.items[1], !item.label.isEmpty {
                            try await client.selectMenuItem(label: item.label)
                            print("Selected menu item 1 by label: \(item.label)")
                        } else {
                            try await client.selectMenuItem(at: 1)
                            print("Selected menu item 1 by index")
                        }
                    default:
                        try await client.selectMenuItem(at: 1)
                        print("Selected item 1 by index")
                    }
                } else {
                    try await client.selectMenuItem(at: 1)
                    print("Selected menu item 1 (L2)")
                }

            case "3":
                if let view = client.currentView {
                    switch view {
                    case .home(let data) where data.menuItems.count > 2:
                        let icon = data.menuItems[2].icon
                        try await client.selectMenuItem(icon: icon)
                        print("Selected home item 2 by icon: \(icon)")
                    case .menu(let data) where data.items.count > 2:
                        if let item = data.items[2], !item.label.isEmpty {
                            try await client.selectMenuItem(label: item.label)
                            print("Selected menu item 2 by label: \(item.label)")
                        } else {
                            try await client.selectMenuItem(at: 2)
                            print("Selected menu item 2 by index")
                        }
                    default:
                        try await client.selectMenuItem(at: 2)
                        print("Selected item 2 by index")
                    }
                } else {
                    try await client.selectMenuItem(at: 2)
                    print("Selected menu item 2 (L3)")
                }

            case "u":
                try await client.scrollMenuUp()
                print("Scrolled Up")

            case "d":
                try await client.scrollMenuDown()
                print("Scrolled Down")

            case "b":
                try await client.navigateBack()
                print("Navigated Back")

            case "h":
                try await client.navigateHome()
                print("Navigated Home")

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

            case "v":
                if client.currentView != nil {
                    // Already subscribed, show current state
                    print("View subscription active. Current state:")
                    if let view = client.currentView {
                        print("  View: \(view)")
                    }
                    if let status = client.statusBar {
                        print("  Status: \(status)")
                    }
                } else {
                    print("Starting view subscription (runs in background)...")
                    print("Use 'i' to show current view, 'vs' to stop subscription")
                    client.startViewSubscription()
                    // Wait briefly for first update
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    if let view = client.currentView {
                        print("  Initial view: \(view)")
                    } else {
                        print("  Waiting for view data...")
                    }
                }

            case "vs":
                client.stopViewSubscription()
                print("Stopped view subscription")

            case "i":
                if let view = client.currentView {
                    print("Current View: \(view)")
                    switch view {
                    case .home(let data):
                        print("  Type: Home")
                        print("  Menu Items: \(data.menuItems.count)")
                        for (i, item) in data.menuItems.enumerated() {
                            print("    [\(i)] \(item.label) (\(item.icon))")
                        }
                        print("  CPU: \(Int(data.cpuPercent))%")
                        print("  RAM: \(Int(data.ramPercent))%")
                        print("  Volume: \(Int(data.volumeLevel))%")
                    case .menu(let data):
                        print("  Type: Menu")
                        print("  Title: \(data.title)")
                        if let heading = data.heading { print("  Heading: \(heading)") }
                        print("  Items: \(data.items.count)")
                        for (i, item) in data.items.enumerated() {
                            if let item = item {
                                print("    [\(i)] \(item.label) (\(item.icon))")
                            } else {
                                print("    [\(i)] (empty)")
                            }
                        }
                        print("  Page: \(data.pageIndex + 1)/\(data.totalPages)")
                    case .notification(let data):
                        print("  Type: Notification")
                        print("  Title: \(data.title)")
                        print("  Content: \(data.content)")
                    case .application(let data):
                        print("  Type: Application")
                        print("  App ID: \(data.applicationId)")
                    case .instruction(let data):
                        print("  Type: Instruction")
                        print("  Title: \(data.title)")
                        print("  Instruction: \(data.instruction)")
                        print("  Spinner: \(data.spinner)")
                    case .prompt(let data):
                        print("  Type: Prompt")
                        print("  Title: \(data.title)")
                        print("  Prompt: \(data.prompt)")
                        print("  Items: \(data.items.count)")
                    case .render(let data):
                        print("  Type: Render")
                        print("  Kind: \(data.kind.rawValue)")
                        print("  Title: \(data.title)")
                        print("  Stream: \(data.streamId)")
                    case .chat(let data):
                        print("  Type: Chat")
                        print("  Bubbles: \(data.bubbles.count)/\(data.totalBubbles)")
                        print("  Scroll: \(data.scrollOffset)")
                    }
                    if let status = client.statusBar {
                        print("Status Bar:")
                        print("  Title: \(status.title)")
                        print("  Clock: \(status.clock)")
                        if let temp = status.temperature {
                            print("  Temperature: \(Int(temp))C")
                        }
                        print("  Icons: \(status.icons.count)")
                    }
                } else {
                    print("No view data available. Use 'v' to subscribe first.")
                }

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

// Entry point
Task { @MainActor in
    await runTest()
    exit(0)
}
RunLoop.main.run()
