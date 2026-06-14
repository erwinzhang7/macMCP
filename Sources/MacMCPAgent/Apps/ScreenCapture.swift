import AppKit
import CoreGraphics
import Foundation
import MacMCPCore
import ScreenCaptureKit

private let shareableContentCacheLock = NSLock()

/// Synchronous ScreenCaptureKit helpers for capturing app windows as PNG data.
enum ScreenCapture {
    private static let shareableContentCacheTTLNanoseconds: UInt64 = 750_000_000
    private static var cachedShareableContent: SCShareableContent?
    private static var cachedShareableContentFetchedAt: DispatchTime?

    private static let permissionHint =
        "Screen Recording permission is required. Enable it for the agent in System Settings "
        + "▸ Privacy & Security ▸ Screen Recording, then relaunch the agent and retry."

    /// Capture the window with the given CoreGraphics window id and return PNG bytes.
    @available(macOS 14.0, *)
    static func capturePNG(
        windowID: Int,
        pixelWidth requestedPixelWidth: Int = 0,
        pixelHeight requestedPixelHeight: Int = 0,
        jpeg: Bool = false
    ) throws -> Data {
        try ensurePermission()
        let enumerateStart = DispatchTime.now().uptimeNanoseconds
        var content = try shareableContent()
        var enumerateEnd = DispatchTime.now().uptimeNanoseconds
        guard let window = content.windows.first(where: { $0.windowID == CGWindowID(windowID) }) else {
            content = try shareableContent(forceRefresh: true)
            enumerateEnd = DispatchTime.now().uptimeNanoseconds
            guard let window = content.windows.first(where: { $0.windowID == CGWindowID(windowID) }) else {
                throw ToolError("No window found with window id \(windowID).")
            }
            let pixelSize = capturePixelSize(
                for: window,
                displays: content.displays,
                requestedPixelWidth: requestedPixelWidth,
                requestedPixelHeight: requestedPixelHeight)
            return try capturePNG(
                windowID: windowID,
                window: window,
                pixelWidth: pixelSize.width,
                pixelHeight: pixelSize.height,
                jpeg: jpeg,
                enumerateMs: (enumerateEnd - enumerateStart) / 1_000_000)
        }
        let pixelSize = capturePixelSize(
            for: window,
            displays: content.displays,
            requestedPixelWidth: requestedPixelWidth,
            requestedPixelHeight: requestedPixelHeight)
        return try capturePNG(
            windowID: windowID,
            window: window,
            pixelWidth: pixelSize.width,
            pixelHeight: pixelSize.height,
            jpeg: jpeg,
            enumerateMs: (enumerateEnd - enumerateStart) / 1_000_000)
    }

    /// Capture the largest on-screen layer-0 window owned by `pid` and return PNG bytes.
    @available(macOS 14.0, *)
    static func capturePNG(pid: pid_t) throws -> Data {
        try ensurePermission()
        let content = try shareableContent()
        let windows = content.windows.filter { window in
            window.owningApplication?.processID == pid
                && window.isOnScreen
                && window.windowLayer == 0
                && window.frame.width > 0
                && window.frame.height > 0
        }
        guard let window = windows.max(by: { area($0.frame) < area($1.frame) }) else {
            throw ToolError("No on-screen layer-0 window found for pid \(pid).")
        }
        let scale = backingScaleFactor(for: window, displays: content.displays)
        let pixelWidth = Int((window.frame.width * scale).rounded())
        let pixelHeight = Int((window.frame.height * scale).rounded())
        return try capturePNG(
            windowID: Int(window.windowID),
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            jpeg: false)
    }

    @available(macOS 14.0, *)
    static func capturePNG(pid: Int) throws -> Data {
        try capturePNG(pid: pid_t(pid))
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
    private static func shareableContent(forceRefresh: Bool = false) throws -> SCShareableContent {
        let now = DispatchTime.now()
        shareableContentCacheLock.lock()
        if !forceRefresh,
            let cachedShareableContent,
            let cachedShareableContentFetchedAt,
            now.uptimeNanoseconds - cachedShareableContentFetchedAt.uptimeNanoseconds
                < shareableContentCacheTTLNanoseconds
        {
            shareableContentCacheLock.unlock()
            return cachedShareableContent
        }
        shareableContentCacheLock.unlock()

        let content = try fetchShareableContent()

        shareableContentCacheLock.lock()
        cachedShareableContent = content
        cachedShareableContentFetchedAt = DispatchTime.now()
        shareableContentCacheLock.unlock()

        return content
    }

    @available(macOS 14.0, *)
    private static func fetchShareableContent() throws -> SCShareableContent {
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
    private static func capturePixelSize(
        for window: SCWindow,
        displays: [SCDisplay],
        requestedPixelWidth: Int,
        requestedPixelHeight: Int
    ) -> (width: Int, height: Int) {
        guard requestedPixelWidth <= 0 || requestedPixelHeight <= 0 else {
            return (requestedPixelWidth, requestedPixelHeight)
        }
        let scale = backingScaleFactor(for: window, displays: displays)
        return (
            Int((window.frame.width * scale).rounded()),
            Int((window.frame.height * scale).rounded()))
    }

    @available(macOS 14.0, *)
    private static func capturePNG(
        windowID: Int,
        window: SCWindow,
        pixelWidth: Int,
        pixelHeight: Int,
        jpeg: Bool,
        enumerateMs: UInt64
    ) throws -> Data {
        let capEncStart = DispatchTime.now().uptimeNanoseconds
        let filter = SCContentFilter(desktopIndependentWindow: window)

        let configuration = SCStreamConfiguration()
        configuration.width = max(1, pixelWidth)
        configuration.height = max(1, pixelHeight)
        configuration.scalesToFit = false
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true

        let image = try captureImage(contentFilter: filter, configuration: configuration)
        let rep = NSBitmapImageRep(cgImage: image)
        let fileType: NSBitmapImageRep.FileType = jpeg ? .jpeg : .png
        let properties: [NSBitmapImageRep.PropertyKey: Any] =
            jpeg ? [.compressionFactor: 0.7] : [:]
        guard let data = rep.representation(using: fileType, properties: properties) else {
            throw ToolError("Could not encode captured window as \(jpeg ? "JPEG" : "PNG").")
        }
        let capEncMs = (DispatchTime.now().uptimeNanoseconds - capEncStart) / 1_000_000
        log(
            "screenshot win=\(windowID) enumerate=\(enumerateMs)ms cap+enc=\(capEncMs)ms bytes=\(data.count) "
                + "\(pixelWidth)x\(pixelHeight) \(jpeg ? "jpeg" : "png")")
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
