import Carbon
import CoreGraphics
import Foundation
import MacMCPCore

/// Mouse buttons supported by the input control helpers.
enum MouseButton {
    case left
    case right
    case center
}

/// Synchronous CoreGraphics input helpers using global display coordinates in points.
enum InputControl {
    private static let queue = DispatchQueue(label: "app.macMCP.input-control")

    /// Click at a global display coordinate in the target process.
    static func click(
        pid: Int,
        at point: CGPoint,
        button: MouseButton,
        clicks: Int,
        flags: CGEventFlags
    ) throws {
        try queue.sync {
            let source = eventSource()
            let pair = mouseEventTypes(for: button)
            let count = max(1, clicks)

            for _ in 0..<count {
                try postMouseEvent(
                    source: source,
                    type: pair.down,
                    point: point,
                    button: pair.button,
                    flags: flags,
                    clickState: count,
                    pid: pid)
                try postMouseEvent(
                    source: source,
                    type: pair.up,
                    point: point,
                    button: pair.button,
                    flags: flags,
                    clickState: count,
                    pid: pid)
            }
        }
    }

    /// Press-drag-release from `from` to `to` (global screen points, top-left origin), delivered
    /// to `pid` via event.postToPid (background-safe cursor-wise). Posts a button-down at `from`,
    /// `steps` interpolated drag events from→to, then a button-up at `to`. A small usleep between
    /// steps lets the target app track the drag. NOTE: a real mouse-down raises the clicked window
    /// — that's inherent to dragging.
    static func drag(
        pid: Int,
        from: CGPoint,
        to: CGPoint,
        steps: Int = 20,
        button: MouseButton = .left,
        flags: CGEventFlags = []
    ) throws {
        try queue.sync {
            let source = eventSource()
            let eventTypes: (down: CGEventType, dragged: CGEventType, up: CGEventType, button: CGMouseButton)
            switch button {
            case .left:
                eventTypes = (.leftMouseDown, .leftMouseDragged, .leftMouseUp, .left)
            case .right:
                eventTypes = (.rightMouseDown, .rightMouseDragged, .rightMouseUp, .right)
            case .center:
                eventTypes = (.otherMouseDown, .otherMouseDragged, .otherMouseUp, .center)
            }

            guard
                let down = CGEvent(
                    mouseEventSource: source,
                    mouseType: eventTypes.down,
                    mouseCursorPosition: from,
                    mouseButton: eventTypes.button)
            else {
                throw ToolError("Could not create mouse event.")
            }
            down.flags = flags
            down.postToPid(pid_t(pid))
            usleep(10_000)

            let count = max(1, steps)
            for i in 1...count {
                let progress = CGFloat(i) / CGFloat(count)
                let point = CGPoint(
                    x: from.x + ((to.x - from.x) * progress),
                    y: from.y + ((to.y - from.y) * progress))
                guard
                    let dragged = CGEvent(
                        mouseEventSource: source,
                        mouseType: eventTypes.dragged,
                        mouseCursorPosition: point,
                        mouseButton: eventTypes.button)
                else {
                    throw ToolError("Could not create mouse event.")
                }
                dragged.flags = flags
                dragged.postToPid(pid_t(pid))
                usleep(10_000)
            }

            guard
                let up = CGEvent(
                    mouseEventSource: source,
                    mouseType: eventTypes.up,
                    mouseCursorPosition: to,
                    mouseButton: eventTypes.button)
            else {
                throw ToolError("Could not create mouse event.")
            }
            up.flags = flags
            up.postToPid(pid_t(pid))
            usleep(10_000)
        }
    }

    /// Type Unicode text into the target process.
    static func typeText(pid: Int, _ text: String) throws {
        try queue.sync {
            let source = eventSource()
            for character in text {
                var utf16 = Array(String(character).utf16)
                try postUnicodeKey(source: source, keyDown: true, utf16: &utf16, pid: pid)
                try postUnicodeKey(source: source, keyDown: false, utf16: &utf16, pid: pid)
                usleep(1_000)
            }
        }
    }

    /// Press a plus-separated key combination in the target process.
    static func pressKey(pid: Int, combo: String) throws {
        try queue.sync {
            let parsed = try parse(combo: combo)
            let source = eventSource()

            guard
                let down = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: CGKeyCode(parsed.keyCode),
                    keyDown: true),
                let up = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: CGKeyCode(parsed.keyCode),
                    keyDown: false)
            else {
                throw ToolError("Could not create keyboard event for '\(combo)'.")
            }

            down.flags = parsed.flags
            up.flags = parsed.flags
            down.postToPid(pid_t(pid))
            up.postToPid(pid_t(pid))
        }
    }

    /// Scroll at a global display coordinate in the target process.
    static func scroll(pid: Int, at point: CGPoint, dx: Int32, dy: Int32) throws {
        try queue.sync {
            guard
                let event = CGEvent(
                    scrollWheelEvent2Source: eventSource(),
                    units: .pixel,
                    wheelCount: 2,
                    wheel1: dy,
                    wheel2: dx,
                    wheel3: 0)
            else {
                throw ToolError("Could not create scroll event.")
            }
            event.location = point
            event.postToPid(pid_t(pid))
        }
    }

    /// Click at a global display coordinate through the HID event tap.
    static func clickGlobal(
        at point: CGPoint,
        button: MouseButton,
        clicks: Int,
        flags: CGEventFlags
    ) throws {
        try queue.sync {
            let source = eventSource()
            let pair = mouseEventTypes(for: button)
            let count = max(1, clicks)

            for _ in 0..<count {
                try postMouseEvent(
                    source: source,
                    type: pair.down,
                    point: point,
                    button: pair.button,
                    flags: flags,
                    clickState: count,
                    pid: nil)
                try postMouseEvent(
                    source: source,
                    type: pair.up,
                    point: point,
                    button: pair.button,
                    flags: flags,
                    clickState: count,
                    pid: nil)
            }
        }
    }

    // MARK: - Internals

    private static func eventSource() -> CGEventSource? {
        CGEventSource(stateID: .hidSystemState)
    }

    private static func mouseEventTypes(for button: MouseButton) -> (
        down: CGEventType, up: CGEventType, button: CGMouseButton
    ) {
        switch button {
        case .left:
            return (.leftMouseDown, .leftMouseUp, .left)
        case .right:
            return (.rightMouseDown, .rightMouseUp, .right)
        case .center:
            return (.otherMouseDown, .otherMouseUp, .center)
        }
    }

    private static func postMouseEvent(
        source: CGEventSource?,
        type: CGEventType,
        point: CGPoint,
        button: CGMouseButton,
        flags: CGEventFlags,
        clickState: Int,
        pid: Int?
    ) throws {
        guard
            let event = CGEvent(
                mouseEventSource: source,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: button)
        else {
            throw ToolError("Could not create mouse event.")
        }

        event.flags = flags
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        if let pid {
            event.postToPid(pid_t(pid))
        } else {
            event.post(tap: .cghidEventTap)
        }
    }

    private static func postUnicodeKey(
        source: CGEventSource?,
        keyDown: Bool,
        utf16: inout [UInt16],
        pid: Int
    ) throws {
        guard
            let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: keyDown)
        else {
            throw ToolError("Could not create text input event.")
        }
        event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        event.postToPid(pid_t(pid))
    }

    private static func parse(combo: String) throws -> (keyCode: Int, flags: CGEventFlags) {
        let tokens = combo.split(separator: "+").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty }

        guard let keyName = tokens.last else {
            throw ToolError("Missing key in combo '\(combo)'.")
        }

        var flags = CGEventFlags()
        for token in tokens.dropLast() {
            switch token {
            case "cmd", "command":
                flags.insert(.maskCommand)
            case "shift":
                flags.insert(.maskShift)
            case "opt", "option", "alt":
                flags.insert(.maskAlternate)
            case "ctrl", "control":
                flags.insert(.maskControl)
            default:
                throw ToolError("Unknown modifier '\(token)' in combo '\(combo)'.")
            }
        }

        guard let keyCode = keyCode(for: keyName) else {
            throw ToolError("Unknown key '\(keyName)' in combo '\(combo)'.")
        }
        return (keyCode, flags)
    }

    private static func keyCode(for key: String) -> Int? {
        switch key {
        case "return", "enter": return kVK_Return
        case "tab": return kVK_Tab
        case "space": return kVK_Space
        case "escape", "esc": return kVK_Escape
        case "delete", "backspace": return kVK_Delete
        case "up": return kVK_UpArrow
        case "down": return kVK_DownArrow
        case "left": return kVK_LeftArrow
        case "right": return kVK_RightArrow
        case "home": return kVK_Home
        case "end": return kVK_End
        case "pageup": return kVK_PageUp
        case "pagedown": return kVK_PageDown
        case "f1": return kVK_F1
        case "f2": return kVK_F2
        case "f3": return kVK_F3
        case "f4": return kVK_F4
        case "f5": return kVK_F5
        case "f6": return kVK_F6
        case "f7": return kVK_F7
        case "f8": return kVK_F8
        case "f9": return kVK_F9
        case "f10": return kVK_F10
        case "f11": return kVK_F11
        case "f12": return kVK_F12
        default:
            return ansiKeyCode(for: key)
        }
    }

    private static func ansiKeyCode(for key: String) -> Int? {
        if key.count == 1, let scalar = key.unicodeScalars.first {
            switch scalar {
            case "a": return kVK_ANSI_A
            case "b": return kVK_ANSI_B
            case "c": return kVK_ANSI_C
            case "d": return kVK_ANSI_D
            case "e": return kVK_ANSI_E
            case "f": return kVK_ANSI_F
            case "g": return kVK_ANSI_G
            case "h": return kVK_ANSI_H
            case "i": return kVK_ANSI_I
            case "j": return kVK_ANSI_J
            case "k": return kVK_ANSI_K
            case "l": return kVK_ANSI_L
            case "m": return kVK_ANSI_M
            case "n": return kVK_ANSI_N
            case "o": return kVK_ANSI_O
            case "p": return kVK_ANSI_P
            case "q": return kVK_ANSI_Q
            case "r": return kVK_ANSI_R
            case "s": return kVK_ANSI_S
            case "t": return kVK_ANSI_T
            case "u": return kVK_ANSI_U
            case "v": return kVK_ANSI_V
            case "w": return kVK_ANSI_W
            case "x": return kVK_ANSI_X
            case "y": return kVK_ANSI_Y
            case "z": return kVK_ANSI_Z
            case "0": return kVK_ANSI_0
            case "1": return kVK_ANSI_1
            case "2": return kVK_ANSI_2
            case "3": return kVK_ANSI_3
            case "4": return kVK_ANSI_4
            case "5": return kVK_ANSI_5
            case "6": return kVK_ANSI_6
            case "7": return kVK_ANSI_7
            case "8": return kVK_ANSI_8
            case "9": return kVK_ANSI_9
            default: return nil
            }
        }
        return nil
    }
}
