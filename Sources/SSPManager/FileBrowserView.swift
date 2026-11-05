import SwiftUI

/// Remote file browser over SSH: navigate, mkdir, rename, trash, up/download.
struct FileBrowserView: View {
    @Environment(SSPService.self) private var ssp
    @State private var path = "samples"          // relative to /media/BOOT
    @State private var items: [RemoteItem] = []
    @State private var sel: RemoteItem.ID?
    private var selItem: RemoteItem? { items.first { $0.id == sel } }
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
        VStack(spacing: 0) {
            // toolbar
            HStack(spacing: 8) {
                Toggle("Trash", isOn: $showTrash).toggleStyle(.checkbox)
                    .onChange(of: showTrash) { Task { await load() } }
                Divider().frame(height: 16)
                Button { up() } label: { Image(systemName: "arrow.up") }
                    .disabled(showTrash || path.isEmpty)
                Text(showTrash ? ".trash" : "/" + path)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                Button { makingDir = true } label: { Image(systemName: "folder.badge.plus") }
                    .disabled(showTrash)
                Button { showPicker = true } label: { Label("Upload", systemImage: "arrow.up.doc") }
                    .disabled(showTrash)
                Button {
                    if let s = selItem {
                        Task {
                            let dst = URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
                            _ = await ssp.download(remotePath: s.path, localDir: dst)
                        }
                    }
                } label: { Label("Download", systemImage: "arrow.down.doc") }
                    .disabled(selItem == nil)
                Button { if let s = selItem { renaming = true; newName = s.name } }
                    label: { Image(systemName: "pencil") }
                    .disabled(sel == nil || showTrash)
                Button {
                    if let s = selItem {
                        Task { await ssp.deleteToTrash(s.path); await load() }
                    }
                } label: { Image(systemName: "trash") }
                    .disabled(sel == nil || showTrash)
                if showTrash {
                    Button("Empty") { Task { await ssp.emptyTrash(); await load() } }
                }
            }
            .padding(8)

            Table(items, selection: $sel) {
                TableColumn("Name") { it in
                    Label(it.name, systemImage: it.isDir ? "folder" : iconFor(it.name))
                }
                TableColumn("Size") { it in Text(it.size).monospaced() }
                    .width(90)
                TableColumn("Path") { it in
                    Text(it.path.replacingOccurrences(of: ssp.root, with: ""))
                        .foregroundStyle(.secondary).lineLimit(1)
                }
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
                        Button("Rename") { sel = it.id; renaming = true; newName = it.name }
                        Button("Delete", role: .destructive) {
                            Task { await ssp.deleteToTrash(it.path); await load() }
                        }
                    }
                }
            } primaryAction: { selItems in
                if let it = selItems.first { go(it) }
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
