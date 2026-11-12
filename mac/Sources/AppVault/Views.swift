import AppKit
import AppVaultCore
import SwiftUI

enum SidebarItem: Hashable {
    case mac
    case library(String?) // nil = all categories
    case transfers
}

enum SortKey: String, CaseIterable, Identifiable {
    case name = "Name", size = "Size", date = "Date"
    var id: String { rawValue }
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var transfers: TransferManager
    @State private var selection: SidebarItem? = .mac
    @State private var newCategory = ""
    @State private var showNewCategory = false
    @State private var renaming: String?
    @State private var renameText = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("This Mac") {
                    Label("Apps & Folders", systemImage: "laptopcomputer").tag(SidebarItem.mac)
                }
                Section {
                    Label("All Items", systemImage: "externaldrive.connected.to.line.below")
                        .badge(model.items.count)
                        .tag(SidebarItem.library(nil))
                    ForEach(model.categories) { c in
                        Label(c.name, systemImage: icon(forCategory: c.name))
                            .badge(c.itemCount)
                            .tag(SidebarItem.library(c.name))
                            .contextMenu {
                                Button("Rename…") { renaming = c.name; renameText = c.name }
                                Button("Delete", role: .destructive) { Task { await model.deleteCategory(c.name) } }
                                    .disabled(c.itemCount > 0 || c.name == "Uncategorized")
                            }
                    }
                } header: {
                    HStack {
                        Text("Server")
                        Spacer()
                        Button { newCategory = ""; showNewCategory = true } label: { Image(systemName: "plus") }
                            .buttonStyle(.borderless)
                            .help("New category")
                    }
                }
                Section {
                    Label("Transfers", systemImage: "arrow.up.arrow.down")
                        .badge(transfers.activeCount)
                        .tag(SidebarItem.transfers)
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) { ServerFooter().padding(10) }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            switch selection ?? .mac {
            case .mac: LocalView()
            case .library(let cat): LibraryView(category: cat)
            case .transfers: TransfersView()
            }
        }
        .task { await model.refreshAll() }
        .alert("New Category", isPresented: $showNewCategory) {
            TextField("Name", text: $newCategory)
            Button("Create") { Task { await model.createCategory(newCategory) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Category", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let old = renaming { Task { await model.renameCategory(old, to: renameText) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("AppVault", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
    }
}

func icon(forCategory name: String) -> String {
    switch name.lowercased() {
    case "games": return "gamecontroller"
    case "tools", "utilities": return "wrench.and.screwdriver"
    case "developer": return "hammer"
    case "creative": return "paintbrush"
    case "productivity": return "briefcase"
    case "entertainment": return "tv"
    case "education": return "book"
    case "social": return "bubble.left.and.bubble.right"
    case "uncategorized": return "tray"
    default: return "folder"
    }
}

struct ServerFooter: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(label).font(.caption).lineLimit(2)
            }
            if let s = model.stats, s.totalBytes > 0 {
                ProgressView(value: Double(s.totalBytes - s.freeBytes), total: Double(s.totalBytes))
                Text("\(Format.bytes(s.libraryBytes)) in library · \(Format.bytes(s.freeBytes)) free")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var color: Color {
        switch model.status {
        case .online: return .green
        case .connecting, .unknown: return .yellow
        case .offline: return .red
        }
    }

    var label: String {
        switch model.status {
        case .online: return "Server online"
        case .connecting, .unknown: return "Connecting…"
        case .offline(let m): return m
        }
    }
}

// MARK: - This Mac

struct LocalView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @State private var search = ""
    @State private var sort: SortKey = .size
    @State private var selection: LocalItem.ID?
    @State private var offloading: LocalItem?

    var rows: [LocalItem] {
        let q = search.lowercased()
        let filtered = q.isEmpty ? model.local : model.local.filter {
            $0.name.lowercased().contains(q) || $0.location.lowercased().contains(q)
        }
        switch sort {
        case .name: return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size: return filtered.sorted { ($0.size ?? -1) > ($1.size ?? -1) }
        case .date: return filtered.sorted { mtime($0.path) > mtime($1.path) }
        }
    }

    private func mtime(_ p: String) -> Date {
        (try? URL(fileURLWithPath: p).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    var totalSize: Int64 { model.local.reduce(0) { $0 + ($1.size ?? 0) } }

    var body: some View {
        Table(rows, selection: $selection) {
            TableColumn("Name") { item in
                HStack {
                    Image(nsImage: model.localIcon(item.path)).resizable().frame(width: 22, height: 22)
                    VStack(alignment: .leading) {
                        Text(item.name)
                        if let v = item.version { Text(v).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            .width(min: 200, ideal: 280)
            TableColumn("Location") { item in Text(item.location).foregroundStyle(.secondary) }
                .width(min: 100, ideal: 140)
            TableColumn("Size") { item in
                if let s = item.size { Text(Format.bytes(s)).monospacedDigit() } else { ProgressView().controlSize(.small) }
            }
            .width(min: 70, ideal: 90)
            TableColumn("Server") { item in statusView(item) }
                .width(min: 120, ideal: 160)
        }
        .contextMenu(forSelectionType: LocalItem.ID.self) { ids in
            if let id = ids.first, let item = model.local.first(where: { $0.id == id }) {
                Button("Send to Server…") { offloading = item }.disabled(model.isBusy(path: item.path))
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let item = model.local.first(where: { $0.id == id }) { offloading = item }
        }
        .searchable(text: $search, prompt: "Search apps")
        .navigationTitle("This Mac")
        .navigationSubtitle("\(model.local.count) items · \(Format.bytes(totalSize))")
        .toolbar {
            ToolbarItemGroup {
                Picker("Sort", selection: $sort) {
                    ForEach(SortKey.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Sort by")
                Button { addFolder() } label: { Label("Add Folder", systemImage: "folder.badge.plus") }
                    .help("Add a folder (e.g. a game library) to scan")
                Button { Task { await model.refreshAll() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Button {
                    if let id = selection, let item = model.local.first(where: { $0.id == id }) { offloading = item }
                } label: {
                    Label("Send to Server", systemImage: "icloud.and.arrow.up")
                }
                .disabled(selection == nil || model.status != .online)
            }
        }
        .sheet(item: $offloading) { item in OffloadSheet(item: item) }
        .overlay {
            if model.local.isEmpty && !model.scanning {
                ContentUnavailableView("No apps found", systemImage: "app.dashed")
            }
        }
    }

    @ViewBuilder func statusView(_ item: LocalItem) -> some View {
        if model.isBusy(path: item.path) {
            Label("Transferring", systemImage: "arrow.up.arrow.down").foregroundStyle(.blue)
        } else {
            switch model.status(of: item) {
            case .notOnServer:
                Text("—").foregroundStyle(.secondary)
            case .onServer(let m, let unchanged):
                if unchanged {
                    Label(m.category, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Label("\(m.category) (older copy)", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
                }
            }
        }
    }

    func addFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = true
        p.prompt = "Add"
        p.message = "Each app or folder inside the chosen folder can be sent to the server."
        if p.runModal() == .OK {
            for u in p.urls where !settings.customFolders.contains(u.path) { settings.customFolders.append(u.path) }
            model.refreshLocal()
        }
    }
}

// MARK: - Offload sheet

struct OffloadSheet: View {
    let item: LocalItem
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var category = ""
    @State private var newCategory = ""
    @State private var candidates: [DataCandidate] = []
    @State private var chosen = Set<String>()
    @State private var loadingData = true
    @State private var confirmMove = false

    private let newTag = "\u{0}new"

    var categoryNames: [String] { model.categories.map(\.name) }
    var finalCategory: String {
        (category == newTag ? newCategory : category).trimmingCharacters(in: .whitespaces)
    }
    var dataSize: Int64 { candidates.filter { chosen.contains($0.relativePath) }.reduce(0) { $0 + $1.size } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: model.localIcon(item.path)).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading) {
                    Text(item.name).font(.title2.bold())
                    Text([item.version, item.size.map(Format.bytes), (item.path as NSString).abbreviatingWithTildeInPath]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Form {
                Picker("Category", selection: $category) {
                    ForEach(categoryNames, id: \.self) { Text($0).tag($0) }
                    Divider()
                    Text("New Category…").tag(newTag)
                }
                if category == newTag {
                    TextField("New category name", text: $newCategory)
                }
            }

            GroupBox("App data in ~/Library (optional)") {
                if loadingData {
                    ProgressView().frame(maxWidth: .infinity)
                } else if candidates.isEmpty {
                    Text("No data folders found for this app.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(candidates) { c in
                            Toggle(isOn: Binding(get: { chosen.contains(c.relativePath) },
                                                 set: { if $0 { chosen.insert(c.relativePath) } else { chosen.remove(c.relativePath) } })) {
                                HStack {
                                    Text("~/" + c.relativePath).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(Format.bytes(c.size)).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                        }
                        Text("Saves and settings travel with the app. Included folders are removed from this Mac on Move.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if case .onServer(let m, let unchanged) = model.status(of: item) {
                Label(unchanged ? "Already on server and unchanged: no upload needed."
                                : "An older copy in \(m.category) will be replaced.",
                      systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Copy to Server") { start(move: false) }
                    .disabled(finalCategory.isEmpty)
                Button("Move to Server") { confirmMove = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(finalCategory.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            let suggestion: String
            if case .onServer(let m, _) = model.status(of: item) { suggestion = m.category }
            else { suggestion = Scanner.suggestedCategory(for: item) }
            if categoryNames.contains(suggestion) { category = suggestion }
            else { category = newTag; newCategory = suggestion }

            let it = item
            candidates = (try? await runInBackground { Scanner.dataCandidates(for: it) }) ?? []
            loadingData = false
        }
        .confirmationDialog("Move \(item.name) to the server?", isPresented: $confirmMove) {
            Button("Move and Delete from Mac", role: .destructive) { start(move: true) }
        } message: {
            Text("After the upload is verified by checksum, \(item.name)\(chosen.isEmpty ? "" : " and the selected data folders") will be permanently deleted from this Mac (not moved to Trash). You can restore it from the server at any time.")
        }
    }

    func start(move: Bool) {
        let cat = finalCategory
        let paths = Array(chosen).sorted()
        dismiss()
        Task {
            if !categoryNames.contains(cat) { await model.createCategory(cat) }
            await model.offload(item, category: cat, move: move, dataPaths: paths)
        }
    }
}

// MARK: - Library

struct LibraryView: View {
    let category: String?
    @EnvironmentObject var model: AppModel
    @State private var search = ""
    @State private var sort: SortKey = .name
    @State private var selection: ItemMeta.ID?
    @State private var restoring: ItemMeta?
    @State private var deleting: ItemMeta?

    var rows: [ItemMeta] {
        let q = search.lowercased()
        var r = model.items.filter { category == nil || $0.category == category }
        if !q.isEmpty { r = r.filter { $0.name.lowercased().contains(q) || ($0.bundleId ?? "").lowercased().contains(q) } }
        switch sort {
        case .name: return r.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size: return r.sorted { $0.storedBytes > $1.storedBytes }
        case .date: return r.sorted { ($0.uploadedAt ?? .distantPast) > ($1.uploadedAt ?? .distantPast) }
        }
    }

    var body: some View {
        Table(rows, selection: $selection) {
            TableColumn("Name") { m in
                HStack {
                    Group {
                        if let img = model.icon(for: m) { Image(nsImage: img).resizable() }
                        else { Image(systemName: m.kind == "app" ? "app" : "folder").resizable().scaledToFit().foregroundStyle(.secondary) }
                    }
                    .frame(width: 22, height: 22)
                    VStack(alignment: .leading) {
                        Text(m.name)
                        if let v = m.version { Text(v).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            .width(min: 200, ideal: 260)
            TableColumn("Category") { m in Text(m.category) }.width(min: 80, ideal: 110)
            TableColumn("On Server") { m in
                Text(Format.bytes(m.storedBytes) + (m.hasData ? " + data" : "")).monospacedDigit()
            }
            .width(min: 80, ideal: 110)
            TableColumn("Uploaded") { m in
                Text(m.uploadedAt.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
            }
            .width(min: 80, ideal: 100)
            TableColumn("On This Mac") { m in
                if model.isBusy(path: m.originalPath) {
                    Label("Transferring", systemImage: "arrow.up.arrow.down").foregroundStyle(.blue)
                } else if model.isInstalled(m) {
                    Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Text("Not installed").foregroundStyle(.secondary)
                }
            }
            .width(min: 100, ideal: 120)
        }
        .contextMenu(forSelectionType: ItemMeta.ID.self) { ids in
            if let id = ids.first, let m = model.items.first(where: { $0.id == id }) {
                Button("Restore to Mac…") { restoring = m }.disabled(model.isBusy(path: m.originalPath))
                Menu("Move to Category") {
                    ForEach(model.categories) { c in
                        Button(c.name) { Task { await model.move(m, to: c.name) } }.disabled(c.name == m.category)
                    }
                }
                Divider()
                Button("Delete from Server…", role: .destructive) { deleting = m }
            }
        } primaryAction: { ids in
            if let id = ids.first, let m = model.items.first(where: { $0.id == id }) { restoring = m }
        }
        .searchable(text: $search, prompt: "Search library")
        .navigationTitle(category ?? "All Items")
        .navigationSubtitle("\(rows.count) items · \(Format.bytes(rows.reduce(0) { $0 + $1.storedBytes }))")
        .toolbar {
            ToolbarItemGroup {
                Picker("Sort", selection: $sort) {
                    ForEach(SortKey.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Button { Task { await model.refreshLibrary() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Button {
                    if let id = selection, let m = model.items.first(where: { $0.id == id }) { restoring = m }
                } label: { Label("Restore", systemImage: "icloud.and.arrow.down") }
                    .disabled(selection == nil)
            }
        }
        .sheet(item: $restoring) { m in RestoreSheet(item: m) }
        .confirmationDialog("Delete \(deleting?.name ?? "") from the server?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let m = deleting { Task { await model.deleteFromServer(m) } }
                deleting = nil
            }
        } message: {
            Text(deleting.map { model.isInstalled($0) ? "The copy on this Mac is not affected."
                                                     : "It is not installed on this Mac. This deletes the only copy." } ?? "")
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(search.isEmpty ? "Nothing here yet" : "No results",
                                       systemImage: "externaldrive",
                                       description: Text(search.isEmpty ? "Send apps from This Mac to store them here." : ""))
            }
        }
    }
}

struct RestoreSheet: View {
    let item: ItemMeta
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var includeData = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Group {
                    if let img = model.icon(for: item) { Image(nsImage: img).resizable() }
                    else { Image(systemName: "app").resizable().scaledToFit() }
                }
                .frame(width: 48, height: 48)
                VStack(alignment: .leading) {
                    Text(item.name).font(.title2.bold())
                    Text([item.version, Format.bytes(item.installedSize)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            LabeledContent("Restore to", value: (item.originalPath as NSString).abbreviatingWithTildeInPath)
            if item.hasData {
                Toggle("Also restore app data (\(item.dataPaths?.count ?? 0) folders, \(Format.bytes(item.parts?["data"]?.size ?? 0)))",
                       isOn: $includeData)
            }
            if model.isInstalled(item) {
                Label("A copy already exists there and will be replaced.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if includeData && item.hasData {
                Text("Existing data folders with the same names will be replaced.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(model.isInstalled(item) ? "Replace" : "Restore") {
                    model.restore(item, includeData: includeData && item.hasData)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - Transfers

struct TransfersView: View {
    @EnvironmentObject var transfers: TransferManager

    var body: some View {
        List {
            ForEach(transfers.transfers.reversed()) { t in TransferRow(t: t) }
        }
        .navigationTitle("Transfers")
        .toolbar {
            Button("Clear Finished") { transfers.clearFinished() }
                .disabled(!transfers.transfers.contains { $0.state.isFinished })
        }
        .overlay {
            if transfers.transfers.isEmpty {
                ContentUnavailableView("No transfers", systemImage: "arrow.up.arrow.down")
            }
        }
    }
}

struct TransferRow: View {
    @ObservedObject var t: Transfer
    @EnvironmentObject var transfers: TransferManager

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: t.kind == .offload ? "icloud.and.arrow.up" : "icloud.and.arrow.down")
                .font(.title2).foregroundStyle(.secondary).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(t.title).font(.headline)
                    Spacer()
                    Text(stateText).font(.caption).foregroundStyle(stateColor)
                }
                if !t.state.isFinished || t.state == .done {
                    ProgressView(value: t.state == .done ? 1 : t.fraction)
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            controls
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder var controls: some View {
        switch t.state {
        case .queued, .preparing, .running, .finishing:
            Button { transfers.pause(t) } label: { Image(systemName: "pause.fill") }.help("Pause")
                .disabled(t.state == .finishing)
            Button { transfers.cancel(t) } label: { Image(systemName: "xmark") }.help("Cancel")
                .disabled(t.state == .finishing)
        case .paused:
            Button { transfers.resume(t) } label: { Image(systemName: "play.fill") }.help("Resume")
            Button { transfers.cancel(t) } label: { Image(systemName: "xmark") }.help("Cancel")
        case .failed:
            Button { transfers.resume(t) } label: { Image(systemName: "arrow.clockwise") }.help("Retry")
            Button { transfers.cancel(t) } label: { Image(systemName: "xmark") }.help("Discard")
        case .done, .cancelled:
            EmptyView()
        }
    }

    var stateText: String {
        switch t.state {
        case .queued: return "Waiting"
        case .preparing: return "Preparing"
        case .running: return t.kind == .offload ? "Uploading" : "Downloading"
        case .paused: return "Paused"
        case .finishing: return "Finishing"
        case .done: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    var stateColor: Color {
        switch t.state {
        case .done: return .green
        case .failed: return .red
        case .paused, .cancelled: return .orange
        default: return .secondary
        }
    }

    var subtitle: String {
        if case .failed(let msg) = t.state { return msg }
        var parts: [String] = []
        if t.total > 0 { parts.append("\(Format.bytes(t.done)) of \(Format.bytes(t.total))") }
        if t.speed > 0 {
            parts.append("\(Format.bytes(Int64(t.speed)))/s")
            let remaining = Double(t.total - t.done) / t.speed
            if remaining.isFinite && remaining > 1 {
                let f = DateComponentsFormatter()
                f.allowedUnits = [.hour, .minute, .second]
                f.unitsStyle = .abbreviated
                f.maximumUnitCount = 2
                if let s = f.string(from: remaining) { parts.append("\(s) left") }
            }
        }
        if !t.detail.isEmpty { parts.append(t.detail) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section("Server") {
                TextField("Address", text: $settings.serverURL, prompt: Text("http://tower.local:8420"))
                SecureField("API token", text: $settings.token)
                HStack {
                    Button(testing ? "Testing…" : "Test Connection") { test() }.disabled(testing)
                    if let r = testResult { Text(r).font(.caption).foregroundStyle(.secondary) }
                }
                Text("Use the server's LAN address, or its Tailscale/WireGuard address when away from home.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Extra folders to scan") {
                if settings.customFolders.isEmpty {
                    Text("None. /Applications and ~/Applications are always scanned.").foregroundStyle(.secondary)
                }
                ForEach(settings.customFolders, id: \.self) { f in
                    HStack {
                        Text((f as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { settings.customFolders.removeAll { $0 == f }; model.refreshLocal() } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add Folder…") {
                    let p = NSOpenPanel()
                    p.canChooseDirectories = true
                    p.canChooseFiles = false
                    p.allowsMultipleSelection = true
                    if p.runModal() == .OK {
                        for u in p.urls where !settings.customFolders.contains(u.path) { settings.customFolders.append(u.path) }
                        model.refreshLocal()
                    }
                }
            }
            Section("Permissions") {
                Text("To delete or replace other apps, macOS needs AppVault allowed under Privacy & Security › App Management. For app data inside ~/Library/Containers, also allow Full Disk Access.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Privacy & Security") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 520)
    }

    func test() {
        testing = true
        testResult = nil
        Task {
            defer { testing = false }
            guard let c = model.client else { testResult = "Enter address and token."; return }
            do {
                let s = try await c.stats()
                testResult = "Connected · server \(s.version) · \(s.itemCount) items · \(Format.bytes(s.freeBytes)) free"
                await model.refreshAll()
            } catch {
                testResult = error.localizedDescription
            }
        }
    }
}
