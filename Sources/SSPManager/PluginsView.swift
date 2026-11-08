import SwiftUI
import AppKit

/// Plugins pane: Catalog (cheat sheet + docs) and Install (card vs staging).
struct PluginsView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case catalog = "Catalog", install = "Install"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .catalog

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in Text(t.rawValue).tag(t) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            switch tab {
            case .catalog: PluginsCatalogView()
            case .install: PluginsInstallView()
            }
        }
    }
}

// MARK: - Catalog

private enum CatalogPresence: String, CaseIterable, Identifiable {
    case all = "All"
    case onCard = "On card"
    case disabled = "Disabled"
    case notInstalled = "Not installed"
    case factory = "Factory"
    var id: String { rawValue }
}

/// Flattened row so every column (incl. on-card status) is sortable.
private struct CatalogRow: Identifiable, Hashable {
    var id: String { code }
    let plugin: CatalogPlugin
    let code: String
    let name: String
    let author: String
    let kind: String
    /// Sortable label: "factory" / "yes" / "disabled" / "no"
    let onCard: String
}

private enum CatalogSort: String, CaseIterable, Identifiable {
    case code, name, author, onCard, kind
    var id: String { rawValue }
    var title: String {
        switch self {
        case .code: return "Code"
        case .name: return "Name"
        case .author: return "Author"
        case .onCard: return "On card"
        case .kind: return "Kind"
        }
    }
}

struct PluginsCatalogView: View {
    @Environment(SSPService.self) private var ssp
    /// Lowercased `.so` filenames currently in `plugins/`.
    @State private var installed = Set<String>()
    /// Lowercased `.so` filenames in `plugins-disabled/`.
    @State private var disabled = Set<String>()
    @State private var query = ""
    @State private var author = "All"
    @State private var kind = "All"
    @State private var presence: CatalogPresence = .all
    @State private var sel = Set<CatalogRow.ID>()
    @State private var sortBy: CatalogSort = .code
    @State private var sortAscending = true

    private var authors: [String] { ["All"] + PluginCatalog.authors }
    private var kinds: [String] { ["All"] + PluginCatalog.kinds }

    private func onCardLabel(_ p: CatalogPlugin) -> String {
        if p.isFactory { return "factory" }
        guard let f = p.file?.lowercased() else { return "no" }
        if installed.contains(f) { return "yes" }
        if disabled.contains(f) { return "disabled" }
        return "no"
    }

    private var rows: [CatalogRow] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let words = q.split(whereSeparator: \.isWhitespace).map(String.init)
        var list = PluginCatalog.all.filter { p in
            if author != "All", p.author != author { return false }
            if kind != "All", p.kind != kind { return false }
            let file = p.file?.lowercased()
            switch presence {
            case .all: break
            case .factory:
                if !p.isFactory { return false }
            case .onCard:
                if p.isFactory { return false }
                guard let f = file, installed.contains(f) else { return false }
            case .disabled:
                if p.isFactory { return false }
                guard let f = file, disabled.contains(f) else { return false }
            case .notInstalled:
                if p.isFactory { return false }
                guard let f = file else { return false }
                if installed.contains(f) || disabled.contains(f) { return false }
            }
            if words.isEmpty { return true }
            let hay = "\(p.code) \(p.name) \(p.summary) \(p.author) \(p.kind)".lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
        .map {
            CatalogRow(plugin: $0, code: $0.code, name: $0.name,
                       author: $0.author, kind: $0.kind, onCard: onCardLabel($0))
        }

        list.sort { a, b in
            let lhs: String
            let rhs: String
            switch sortBy {
            case .code: lhs = a.code; rhs = b.code
            case .name: lhs = a.name; rhs = b.name
            case .author: lhs = a.author; rhs = b.author
            case .onCard: lhs = a.onCard; rhs = b.onCard
            case .kind: lhs = a.kind; rhs = b.kind
            }
            let cmp = lhs.localizedStandardCompare(rhs)
            if cmp == .orderedSame { return a.code < b.code }
            return sortAscending ? cmp == .orderedAscending : cmp == .orderedDescending
        }
        return list
    }

    private var selected: CatalogPlugin? {
        guard let id = sel.first else { return nil }
        return rows.first { $0.id == id }?.plugin
            ?? PluginCatalog.all.first { $0.code == id }
    }

    private func toggleSort(_ col: CatalogSort) {
        if sortBy == col {
            sortAscending.toggle()
        } else {
            sortBy = col
            sortAscending = true
        }
    }

    private func sortHeader(_ col: CatalogSort) -> some View {
        Button {
            toggleSort(col)
        } label: {
            HStack(spacing: 2) {
                Text(col.title)
                if sortBy == col {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(sortBy == col ? Color.accentColor.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.borderless)
        .help("Sort by \(col.title)")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search code, name, keyword…", text: $query)
                    .textFieldStyle(.roundedBorder)
                Picker("Author", selection: $author) {
                    ForEach(authors, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 160)
                Picker("Kind", selection: $kind) {
                    ForEach(kinds, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 120)
                Picker("Presence", selection: $presence) {
                    ForEach(CatalogPresence.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(maxWidth: 160)
                Button {
                    Task { await refreshInstalled() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh install status from card")
                .disabled(!ssp.online)
            }
            .padding(8)

            // Sort lives outside Table — SwiftUI Table header clicks / custom
            // headers don't reliably drive sortOrder on macOS.
            HStack(spacing: 4) {
                Text("Sort").font(.caption).foregroundStyle(.secondary)
                ForEach(CatalogSort.allCases) { col in
                    sortHeader(col)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)

            HSplitView {
                Table(rows, selection: $sel) {
                    TableColumn("Code") { row in
                        Text(row.code).font(.body.monospaced()).fontWeight(.semibold)
                    }
                    .width(min: 56, ideal: 72)
                    TableColumn("Name", value: \.name)
                    TableColumn("Author", value: \.author)
                        .width(min: 90, ideal: 110)
                    TableColumn("On card") { row in
                        switch row.onCard {
                        case "factory":
                            Text("factory").foregroundStyle(.secondary)
                        case "yes":
                            Text("yes").foregroundStyle(.green)
                        case "disabled":
                            Text("disabled").foregroundStyle(.yellow)
                        default:
                            Text("no").foregroundStyle(.orange)
                        }
                    }
                    .width(88)
                    TableColumn("Kind", value: \.kind)
                        .width(70)
                }
                .frame(minWidth: 480)
                .layoutPriority(1)

                // Fixed-width detail pane so selecting a row doesn't reflow the split.
                Group {
                    if let p = selected {
                        catalogDetail(p)
                    } else {
                        Text("Select a module")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 300, idealWidth: 320, maxWidth: 360)
                .layoutPriority(0)
            }
        }
        .task { await refreshInstalled() }
        .onChange(of: ssp.online) { _, online in
            if online { Task { await refreshInstalled() } }
        }
    }

    @ViewBuilder
    private func catalogDetail(_ p: CatalogPlugin) -> some View {
        let status = onCardLabel(p)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(p.code).font(.title2.monospaced()).fontWeight(.bold)
                Text(p.name).font(.title3)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Text(p.author).font(.subheadline)
                Text("·").foregroundStyle(.secondary)
                Text(p.kind).font(.subheadline).foregroundStyle(.secondary)
                statusBadge(status)
            }
            if let f = p.file {
                Text(f).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Text(p.summary)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let url = p.docs {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open docs", systemImage: "safari")
                }
                .buttonStyle(.borderedProminent)
                Text(url.absoluteString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func statusBadge(_ status: String) -> some View {
        let label: String
        let color: Color
        switch status {
        case "factory":
            label = "Factory"; color = Color.secondary
        case "yes":
            label = "On card"; color = .green
        case "disabled":
            label = "Disabled"; color = .yellow
        default:
            label = "Not installed"; color = .orange
        }
        return Text(label)
            .font(.caption)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.2))
            .clipShape(Capsule())
    }

    private func refreshInstalled() async {
        async let active = ssp.listPlugins()
        async let off = ssp.listDisabledPlugins()
        installed = Set((await active).map { $0.name.lowercased() })
        disabled = Set((await off).map { $0.name.lowercased() })
    }
}

// MARK: - Install

private struct CardPluginRow: Identifiable, Hashable {
    var id: String { file }
    let file: String
    let title: String
    let author: String
    let status: String   // "active" | "disabled"

    static func make(file: String, status: String) -> CardPluginRow {
        let cat = PluginCatalog.forFile(file)
        return CardPluginRow(
            file: file,
            title: cat?.name ?? "—",
            author: cat?.author ?? "—",
            status: status
        )
    }
}

/// Remote .so list on card vs local staging dir; install / disable / remove + restart.
struct PluginsInstallView: View {
    @Environment(SSPService.self) private var ssp
    @State private var active: [RemoteItem] = []
    @State private var disabled: [RemoteItem] = []
    @State private var cardSel = Set<String>()
    @State private var local: [URL] = []
    @State private var localSel = Set<URL>()
    @State private var staging = NSHomeDirectory()
        + "/_dev/Percussa SSP/thirdparty-plugins/latest"
    @State private var restarting = false
    @State private var busy = false
    @State private var confirmRemove = false
    @State private var needsRestart = false

    private var cardRows: [CardPluginRow] {
        let a = active.map { CardPluginRow.make(file: $0.name, status: "active") }
        let d = disabled.map { CardPluginRow.make(file: $0.name, status: "disabled") }
        return (a + d).sorted {
            let t = $0.title.localizedStandardCompare($1.title)
            if t != .orderedSame { return t == .orderedAscending }
            return $0.file.localizedStandardCompare($1.file) == .orderedAscending
        }
    }

    private var selectedActive: [String] {
        cardSel.filter { name in active.contains { $0.name == name } }.sorted()
    }
    private var selectedDisabled: [String] {
        cardSel.filter { name in disabled.contains { $0.name == name } }.sorted()
    }

    private func scanLocal() {
        let fm = FileManager.default
        var found: [URL] = []
        var seen = Set<String>()
        // Walk manually so directory symlinks are followed.
        var queue = [URL(fileURLWithPath: staging)]
        while let dir = queue.first {
            queue.removeFirst()
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for u in items {
                let name = u.lastPathComponent
                if name.hasPrefix("._") { continue }
                let resolved = u.resolvingSymlinksInPath()
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: resolved.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    queue.append(resolved)
                } else if resolved.pathExtension == "so" {
                    let key = resolved.path
                    if seen.insert(key).inserted {
                        found.append(resolved)
                    }
                }
            }
        }
        local = found.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func refreshCard() async {
        active = await ssp.listPlugins()
        disabled = await ssp.listDisabledPlugins()
        let live = Set(active.map(\.name)).union(disabled.map(\.name))
        cardSel = cardSel.intersection(live)
    }

    private func runCardOp(_ op: @escaping ([String]) async -> Void, names: [String]) {
        guard !names.isEmpty else { return }
        Task {
            busy = true
            await op(names)
            await refreshCard()
            busy = false
            needsRestart = true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("on card (\(active.count) active · \(disabled.count) disabled)")
                    .font(.headline)
                if needsRestart {
                    Text("Restart SYNTHOR to apply")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button {
                    Task { await refreshCard() }
                } label: { Image(systemName: "arrow.clockwise") }
                .disabled(busy || !ssp.online)
                Button {
                    Task {
                        restarting = true
                        await ssp.restartSynthor()
                        restarting = false
                        needsRestart = false
                    }
                } label: {
                    Label(restarting ? "Restarting…" : "Restart SYNTHOR",
                          systemImage: "power")
                }
                .disabled(restarting || busy || !ssp.online)
            }
            .padding(8)

            HSplitView {
                VStack(spacing: 0) {
                    Table(cardRows, selection: $cardSel) {
                        TableColumn("file", value: \.file)
                            .width(min: 72, ideal: 88)
                        TableColumn("name", value: \.title)
                        TableColumn("author", value: \.author)
                            .width(min: 80, ideal: 110)
                        TableColumn("status") { row in
                            Text(row.status)
                                .font(.caption)
                                .foregroundStyle(row.status == "active" ? .green : .secondary)
                        }
                        .width(72)
                    }
                    .disabled(busy || !ssp.online)

                    HStack(spacing: 8) {
                        Button {
                            runCardOp({ names in
                                for n in names { _ = await ssp.disablePlugin(n) }
                            }, names: selectedActive)
                        } label: {
                            Label("Disable (\(selectedActive.count))",
                                  systemImage: "pause.circle")
                        }
                        .disabled(selectedActive.isEmpty || busy || !ssp.online)
                        .help("Move out of plugins/ so SYNTHOR won’t load them")

                        Button {
                            runCardOp({ names in
                                for n in names { _ = await ssp.enablePlugin(n) }
                            }, names: selectedDisabled)
                        } label: {
                            Label("Enable (\(selectedDisabled.count))",
                                  systemImage: "play.circle")
                        }
                        .disabled(selectedDisabled.isEmpty || busy || !ssp.online)
                        .help("Move back into plugins/ for the next SYNTHOR scan")

                        Button {
                            confirmRemove = true
                        } label: {
                            Label("Remove (\(cardSel.count))",
                                  systemImage: "trash")
                        }
                        .disabled(cardSel.isEmpty || busy || !ssp.online)
                        .help("Move to .trash (recoverable from Files)")
                        Spacer()
                    }
                    .padding(8)
                }
                .frame(minWidth: 320)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("local staging").font(.headline)
                        Spacer()
                        Button("Scan") { scanLocal() }
                    }
                    Text(staging).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(local, id: \.self) { u in
                                let name = u.lastPathComponent
                                let cat = PluginCatalog.forFile(name)
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(name).monospaced().frame(width: 88, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(cat?.name ?? "—")
                                            .lineLimit(1)
                                        Text(cat?.author ?? "—")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 4)
                                    if active.contains(where: { $0.name == name }) {
                                        Text("active").font(.caption).foregroundStyle(.green)
                                    } else if disabled.contains(where: { $0.name == name }) {
                                        Text("disabled").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(4)
                                .background(localSel.contains(u) ? Color.accentColor.opacity(0.25) : .clear)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if localSel.contains(u) { localSel.remove(u) }
                                    else { localSel.insert(u) }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                    Button {
                        Task {
                            busy = true
                            for u in localSel.sorted(by: { $0.path < $1.path }) {
                                _ = await ssp.installPlugin(u)
                            }
                            await refreshCard()
                            busy = false
                            needsRestart = true
                        }
                    } label: {
                        Label("Install selected (\(localSel.count))",
                              systemImage: "square.and.arrow.down")
                    }
                    .disabled(localSel.isEmpty || busy || !ssp.online)
                }
                .padding(8)
                .frame(minWidth: 360)
            }
        }
        .confirmationDialog(
            "Remove \(cardSel.count) plugin(s)?",
            isPresented: $confirmRemove,
            titleVisibility: .visible
        ) {
            Button("Move to trash", role: .destructive) {
                let names = Array(cardSel).sorted()
                runCardOp({ names in
                    for n in names { _ = await ssp.removePlugin(n) }
                }, names: names)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Files go to .trash on the card (recoverable from Files). Restart SYNTHOR afterward.")
        }
        .task {
            await refreshCard()
            scanLocal()
        }
    }
}
