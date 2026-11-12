import AppKit
import AppVaultCore
import Foundation

enum ServerStatus: Equatable {
    case unknown, connecting, online, offline(String)
}

/// How a local item relates to the server library.
enum LocalStatus {
    case notOnServer
    case onServer(ItemMeta, unchanged: Bool)
}

@MainActor
final class AppModel: ObservableObject {
    let settings = AppSettings()
    let transfers = TransferManager()

    @Published var local: [LocalItem] = []
    @Published var items: [ItemMeta] = []
    @Published var categories: [CategoryInfo] = []
    @Published var stats: ServerStats?
    @Published var status: ServerStatus = .unknown
    @Published var alert: String?
    @Published var scanning = false
    @Published private(set) var icons: [String: NSImage] = [:]

    private var measureTask: Task<Void, Never>?
    private var measureCache: [String: (mtime: Date, size: Int64, fp: String)] = [:]
    private var iconLoads = Set<String>()

    init() {
        transfers.model = self
    }

    var client: APIClient? {
        guard let url = settings.normalizedURL, !settings.token.isEmpty else { return nil }
        return APIClient(baseURL: url, token: settings.token)
    }

    // MARK: refresh

    func refreshAll() async {
        async let a: Void = refreshLibrary()
        refreshLocal()
        await a
    }

    func refreshAfterTransfer() async {
        refreshLocal()
        await refreshLibrary()
    }

    func refreshLibrary() async {
        guard let client else {
            status = .offline("Not configured")
            return
        }
        if status != .online { status = .connecting }
        do {
            async let i = client.items()
            async let c = client.categories()
            async let s = client.stats()
            let (ii, cc, ss) = try await (i, c, s)
            items = ii
            categories = cc
            stats = ss
            status = .online
        } catch {
            status = .offline(error.localizedDescription)
        }
    }

    func refreshLocal() {
        let folders = settings.customFolders
        scanning = true
        Task {
            let found = (try? await runInBackground { Scanner.scan(customFolders: folders) }) ?? []
            // Keep sizes we already know for unchanged items.
            local = found.map { item in
                var it = item
                if let c = measureCache[item.path], c.mtime == Self.mtime(item.path) {
                    it.size = c.size
                    it.fingerprint = c.fp
                }
                return it
            }
            scanning = false
            measureMissing()
        }
    }

    nonisolated private static func mtime(_ path: String) -> Date {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func measureMissing() {
        measureTask?.cancel()
        let todo = local.filter { $0.size == nil }.map(\.path)
        guard !todo.isEmpty else { return }
        measureTask = Task {
            await withTaskGroup(of: (String, Int64, String, Date).self) { group in
                var it = todo.makeIterator()
                func addNext() {
                    guard let p = it.next() else { return }
                    group.addTask {
                        let m = Scanner.measure(p)
                        return (p, m.size, m.fingerprint, AppModel.mtime(p))
                    }
                }
                for _ in 0..<4 { addNext() }
                for await (p, size, fp, mt) in group {
                    if Task.isCancelled { break }
                    measureCache[p] = (mt, size, fp)
                    if let i = local.firstIndex(where: { $0.path == p }) {
                        local[i].size = size
                        local[i].fingerprint = fp
                    }
                    addNext()
                }
            }
        }
    }

    // MARK: matching

    func serverItem(for l: LocalItem) -> ItemMeta? {
        if let m = items.first(where: { $0.originalPath == l.path }) { return m }
        if let b = l.bundleId { return items.first { $0.bundleId == b && $0.kind == "app" } }
        return nil
    }

    func status(of l: LocalItem) -> LocalStatus {
        guard let m = serverItem(for: l) else { return .notOnServer }
        return .onServer(m, unchanged: l.fingerprint != nil && l.fingerprint == m.fingerprint)
    }

    func isInstalled(_ m: ItemMeta) -> Bool { FileManager.default.fileExists(atPath: m.originalPath) }

    func isBusy(path: String) -> Bool {
        transfers.transfers.contains {
            !$0.state.isFinished && ($0.offload?.path == path || $0.restore?.item.originalPath == path)
        }
    }

    // MARK: actions

    func offload(_ l: LocalItem, category: String, move: Bool, dataPaths: [String]) async {
        guard let client else { alert = APIError.notConfigured.localizedDescription; return }
        let existing = serverItem(for: l)

        // Same version already stored? Skip the upload.
        if let existing, let fp = l.fingerprint, fp == existing.fingerprint,
           dataPaths.isEmpty || Set(dataPaths) == Set(existing.dataPaths ?? []) {
            do {
                if existing.category != category { _ = try await client.setCategory(existing.id, category) }
                if move {
                    if let running = LocalFiles.isRunning(l.path) {
                        alert = "Quit \(running.localizedName ?? l.name) first."
                        return
                    }
                    try LocalFiles.remove(l.path)
                    for rel in dataPaths { try LocalFiles.remove(Scanner.home + "/" + rel) }
                }
                alert = move ? "\(l.name) was already on the server unchanged. Removed it from this Mac."
                             : "\(l.name) is already on the server and unchanged."
            } catch {
                alert = error.localizedDescription
            }
            await refreshAfterTransfer()
            return
        }

        let rec = OffloadRecord(path: l.path, name: l.name, kind: l.kind, bundleId: l.bundleId, version: l.version,
                                build: l.build, appCategory: l.appCategory, category: category, move: move,
                                dataPaths: dataPaths, replaces: existing?.id)
        transfers.enqueue(offload: rec)
    }

    func restore(_ m: ItemMeta, includeData: Bool) {
        transfers.enqueue(restore: RestoreRequest(item: m, includeData: includeData))
    }

    func deleteFromServer(_ m: ItemMeta) async {
        await perform { try await $0.deleteItem(m.id) }
        icons[m.id] = nil
    }

    func move(_ m: ItemMeta, to category: String) async {
        await perform { _ = try await $0.setCategory(m.id, category) }
    }

    func createCategory(_ name: String) async {
        await perform { try await $0.createCategory(name) }
    }

    func renameCategory(_ old: String, to new: String) async {
        await perform { try await $0.renameCategory(old, to: new) }
    }

    func deleteCategory(_ name: String) async {
        await perform { try await $0.deleteCategory(name) }
    }

    private func perform(_ op: (APIClient) async throws -> Void) async {
        guard let client else { alert = APIError.notConfigured.localizedDescription; return }
        do { try await op(client) } catch { alert = error.localizedDescription }
        await refreshLibrary()
    }

    // MARK: icons

    func localIcon(_ path: String) -> NSImage { NSWorkspace.shared.icon(forFile: path) }

    func icon(for m: ItemMeta) -> NSImage? {
        if let i = icons[m.id] { return i }
        guard m.hasIcon, !iconLoads.contains(m.id) else { return nil }
        iconLoads.insert(m.id)
        let stamp = Int(m.uploadedAt?.timeIntervalSince1970 ?? 0)
        let file = LocalFiles.iconCacheDir.appendingPathComponent("\(m.id)-\(stamp).png")
        Task {
            defer { iconLoads.remove(m.id) }
            if let d = try? Data(contentsOf: file), let img = NSImage(data: d) {
                icons[m.id] = img
                return
            }
            guard let client, let d = try? await client.icon(m.id), let img = NSImage(data: d) else { return }
            try? d.write(to: file)
            icons[m.id] = img
        }
        return nil
    }
}
