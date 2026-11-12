#if DEBUG
import AppKit
import AppVaultCore
import Foundation

/// Debug builds only: `AppVault --selftest <server-url> <token> <app-path>`
/// runs offload (move + data, with a pause/resume) and restore against a
/// real server, without the UI. Used during development.
@MainActor
enum SelfTest {
    static func runIfRequested() {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--selftest"), a.count >= i + 4 else { return }
        let url = a[i + 1], token = a[i + 2], path = a[i + 3]
        Task {
            let ok = await run(url: url, token: token, path: path)
            print(ok ? "SELFTEST PASS" : "SELFTEST FAIL")
            exit(ok ? 0 : 1)
        }
    }

    static func check(_ c: Bool, _ msg: String) -> Bool {
        print((c ? "  ok   " : "  FAIL ") + msg)
        return c
    }

    static func waitFor(_ t: Transfer, _ cond: @escaping (Transfer) -> Bool) async {
        while !cond(t) { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    static func run(url: String, token: String, path: String) async -> Bool {
        let model = AppModel()
        let previousURL = model.settings.serverURL
        let previousToken = model.settings.token
        model.settings.serverURL = url
        model.settings.token = token
        defer {
            model.settings.serverURL = previousURL
            model.settings.token = previousToken
        }
        var ok = true
        let fm = FileManager.default
        let dataRel = "Library/Application Support/AppVaultSelfTest"
        let dataAbs = Scanner.home + "/" + dataRel
        try? fm.createDirectory(atPath: dataAbs, withIntermediateDirectories: true)
        fm.createFile(atPath: dataAbs + "/save.dat", contents: Data(repeating: 7, count: 5_000_000))

        await model.refreshLibrary()
        ok = check(model.status == .online, "server online") && ok
        let m = Scanner.measure(path)
        let local = LocalItem(path: path, name: "SelfTest " + (path as NSString).lastPathComponent, kind: "app",
                              bundleId: "local.appvault.selftest", version: "1.0", build: "1", appCategory: nil,
                              location: "test", size: m.size, fingerprint: m.fingerprint)

        // Offload with move + data, pausing after the first chunk.
        await model.createCategory("SelfTest")
        await model.offload(local, category: "SelfTest", move: true, dataPaths: [dataRel])
        guard let up = model.transfers.transfers.last else { return check(false, "upload queued") }
        await waitFor(up) { $0.done > 0 || $0.state.isFinished }
        model.transfers.pause(up)
        await waitFor(up) { $0.state == .paused || $0.state.isFinished }
        ok = check(up.state == .paused, "paused mid-upload at \(up.done) of \(up.total)") && ok
        model.transfers.resume(up)
        await waitFor(up) { $0.state.isFinished }
        if case .failed(let e) = up.state { print("  error: \(e)") }
        ok = check(up.state == .done, "upload done") && ok
        ok = check(!fm.fileExists(atPath: path), "local app removed after move") && ok
        ok = check(!fm.fileExists(atPath: dataAbs), "local data removed after move") && ok

        await model.refreshLibrary()
        guard let item = model.items.first(where: { $0.bundleId == "local.appvault.selftest" }) else {
            return check(false, "item listed on server")
        }
        ok = check(item.category == "SelfTest" && item.hasData && item.hasIcon, "item has category, data, icon") && ok

        // Restore app + data.
        model.restore(item, includeData: true)
        guard let down = model.transfers.transfers.last, down.kind == .restore else { return check(false, "restore queued") }
        await waitFor(down) { $0.state.isFinished }
        if case .failed(let e) = down.state { print("  error: \(e)") }
        ok = check(down.state == .done, "restore done") && ok
        ok = check(fm.fileExists(atPath: path), "app back in place") && ok
        let cs = Process()
        cs.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        cs.arguments = ["--verify", "--deep", "--strict", path]
        try? cs.run()
        cs.waitUntilExit()
        ok = check(cs.terminationStatus == 0, "code signature valid after restore") && ok
        let restored = fm.contents(atPath: dataAbs + "/save.dat")
        ok = check(restored == Data(repeating: 7, count: 5_000_000), "app data restored") && ok

        // Re-offload unchanged: must skip upload.
        let before = model.transfers.transfers.count
        let m2 = Scanner.measure(path)
        var again = local
        again.fingerprint = m2.fingerprint
        await model.offload(again, category: "SelfTest", move: false, dataPaths: [])
        ok = check(model.transfers.transfers.count == before, "unchanged re-offload skipped upload") && ok

        // Clean up.
        await model.deleteFromServer(item)
        await model.deleteCategory("SelfTest")
        try? fm.removeItem(atPath: dataAbs)
        return ok
    }
}
#endif
