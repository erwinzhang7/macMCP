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
        let prepareStart = DispatchTime.now().uptimeNanoseconds
        let appElement = prepareApplicationElement(pid: pid)
        resetCache(pid: pid)
        let prepareEnd = DispatchTime.now().uptimeNanoseconds
        let result = collect(
            appElement: appElement,
            pid: pid,
            query: nil,
            roleFilter: nil,
            maxElements: max(0, maxElements))
        let walkEnd = DispatchTime.now().uptimeNanoseconds
        let prepMs = (prepareEnd - prepareStart) / 1_000_000
        let walkMs = (walkEnd - prepareEnd) / 1_000_000
        log("ax snapshot pid=\(pid) prepare=\(prepMs)ms walk=\(walkMs)ms visited=\(result.visited) included=\(result.included)")
        return result.json
    }

    /// Find actionable or labeled Accessibility elements matching `query` and optional role.
    static func find(pid: Int, query: String, role: String?, max: Int) throws -> JSONValue {
        try ensureTrusted()
        let prepareStart = DispatchTime.now().uptimeNanoseconds
        let appElement = prepareApplicationElement(pid: pid)
        resetCache(pid: pid)
        let prepareEnd = DispatchTime.now().uptimeNanoseconds
        let result = collect(
            appElement: appElement,
            pid: pid,
            query: query,
            roleFilter: role,
            maxElements: Swift.max(0, max))
        let walkEnd = DispatchTime.now().uptimeNanoseconds
        let prepMs = (prepareEnd - prepareStart) / 1_000_000
        let walkMs = (walkEnd - prepareEnd) / 1_000_000
        log("ax find pid=\(pid) prepare=\(prepMs)ms walk=\(walkMs)ms visited=\(result.visited) included=\(result.included)")
        return result.json
    }

    /// Find the first element matching `query` (and optional role) and return its cached ref,
    /// or nil if none. Used by one-shot actions (click-by-query, wait_for). The matched element
    /// is cached so the ref is immediately usable by press/frame/setValue.
    static func firstMatchRef(pid: Int, query: String, role: String?) throws -> String? {
        let result = try find(pid: pid, query: query, role: role, max: 1)
        return result["elements"]?.arrayValue?.first?["ref"]?.stringValue
    }

    /// Return a cached Accessibility element for a previous snapshot/find ref.
    static func element(forRef ref: String, pid: Int) -> AXUIElement? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return elementCache[cacheKey(pid: pid, ref: ref)]
    }

    /// Perform AXPress on a cached Accessibility element when the action is available.
    static func press(ref: String, pid: Int) throws -> Bool {
        guard let element = element(forRef: ref, pid: pid) else { return false }
        var names: CFArray?
        let namesError = AXUIElementCopyActionNames(element, &names)
        guard namesError == .success else {
            throw ToolError("Could not read actions for Accessibility ref '\(ref)': \(namesError).")
        }
        let actions = (names as? [String]) ?? []
        guard actions.contains(kAXPressAction as String) else { return false }

        let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard error == .success else {
            throw ToolError("Could not press Accessibility ref '\(ref)': \(error).")
        }
        return true
    }

    /// Set AXValue on a cached Accessibility element when the attribute accepts it.
    static func setValue(ref: String, pid: Int, _ value: String) throws -> Bool {
        guard let element = element(forRef: ref, pid: pid) else { return false }
        let error = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            value as CFTypeRef)
        switch error {
        case .success:
            return true
        case .illegalArgument, .attributeUnsupported:
            return false
        default:
            throw ToolError("Could not set value for Accessibility ref '\(ref)': \(error).")
        }
    }

    /// Focus a cached Accessibility element.
    static func focus(ref: String, pid: Int) throws {
        guard let element = element(forRef: ref, pid: pid) else { return }
        let error = AXUIElementSetAttributeValue(
            element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue)
        guard error == .success else {
            throw ToolError("Could not focus Accessibility ref '\(ref)': \(error).")
        }
    }

    /// Return the frame of a cached Accessibility element in global display coordinates.
    static func frame(ref: String, pid: Int) -> CGRect? {
        guard let element = element(forRef: ref, pid: pid),
            let position = pointAttribute(element, kAXPositionAttribute),
            let size = sizeAttribute(element, kAXSizeAttribute)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// "Click" the actionable element at a global screen point via AXPress instead of a synthetic
    /// mouse event. AXPress invokes the control WITHOUT activating/raising the app, so this keeps
    /// a backgrounded app in the background and never steals the user's focus. Walks up a few
    /// ancestors so a click on a label inside a button still finds the button. Returns false when
    /// nothing AXPress-able is under the point (caller falls back to a synthetic click).
    static func pressElementAt(_ point: CGPoint) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var found: AXUIElement?
        guard
            AXUIElementCopyElementAtPosition(
                systemWide, Float(point.x), Float(point.y), &found) == .success,
            var element = found
        else { return false }
        for _ in 0..<5 {
            if actionNames(element).contains(kAXPressAction as String) {
                return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
            }
            guard let parent = parentElement(element) else { break }
            element = parent
        }
        return false
    }

    private static func parentElement(_ element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value)
                == .success,
            let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    // MARK: - Collection

    private static func collect(
        appElement: AXUIElement,
        pid: Int,
        query: String?,
        roleFilter: String?,
        maxElements: Int
    ) -> (json: JSONValue, visited: Int, included: Int) {
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

        let json: JSONValue = [
            "app": .int(pid),
            "count": .int(elements.count),
            "elements": .array(elements),
        ]
        return (json, visited.count, elements.count)
    }

    private static func elementInfo(_ element: AXUIElement) -> ElementInfo {
        let attributes = [
            kAXRoleAttribute,
            kAXSubroleAttribute,
            kAXTitleAttribute,
            kAXValueAttribute,
            kAXDescriptionAttribute,
            kAXEnabledAttribute,
            kAXFocusedAttribute,
            kAXPositionAttribute,
            kAXSizeAttribute,
        ] as CFArray
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            element,
            attributes,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &values)
        if error != .success {
            values = nil
        }

        let role = stringValue(multipleAttributeValue(values, at: 0)) ?? ""
        let subrole = stringValue(multipleAttributeValue(values, at: 1))
        let title = stringValue(multipleAttributeValue(values, at: 2))
        let value = isSecureTextField(role: role, subrole: subrole)
            ? nil : stringLikeValue(multipleAttributeValue(values, at: 3))
        let description = stringValue(multipleAttributeValue(values, at: 4))
        let enabled = boolValue(multipleAttributeValue(values, at: 5))
        let focused = boolValue(multipleAttributeValue(values, at: 6))
        let position = pointValue(multipleAttributeValue(values, at: 7))
        let size = sizeValue(multipleAttributeValue(values, at: 8))
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
        // Always (re)enable: Electron/Chromium tears down its renderer accessibility tree when
        // the app loses focus, so caching "already enabled" would leave us with only the menu
        // bar. Re-setting AXManualAccessibility each time prompts it to rebuild. It's one cheap
        // IPC, and the poll below exits immediately when content is already present (native apps).
        enableManualAccessibility(appElement)
        waitForWindowContent(appElement)
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

    /// Poll until the app's windows expose child content — Electron rebuilds its window subtree
    /// lazily after AXManualAccessibility is (re)enabled. Native apps return immediately; a
    /// backgrounded Electron app never populates (Chromium only builds the tree for a focused
    /// window), so this is bounded to ~1.2s and then returns what's available (the menu bar).
    private static func waitForWindowContent(_ appElement: AXUIElement) {
        for _ in 0..<6 {
            if windowsHaveContent(appElement) { return }
            usleep(200_000)
        }
    }

    private static func windowsHaveContent(_ appElement: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
                == .success,
            let windows = value as? [AXUIElement]
        else { return false }
        if windows.isEmpty { return true }  // menu-bar-only app: nothing to wait for
        return windows.contains { (children(of: $0)?.count ?? 0) > 0 }
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
        return stringLikeValue(value)
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
        guard error == .success, let value else { return nil }
        return pointValue(value)
    }

    private static func sizeAttribute(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success, let value else { return nil }
        return sizeValue(value)
    }

    private static func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        let error = AXUIElementCopyActionNames(element, &names)
        guard error == .success else { return [] }
        return (names as? [String]) ?? []
    }

    private static func multipleAttributeValue(_ values: CFArray?, at index: CFIndex) -> CFTypeRef? {
        guard let values, index < CFArrayGetCount(values) else { return nil }
        let raw = CFArrayGetValueAtIndex(values, index)
        let value = Unmanaged<CFTypeRef>.fromOpaque(raw!).takeUnretainedValue()
        return isAXErrorValue(value) ? nil : value
    }

    private static func isAXErrorValue(_ value: CFTypeRef) -> Bool {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return false }
        return AXValueGetType(value as! AXValue) == .axError
    }

    private static func stringValue(_ value: CFTypeRef?) -> String? {
        value as? String
    }

    private static func stringLikeValue(_ value: CFTypeRef?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func boolValue(_ value: CFTypeRef?) -> Bool? {
        value as? Bool
    }

    private static func pointValue(_ value: CFTypeRef?) -> CGPoint? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    private static func sizeValue(_ value: CFTypeRef?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
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
