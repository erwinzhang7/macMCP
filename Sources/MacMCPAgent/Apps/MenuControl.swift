import ApplicationServices
import Foundation
import MacMCPCore

/// Invoke an app's menu-bar items by title path (e.g. ["Playback", "Next"]). This works even
/// when the app is NOT frontmost — an app's menu bar stays in its Accessibility tree
/// regardless of focus, so this is the one reliable way to drive a backgrounded Electron app
/// (whose in-window AX tree collapses when it loses focus).
enum MenuControl {
    /// Select a menu item by its title path. Throws if any segment isn't found.
    static func select(pid: Int, path: [String]) throws -> String {
        guard !path.isEmpty else { throw ToolError("menu 'path' must have at least one entry.") }
        let appEl = AXUIElementCreateApplication(pid_t(pid))
        AXUIElementSetMessagingTimeout(appEl, 3.0)
        guard let menuBar = elementAttr(appEl, kAXMenuBarAttribute) else {
            throw ToolError("App (pid \(pid)) exposes no menu bar.")
        }

        var container = menuBar  // children are AXMenuBarItems; later, AXMenu items
        for (idx, segment) in path.enumerated() {
            let isLast = idx == path.count - 1
            guard let item = child(of: container, matchingTitle: segment) else {
                let sofar = path[..<idx].joined(separator: " ▸ ")
                throw ToolError(
                    "Menu item '\(segment)' not found"
                        + (sofar.isEmpty ? "." : " under \(sofar).")
                        + " (use mac_menu with no path, or mac_read_ui, to list available items)")
            }
            if isLast {
                let err = AXUIElementPerformAction(item, kAXPressAction as CFString)
                guard err == .success else {
                    throw ToolError("Could not invoke menu item '\(segment)': \(err).")
                }
                return "Selected: " + path.joined(separator: " ▸ ")
            }
            // Descend into this item's submenu (an AXMenu child). Cocoa menus sometimes only
            // populate a submenu's children after it's opened, so if it looks empty, press to
            // open it and re-read.
            guard var submenu = firstMenu(of: item) else {
                throw ToolError("Menu '\(segment)' has no submenu.")
            }
            if children(of: submenu).isEmpty {
                _ = AXUIElementPerformAction(item, kAXPressAction as CFString)
                submenu = firstMenu(of: item) ?? submenu
            }
            container = submenu
        }
        return "Selected: " + path.joined(separator: " ▸ ")
    }

    /// List the top-level menu titles and (optionally) the items under one of them — for
    /// discovering what `select` can target on a backgrounded app.
    static func list(pid: Int, under: String?) throws -> JSONValue {
        let appEl = AXUIElementCreateApplication(pid_t(pid))
        AXUIElementSetMessagingTimeout(appEl, 3.0)
        guard let menuBar = elementAttr(appEl, kAXMenuBarAttribute) else {
            throw ToolError("App (pid \(pid)) exposes no menu bar.")
        }
        let topTitles = children(of: menuBar).compactMap { title(of: $0) }
        guard let under else {
            return ["menus": .array(topTitles.map { .string($0) })]
        }
        guard let item = child(of: menuBar, matchingTitle: under),
            let submenu = firstMenu(of: item)
        else {
            throw ToolError("Top-level menu '\(under)' not found.")
        }
        var items = children(of: submenu)
        if items.isEmpty {  // lazy submenu: open then re-read
            _ = AXUIElementPerformAction(item, kAXPressAction as CFString)
            items = children(of: firstMenu(of: item) ?? submenu)
        }
        let names = items.compactMap { title(of: $0) }.filter { !$0.isEmpty }
        return ["menu": .string(under), "items": .array(names.map { .string($0) })]
    }

    // MARK: - AX helpers

    private static func elementAttr(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func children(of el: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &value) == .success,
            let array = value as? [AXUIElement]
        else { return [] }
        return array
    }

    private static func title(of el: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private static func role(of el: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private static func child(of container: AXUIElement, matchingTitle wanted: String)
        -> AXUIElement?
    {
        let target = wanted.lowercased()
        return children(of: container).first { title(of: $0)?.lowercased() == target }
    }

    private static func firstMenu(of item: AXUIElement) -> AXUIElement? {
        children(of: item).first { role(of: $0) == (kAXMenuRole as String) }
    }
}
