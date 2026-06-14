import ApplicationServices
import CoreGraphics
import Foundation
import MacMCPCore

/// Accessibility-backed window operations for an app process.
enum WindowControl {
    static func move(pid: Int, title: String?, to point: CGPoint) throws -> String {
        let window = try window(pid: pid, title: title)
        var point = point
        guard let axValue = AXValueCreate(.cgPoint, &point) else {
            throw ToolError("Could not create AX point value.")
        }
        let error = AXUIElementSetAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            axValue)
        guard error == .success else {
            throw ToolError("Could not move window: \(error).")
        }
        return "Moved \"\(displayTitle(of: window))\" to (\(format(point.x)), \(format(point.y)))"
    }

    static func resize(pid: Int, title: String?, to size: CGSize) throws -> String {
        let window = try window(pid: pid, title: title)
        var size = size
        guard let axValue = AXValueCreate(.cgSize, &size) else {
            throw ToolError("Could not create AX size value.")
        }
        let error = AXUIElementSetAttributeValue(
            window,
            kAXSizeAttribute as CFString,
            axValue)
        guard error == .success else {
            throw ToolError("Could not resize window: \(error).")
        }
        return "Resized \"\(displayTitle(of: window))\" to \(format(size.width))×\(format(size.height))"
    }

    static func setMinimized(pid: Int, title: String?, _ minimized: Bool) throws -> String {
        let window = try window(pid: pid, title: title)
        let value = (minimized ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef
        let error = AXUIElementSetAttributeValue(
            window,
            kAXMinimizedAttribute as CFString,
            value)
        guard error == .success else {
            throw ToolError("Could not set window minimized=\(minimized): \(error).")
        }
        let action = minimized ? "Minimized" : "Unminimized"
        return "\(action) \"\(displayTitle(of: window))\""
    }

    static func close(pid: Int, title: String?) throws -> String {
        let window = try window(pid: pid, title: title)
        guard let closeButton = elementAttr(window, kAXCloseButtonAttribute) else {
            throw ToolError("Window has no close button.")
        }
        let error = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
        guard error == .success else {
            throw ToolError("Could not close window: \(error).")
        }
        return "Closed \"\(displayTitle(of: window))\""
    }

    static func raise(pid: Int, title: String?) throws -> String {
        let window = try window(pid: pid, title: title)
        let error = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        guard error == .success else {
            throw ToolError("Could not raise window: \(error).")
        }
        return "Raised \"\(displayTitle(of: window))\""
    }

    static func list(pid: Int) -> JSONValue {
        let app = appElement(pid: pid)
        let windows = windows(of: app)
        let items = windows.map { window -> JSONValue in
            var object: [String: JSONValue] = [:]
            if let title = title(of: window) { object["title"] = .string(title) }
            if let position = pointAttribute(window, kAXPositionAttribute) {
                object["position"] = [
                    "x": .double(position.x),
                    "y": .double(position.y),
                ]
            }
            if let size = sizeAttribute(window, kAXSizeAttribute) {
                object["size"] = [
                    "width": .double(size.width),
                    "height": .double(size.height),
                ]
            }
            if let minimized = boolAttribute(window, kAXMinimizedAttribute) {
                object["minimized"] = .bool(minimized)
            }
            return .object(object)
        }
        return [
            "pid": .int(pid),
            "count": .int(items.count),
            "windows": .array(items),
        ]
    }

    // MARK: - Target selection

    private static func window(pid: Int, title wantedTitle: String?) throws -> AXUIElement {
        let app = appElement(pid: pid)
        let windows = windows(of: app)
        if let wantedTitle {
            let target = wantedTitle.lowercased()
            if let match = windows.first(where: {
                title(of: $0)?.lowercased().contains(target) == true
            }) {
                return match
            }
            throw ToolError("no matching window")
        }

        if let focusedWindow = elementAttr(app, kAXFocusedWindowAttribute) {
            return focusedWindow
        }
        if let first = windows.first {
            return first
        }
        throw ToolError("no matching window")
    }

    private static func appElement(pid: Int) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid_t(pid))
        AXUIElementSetMessagingTimeout(app, 2.0)
        return app
    }

    // MARK: - AX helpers

    private static func windows(of app: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
            let windows = value as? [AXUIElement]
        else { return [] }
        return windows
    }

    private static func elementAttr(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func title(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private static func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? Bool
    }

    private static func pointAttribute(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    private static func sizeAttribute(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }

    private static func displayTitle(of element: AXUIElement) -> String {
        let trimmed = title(of: element)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed! : "Untitled"
    }

    private static func format(_ value: CGFloat) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", Double(value))
    }
}
