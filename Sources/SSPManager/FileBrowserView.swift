import SwiftUI

/// Local navigator (left) + remote card browser (right). All remote actions
/// live in the right pane's own toolbar row.
struct FileBrowserView: View {
    @Environment(SSPService.self) private var ssp
    @State private var path = "samples"
    @State private var items: [RemoteItem] = []
    @State private var sel = Set<RemoteItem.ID>()
    private var selItems: [RemoteItem] { items.filter { sel.contains($0.id) } }
    private var selItem: RemoteItem? { selItems.count == 1 ? selItems[0] : nil }
    @State private var showPicker = false
    @State private var showTrash = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var makingDir = false
    @State private var dirName = ""

    private func load() async {
        items = await ssp.listDir(showTrash ? ".trash" : path)
    }

    private func go(_ item: RemoteItem) {
        if item.isDir {
            path = item.path.replacingOccurrences(of: ssp.root + "/", with: "")
            Task { await load() }
        }
    }

    private func up() {
        if let i = path.lastIndex(of: "/") { path = String(path[..<i]) } else { path = "" }
        Task { await load() }
    }

    var body: some View {
        HSplitView {
            LocalPane(remoteDir: path) { Task { await load() } }
                .frame(minWidth: 300)

            VStack(spacing: 0) {
                // remote nav row
                HStack(spacing: 6) {
                    Button { up() } label: { Image(systemName: "arrow.up") }
                        .disabled(showTrash || path.isEmpty)
                    Text(showTrash ? ".trash" : "/" + path)
                        .font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { Task { await load() } }
                        label: { Image(systemName: "arrow.clockwise") }
                }
                .padding(.horizontal, 6).padding(.top, 6)

                // remote actions row
                HStack(spacing: 8) {
                    Toggle("Trash", isOn: $showTrash).toggleStyle(.checkbox)
                        .onChange(of: showTrash) { Task { await load() } }
                    Divider().frame(height: 16)
                    Button { makingDir = true } label: { Image(systemName: "folder.badge.plus") }
                        .disabled(showTrash).help("New folder")
                    Button { showPicker = true } label: { Image(systemName: "arrow.up.doc") }
                        .disabled(showTrash).help("Upload files")
                    Button {
                        Task {
                            for s in selItems {
                                _ = await ssp.download(remotePath: s.path,
                                    localDir: URL(fileURLWithPath: NSHomeDirectory() + "/Downloads"))
                            }
                        }
                    } label: { Image(systemName: "arrow.down.doc") }
                        .disabled(sel.isEmpty).help("Download to ~/Downloads")
                    Button { if let s = selItem, s.isDir { go(s) } }
                        label: { Image(systemName: "folder.badge.arrow.up.forward") }
                        .disabled(!(selItem?.isDir ?? false)).help("Open folder")
                    Button { if let s = selItem { renaming = true; newName = s.name } }
                        label: { Image(systemName: "pencil") }
                        .disabled(selItem == nil || showTrash).help("Rename")
                    Button {
                        Task {
                            for s in selItems { await ssp.deleteToTrash(s.path) }
                            await load()
                        }
                    } label: { Image(systemName: "trash") }
                        .disabled(sel.isEmpty || showTrash).help("Move to trash")
                    if showTrash {
                        Button("Empty") { Task { await ssp.emptyTrash(); await load() } }
                    }
                    Spacer()
                }
                .padding(.horizontal, 6).padding(.vertical, 4)

                Table(items, selection: $sel) {
                    TableColumn("Name") { it in
                        if it.isDir {
                            Button { go(it) } label: {
                                Label(it.name, systemImage: "folder")
                                    .foregroundStyle(.primary)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Label(it.name, systemImage: iconFor(it.name))
                        }
                    }
                    TableColumn("Size") { it in Text(it.size).monospaced() }
                        .width(90)
                }
                .contextMenu(forSelectionType: RemoteItem.self) { selItems in
                    if let it = selItems.first {
                        if it.isDir { Button("Open") { go(it) } }
                        Button("Download") {
                            Task {
                                _ = await ssp.download(remotePath: it.path,
                                    localDir: URL(fileURLWithPath: NSHomeDirectory() + "/Downloads"))
                            }
                        }
                        if !showTrash {
                            Button("Rename") { sel = [it.id]; renaming = true; newName = it.name }
                            Button("Delete", role: .destructive) {
                                Task { await ssp.deleteToTrash(it.path); await load() }
                            }
                        }
                    }
                } primaryAction: { selItems in
                    if let it = selItems.first, it.isDir { go(it) }
                }
            }
        }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.item, .folder],
                      allowsMultipleSelection: true) { res in
            if case .success(let urls) = res {
                Task {
                    for u in urls { _ = await ssp.upload(local: u, remoteDir: path) }
                    await load()
                }
            }
        }
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let s = selItem {
                    let dst = s.path.replacingOccurrences(of: "/\(s.name)", with: "/\(newName)")
                    Task { await ssp.move(s.path, dst); await load() }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New folder", isPresented: $makingDir) {
            TextField("Folder name", text: $dirName)
            Button("Create") {
                if !dirName.isEmpty {
                    Task { await ssp.mkdir(path.isEmpty ? dirName : "\(path)/\(dirName)"); await load() }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .task { await load() }
    }

    private func iconFor(_ name: String) -> String {
        if name.hasSuffix(".wav") || name.hasSuffix(".aif") { return "waveform" }
        if name.hasSuffix(".yaml") || name.hasSuffix(".yml") { return "doc.text" }
        if name.hasSuffix(".so") { return "puzzlepiece" }
        if name.hasSuffix(".pbp") { return "doc.on.doc" }
        return "doc"
    }
}

struct LocalFile: Identifiable, Hashable {
    let url: URL
    var id: String { url.path }
}

/// Local filesystem navigator: browse dirs, select files, upload or
/// convert-to-WAV then upload into the current remote directory.
struct LocalPane: View {
    @Environment(SSPService.self) private var ssp
    let remoteDir: String
    var onUploaded: () -> Void = {}
    @State private var dir = URL(fileURLWithPath: NSHomeDirectory() + "/Music")
    @State private var items: [LocalFile] = []
    @State private var sel = Set<LocalFile.ID>()
    @State private var working = ""

    private static let audioExt: Set<String> =
        ["aif", "aiff", "aifc", "wav", "flac", "mp3", "m4a", "ogg"]

    private func isDir(_ u: URL) -> Bool {
        (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }
    private func isAudio(_ u: URL) -> Bool {
        Self.audioExt.contains(u.pathExtension.lowercased())
    }

    private func load() {
        let raw = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        items = raw.sorted {
            let d1 = isDir($0), d2 = isDir($1)
            return d1 == d2 ? $0.lastPathComponent < $1.lastPathComponent : d1
        }.map(LocalFile.init)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { dir = dir.deletingLastPathComponent(); load() }
                    label: { Image(systemName: "arrow.up") }
                Text(dir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { load() } label: { Image(systemName: "arrow.clockwise") }
            }
            .padding(.horizontal, 6).padding(.top, 6)

            Table(items, selection: $sel) {
                TableColumn("local") { f in
                    if isDir(f.url) {
                        Button { dir = f.url; load() } label: {
                            Label(f.url.lastPathComponent, systemImage: "folder")
                                .font(.system(size: 12)).foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Label(f.url.lastPathComponent, systemImage:
                                isAudio(f.url) ? "waveform" : "doc")
                            .font(.system(size: 12))
                    }
                }
            }
            .contextMenu(forSelectionType: LocalFile.self) { s in
                if let f = s.first, isDir(f.url) { Button("Open") { dir = f.url; load() } }
            } primaryAction: { s in
                if let f = s.first, isDir(f.url) { dir = f.url; load() }
            }

            HStack(spacing: 8) {
                Button {
                    Task {
                        working = "uploading…"
                        for id in sel { _ = await ssp.upload(local: URL(fileURLWithPath: id), remoteDir: remoteDir) }
                        working = ""; onUploaded()
                    }
                } label: { Label("Upload", systemImage: "arrow.up.doc") }
                    .disabled(sel.isEmpty || !ssp.online)
                Button {
                    Task {
                        working = "converting…"
                        for id in sel { _ = await ssp.convertUpload(local: URL(fileURLWithPath: id), remoteDir: remoteDir) }
                        working = ""; onUploaded()
                    }
                } label: { Label("→WAV + Upload", systemImage: "waveform.badge.plus") }
                    .disabled(sel.isEmpty || !ssp.online)
                Text(working).font(.caption).foregroundStyle(.secondary)
            }
            .padding(6)
        }
        .onAppear(perform: load)
    }
}
