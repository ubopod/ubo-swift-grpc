import Foundation

/// A menu item displayed in the Ubo UI
public struct MenuItem: Sendable, Identifiable, Equatable {
    public var id: String { key ?? UUID().uuidString }

    /// Unique key for this item
    public let key: String?

    /// Display label
    public let label: String?

    /// Icon (typically a Unicode character)
    public let icon: String?

    /// Foreground color (hex string)
    public let color: String?

    /// Background color (hex string)
    public let backgroundColor: String?

    /// Whether this is a short/compact item
    public let isShort: Bool

    /// Item opacity (0.0 to 1.0)
    public let opacity: Float?

    /// Progress indicator (0.0 to 1.0)
    public let progress: Float?

    public init(
        key: String? = nil,
        label: String? = nil,
        icon: String? = nil,
        color: String? = nil,
        backgroundColor: String? = nil,
        isShort: Bool = false,
        opacity: Float? = nil,
        progress: Float? = nil
    ) {
        self.key = key
        self.label = label
        self.icon = icon
        self.color = color
        self.backgroundColor = backgroundColor
        self.isShort = isShort
        self.opacity = opacity
        self.progress = progress
    }

    /// Parse color as UboColor
    public var uboColor: UboColor? {
        color.flatMap { UboColor(hex: $0) }
    }

    /// Parse background color as UboColor
    public var uboBackgroundColor: UboColor? {
        backgroundColor.flatMap { UboColor(hex: $0) }
    }
}

#if canImport(SwiftUI)
import SwiftUI

extension MenuItem {
    /// Foreground color as SwiftUI Color
    public var swiftUIColor: Color? {
        uboColor?.swiftUIColor
    }

    /// Background color as SwiftUI Color
    public var swiftUIBackgroundColor: Color? {
        uboBackgroundColor?.swiftUIColor
    }
}
#endif
