import SwiftUI

/// Presets pane: list NNN.pbp on card, backup-all to Mac, push files back.
/// .pbp is opaque binary SYNTHOR state — backup/restore only until decoded.
struct PresetsView: View {
    @Environment(SSPService.self) private var ssp
    @State private var items: [RemoteItem] = []
    @State private var names: [String: String] = [:]
    @State private var sel = Set<RemoteItem.ID>()
    @State private var showPush = false
    @State private var lastBackup = ""

    private func refresh() async {
        items = await ssp.listPresets()
        let n = await ssp.presetNames()
        names = n
        items = items.map {
            var it = $0; it.extra = n[$0.name] ?? ""; return it
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("presets (\(items.count))").font(.headline)
                Text(".pbp is closed SYNTHOR format — backup/restore only")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await refresh() } }
                    label: { Image(systemName: "arrow.clockwise") }
                Button {
                    Task {
                        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmm"
                        let dir = URL(fileURLWithPath: NSHomeDirectory()
                            + "/Documents/SSP-presets-\(df.string(from: Date()))")
                        if await ssp.backupPresets(to: dir) {
                            lastBackup = dir.path
                        }
                    }
                } label: { Label("Backup all → Documents", systemImage: "externaldrive") }
                    .disabled(!ssp.online)
                Button { showPush = true } label: {
                    Label("Push .pbp…", systemImage: "arrow.up.doc")
                }.disabled(!ssp.online)
            }
            .padding(8)

            Table(items, selection: $sel) {
                TableColumn("preset", value: \.name).width(90)
                TableColumn("name") { Text($0.extra.isEmpty ? "—" : $0.extra) }
                TableColumn("size") { Text($0.size).monospaced() }.width(90)
            }

            if !lastBackup.isEmpty {
                Text("backed up → \(lastBackup)")
                    .font(.caption).foregroundStyle(.secondary).padding(6)
            }
        }
        .fileImporter(isPresented: $showPush,
                      allowedContentTypes: [.init(filenameExtension: "pbp")!],
                      allowsMultipleSelection: true) { res in
            if case .success(let urls) = res {
                Task {
                    // remote snapshot happens inside pushPreset per file —
                    // do one explicit snapshot first to avoid N backups
                    for u in urls { _ = await ssp.pushPreset(u) }
                    await refresh()
                }
            }
        }
        .task { await refresh() }
    }
}

/// Device pane: connectivity, space, synthor ops.
struct DeviceView: View {
    @Environment(SSPService.self) private var ssp
    @State private var disk = ""
    var body: some View {
        @Bindable var s = ssp
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Host")
                TextField("ip", text: $s.host).frame(width: 140)
                    .onSubmit { Task { await ssp.ping() } }
                Text("Card root")
                TextField("path", text: $s.root).frame(width: 130)
                    .help("/media/BOOT on the 2022 image, /media/linaro/SYNTHOR on older")
                Circle().fill(ssp.online ? .green : .red).frame(width: 8, height: 8)
                Text(ssp.online ? "online" : "offline")
                Button("Ping") { Task { await ssp.ping() } }
            }
            HStack {
                Text("Card space")
                Text(disk.isEmpty ? "—" : disk).monospaced()
                Button("Refresh") { Task { disk = await ssp.df() } }
            }
            Divider()
            Button("Restart SYNTHOR (rescan plugins)") {
                Task { await ssp.restartSynthor() }
            }.disabled(!ssp.online)
            Spacer()
        }
        .padding(16)
        .task { await ssp.ping(); disk = await ssp.df() }
    }
}
