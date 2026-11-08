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
    /// Sortable label: "factory" / "yes" / "no"
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
    @State private var installed = Set<String>()
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
        guard let f = p.file else { return "no" }
        return installed.contains(f) ? "yes" : "no"
    }

    private var rows: [CatalogRow] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let words = q.split(whereSeparator: \.isWhitespace).map(String.init)
        var list = PluginCatalog.all.filter { p in
            if author != "All", p.author != author { return false }
            if kind != "All", p.kind != kind { return false }
            switch presence {
            case .all: break
            case .factory:
                if !p.isFactory { return false }
            case .onCard:
                if p.isFactory { return false }
                guard let f = p.file, installed.contains(f) else { return false }
            case .notInstalled:
                if p.isFactory { return false }
                guard let f = p.file else { return false }
                if installed.contains(f) { return false }
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
                .frame(maxWidth: 140)
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
                        default:
                            Text("no").foregroundStyle(.orange)
                        }
                    }
                    .width(80)
                    TableColumn("Kind", value: \.kind)
                        .width(70)
                }

                Group {
                    if let p = selected {
                        catalogDetail(p)
                    } else {
                        Text("Select a module")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 280, idealWidth: 320)
            }
        }
        .task { await refreshInstalled() }
        .onChange(of: ssp.online) { _, online in
            if online { Task { await refreshInstalled() } }
        }
    }

    @ViewBuilder
    private func catalogDetail(_ p: CatalogPlugin) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(p.code).font(.title2.monospaced()).fontWeight(.bold)
                Text(p.name).font(.title3)
                Spacer()
            }
            HStack(spacing: 8) {
                Text(p.author).font(.subheadline)
                Text("·").foregroundStyle(.secondary)
                Text(p.kind).font(.subheadline).foregroundStyle(.secondary)
                if p.isFactory {
                    Text("Factory")
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .clipShape(Capsule())
                } else if onCardLabel(p) == "yes" {
                    Text("On card")
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.green.opacity(0.2))
                        .clipShape(Capsule())
                } else {
                    Text("Not installed")
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2))
                        .clipShape(Capsule())
                }
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

    private func refreshInstalled() async {
        let remote = await ssp.listPlugins()
        installed = Set(remote.map(\.name))
    }
}

// MARK: - Install

/// Remote .so list on card vs local staging dir; install + restart.
struct PluginsInstallView: View {
    @Environment(SSPService.self) private var ssp
    @State private var remote: [RemoteItem] = []
    @State private var local: [URL] = []
    @State private var sel: RemoteItem.ID?
    @State private var localSel = Set<URL>()
    @State private var staging = NSHomeDirectory()
        + "/_dev/Percussa SSP/thirdparty-plugins"
    @State private var restarting = false

    private func scanLocal() {
        var found: [URL] = []
        if let e = FileManager.default.enumerator(
            at: URL(fileURLWithPath: staging),
            includingPropertiesForKeys: nil) {
            for case let u as URL in e where u.pathExtension == "so"
                      && !u.lastPathComponent.hasPrefix("._") {
                found.append(u)
            }
        }
        local = found.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func remoteNames() -> Set<String> { Set(remote.map(\.name)) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("on card (\(remote.count))").font(.headline)
                Spacer()
                Button { Task { remote = await ssp.listPlugins() } }
                    label: { Image(systemName: "arrow.clockwise") }
                Button {
                    Task {
                        restarting = true
                        await ssp.restartSynthor()
                        restarting = false
                    }
                } label: { Label(restarting ? "Restarting…" : "Restart SYNTHOR",
                               systemImage: "power") }
                .disabled(restarting || !ssp.online)
            }
            .padding(8)

            HSplitView {
                Table(remote, selection: $sel) {
                    TableColumn("module", value: \.name)
                    TableColumn("size") { Text($0.size).monospaced() }.width(90)
                }

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
                                HStack {
                                    Text(u.lastPathComponent).monospaced()
                                    Spacer()
                                    if remoteNames().contains(u.lastPathComponent) {
                                        Text("installed").font(.caption).foregroundStyle(.green)
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
                            for u in localSel.sorted(by: { $0.path < $1.path }) {
                                _ = await ssp.installPlugin(u)
                            }
                            remote = await ssp.listPlugins()
                        }
                    } label: {
                        Label("Install selected (\(localSel.count))",
                              systemImage: "square.and.arrow.down")
                    }
                    .disabled(localSel.isEmpty || !ssp.online)
                }
                .padding(8)
                .frame(minWidth: 360)
            }
        }
        .task {
            remote = await ssp.listPlugins()
            scanLocal()
        }
    }
}
