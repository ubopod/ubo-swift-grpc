# UboSwift

Swift client library for connecting to Ubo devices via gRPC.

## Requirements

- iOS 16.0+ / macOS 13.0+ / watchOS 9.0+ / tvOS 16.0+
- Swift 5.9+
- Xcode 15.0+

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/ubopod/ubo-swift-grpc.git", from: "0.1.0")
]
```

Or in Xcode: File > Add Packages > enter the repository URL.

## Quick Start

```swift
import UboSwift

// Create a client
let client = UboClient()

// Connect to device
try await client.connect(host: "192.168.1.100", port: 50051)

// Press buttons
try await client.pressKey(.up)
try await client.pressKey(.l1)

// Control audio
try await client.setVolume(0.5)
try await client.playChime(.done)

// Show notifications
try await client.notify(title: "Hello", content: "World", chime: .add)

// Control RGB LEDs
try await client.setLEDColor(.red)
try await client.rainbowLEDs(rounds: 2)

// Disconnect
await client.disconnect()
```

## SwiftUI Example

```swift
import SwiftUI
import UboSwift

@main
struct UboMirrorApp: App {
    @StateObject private var client = UboClient()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(client)
                .task {
                    try? await client.connect(host: "192.168.1.100")
                }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var client: UboClient

    var body: some View {
        VStack(spacing: 20) {
            // Connection status
            HStack {
                Circle()
                    .fill(client.isConnected ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                Text(client.isConnected ? "Connected" : "Disconnected")
            }

            // Navigation buttons
            HStack(spacing: 20) {
                Button("Back") { Task { try? await client.goBack() } }
                Button("Home") { Task { try? await client.goHome() } }
            }

            // D-pad
            VStack(spacing: 10) {
                Button("Up") { Task { try? await client.scrollUp() } }
                Button("Down") { Task { try? await client.scrollDown() } }
            }

            // Side buttons
            HStack(spacing: 10) {
                Button("L1") { Task { try? await client.pressL1() } }
                Button("L2") { Task { try? await client.pressL2() } }
                Button("L3") { Task { try? await client.pressL3() } }
            }
        }
        .buttonStyle(.borderedProminent)
        .padding()
    }
}
```

## Available Actions

### Button Controls
- `pressKey(_:)` - Press any key (`.back`, `.home`, `.up`, `.down`, `.l1`, `.l2`, `.l3`)
- `goBack()`, `goHome()`, `scrollUp()`, `scrollDown()` - Navigation shortcuts
- `pressL1()`, `pressL2()`, `pressL3()` - Side button shortcuts

### Audio
- `setVolume(_:device:)` - Set volume (0.0 to 1.0)
- `changeVolume(by:device:)` - Adjust volume relative
- `toggleMute(device:)` - Toggle mute
- `playChime(_:)` - Play sound (`.add`, `.done`, `.failure`, `.volumeChange`)
- `startRecording()`, `stopRecording()`, `playRecording()` - Audio recording

### Display
- `blankDisplay()`, `unblankDisplay()` - Sleep/wake display
- `pauseDisplay()`, `resumeDisplay()` - Pause/resume updates
- `setDisplayTimeout(_:)` - Set auto-blank timeout
- `requestDisplayRedraw()` - Force redraw

### RGB LED Ring
- `setLEDColor(_:)` - Set all LEDs to one color
- `clearLEDs()` - Turn off all LEDs
- `setLEDBrightness(_:)` - Set brightness (0.0 to 1.0)
- `pulseLEDs(color:repetitions:wait:)` - Pulse effect
- `blinkLEDs(color:repetitions:wait:)` - Blink effect
- `rainbowLEDs(rounds:wait:)` - Rainbow effect
- `spinningWheelLEDs(color:rounds:length:wait:)` - Spinning effect
- `progressWheelLEDs(color:percentage:)` - Progress indicator

### Notifications
- `notify(title:content:chime:)` - Quick notification
- `addNotification(_:)` - Add custom notification
- `removeNotification(id:)` - Remove by ID
- `clearAllNotifications()` - Clear all

### Power
- `powerOff()` - Shutdown device
- `reboot()` - Restart device

### Assistant
- `startAssistantListening()`, `stopAssistantListening()`, `toggleAssistantListening()`

## Proto Generation

To regenerate Swift proto files from the proto definitions:

```bash
# Install required tools
brew install protobuf swift-protobuf grpc-swift

# Generate Swift files
./generate-protos.sh
```

## License

MIT License
