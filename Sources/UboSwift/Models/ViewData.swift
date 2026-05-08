import Foundation

/// Data for a single menu item
public struct MenuItemData: Sendable, Hashable {
    public var key: String
    public var label: String
    public var icon: String
    public var color: String
    public var backgroundColor: String?
    public var isShort: Bool
    public var actionId: String?

    public init(
        key: String = "",
        label: String = "",
        icon: String = "",
        color: String = "#ffffff",
        backgroundColor: String? = nil,
        isShort: Bool = false,
        actionId: String? = nil
    ) {
        self.key = key
        self.label = label
        self.icon = icon
        self.color = color
        self.backgroundColor = backgroundColor
        self.isShort = isShort
        self.actionId = actionId
    }
}

/// Data for rendering the home screen view
public struct HomeViewData: Sendable {
    public var type: String = "home"
    public var showStatusBar: Bool = true
    public var menuItems: [MenuItemData] = []
    public var cpuPercent: Float = 0
    public var ramPercent: Float = 0
    public var volumeLevel: Float = 0

    public init(
        type: String = "home",
        showStatusBar: Bool = true,
        menuItems: [MenuItemData] = [],
        cpuPercent: Float = 0,
        ramPercent: Float = 0,
        volumeLevel: Float = 0
    ) {
        self.type = type
        self.showStatusBar = showStatusBar
        self.menuItems = menuItems
        self.cpuPercent = cpuPercent
        self.ramPercent = ramPercent
        self.volumeLevel = volumeLevel
    }
}

/// Data for rendering a menu view
public struct MenuViewData: Sendable {
    public var type: String = "menu"
    public var showStatusBar: Bool = true
    public var title: String = ""
    public var heading: String?
    public var subHeading: String?
    public var items: [MenuItemData?] = []
    public var pageIndex: Int = 0
    public var totalPages: Int = 1

    public init(
        type: String = "menu",
        showStatusBar: Bool = true,
        title: String = "",
        heading: String? = nil,
        subHeading: String? = nil,
        items: [MenuItemData?] = [],
        pageIndex: Int = 0,
        totalPages: Int = 1
    ) {
        self.type = type
        self.showStatusBar = showStatusBar
        self.title = title
        self.heading = heading
        self.subHeading = subHeading
        self.items = items
        self.pageIndex = pageIndex
        self.totalPages = totalPages
    }
}

/// Data for rendering a notification overlay view
public struct NotificationViewData: Sendable {
    public var type: String = "notification"
    public var showStatusBar: Bool = false
    public var notificationId: String = ""
    public var title: String = ""
    public var content: String = ""
    public var icon: String = ""
    public var color: String = "#ffffff"
    public var items: [MenuItemData?] = []
    public var extraInformation: String = ""

    public init(
        type: String = "notification",
        showStatusBar: Bool = false,
        notificationId: String = "",
        title: String = "",
        content: String = "",
        icon: String = "",
        color: String = "#ffffff",
        items: [MenuItemData?] = [],
        extraInformation: String = ""
    ) {
        self.type = type
        self.showStatusBar = showStatusBar
        self.notificationId = notificationId
        self.title = title
        self.content = content
        self.icon = icon
        self.color = color
        self.items = items
        self.extraInformation = extraInformation
    }
}

/// Data for rendering an application view
public struct ApplicationViewData: Sendable {
    public var type: String = "application"
    public var showStatusBar: Bool = false
    public var applicationId: String = ""
    public var extraData: [String: String] = [:]

    public init(
        type: String = "application",
        showStatusBar: Bool = false,
        applicationId: String = "",
        extraData: [String: String] = [:]
    ) {
        self.type = type
        self.showStatusBar = showStatusBar
        self.applicationId = applicationId
        self.extraData = extraData
    }
}

/// Sub-kinds of `RenderViewData` that the core dispatches to clients.
///
/// Mirrors the `kind` strings used by `ubo_app.store.core.types.view_data.RenderViewData`
/// (e.g. `'qr_code'`, `'frame_stream'`). New kinds added on the Python side without
/// a Swift counterpart fall through to `.unknown` so clients can degrade gracefully.
public enum RenderKind: Sendable, Equatable {
    case qrCode
    case qrCodeCarousel
    case textViewer
    case imageViewer
    case frameStream
    case status
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "qr_code": self = .qrCode
        case "qr_code_carousel": self = .qrCodeCarousel
        case "text_viewer": self = .textViewer
        case "image_viewer": self = .imageViewer
        case "frame_stream": self = .frameStream
        case "status": self = .status
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .qrCode: return "qr_code"
        case .qrCodeCarousel: return "qr_code_carousel"
        case .textViewer: return "text_viewer"
        case .imageViewer: return "image_viewer"
        case .frameStream: return "frame_stream"
        case .status: return "status"
        case .unknown(let value): return value
        }
    }
}

/// A `props` value attached to a `RenderViewData` payload. Either a primitive
/// (string/int64/float/bool/bytes) or a list of primitives — mirrors the
/// `BasicType | tuple[BasicType, ...] | list[BasicType]` union from Python.
public enum RenderPropValue: Sendable, Equatable {
    case string(String)
    case int(Int64)
    case float(Float)
    case bool(Bool)
    case bytes(Data)
    case list([RenderPropValue])
}

/// Data for rendering a generic widget such as a QR code, image/text viewer,
/// status page, or live frame stream. The sub-kind is carried in `kind` and
/// the renderer-specific arguments live in `props`.
public struct RenderViewData: Sendable {
    public var type: String = "render"
    public var showStatusBar: Bool = false
    public var kind: RenderKind
    public var title: String = ""
    public var props: [String: RenderPropValue] = [:]
    public var items: [MenuItemData] = []
    public var streamId: String = ""

    public init(
        type: String = "render",
        showStatusBar: Bool = false,
        kind: RenderKind,
        title: String = "",
        props: [String: RenderPropValue] = [:],
        items: [MenuItemData] = [],
        streamId: String = ""
    ) {
        self.type = type
        self.showStatusBar = showStatusBar
        self.kind = kind
        self.title = title
        self.props = props
        self.items = items
        self.streamId = streamId
    }
}

/// Data for rendering an instruction/waiting view (e.g. "Press the button on
/// your device", "Scan this QR code"). Optionally shows a spinner and a
/// timeout countdown.
public struct InstructionViewData: Sendable {
    public var type: String = "instruction"
    public var showStatusBar: Bool = false
    public var title: String = ""
    public var instruction: String = ""
    public var icon: String = ""
    public var spinner: Bool = false
    public var timeoutSeconds: Int = 0
    public var progressText: String = ""
    public var footerText: String = ""

    public init(
        type: String = "instruction",
        showStatusBar: Bool = false,
        title: String = "",
        instruction: String = "",
        icon: String = "",
        spinner: Bool = false,
        timeoutSeconds: Int = 0,
        progressText: String = "",
        footerText: String = ""
    ) {
        self.type = type
        self.showStatusBar = showStatusBar
        self.title = title
        self.instruction = instruction
        self.icon = icon
        self.spinner = spinner
        self.timeoutSeconds = timeoutSeconds
        self.progressText = progressText
        self.footerText = footerText
    }
}

/// Data for rendering a confirmation/prompt view (e.g. Yes/Cancel,
/// Connect/Delete). Items carry the action button labels and `action_id`s.
public struct PromptViewData: Sendable {
    public var type: String = "prompt"
    public var showStatusBar: Bool = false
    public var title: String = ""
    public var prompt: String = ""
    public var icon: String = ""
    public var items: [MenuItemData] = []

    public init(
        type: String = "prompt",
        showStatusBar: Bool = false,
        title: String = "",
        prompt: String = "",
        icon: String = "",
        items: [MenuItemData] = []
    ) {
        self.type = type
        self.showStatusBar = showStatusBar
        self.title = title
        self.prompt = prompt
        self.icon = icon
        self.items = items
    }
}

/// Union type for all view data types
public enum ViewData: Sendable {
    case home(HomeViewData)
    case menu(MenuViewData)
    case notification(NotificationViewData)
    case application(ApplicationViewData)
    case instruction(InstructionViewData)
    case prompt(PromptViewData)
    case render(RenderViewData)

    /// Returns true if this is a home view
    public var isHome: Bool {
        if case .home = self { return true }
        return false
    }

    /// Returns true if this is a menu view
    public var isMenu: Bool {
        if case .menu = self { return true }
        return false
    }

    /// Returns true if this is a notification view
    public var isNotification: Bool {
        if case .notification = self { return true }
        return false
    }

    /// Returns true if this is an application view
    public var isApplication: Bool {
        if case .application = self { return true }
        return false
    }

    /// Returns true if this is an instruction view
    public var isInstruction: Bool {
        if case .instruction = self { return true }
        return false
    }

    /// Returns true if this is a prompt view
    public var isPrompt: Bool {
        if case .prompt = self { return true }
        return false
    }

    /// Returns true if this is a render view
    public var isRender: Bool {
        if case .render = self { return true }
        return false
    }

    /// Returns the view type string
    public var type: String {
        switch self {
        case .home: return "home"
        case .menu: return "menu"
        case .notification: return "notification"
        case .application: return "application"
        case .instruction: return "instruction"
        case .prompt: return "prompt"
        case .render: return "render"
        }
    }

    /// Returns whether the status bar should be shown
    public var showStatusBar: Bool {
        switch self {
        case .home(let data): return data.showStatusBar
        case .menu(let data): return data.showStatusBar
        case .notification(let data): return data.showStatusBar
        case .application(let data): return data.showStatusBar
        case .instruction(let data): return data.showStatusBar
        case .prompt(let data): return data.showStatusBar
        case .render(let data): return data.showStatusBar
        }
    }
}

extension ViewData: CustomStringConvertible {
    public var description: String {
        switch self {
        case .home(let data):
            return "HomeView(items: \(data.menuItems.count), cpu: \(Int(data.cpuPercent))%, ram: \(Int(data.ramPercent))%)"
        case .menu(let data):
            return "MenuView(title: \"\(data.title)\", items: \(data.items.count), page: \(data.pageIndex + 1)/\(data.totalPages))"
        case .notification(let data):
            return "NotificationView(title: \"\(data.title)\")"
        case .application(let data):
            return "ApplicationView(id: \"\(data.applicationId)\")"
        case .instruction(let data):
            return "InstructionView(title: \"\(data.title)\", spinner: \(data.spinner))"
        case .prompt(let data):
            return "PromptView(title: \"\(data.title)\", items: \(data.items.count))"
        case .render(let data):
            return "RenderView(kind: \(data.kind.rawValue), title: \"\(data.title)\")"
        }
    }
}
