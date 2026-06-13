import ApplicationServices
import CoreGraphics
import Foundation
import MacMCPCore

/// Synchronous Accessibility helpers for discovering and resolving UI elements by ref.
enum AXController {
    private static let cacheLock = NSLock()
    private static var elementCache: [String: AXUIElement] = [:]

    private static let actionableRoles: Set<String> = [
        "AXButton",
        "AXTextField",
        "AXTextArea",
        "AXLink",
        "AXMenuItem",
        "AXCheckBox",
        "AXRadioButton",
        "AXComboBox",
        "AXPopUpButton",
        "AXSlider",
        "AXStaticText",
        "AXImage",
    ]

    /// Return whether the current process is trusted for Accessibility.
    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prompt the user to grant Accessibility trust to the current process.
    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Snapshot actionable or labeled Accessibility elements for an app pid.
    static func snapshot(pid: Int, maxElements: Int) throws -> JSONValue {
        try ensureTrusted()
        let appElement = prepareApplicationElement(pid: pid)
        resetCache(pid: pid)
        return collect(
            appElement: appElement,
            pid: pid,
            query: nil,
            roleFilter: nil,
            maxElements: max(0, maxElements))
    }

    /// Find actionable or labeled Accessibility elements matching `query` and optional role.
    static func find(pid: Int, query: String, role: String?, max: Int) throws -> JSONValue {
        try ensureTrusted()
        let appElement = prepareApplicationElement(pid: pid)
        resetCache(pid: pid)
        return collect(
            appElement: appElement,
            pid: pid,
            query: query,
            roleFilter: role,
            maxElements: Swift.max(0, max))
    }

    /// Return a cached Accessibility element for a previous snapshot/find ref.
    static func element(forRef ref: String, pid: Int) -> AXUIElement? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return elementCache[cacheKey(pid: pid, ref: ref)]
    }

    // MARK: - Collection

    private static func collect(
        appElement: AXUIElement,
        pid: Int,
        query: String?,
        roleFilter: String?,
        maxElements: Int
    ) -> JSONValue {
        var queue: [AXUIElement] = [appElement]
        var nextIndex = 0
        var visited = Set<UInt>()
        var elements: [JSONValue] = []
        var refNumber = 1
        let normalizedQuery = query?.lowercased() ?? ""
        let normalizedRole = roleFilter?.lowercased()

        while nextIndex < queue.count && elements.count < maxElements {
            let element = queue[nextIndex]
            nextIndex += 1

            let hash = CFHash(element)
            guard !visited.contains(hash) else { continue }
            visited.insert(hash)

            let info = elementInfo(element)
            if let children = children(of: element) {
                queue.append(contentsOf: children)
            }

            guard shouldInclude(info) else { continue }
            if let normalizedRole, info.role.lowercased() != normalizedRole { continue }
            if !normalizedQuery.isEmpty && !matches(info, query: normalizedQuery) { continue }

            let ref = "e\(refNumber)"
            refNumber += 1
            cache(element: element, pid: pid, ref: ref)
            elements.append(json(for: info, ref: ref))
        }

        return [
            "app": .int(pid),
            "count": .int(elements.count),
            "elements": .array(elements),
        ]
    }

    private static func elementInfo(_ element: AXUIElement) -> ElementInfo {
        let role = stringAttribute(element, kAXRoleAttribute) ?? ""
        let subrole = stringAttribute(element, kAXSubroleAttribute)
        let title = stringAttribute(element, kAXTitleAttribute)
        let value = isSecureTextField(role: role, subrole: subrole)
            ? nil : stringLikeAttribute(element, kAXValueAttribute)
        let description = stringAttribute(element, kAXDescriptionAttribute)
        let enabled = boolAttribute(element, kAXEnabledAttribute)
        let focused = boolAttribute(element, kAXFocusedAttribute)
        let position = pointAttribute(element, kAXPositionAttribute)
        let size = sizeAttribute(element, kAXSizeAttribute)
        let actions = actionNames(element)

        return ElementInfo(
            role: role,
            subrole: subrole,
            title: title,
            value: value,
            description: description,
            enabled: enabled,
            focused: focused,
            position: position,
            size: size,
            actions: actions)
    }

    private static func shouldInclude(_ info: ElementInfo) -> Bool {
        guard let size = info.size, size.width > 0, size.height > 0 else { return false }
        if !info.actions.isEmpty { return true }

        switch info.role {
        case "AXStaticText":
            return hasText(info.title) || hasText(info.value)
        case "AXImage":
            return hasText(info.title) || hasText(info.description)
        default:
            return actionableRoles.contains(info.role)
        }
    }

    private static func matches(_ info: ElementInfo, query: String) -> Bool {
        [info.role, info.title, info.value, info.description]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains(query) }
    }

    private static func json(for info: ElementInfo, ref: String) -> JSONValue {
        var object: [String: JSONValue] = [
            "ref": .string(ref),
            "role": .string(info.role),
            "actions": .array(info.actions.map { .string($0) }),
        ]

        if let title = nonEmpty(info.title) { object["title"] = .string(title) }
        if let subrole = nonEmpty(info.subrole) { object["subrole"] = .string(subrole) }
        if let value = nonEmpty(info.value) { object["value"] = .string(value) }
        if let description = nonEmpty(info.description) {
            object["description"] = .string(description)
        }
        if let enabled = info.enabled { object["enabled"] = .bool(enabled) }
        if let focused = info.focused { object["focused"] = .bool(focused) }
        if let position = info.position, let size = info.size {
            object["rect"] = [
                "x": .double(position.x),
                "y": .double(position.y),
                "width": .double(size.width),
                "height": .double(size.height),
            ]
        }

        return .object(object)
    }

    // MARK: - App setup

    private static func ensureTrusted() throws {
        guard AXIsProcessTrusted() else {
            throw ToolError(
                "Accessibility permission is required. Enable it for the agent in System Settings "
                    + "▸ Privacy & Security ▸ Accessibility, then relaunch the agent and retry.")
        }
    }

    private static func prepareApplicationElement(pid: Int) -> AXUIElement {
        let appElement = AXUIElementCreateApplication(pid_t(pid))
        AXUIElementSetMessagingTimeout(appElement, 2.0)
        enableManualAccessibility(appElement)
        waitForChildren(appElement)
        return appElement
    }

    private static func enableManualAccessibility(_ appElement: AXUIElement) {
        let manual = AXUIElementSetAttributeValue(
            appElement,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue)
        if manual == .attributeUnsupported {
            _ = AXUIElementSetAttributeValue(
                appElement,
                "AXEnhancedUserInterface" as CFString,
                kCFBooleanTrue)
        }
    }

    private static func waitForChildren(_ appElement: AXUIElement) {
        for _ in 0..<5 {
            if (children(of: appElement)?.count ?? 0) > 0 { return }
            usleep(300_000)
        }
    }

    // MARK: - AX reads

    private static func children(of element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        guard error == .success else { return nil }
        return value as? [AXUIElement]
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value as? String
    }

    private static func stringLikeAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success, let value else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value as? Bool
    }

    private static func pointAttribute(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    private static func sizeAttribute(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }

    private static func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        let error = AXUIElementCopyActionNames(element, &names)
        guard error == .success else { return [] }
        return (names as? [String]) ?? []
    }

    // MARK: - Cache

    private static func resetCache(pid: Int) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let prefix = "\(pid):"
        elementCache = elementCache.filter { !$0.key.hasPrefix(prefix) }
    }

    private static func cache(element: AXUIElement, pid: Int, ref: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        elementCache[cacheKey(pid: pid, ref: ref)] = element
    }

    private static func cacheKey(pid: Int, ref: String) -> String {
        "\(pid):\(ref)"
    }

    // MARK: - Helpers

    private static func isSecureTextField(role: String, subrole: String?) -> Bool {
        role == "AXTextField" && subrole == "AXSecureTextField"
    }

    private static func hasText(_ value: String?) -> Bool {
        nonEmpty(value) != nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }
}

private struct ElementInfo {
    let role: String
    let subrole: String?
    let title: String?
    let value: String?
    let description: String?
    let enabled: Bool?
    let focused: Bool?
    let position: CGPoint?
    let size: CGSize?
    let actions: [String]
}
