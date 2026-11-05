import SwiftUI

/// Plugins pane: remote .so list on card vs local staging dir; install + restart.
struct PluginsView: View {
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
