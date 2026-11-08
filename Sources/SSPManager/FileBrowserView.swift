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
    @State private var moving = false
    @State private var moveDest = "samples"
    @State private var moveFolders: [RemoteItem] = []
    @State private var loadTask: Task<Void, Never>?
    @State private var loadGen = 0

    /// Kick a directory refresh; cancels any in-flight listing so a hung `ls`
    /// on a fat sample folder can't block further navigation.
    private func scheduleLoad() {
        loadGen += 1
        let gen = loadGen
        let target = showTrash ? ".trash" : path
        loadTask?.cancel()
        loadTask = Task {
            await ssp.cancelBrowse()
            let listed = await ssp.listDir(target)
            guard !Task.isCancelled, gen == loadGen else { return }
            items = listed
            sel.removeAll()
        }
    }

    private func loadMoveFolders() async {
        moveFolders = (await ssp.listDir(moveDest)).filter(\.isDir)
    }

    private func openMove() {
        moveDest = path.isEmpty ? "samples" : path
        moving = true
        Task { await loadMoveFolders() }
    }

    /// Absolute dest for `name` under the relative moveDest path.
    private func moveTarget(for name: String) -> String {
        moveDest.isEmpty ? name : "\(moveDest)/\(name)"
    }

    private func canMove(_ item: RemoteItem) -> Bool {
        let destAbs = moveDest.isEmpty ? ssp.root : "\(ssp.root)/\(moveDest)"
        if item.path == destAbs { return false }                          // onto itself
        if destAbs.hasPrefix(item.path + "/") { return false }            // into own child
        let parent = (item.path as NSString).deletingLastPathComponent
        return parent != destAbs                                         // already there
    }

    private func performMove() {
        let targets = selItems
        Task {
            for s in targets where canMove(s) {
                await ssp.move(s.path, moveTarget(for: s.name))
            }
            moving = false
            sel.removeAll()
            scheduleLoad()
        }
    }

    private func go(_ item: RemoteItem) {
        if item.isDir {
            path = item.path.replacingOccurrences(of: ssp.root + "/", with: "")
            scheduleLoad()
        }
    }

    private func up() {
        if let i = path.lastIndex(of: "/") { path = String(path[..<i]) } else { path = "" }
        scheduleLoad()
    }

    var body: some View {
        HSplitView {
            LocalPane(remoteDir: path) { scheduleLoad() }
                .frame(minWidth: 300)

            VStack(spacing: 0) {
                // remote nav row
                HStack(spacing: 6) {
                    Button { up() } label: { Image(systemName: "arrow.up") }
                        .disabled(showTrash || path.isEmpty)
                    Text(showTrash ? ".trash" : "/" + path)
                        .font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { scheduleLoad() }
                        label: { Image(systemName: "arrow.clockwise") }
                }
                .padding(.horizontal, 6).padding(.top, 6)

                // remote actions row
                HStack(spacing: 8) {
                    Toggle("Trash", isOn: $showTrash).toggleStyle(.checkbox)
                        .onChange(of: showTrash) { scheduleLoad() }
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
                    Button { openMove() }
                        label: { Image(systemName: "rectangle.portrait.and.arrow.right") }
                        .disabled(sel.isEmpty || showTrash).help("Move to folder…")
                    Button {
                        Task {
                            for s in selItems { await ssp.deleteToTrash(s.path) }
                            scheduleLoad()
                        }
                    } label: { Image(systemName: "trash") }
                        .disabled(sel.isEmpty || showTrash).help("Move to trash")
                    if showTrash {
                        Button("Empty") { Task { await ssp.emptyTrash(); scheduleLoad() } }
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
                            Button("Move…") {
                                sel = Set(selItems.map(\.id))
                                openMove()
                            }
                            Button("Delete", role: .destructive) {
                                Task { await ssp.deleteToTrash(it.path); scheduleLoad() }
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
                // Freeze destination — navigating the remote pane mid-transfer
                // must not retarget (or race) the upload.
                let dest = path
                Task {
                    for u in urls { _ = await ssp.upload(local: u, remoteDir: dest) }
                    scheduleLoad()
                }
            }
        }
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let s = selItem {
                    let dst = s.path.replacingOccurrences(of: "/\(s.name)", with: "/\(newName)")
                    Task { await ssp.move(s.path, dst); scheduleLoad() }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New folder", isPresented: $makingDir) {
            TextField("Folder name", text: $dirName)
            Button("Create") {
                if !dirName.isEmpty {
                    Task { await ssp.mkdir(path.isEmpty ? dirName : "\(path)/\(dirName)"); scheduleLoad() }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $moving) {
            MoveSheet(
                count: selItems.count,
                names: selItems.map(\.name),
                dest: $moveDest,
                folders: moveFolders,
                onUp: {
                    if let i = moveDest.lastIndex(of: "/") {
                        moveDest = String(moveDest[..<i])
                    } else { moveDest = "" }
                    Task { await loadMoveFolders() }
                },
                onEnter: { folder in
                    moveDest = folder.path.replacingOccurrences(of: ssp.root + "/", with: "")
                    Task { await loadMoveFolders() }
                },
                onConfirm: performMove,
                onCancel: { moving = false }
            )
        }
        .task { scheduleLoad() }
    }

/// Folder picker sheet for moving selected remote items.
private struct MoveSheet: View {
    let count: Int
    let names: [String]
    @Binding var dest: String
    let folders: [RemoteItem]
    var onUp: () -> Void
    var onEnter: (RemoteItem) -> Void
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Move \(count) item\(count == 1 ? "" : "s")")
                .font(.headline)
            Text(names.prefix(4).joined(separator: ", ")
                 + (names.count > 4 ? "…" : ""))
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(2)

            HStack(spacing: 6) {
                Button(action: onUp) { Image(systemName: "arrow.up") }
                    .disabled(dest.isEmpty)
                Text("/" + dest)
                    .font(.caption).lineLimit(1).truncationMode(.middle)
                Spacer()
            }

            List(folders) { f in
                Button { onEnter(f) } label: {
                    Label(f.name, systemImage: "folder")
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 220)
            .border(Color.secondary.opacity(0.25))

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Move Here", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(count == 0)
            }
        }
        .padding(16)
        .frame(width: 420, height: 380)
    }
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
                    let dest = remoteDir
                    let urls = sel.map { URL(fileURLWithPath: $0) }
                    Task {
                        working = "uploading → /\(dest)…"
                        for u in urls { _ = await ssp.upload(local: u, remoteDir: dest) }
                        working = ""; onUploaded()
                    }
                } label: { Label("Upload", systemImage: "arrow.up.doc") }
                    .disabled(sel.isEmpty || !ssp.online || !working.isEmpty)
                Button {
                    let dest = remoteDir
                    let urls = sel.map { URL(fileURLWithPath: $0) }
                    Task {
                        working = "converting → /\(dest)…"
                        for u in urls { _ = await ssp.convertUpload(local: u, remoteDir: dest) }
                        working = ""; onUploaded()
                    }
                } label: { Label("→WAV + Upload", systemImage: "waveform.badge.plus") }
                    .disabled(sel.isEmpty || !ssp.online || !working.isEmpty)
                Text(working).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(6)
        }
        .onAppear(perform: load)
    }
}
