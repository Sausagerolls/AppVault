import AppKit
import Foundation

enum LocalFiles {
    static let supportDir: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppVault", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static let iconCacheDir: URL = {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppVault/icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static func isRunning(_ path: String) -> NSRunningApplication? {
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.first {
            guard let b = $0.bundleURL?.standardizedFileURL.path else { return false }
            return b == target || b.hasPrefix(target + "/")
        }
    }

    static func iconPNG(for path: String, size: CGFloat = 256) -> Data? {
        let img = NSWorkspace.shared.icon(forFile: path)
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    static func freeSpace(at path: String) -> Int64? {
        var p = path
        while !FileManager.default.fileExists(atPath: p), p != "/" { p = (p as NSString).deletingLastPathComponent }
        let v = try? URL(fileURLWithPath: p).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage
    }

    /// Removes a file or folder. It is first renamed (atomic), so a failure
    /// never leaves a half-deleted app behind. Falls back to an admin prompt
    /// when the item is owned by root (for example apps installed by a .pkg).
    static func remove(_ path: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) || (try? fm.destinationOfSymbolicLink(atPath: path)) != nil else { return }
        let parent = (path as NSString).deletingLastPathComponent
        let doomed = parent + "/.appvault-delete-" + UUID().uuidString
        do {
            try fm.moveItem(atPath: path, toPath: doomed)
        } catch {
            try adminRemove(path, original: error)
            return
        }
        do {
            try fm.removeItem(atPath: doomed)
        } catch {
            try adminRemove(doomed, original: error)
        }
    }

    private static func adminRemove(_ path: String, original: Error) throws {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"/bin/rm -rf \" & quoted form of \"\(escaped)\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&err)
        if FileManager.default.fileExists(atPath: path) {
            throw NSError(domain: "AppVault", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Could not delete \(path): \(original.localizedDescription). " +
                "If macOS blocked it, allow AppVault under System Settings › Privacy & Security › App Management."])
        }
    }

    /// Moves `src` to `dst`, replacing whatever is at `dst`.
    static func place(_ src: String, at dst: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if fm.fileExists(atPath: dst) || (try? fm.destinationOfSymbolicLink(atPath: dst)) != nil {
            try remove(dst)
        }
        try fm.moveItem(atPath: src, toPath: dst)
    }
}
