import AppKit
import CoreGraphics
import Foundation
import MacMCPCore
import ScreenCaptureKit

/// Synchronous ScreenCaptureKit helpers for capturing app windows as PNG data.
enum ScreenCapture {
    private static let permissionHint =
        "Screen Recording permission is required. Enable it for the agent in System Settings "
        + "▸ Privacy & Security ▸ Screen Recording, then relaunch the agent and retry."

    /// Capture the window with the given CoreGraphics window id and return PNG bytes.
    @available(macOS 14.0, *)
    static func capturePNG(windowID: Int) throws -> Data {
        try ensurePermission()
        let content = try shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == CGWindowID(windowID) }) else {
            throw ToolError("No window found with window id \(windowID).")
        }
        return try capturePNG(window: window, displays: content.displays)
    }

    /// Capture the largest on-screen layer-0 window owned by `pid` and return PNG bytes.
    @available(macOS 14.0, *)
    static func capturePNG(pid: Int) throws -> Data {
        try ensurePermission()
        let content = try shareableContent()
        let windows = content.windows.filter { window in
            window.owningApplication?.processID == pid_t(pid)
                && window.isOnScreen
                && window.windowLayer == 0
                && window.frame.width > 0
                && window.frame.height > 0
        }
        guard let window = windows.max(by: { area($0.frame) < area($1.frame) }) else {
            throw ToolError("No on-screen layer-0 window found for pid \(pid).")
        }
        return try capturePNG(window: window, displays: content.displays)
    }

    /// Return whether the current process already has Screen Recording permission.
    static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Prompt for Screen Recording permission and return the system call result.
    @discardableResult
    static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    // MARK: - Internals

    private static func ensurePermission() throws {
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            throw ToolError(permissionHint)
        }
    }

    @available(macOS 14.0, *)
    private static func shareableContent() throws -> SCShareableContent {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<SCShareableContent, Error>?

        SCShareableContent.getWithCompletionHandler { content, error in
            if let content {
                result = .success(content)
            } else {
                result = .failure(error ?? ToolError("ScreenCaptureKit returned no shareable content."))
            }
            semaphore.signal()
        }

        semaphore.wait()
        switch result {
        case .success(let content):
            return content
        case .failure(let error):
            throw ToolError("Could not enumerate windows with ScreenCaptureKit: \(error)")
        case .none:
            throw ToolError("Could not enumerate windows with ScreenCaptureKit.")
        }
    }

    @available(macOS 14.0, *)
    private static func capturePNG(window: SCWindow, displays: [SCDisplay]) throws -> Data {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = backingScaleFactor(for: window, displays: displays)

        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((window.frame.width * scale).rounded()))
        configuration.height = max(1, Int((window.frame.height * scale).rounded()))
        configuration.scalesToFit = false
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true

        let image = try captureImage(contentFilter: filter, configuration: configuration)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw ToolError("Could not encode captured window as PNG.")
        }
        return data
    }

    @available(macOS 14.0, *)
    private static func captureImage(
        contentFilter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) throws -> CGImage {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<CGImage, Error>?

        Task {
            do {
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: contentFilter,
                    configuration: configuration)
                result = .success(image)
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }

        semaphore.wait()
        switch result {
        case .success(let image):
            return image
        case .failure(let error):
            throw ToolError("Could not capture window with ScreenCaptureKit: \(error)")
        case .none:
            throw ToolError("Could not capture window with ScreenCaptureKit.")
        }
    }

    @available(macOS 14.0, *)
    private static func backingScaleFactor(for window: SCWindow, displays: [SCDisplay]) -> CGFloat {
        let windowFrame = window.frame
        let display = displays.max { lhs, rhs in
            lhs.frame.intersection(windowFrame).area < rhs.frame.intersection(windowFrame).area
        }
        guard let display, display.frame.intersects(windowFrame) else { return 2.0 }

        for screen in NSScreen.screens {
            guard
                let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? NSNumber,
                CGDirectDisplayID(number.uint32Value) == display.displayID
            else { continue }
            return screen.backingScaleFactor
        }
        return 2.0
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.width * rect.height
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull else { return 0 }
        return width * height
    }
}
