import Foundation

/// RGBA color representation
public struct UboColor: Sendable, Equatable, Codable {
    /// Red component (0-255)
    public let red: UInt8
    /// Green component (0-255)
    public let green: UInt8
    /// Blue component (0-255)
    public let blue: UInt8
    /// Alpha component (0-255)
    public let alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Initialize from hex string (e.g., "#ff0000" or "ff0000")
    public init?(hex: String) {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexString.hasPrefix("#") {
            hexString.removeFirst()
        }

        guard hexString.count == 6 || hexString.count == 8 else {
            return nil
        }

        var rgb: UInt64 = 0
        guard Scanner(string: hexString).scanHexInt64(&rgb) else {
            return nil
        }

        if hexString.count == 6 {
            self.red = UInt8((rgb >> 16) & 0xFF)
            self.green = UInt8((rgb >> 8) & 0xFF)
            self.blue = UInt8(rgb & 0xFF)
            self.alpha = 255
        } else {
            self.red = UInt8((rgb >> 24) & 0xFF)
            self.green = UInt8((rgb >> 16) & 0xFF)
            self.blue = UInt8((rgb >> 8) & 0xFF)
            self.alpha = UInt8(rgb & 0xFF)
        }
    }

    /// Convert to hex string
    public var hexString: String {
        if alpha == 255 {
            return String(format: "#%02x%02x%02x", red, green, blue)
        } else {
            return String(format: "#%02x%02x%02x%02x", red, green, blue, alpha)
        }
    }

    // MARK: - Common Colors

    public static let black = UboColor(red: 0, green: 0, blue: 0)
    public static let white = UboColor(red: 255, green: 255, blue: 255)
    public static let red = UboColor(red: 255, green: 0, blue: 0)
    public static let green = UboColor(red: 0, green: 255, blue: 0)
    public static let blue = UboColor(red: 0, green: 0, blue: 255)
    public static let clear = UboColor(red: 0, green: 0, blue: 0, alpha: 0)
}

#if canImport(SwiftUI)
import SwiftUI

extension UboColor {
    /// Convert to SwiftUI Color
    public var swiftUIColor: Color {
        Color(
            red: Double(red) / 255.0,
            green: Double(green) / 255.0,
            blue: Double(blue) / 255.0,
            opacity: Double(alpha) / 255.0
        )
    }

    /// Initialize from SwiftUI Color (approximate conversion)
    public init(_ color: Color) {
        // Note: This is an approximate conversion as Color doesn't directly expose components
        // For accurate conversion, use UIColor/NSColor intermediary
        self.init(red: 128, green: 128, blue: 128, alpha: 255)
    }
}
#endif

#if canImport(UIKit)
import UIKit

extension UboColor {
    /// Convert to UIColor
    public var uiColor: UIColor {
        UIColor(
            red: CGFloat(red) / 255.0,
            green: CGFloat(green) / 255.0,
            blue: CGFloat(blue) / 255.0,
            alpha: CGFloat(alpha) / 255.0
        )
    }

    /// Initialize from UIColor
    public init(_ uiColor: UIColor) {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(
            red: UInt8(r * 255),
            green: UInt8(g * 255),
            blue: UInt8(b * 255),
            alpha: UInt8(a * 255)
        )
    }
}
#endif
