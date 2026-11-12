import AppKit
import AppVaultCore
import Foundation

// MARK: - Persisted state for offloads (so they survive app restarts)

struct PartProgress: Codable {
    var offset: Int64
    var hashState: Data
}

struct OffloadRecord: Codable {
    var id = UUID()
    var path: String
    var name: String
    var kind: String
    var bundleId: String?
    var version: String?
    var build: String?
    var appCategory: String?
    var category: String
    var move: Bool
    var dataPaths: [String]
    var replaces: String?
    var uploadId: String?
    var signatures: [String: String] = [:]
    var progress: [String: PartProgress] = [:]
    var finished: [String: PartInfo] = [:]
}

struct RestoreRequest {
    var item: ItemMeta
    var includeData: Bool
}

// MARK: - Transfer

@MainActor
final class Transfer: ObservableObject, Identifiable {
    enum Kind { case offload, restore }
    enum State: Equatable {
        case queued, preparing, running, paused, finishing, done, failed(String), cancelled
        var isActive: Bool { [.preparing, .running, .finishing].contains(self) }
        var isFinished: Bool {
            switch self { case .done, .cancelled, .failed: return true; default: return false }
        }
    }

    let id = UUID()
    let kind: Kind
    let title: String
    @Published var state: State = .queued
    @Published var detail = ""
    @Published var done: Int64 = 0
    @Published var total: Int64 = 0
    @Published var speed: Double = 0 // bytes per second

    var offload: OffloadRecord?
    var restore: RestoreRequest?
    var pauseRequested = false
    var cancelRequested = false

    init(offload: OffloadRecord) {
        kind = .offload
        title = offload.name
        self.offload = offload
    }

    init(restore: RestoreRequest) {
        kind = .restore
        title = restore.item.name
        self.restore = restore
    }

    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
}

struct PausedSignal: Error {}
struct CancelledSignal: Error {}

/// Lets non-Sendable work move to a background thread. Each value is used
/// by one task at a time.
struct Unchecked<T>: @unchecked Sendable { let value: T }

func runInBackground<T>(_ work: @escaping () throws -> T) async throws -> T {
    let box = Unchecked(value: work)
    let result = try await Task.detached(priority: .userInitiated) { Unchecked(value: try box.value()) }.value
    return result.value
}

// MARK: - Manager

@MainActor
final class TransferManager: ObservableObject {
    @Published private(set) var transfers: [Transfer] = []
    weak var model: AppModel?

    private var running = false
    private let chunkSize = 32 << 20     // upload chunk
    private let downloadChunk: Int64 = 64 << 20
    private let recordsURL = LocalFiles.supportDir.appendingPathComponent("offloads.json")

    init() {
        if let d = try? Data(contentsOf: recordsURL),
           let recs = try? JSONDecoder().decode([OffloadRecord].self, from: d) {
            for r in recs {
                let t = Transfer(offload: r)
                t.state = .paused
                t.detail = "Interrupted. Press Resume to continue."
                transfers.append(t)
            }
        }
    }

    var activeCount: Int { transfers.filter { !$0.state.isFinished }.count }

    func enqueue(offload r: OffloadRecord) {
        transfers.append(Transfer(offload: r))
        persist()
        pump()
    }

    func enqueue(restore r: RestoreRequest) {
        transfers.append(Transfer(restore: r))
        pump()
    }

    func pause(_ t: Transfer) {
        if t.state == .queued { t.state = .paused; return }
        t.pauseRequested = true
        t.detail = "Pausing…"
    }

    func resume(_ t: Transfer) {
        guard t.state == .paused || { if case .failed = t.state { return true } else { return false } }() else { return }
        t.pauseRequested = false
        t.cancelRequested = false
        t.state = .queued
        t.detail = ""
        pump()
    }

    func cancel(_ t: Transfer) {
        if t.state.isActive {
            t.cancelRequested = true
            t.detail = "Cancelling…"
        } else {
            finishCancel(t)
        }
    }

    private func finishCancel(_ t: Transfer) {
        t.state = .cancelled
        t.detail = ""
        if let r = t.offload, let uid = r.uploadId, let client = model?.client {
            Task { try? await client.abortUpload(uid) }
        }
        persist()
    }

    func clearFinished() {
        transfers.removeAll { $0.state.isFinished }
        persist()
    }

    private func persist() {
        let recs = transfers.filter { !$0.state.isFinished }.compactMap { $0.offload }
        if let d = try? JSONEncoder().encode(recs) { try? d.write(to: recordsURL, options: .atomic) }
    }

    private func pump() {
        guard !running, let next = transfers.first(where: { $0.state == .queued }) else { return }
        running = true
        Task {
            await run(next)
            running = false
            pump()
        }
    }

    private func run(_ t: Transfer) async {
        t.state = .preparing
        do {
            guard let client = model?.client else { throw APIError.notConfigured }
            switch t.kind {
            case .offload: try await runOffload(t, client)
            case .restore: try await runRestore(t, client)
            }
            t.state = .done
            t.speed = 0
        } catch is PausedSignal {
            t.state = .paused
            t.detail = "Paused"
            t.speed = 0
        } catch is CancelledSignal {
            finishCancel(t)
        } catch {
            t.state = .failed(error.localizedDescription)
            t.detail = ""
            t.speed = 0
        }
        persist()
        await model?.refreshAfterTransfer()
    }

    private func checkpoint(_ t: Transfer) throws {
        if t.cancelRequested { throw CancelledSignal() }
        if t.pauseRequested { throw PausedSignal() }
    }

    // MARK: Offload

    private func runOffload(_ t: Transfer, _ client: APIClient) async throws {
        guard var rec = t.offload else { return }
        let save = { [weak self] in t.offload = rec; self?.persist() }

        guard FileManager.default.fileExists(atPath: rec.path) else {
            throw NSError(domain: "AppVault", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(rec.path) no longer exists."])
        }
        if let app = LocalFiles.isRunning(rec.path) {
            throw NSError(domain: "AppVault", code: 3, userInfo: [NSLocalizedDescriptionKey:
                "Quit \(app.localizedName ?? rec.name) before sending it."])
        }

        t.detail = "Reading files…"
        let path = rec.path, dataPaths = rec.dataPaths
        let appPlan = try await runInBackground { try TarPlan(roots: [(path, (path as NSString).lastPathComponent)]) }
        let dataPlan: TarPlan? = dataPaths.isEmpty ? nil : try await runInBackground {
            try TarPlan(roots: dataPaths.map { (Scanner.home + "/" + $0, $0) })
        }
        var plans: [(String, TarPlan)] = [("app", appPlan)]
        if let dataPlan { plans.append(("data", dataPlan)) }
        try checkpoint(t)

        // Files changed since a previous attempt? Then start fresh.
        let sigs = Dictionary(uniqueKeysWithValues: plans.map { ($0.0, $0.1.signature) })
        if rec.uploadId != nil && rec.signatures != sigs {
            if let uid = rec.uploadId { try? await client.abortUpload(uid) }
            rec.uploadId = nil
        }

        var serverOffsets: [String: Int64] = [:]
        if let uid = rec.uploadId {
            do {
                serverOffsets = try await client.upload(uid).offsets
            } catch APIError.http(404, _) {
                rec.uploadId = nil
            }
        }
        if rec.uploadId == nil {
            rec.progress = [:]
            rec.finished = [:]
            rec.signatures = sigs
            t.detail = "Measuring…"
            let measured = try await runInBackground { Scanner.measure(path) }
            let meta = ItemMeta(name: rec.name, kind: rec.kind, bundleId: rec.bundleId, version: rec.version,
                                build: rec.build, appCategory: rec.appCategory, category: rec.category,
                                originalPath: rec.path, fingerprint: measured.fingerprint,
                                installedSize: measured.size, dataPaths: rec.dataPaths.isEmpty ? nil : rec.dataPaths)
            let expected = plans.reduce(Int64(0)) { $0 + $1.1.totalSize }
            let up = try await client.createUpload(meta: meta, replaces: rec.replaces, expectedBytes: expected)
            rec.uploadId = up.id
            serverOffsets = up.offsets
            save()
            if let png = LocalFiles.iconPNG(for: rec.path) {
                try? await client.putIcon(up.id, png: png)
            }
        }
        guard let uploadId = rec.uploadId else { return }

        t.total = plans.reduce(0) { $0 + $1.1.totalSize }
        t.done = plans.reduce(0) { $0 + min(serverOffsets[$1.0] ?? 0, $1.1.totalSize) }
        t.state = .running

        for (part, plan) in plans where rec.finished[part] == nil {
            let base = t.done - min(serverOffsets[part] ?? 0, plan.totalSize)
            let info = try await uploadPart(t, client, uploadId: uploadId, part: part, plan: plan,
                                            serverOffset: serverOffsets[part] ?? 0, saved: rec.progress[part],
                                            progressBase: base) { p in
                rec.progress[part] = p
                save()
            }
            rec.finished[part] = info
            save()
        }

        t.state = .finishing
        t.detail = "Verifying on server…"
        do {
            _ = try await client.completeUpload(uploadId, parts: rec.finished)
        } catch APIError.http(422, let msg) {
            // Checksum mismatch: drop this attempt so the next one starts clean.
            try? await client.abortUpload(uploadId)
            rec.uploadId = nil
            save()
            throw NSError(domain: "AppVault", code: 4, userInfo: [NSLocalizedDescriptionKey: "Verification failed: \(msg). Press Retry."])
        }

        if rec.move {
            t.detail = "Removing from Mac…"
            try deleteLocal(rec)
        }
        t.offload = rec
        t.detail = rec.move ? "Moved to server" : "Copied to server"
    }

    func deleteLocal(_ rec: OffloadRecord) throws {
        try LocalFiles.remove(rec.path)
        for rel in rec.dataPaths {
            try LocalFiles.remove(Scanner.home + "/" + rel)
        }
    }

    private func uploadPart(_ t: Transfer, _ client: APIClient, uploadId: String, part: String, plan: TarPlan,
                            serverOffset: Int64, saved: PartProgress?, progressBase: Int64,
                            onProgress: (PartProgress) -> Void) async throws -> PartInfo {
        var offset = serverOffset
        var hasher: SHA256Stream
        if offset == 0 {
            hasher = SHA256Stream()
        } else if let saved, saved.offset == offset, let h = SHA256Stream(state: saved.hashState) {
            hasher = h
        } else {
            // No usable saved hash state: re-read what was already sent to rebuild it.
            t.detail = "Checking data already on server…"
            let h = SHA256Stream()
            let reader = TarReader(plan: plan)
            var pos: Int64 = 0
            while pos < offset {
                try checkpoint(t)
                let n = Int(min(Int64(chunkSize), offset - pos))
                let box = Unchecked(value: (reader, h))
                pos += try await runInBackground { () -> Int64 in
                    let d = try box.value.0.read(max: n)
                    box.value.1.update(d)
                    return Int64(d.count)
                }
            }
            hasher = h
        }

        let reader = TarReader(plan: plan, offset: offset)
        var lastTick = Date()
        var bytesSinceTick: Int64 = 0
        t.detail = part == "data" ? "Sending app data…" : "Sending…"

        while offset < plan.totalSize {
            try checkpoint(t)
            let n = chunkSize
            let box = Unchecked(value: (reader, hasher))
            let chunk = try await runInBackground { () -> Data in
                let d = try box.value.0.read(max: n)
                box.value.1.update(d)
                return d
            }
            // Send the chunk, resending only what the server is missing.
            let chunkStart = offset
            let chunkEnd = offset + Int64(chunk.count)
            var sent = offset
            var attempt = 0
            while sent < chunkEnd {
                if t.cancelRequested { throw CancelledSignal() }
                let slice = chunk.subdata(in: Int(sent - chunkStart)..<chunk.count)
                do {
                    sent = try await client.appendChunk(uploadId, part: part, offset: sent, data: slice)
                    attempt = 0
                } catch let e {
                    var serverAt: Int64?
                    switch e {
                    case APIError.offsetMismatch(let o): serverAt = o
                    case APIError.partial(let o, _): serverAt = o
                    case APIError.http(let code, _) where code != 500 && code != 502 && code != 503: throw e
                    default: break
                    }
                    if serverAt == nil {
                        // Network problem: back off, then ask the server where it is.
                        attempt += 1
                        let wait = min(30.0, pow(2.0, Double(attempt)))
                        t.detail = "Connection lost, retrying in \(Int(wait))s…"
                        try await Task.sleep(nanoseconds: UInt64(wait * 1e9))
                        serverAt = try? await client.upload(uploadId).offsets[part]
                    }
                    guard let at = serverAt else { continue }
                    guard at >= chunkStart && at <= chunkEnd else {
                        throw NSError(domain: "AppVault", code: 5, userInfo: [NSLocalizedDescriptionKey:
                            "Server and Mac disagree on upload position (\(at)). Cancel and send again."])
                    }
                    sent = at
                    t.detail = part == "data" ? "Sending app data…" : "Sending…"
                }
            }
            offset = chunkEnd
            onProgress(PartProgress(offset: offset, hashState: hasher.state))

            t.done = progressBase + offset
            bytesSinceTick += Int64(chunk.count)
            let dt = Date().timeIntervalSince(lastTick)
            if dt >= 1 {
                let inst = Double(bytesSinceTick) / dt
                t.speed = t.speed == 0 ? inst : t.speed * 0.6 + inst * 0.4
                lastTick = Date()
                bytesSinceTick = 0
            }
        }
        return PartInfo(size: plan.totalSize, sha256: hasher.finalHex())
    }

    // MARK: Restore

    private func runRestore(_ t: Transfer, _ client: APIClient) async throws {
        guard let req = t.restore else { return }
        let item = try await client.item(req.item.id) // fresh metadata
        guard let app = item.parts?["app"] else { throw APIError.invalidResponse }
        let data = req.includeData ? item.parts?["data"] : nil

        let dest = item.originalPath
        let parent = (dest as NSString).deletingLastPathComponent
        let need = max(item.installedSize, app.size) + (data?.size ?? 0)
        if let free = LocalFiles.freeSpace(at: parent), free < need + (1 << 30) {
            throw NSError(domain: "AppVault", code: 6, userInfo: [NSLocalizedDescriptionKey:
                "Not enough space on this Mac: need \(Format.bytes(need)), \(Format.bytes(free)) free."])
        }
        if let running = LocalFiles.isRunning(dest) {
            throw NSError(domain: "AppVault", code: 3, userInfo: [NSLocalizedDescriptionKey:
                "Quit \(running.localizedName ?? item.name) before restoring over it."])
        }

        t.total = app.size + (data?.size ?? 0)
        t.done = 0
        t.state = .running

        // App: extract next to the destination, then move into place.
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let staging = parent + "/.appvault-restore-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: staging) }
        t.detail = "Downloading…"
        try await downloadAndExtract(t, client, item: item, part: "app", info: app, into: staging, progressBase: 0)

        let extracted = staging + "/" + (dest as NSString).lastPathComponent
        guard FileManager.default.fileExists(atPath: extracted) else {
            throw NSError(domain: "AppVault", code: 7, userInfo: [NSLocalizedDescriptionKey: "Archive did not contain \((dest as NSString).lastPathComponent)."])
        }

        var dataStaging: String?
        if let data {
            let ds = LocalFiles.supportDir.appendingPathComponent("restore-" + UUID().uuidString).path
            try FileManager.default.createDirectory(atPath: ds, withIntermediateDirectories: true)
            dataStaging = ds
            t.detail = "Downloading app data…"
            do {
                try await downloadAndExtract(t, client, item: item, part: "data", info: data, into: ds, progressBase: app.size)
            } catch {
                try? FileManager.default.removeItem(atPath: ds)
                throw error
            }
        }
        defer { if let ds = dataStaging { try? FileManager.default.removeItem(atPath: ds) } }

        t.state = .finishing
        t.detail = "Installing…"
        try LocalFiles.place(extracted, at: dest)
        if let ds = dataStaging {
            for rel in item.dataPaths ?? [] {
                let src = ds + "/" + rel
                guard FileManager.default.fileExists(atPath: src) else { continue }
                try LocalFiles.place(src, at: Scanner.home + "/" + rel)
            }
        }
        if item.kind == "app" {
            LSRegisterURL(URL(fileURLWithPath: dest) as CFURL, true)
        }
        t.detail = "Restored to \((dest as NSString).abbreviatingWithTildeInPath)"
    }

    /// Streams a stored tar archive into /usr/bin/tar in 64 MB ranges. Each
    /// range is retried on failure, and a pause simply stops fetching (tar waits).
    private func downloadAndExtract(_ t: Transfer, _ client: APIClient, item: ItemMeta, part: String,
                                    info: PartInfo, into dir: String, progressBase: Int64) async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        proc.arguments = ["-xpf", "-", "-C", dir]
        let stdin = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardError = stderr
        proc.standardOutput = FileHandle.nullDevice
        // Drain stderr continuously so tar never blocks on a full pipe.
        let errBuf = ErrorBuffer()
        stderr.fileHandleForReading.readabilityHandler = { h in errBuf.append(h.availableData) }
        try proc.run()
        let writer = stdin.fileHandleForWriting
        var finishedOK = false
        defer {
            if !finishedOK {
                try? writer.close()
                if proc.isRunning { proc.terminate() }
            }
        }

        let hasher = SHA256Stream()
        var offset: Int64 = 0
        var attempt = 0
        var lastTick = Date()
        var bytesSinceTick: Int64 = 0

        while offset < info.size {
            if t.cancelRequested { throw CancelledSignal() }
            while t.pauseRequested && !t.cancelRequested {
                t.state = .paused
                t.detail = "Paused"
                t.speed = 0
                try await Task.sleep(nanoseconds: 300_000_000)
            }
            if t.cancelRequested { throw CancelledSignal() }
            if t.state == .paused { t.state = .running; t.detail = "Downloading…" }

            let len = min(downloadChunk, info.size - offset)
            let tmp: URL
            do {
                tmp = try await client.downloadRange(item.id, part: part, from: offset, length: len, etag: info.sha256)
                attempt = 0
            } catch APIError.http(let code, let msg) where code != 500 && code != 502 && code != 503 {
                throw APIError.http(code, msg)
            } catch {
                attempt += 1
                let wait = min(30.0, pow(2.0, Double(attempt)))
                t.detail = "Connection lost, retrying in \(Int(wait))s…"
                try await Task.sleep(nanoseconds: UInt64(wait * 1e9))
                continue
            }
            let box = Unchecked(value: (hasher, writer))
            let got = try await runInBackground { () -> Int64 in
                defer { try? FileManager.default.removeItem(at: tmp) }
                let fh = try FileHandle(forReadingFrom: tmp)
                defer { try? fh.close() }
                var n: Int64 = 0
                while let d = try fh.read(upToCount: 4 << 20), !d.isEmpty {
                    box.value.0.update(d)
                    try box.value.1.write(contentsOf: d)
                    n += Int64(d.count)
                }
                return n
            }
            guard got == len else { throw APIError.partial(offset + got, "short read from server") }
            offset += got
            t.done = progressBase + offset
            bytesSinceTick += got
            let dt = Date().timeIntervalSince(lastTick)
            if dt >= 1 {
                let inst = Double(bytesSinceTick) / dt
                t.speed = t.speed == 0 ? inst : t.speed * 0.6 + inst * 0.4
                lastTick = Date()
                bytesSinceTick = 0
            }
        }

        try writer.close()
        let p = Unchecked(value: proc)
        try await runInBackground { p.value.waitUntilExit() }
        finishedOK = true
        stderr.fileHandleForReading.readabilityHandler = nil
        let errText = errBuf.text
        if hasher.finalHex() != info.sha256.lowercased() {
            throw NSError(domain: "AppVault", code: 8, userInfo: [NSLocalizedDescriptionKey: "Downloaded data is corrupt (checksum mismatch). Try again."])
        }
        if proc.terminationStatus != 0 {
            throw NSError(domain: "AppVault", code: 9, userInfo: [NSLocalizedDescriptionKey:
                "tar failed: \(errText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))"])
        }
    }
}

final class ErrorBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        if data.count < 64 << 10 { data.append(d) }
    }
    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
