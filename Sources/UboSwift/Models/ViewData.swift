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

/// Union type for all view data types
public enum ViewData: Sendable {
    case home(HomeViewData)
    case menu(MenuViewData)
    case notification(NotificationViewData)
    case application(ApplicationViewData)

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

    /// Returns the view type string
    public var type: String {
        switch self {
        case .home: return "home"
        case .menu: return "menu"
        case .notification: return "notification"
        case .application: return "application"
        }
    }

    /// Returns whether the status bar should be shown
    public var showStatusBar: Bool {
        switch self {
        case .home(let data): return data.showStatusBar
        case .menu(let data): return data.showStatusBar
        case .notification(let data): return data.showStatusBar
        case .application(let data): return data.showStatusBar
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
        }
    }
}
