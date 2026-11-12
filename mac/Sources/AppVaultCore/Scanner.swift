import Foundation

/// An app (or plain folder) found on this Mac that can be sent to the server.
public struct LocalItem: Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let kind: String // "app" or "folder"
    public let bundleId: String?
    public let version: String?
    public let build: String?
    public let appCategory: String?
    public let location: String
    public var size: Int64?          // allocated bytes on disk, nil while measuring
    public var fingerprint: String?

    public var url: URL { URL(fileURLWithPath: path) }

    public init(path: String, name: String, kind: String, bundleId: String?, version: String?, build: String?,
                appCategory: String?, location: String, size: Int64?, fingerprint: String?) {
        self.path = path; self.name = name; self.kind = kind; self.bundleId = bundleId
        self.version = version; self.build = build; self.appCategory = appCategory
        self.location = location; self.size = size; self.fingerprint = fingerprint
    }
}

public struct DataCandidate: Identifiable, Hashable {
    public var id: String { relativePath }
    /// Path relative to the home folder, e.g. "Library/Application Support/Foo".
    public let relativePath: String
    public let size: Int64
    public let suggested: Bool
}

public enum Scanner {
    public static let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// Lists offloadable items. Sizes are filled in later by `measure`.
    public static func scan(customFolders: [String]) -> [LocalItem] {
        var out: [LocalItem] = []
        var seen = Set<String>()
        let fm = FileManager.default
        let ownBundle = Bundle.main.bundlePath

        func addApp(_ path: String, location: String) {
            guard !seen.contains(path), path != ownBundle else { return }
            let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") as? [String: Any] ?? [:]
            let bid = info["CFBundleIdentifier"] as? String
            if let bid, bid.hasPrefix("com.apple.") { return } // built-in apps
            seen.insert(path)
            let name = (info["CFBundleDisplayName"] as? String)
                ?? (info["CFBundleName"] as? String)
                ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            out.append(LocalItem(path: path, name: name.isEmpty ? (path as NSString).lastPathComponent : name,
                                 kind: "app", bundleId: bid,
                                 version: info["CFBundleShortVersionString"] as? String,
                                 build: info["CFBundleVersion"] as? String,
                                 appCategory: info["LSApplicationCategoryType"] as? String,
                                 location: location, size: nil, fingerprint: nil))
        }

        func children(_ dir: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        }

        for (root, label) in [("/Applications", "Applications"), (home + "/Applications", "~/Applications")] {
            for c in children(root) {
                let p = root + "/" + c
                if c.hasSuffix(".app") {
                    addApp(p, location: label)
                } else if isDir(p) {
                    // One level deep, e.g. /Applications/Utilities or vendor folders.
                    for cc in children(p) where cc.hasSuffix(".app") {
                        addApp(p + "/" + cc, location: label + "/" + c)
                    }
                }
            }
        }

        for root in customFolders {
            let label = (root as NSString).abbreviatingWithTildeInPath
            for c in children(root) {
                let p = root + "/" + c
                if c.hasSuffix(".app") {
                    addApp(p, location: label)
                } else if isDir(p), !seen.contains(p) {
                    seen.insert(p)
                    out.append(LocalItem(path: p, name: c, kind: "folder", bundleId: nil, version: nil, build: nil,
                                         appCategory: nil, location: label, size: nil, fingerprint: nil))
                }
            }
        }
        return out
    }

    static func isDir(_ p: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &d) && d.boolValue
    }

    /// Measures disk usage and builds a cheap change fingerprint.
    /// The fingerprint changes when any file is added, removed, resized or modified.
    public static func measure(_ path: String) -> (size: Int64, fingerprint: String) {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        var allocated: Int64 = 0, logical: Int64 = 0, count = 0
        var newest: TimeInterval = 0
        if let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey]) {
            newest = rv.contentModificationDate?.timeIntervalSince1970 ?? 0
        }
        if let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) {
            for case let f as URL in en {
                guard let rv = try? f.resourceValues(forKeys: Set(keys)) else { continue }
                count += 1
                allocated += Int64(rv.totalFileAllocatedSize ?? 0)
                logical += Int64(rv.fileSize ?? 0)
                newest = max(newest, rv.contentModificationDate?.timeIntervalSince1970 ?? 0)
            }
        }
        return (allocated, "v1-\(count)-\(logical)-\(Int64(newest))")
    }

    /// Finds folders in ~/Library that probably belong to an app.
    public static func dataCandidates(for item: LocalItem) -> [DataCandidate] {
        var rel: [(String, Bool)] = []
        let folderName = (item.path as NSString).lastPathComponent
        let plainName = item.kind == "app" ? (folderName as NSString).deletingPathExtension : folderName
        var names = [plainName]
        if item.name != plainName { names.append(item.name) }
        if let b = item.bundleId {
            rel += [
                ("Library/Application Support/\(b)", true),
                ("Library/Containers/\(b)", true),
                ("Library/Preferences/\(b).plist", false),
                ("Library/Caches/\(b)", false),
                ("Library/HTTPStorages/\(b)", false),
                ("Library/Saved Application State/\(b).savedState", false),
                ("Library/WebKit/\(b)", false),
            ]
        }
        for n in names {
            rel += [("Library/Application Support/\(n)", true), ("Library/Logs/\(n)", false), ("Library/Caches/\(n)", false)]
        }
        var seen = Set<String>()
        var out: [DataCandidate] = []
        for (r, suggested) in rel where !seen.contains(r) {
            seen.insert(r)
            let full = home + "/" + r
            guard FileManager.default.fileExists(atPath: full) else { continue }
            out.append(DataCandidate(relativePath: r, size: measure(full).size, suggested: suggested))
        }
        return out
    }

    /// Maps LSApplicationCategoryType to a default AppVault category name.
    public static func suggestedCategory(for item: LocalItem) -> String {
        guard let c = item.appCategory?.lowercased() else { return "Uncategorized" }
        if c.contains("games") { return "Games" }
        let map: [String: String] = [
            "public.app-category.developer-tools": "Developer",
            "public.app-category.utilities": "Tools",
            "public.app-category.productivity": "Productivity",
            "public.app-category.business": "Productivity",
            "public.app-category.finance": "Productivity",
            "public.app-category.graphics-design": "Creative",
            "public.app-category.photography": "Creative",
            "public.app-category.video": "Creative",
            "public.app-category.music": "Creative",
            "public.app-category.entertainment": "Entertainment",
            "public.app-category.education": "Education",
            "public.app-category.reference": "Education",
            "public.app-category.social-networking": "Social",
            "public.app-category.news": "Social",
        ]
        return map[c] ?? "Uncategorized"
    }
}

public enum Format {
    private static let bcf: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
    public static func bytes(_ n: Int64) -> String { bcf.string(fromByteCount: n) }
}
