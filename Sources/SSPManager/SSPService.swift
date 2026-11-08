import Foundation

/// Remote item on the SSP card.
struct RemoteItem: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let isDir: Bool
    let size: String
    var extra = ""                 // preset name etc. — baked in, not a lookup
}

/// SSH-backed operations against the SSP card. All UI-thread safe (@MainActor).
/// dropbear has no sftp -> scp -O for files, tar-over-ssh for dirs.
///
/// All remote ssh/scp/tar|ssh calls go through ``SSPTransport`` so they never
/// overlap — dropbear on the SSP often only allows one session, and a mid-
/// transfer `ls` (from navigating folders) used to kill the upload.
struct NetPort: Identifiable, Hashable {
    let name: String      // service / hardware port name, e.g. "USB 10/100/1000 LAN"
    let device: String    // current BSD name, e.g. "en8" (may change)
    var id: String { name }
}

/// Serializes Process launches that talk to the SSP (one session at a time).
/// Explicit task chain (actors are reentrant across `await`). Browse ops can
/// preempt a prior browse (kill its Process) so a hung `ls` doesn't freeze nav;
/// transfers preempt browse so uploads still get the single dropbear slot.
actor SSPTransport {
    enum Kind { case browse, transfer }

    private var chain: Task<(Int32, String, String), Never>?
    private var active: Process?
    private var activeKind: Kind?

    func cancelBrowse() {
        if activeKind == .browse {
            active?.terminate()
            active = nil
            activeKind = nil
        }
    }

    func run(_ exe: String, _ args: [String], kind: Kind = .transfer) async -> (Int32, String, String) {
        // New browse replaces a wedged browse; transfers bump browse off the slot.
        // Never terminate an in-flight transfer.
        cancelBrowse()
        let prior = chain
        let task = Task<(Int32, String, String), Never> {
            _ = await prior?.value
            return await self.exec(exe, args, kind: kind)
        }
        chain = task
        return await task.value
    }

    private func exec(_ exe: String, _ args: [String], kind: Kind) async -> (Int32, String, String) {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<(Int32, String, String), Never>) in
                let p = Process()
                let out = Pipe(), err = Pipe()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                p.standardOutput = out
                p.standardError = err
                do {
                    try p.run()
                    self.active = p
                    self.activeKind = kind
                    p.terminationHandler = { proc in
                        let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                        Task { await self.clearActive(p) }
                        cont.resume(returning: (proc.terminationStatus, o, e))
                    }
                } catch {
                    cont.resume(returning: (-1, "", "\(error)"))
                }
            }
        } onCancel: {
            // Only browse ops are cancellable mid-flight — never kill a transfer.
            if kind == .browse {
                Task { await self.cancelBrowse() }
            }
        }
    }

    private func clearActive(_ p: Process) {
        if active === p {
            active = nil
            activeKind = nil
        }
    }
}

@MainActor @Observable
final class SSPService {
    var host = "192.168.1.6"
    var netPorts: [NetPort] = []
    var port = UserDefaults.standard.string(forKey: "sspPort") ?? "" {
        didSet { UserDefaults.standard.set(port, forKey: "sspPort") }
    }
    var routeIface = ""                 // interface the host currently routes through
    var root = "/media/BOOT"
    var busy = false
    var online = false
    var log: [String] = []

    private let transport = SSPTransport()
    private var busyDepth = 0

    private func note(_ s: String) { log.append(s); if log.count > 500 { log.removeFirst() } }

    private func pushBusy() {
        busyDepth += 1
        busy = true
    }
    private func popBusy() {
        busyDepth = max(0, busyDepth - 1)
        busy = busyDepth > 0
    }

    // ---- primitives ---------------------------------------------------------

    /// Short keepalives for browse/`ls` only — kill wedged listings.
    /// Transfers omit keepalives: a long FAT `sync` with no SSH traffic used to
    /// trip ServerAliveInterval=3 and drop the connection mid-tree.
    private var browseSSH: [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
         "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3"]
    }
    private var transferSSH: [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
         "-o", "ServerAliveInterval=0"]
    }

    /// Interrupt a hung directory listing so navigation can continue.
    func cancelBrowse() async { await transport.cancelBrowse() }

    @discardableResult
    func sh(_ script: String, browse: Bool = false) async -> (Int32, String, String) {
        note("$ ssh \(script)")
        return await transport.run("/usr/bin/ssh",
            (browse ? browseSSH : transferSSH) + ["root@\(host)", script],
            kind: browse ? .browse : .transfer)
    }

    /// Run a local shell pipeline (for tar streams). Goes through the transport
    /// when the pipeline includes ssh to the SSP so it can't race an scp.
    @discardableResult
    func shell(_ cmd: String) async -> (Int32, String, String) {
        note("$ \(cmd)")
        return await transport.run("/bin/bash", ["-c", cmd], kind: .transfer)
    }

    func scp(_ local: String, to remote: String) async -> (Int32, String, String) {
        note("$ scp -O \(local) -> \(remote)")
        return await transport.run("/usr/bin/scp",
            ["-O", "-q"] + transferSSH + [local, "root@\(host):\(remote)"],
            kind: .transfer)
    }

    // FAT/VFAT rejects these in a single path component — busybox tar then
    // errors (`Invalid argument`) and aborts mid-library (`tar: Write error`).
    private static let fatIllegal = CharacterSet(charactersIn: ":*?\"<>|\\")

    static func fatSafeComponent(_ name: String) -> String {
        var s = ""
        for ch in name {
            if ch.unicodeScalars.contains(where: { fatIllegal.contains($0) }) { s.append("-") }
            else { s.append(ch) }
        }
        while s.hasSuffix(".") || s.hasSuffix(" ") { s.removeLast() }
        return s.isEmpty ? "_" : s
    }

    /// Stream a directory as a tar on stdout, rewriting arcnames so every
    /// path component is FAT-safe (`:` → `-`, etc.). Uses python3 (macOS).
    private static let fatSafeTarPy = #"""
    import tarfile, os, sys
    ILLEGAL = set(':*?"<>|\\')
    JUNK = {'.DS_Store', '.Spotlight-V100', '.fseventsd', '.Trashes',
            '.TemporaryItems', '.apdisk'}
    def safe_comp(n: str) -> str:
        s = ''.join('-' if c in ILLEGAL else c for c in n).rstrip('. ')
        return s or '_'
    def safe_rel(rel: str) -> str:
        parts = [p for p in rel.replace('\\', '/').split('/') if p and p != '.']
        return '/'.join(safe_comp(p) for p in parts)
    def is_junk(name: str) -> bool:
        return name.startswith('._') or name in JUNK
    root = sys.argv[1]
    rewrites = 0
    files = 0
    with tarfile.open(fileobj=sys.stdout.buffer, mode='w|') as tar:
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if not is_junk(d)]
            rel_dir = os.path.relpath(dirpath, root)
            if rel_dir == '.':
                rel_dir = ''
            for fn in filenames:
                if is_junk(fn):
                    continue
                full = os.path.join(dirpath, fn)
                if not os.path.isfile(full):
                    continue
                rel = fn if not rel_dir else os.path.join(rel_dir, fn)
                arc = safe_rel(rel)
                if arc != rel.replace('\\', '/'):
                    rewrites += 1
                tar.add(full, arcname=arc, recursive=False)
                files += 1
    print(f'FAT-safe tar: {files} files, {rewrites} path(s) renamed', file=sys.stderr)
    """#

    private func fatSafeTarScript() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssp-fat-tar-\(UUID().uuidString).py")
        try Self.fatSafeTarPy.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Local-only Process (afconvert, etc.) — may run concurrent with SSP I/O.
    static func run(_ exe: String, _ args: [String]) async -> (Int32, String, String) {
        await withCheckedContinuation { cont in
            let p = Process()
            let out = Pipe(), err = Pipe()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            p.standardOutput = out
            p.standardError = err
            do {
                try p.run()
                p.terminationHandler = { proc in
                    let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    cont.resume(returning: (proc.terminationStatus, o, e))
                }
            } catch {
                cont.resume(returning: (-1, "", "\(error)"))
            }
        }
    }

    private func q(_ s: String) -> String { "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'" }
    private func abs(_ p: String) -> String {
        if p.isEmpty { return root }
        return p.hasPrefix("/") ? p : "\(root)/\(p)"
    }

    // ---- mac junk -----------------------------------------------------------
    // AppleDouble (._x), Finder and Spotlight metadata must never reach the SSP:
    // they double FAT entries and confuse SYNTHOR's file lists.
    static let junkNames = ["._*", ".DS_Store", ".Spotlight-V100", ".fseventsd", ".Trashes",
                            ".TemporaryItems", ".apdisk"]
    static var junkExcludes: String { junkNames.map { "--exclude='\($0)'" }.joined(separator: " ") }
    static func isMacJunk(_ name: String) -> Bool {
        name.hasPrefix("._") || junkNames.contains(name)
    }

    /// Count AppleDouble/.DS_Store files under the card root (read-only).
    func countMacJunk() async -> Int {
        let (_, out, _) = await sh("find \(q(root)) \\( -name '._*' -o -name .DS_Store \\) -type f | wc -l")
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Delete AppleDouble/.DS_Store files under the card root.
    func cleanMacJunk() async -> Int {
        pushBusy(); defer { popBusy() }
        let n = await countMacJunk()
        _ = await sh("find \(q(root)) \\( -name '._*' -o -name .DS_Store \\) -type f -delete; sync")
        note("removed \(n) mac junk file(s)")
        return n
    }

    // ---- device -------------------------------------------------------------

    private func run(_ exe: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try? p.run(); p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    /// Wired adapters by service name (stable across enX renumbering).
    func refreshPorts() {
        var res: [NetPort] = []
        var hw = ""
        for line in run("/usr/sbin/networksetup", ["-listallhardwareports"]).split(separator: "\n") {
            if line.hasPrefix("Hardware Port: ") { hw = String(line.dropFirst(15)) }
            else if line.hasPrefix("Device: "), !hw.localizedCaseInsensitiveContains("wi-fi"),
                    !hw.localizedCaseInsensitiveContains("bluetooth"),
                    !hw.localizedCaseInsensitiveContains("thunderbolt bridge") {
                res.append(NetPort(name: hw, device: String(line.dropFirst(8))))
            }
        }
        netPorts = res
        if port.isEmpty, let usb = res.first(where: { $0.name.contains("USB") }) { port = usb.name }
        routeIface = run("/sbin/route", ["-n", "get", host]).split(separator: "\n")
            .first { $0.contains("interface:") }?
            .split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// Narrow mask on the chosen adapter so the SSP's address routes out of it
    /// even when Wi-Fi uses the same /24. SSP addressing is untouched.
    func applyPort() async {
        let o = host.split(separator: ".").compactMap { Int($0) }
        guard o.count == 4, !port.isEmpty else { note("port: bad host or no adapter"); return }
        let d = o[3]
        let (base, mask) = (d % 4 == 0 || d % 4 == 3) ? (d & ~7, "255.255.255.248")
                                                      : (d & ~3, "255.255.255.252")
        let mac = base + 1 == d ? base + 2 : base + 1
        let ip = "\(o[0]).\(o[1]).\(o[2]).\(mac)"
        let cmd = "/usr/sbin/networksetup -setmanual '\(port)' \(ip) \(mask)"
        let out = run("/usr/bin/osascript",
                      ["-e", "do shell script \"\(cmd)\" with administrator privileges"])
        note("\(cmd)  ->  \(out.isEmpty ? "ok" : out)")
        try? await Task.sleep(for: .seconds(2))
        refreshPorts()
        await ping()
    }

    func ping() async {
        pushBusy(); defer { popBusy() }
        let (rc, out, _) = await sh("echo PONG")
        online = rc == 0 && out.contains("PONG")
    }

    func df() async -> String {
        pushBusy(); defer { popBusy() }
        let (_, out, _) = await sh("df -h \(q(root)) | tail -1")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func restartSynthor() async {
        pushBusy(); defer { popBusy() }
        let (_, out, _) = await sh("/etc/init.d/S90synthor restart")
        note(out)
    }

    // ---- file manager -------------------------------------------------------

    /// Fast name listing (`ls -1Ap`) — avoids `ls -l` stat-storms on fat
    /// sample dirs that hang dropbear for minutes.
    func listDir(_ path: String) async -> [RemoteItem] {
        pushBusy(); defer { popBusy() }
        let p = abs(path)
        // -1 one per line, -A almost-all, -p dirs get trailing /
        let (rc, out, err) = await sh("ls -1Ap \(q(p)) 2>/dev/null | head -n 4000", browse: true)
        guard rc == 0 else {
            if !err.isEmpty { note("listDir \(p): \(err)") }
            return []
        }
        var items: [RemoteItem] = []
        for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
            var name = String(line)
            let isDir = name.hasSuffix("/")
            if isDir { name.removeLast() }
            guard !name.isEmpty, name != ".", name != "..", !Self.isMacJunk(name),
                  !name.hasPrefix(".") else { continue }
            items.append(RemoteItem(name: name, path: "\(p)/\(name)",
                                    isDir: isDir, size: isDir ? "—" : ""))
        }
        return items.sorted { $0.isDir == $1.isDir ? $0.name < $1.name : $0.isDir }
    }

    func mkdir(_ path: String) async { pushBusy(); defer { popBusy() }; _ = await sh("mkdir -p \(q(abs(path)))") }
    func move(_ src: String, _ dst: String) async { pushBusy(); defer { popBusy() }; _ = await sh("mv \(q(abs(src))) \(q(abs(dst)))") }

    /// Safe delete: move to /media/BOOT/.trash
    func deleteToTrash(_ path: String) async {
        pushBusy(); defer { popBusy() }
        _ = await sh("mkdir -p \(q(root))/.trash && mv \(q(abs(path))) \(q(root))/.trash/")
    }
    func emptyTrash() async {
        pushBusy(); defer { popBusy() }
        _ = await sh("rm -rf \(q(root))/.trash && mkdir -p \(q(root))/.trash && sync")
    }

    /// Upload file or directory into remote dir.
    func upload(local: URL, remoteDir: String) async -> Bool {
        await upload(locals: [local], remoteDir: remoteDir)
    }

    /// Batch upload into remoteDir. Loose files share one `mkdir -p`, one tar
    /// stream, and one `sync` (avoids N round-trips when dropping many yamls).
    /// Directories still stream individually into their own remote folders.
    func upload(locals: [URL], remoteDir: String) async -> Bool {
        pushBusy(); defer { popBusy() }
        guard !locals.isEmpty else { return true }
        let dst = abs(remoteDir)
        var files: [URL] = []
        var ok = true
        for local in locals {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: local.path, isDirectory: &isDir), isDir.boolValue {
                if !(await uploadDirectory(local, into: dst)) { ok = false }
            } else if Self.isMacJunk(local.lastPathComponent) {
                note("skipped mac junk \(local.lastPathComponent)")
            } else {
                files.append(local)
            }
        }
        if !files.isEmpty, !(await uploadFiles(files, into: dst)) { ok = false }
        return ok
    }

    /// Stream a local directory as FAT-safe tar into `dst/<folderName>/`.
    private func uploadDirectory(_ local: URL, into dst: String) async -> Bool {
        let remoteName = Self.fatSafeComponent(local.lastPathComponent)
        if remoteName != local.lastPathComponent {
            note("FAT-safe rename \(local.lastPathComponent) → \(remoteName)")
        }
        let script: URL
        do { script = try fatSafeTarScript() }
        catch { note("FAT-safe tar script: \(error)"); return false }
        defer { try? FileManager.default.removeItem(at: script) }

        let ssh = transferSSH.joined(separator: " ")
        let remote = dst + "/" + remoteName
        let (rc, _, e) = await shell("""
            set -o pipefail
            /usr/bin/python3 \(q(script.path)) \(q(local.path)) \
              | /usr/bin/ssh \(ssh) root@\(host) \
                "mkdir -p \(q(remote)) && tar xf - -C \(q(remote)) && sync"
            """)
        if !e.isEmpty { note(e.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if rc != 0 { note("upload failed rc=\(rc)") }
        return rc == 0
    }

    /// Stage loose files with FAT-safe names, then one tar|ssh into `dst`.
    private func uploadFiles(_ files: [URL], into dst: String) async -> Bool {
        let stage = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssp-up-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }

        var used = Set<String>()
        var staged = 0
        for f in files {
            var name = Self.fatSafeComponent(f.lastPathComponent)
            if name != f.lastPathComponent {
                note("FAT-safe rename \(f.lastPathComponent) → \(name)")
            }
            // Avoid clobbering if two locals collapse to the same FAT-safe name.
            if used.contains(name) {
                let base = (name as NSString).deletingPathExtension
                let ext = (name as NSString).pathExtension
                var n = 2
                repeat {
                    name = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
                    n += 1
                } while used.contains(name)
            }
            used.insert(name)
            do {
                try FileManager.default.copyItem(at: f, to: stage.appendingPathComponent(name))
                staged += 1
            } catch {
                note("stage \(f.lastPathComponent): \(error)")
            }
        }
        guard staged > 0 else { return true }

        let script: URL
        do { script = try fatSafeTarScript() }
        catch { note("FAT-safe tar script: \(error)"); return false }
        defer { try? FileManager.default.removeItem(at: script) }

        let ssh = transferSSH.joined(separator: " ")
        note("upload \(staged) file(s) → \(dst)")
        let (rc, _, e) = await shell("""
            set -o pipefail
            /usr/bin/python3 \(q(script.path)) \(q(stage.path)) \
              | /usr/bin/ssh \(ssh) root@\(host) \
                "mkdir -p \(q(dst)) && tar xf - -C \(q(dst)) && sync"
            """)
        if !e.isEmpty { note(e.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if rc != 0 { note("upload failed rc=\(rc)") }
        return rc == 0
    }

    /// Download remote file/dir to local dir.
    func download(remotePath: String, localDir: URL) async -> Bool {
        pushBusy(); defer { popBusy() }
        let r = abs(remotePath)
        let (rc, out, _) = await sh("test -d \(q(r)) && echo DIR || echo FILE")
        let destDir = localDir.appendingPathComponent(r.split(separator: "/").last.map(String.init) ?? "dl")
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        if rc == 0 && out.contains("DIR") {
            let (rc2, _, e) = await shell(
                "/usr/bin/ssh -o BatchMode=yes root@\(host) \"COPYFILE_DISABLE=1 tar cf - -C '\(r)' .\" | tar xf - -C '\(destDir.path)'")
            if rc2 != 0 { note(e) }
            return rc2 == 0
        }
        note("$ scp -O \(r) -> \(destDir.path)")
        let (rc2, _, e) = await transport.run("/usr/bin/scp",
            ["-O", "-q"] + transferSSH + ["root@\(host):\(r)", destDir.path + "/"],
            kind: .transfer)
        if rc2 != 0 { note(e) }
        return rc2 == 0
    }

    /// Convert local audio (aif/flac/mp3) to 48k 24-bit WAV in a temp dir
    /// (afconvert), then upload wav + renamed sidecars into remoteDir.
    /// Non-audio files are uploaded unchanged. Returns count converted/uploaded.
    func convertUpload(local: URL, remoteDir: String) async -> Int {
        pushBusy(); defer { popBusy() }
        let audioExt: Set<String> = ["aif", "aiff", "aifc", "flac", "mp3", "m4a", "ogg"]
        var files: [URL] = []
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: local.path, isDirectory: &isDir)
        if isDir.boolValue {
            if let e = FileManager.default.enumerator(at: local, includingPropertiesForKeys: nil) {
                for case let u as URL in e where !Self.isMacJunk(u.lastPathComponent) { files.append(u) }
            }
        } else { files = [local] }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sspconv-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // stage converted output in tmp tree, preserving relative paths,
        // then stream as one folder: remoteDir/<folder name>/...
        let stage = tmp.appendingPathComponent(local.lastPathComponent)
        try? FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        var done = 0
        for f in files {
            let ext = f.pathExtension.lowercased()
            guard !ext.isEmpty else { continue }
            var rel = f.path
            if isDir.boolValue, rel.hasPrefix(local.path + "/") {
                rel = String(rel.dropFirst(local.path.count + 1))
            } else { rel = f.lastPathComponent }
            let relURL = URL(fileURLWithPath: rel)
            var out = stage.appendingPathComponent(rel)
            var src = f
            if audioExt.contains(ext) {
                out = out.deletingPathExtension().appendingPathExtension("wav")
                try? FileManager.default.createDirectory(
                    at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                let (rc, _, e) = await Self.run("/usr/bin/afconvert",
                    ["-f", "WAVE", "-d", "LEI24", f.path, out.path])
                if rc != 0 { note("afconvert \(f.lastPathComponent): \(e)"); continue }
                src = out
                for sfx in [".yaml", "_tags.yaml", "_edits.yaml", ".sfc", ".wfx"] {
                    let sc = URL(fileURLWithPath: f.path + sfx)
                    if FileManager.default.fileExists(atPath: sc.path) {
                        let d = URL(fileURLWithPath: out.path + sfx)
                        try? FileManager.default.copyItem(at: sc, to: d)
                    }
                }
            } else {
                try? FileManager.default.createDirectory(
                    at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.copyItem(at: f, to: out)
            }
            done += 1
        }
        let remoteName = Self.fatSafeComponent(local.lastPathComponent)
        let dstDir = abs(remoteDir) + "/" + remoteName
        let script: URL
        do { script = try fatSafeTarScript() }
        catch { note("FAT-safe tar script: \(error)"); return 0 }
        defer { try? FileManager.default.removeItem(at: script) }
        let ssh = transferSSH.joined(separator: " ")
        let (rc, _, e) = await shell("""
            set -o pipefail
            /usr/bin/python3 \(q(script.path)) \(q(stage.path)) \
              | /usr/bin/ssh \(ssh) root@\(host) \
                "mkdir -p \(q(dstDir)) && tar xf - -C \(q(dstDir)) && sync"
            """)
        if !e.isEmpty { note(e.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if rc != 0 { note("convertUpload failed rc=\(rc)"); return 0 }
        note("convertUpload: \(done) file(s) -> \(dstDir)")
        return done
    }

    // ---- plugins ------------------------------------------------------------

    /// Active modules loaded by SYNTHOR at startup (`plugins/*.so`).
    func listPlugins() async -> [RemoteItem] {
        (await listDir("plugins")).filter { $0.name.hasSuffix(".so") }
    }

    /// Modules kept on the card but not scanned (`plugins-disabled/*.so`).
    func listDisabledPlugins() async -> [RemoteItem] {
        _ = await sh("mkdir -p \(q(root))/plugins-disabled")
        return (await listDir("plugins-disabled")).filter { $0.name.hasSuffix(".so") }
    }

    func installPlugin(_ local: URL) async -> Bool {
        pushBusy(); defer { popBusy() }
        let name = local.lastPathComponent
        let (rc, _, e) = await scp(local.path, to: "\(root)/plugins/\(name)")
        if rc != 0 { note(e); return false }
        // Installing wins over a disabled copy of the same name.
        _ = await sh("rm -f \(q("\(root)/plugins-disabled/\(name)")); sync")
        note("installed \(name)")
        return true
    }

    /// Move active plugin out of SYNTHOR's scan path.
    func disablePlugin(_ name: String) async -> Bool {
        pushBusy(); defer { popBusy() }
        guard Self.isPluginFilename(name) else { return false }
        let src = "\(root)/plugins/\(name)"
        let dst = "\(root)/plugins-disabled/\(name)"
        let (rc, _, e) = await sh("""
            mkdir -p \(q("\(root)/plugins-disabled")) && \
            test -f \(q(src)) && mv \(q(src)) \(q(dst)) && sync
            """)
        if rc != 0 { note(e.isEmpty ? "disable failed: \(name)" : e); return false }
        note("disabled \(name)")
        return true
    }

    /// Move disabled plugin back into `plugins/` for the next SYNTHOR scan.
    func enablePlugin(_ name: String) async -> Bool {
        pushBusy(); defer { popBusy() }
        guard Self.isPluginFilename(name) else { return false }
        let src = "\(root)/plugins-disabled/\(name)"
        let dst = "\(root)/plugins/\(name)"
        let (rc, _, e) = await sh("""
            test -f \(q(src)) && ! test -e \(q(dst)) && \
            mv \(q(src)) \(q(dst)) && sync
            """)
        if rc != 0 { note(e.isEmpty ? "enable failed: \(name)" : e); return false }
        note("enabled \(name)")
        return true
    }

    /// Trash an active or disabled plugin (recoverable via Files → .trash).
    func removePlugin(_ name: String) async -> Bool {
        pushBusy(); defer { popBusy() }
        guard Self.isPluginFilename(name) else { return false }
        let active = "\(root)/plugins/\(name)"
        let disabled = "\(root)/plugins-disabled/\(name)"
        let trash = "\(root)/.trash"
        let (rc, _, e) = await sh("""
            mkdir -p \(q(trash))
            if test -f \(q(active)); then mv \(q(active)) \(q(trash))/
            elif test -f \(q(disabled)); then mv \(q(disabled)) \(q(trash))/
            else exit 1
            fi
            sync
            """)
        if rc != 0 { note(e.isEmpty ? "remove failed: \(name)" : e); return false }
        note("removed \(name) → .trash")
        return true
    }

    private static func isPluginFilename(_ name: String) -> Bool {
        name.hasSuffix(".so")
            && !name.isEmpty
            && !name.contains("/")
            && !name.contains("\0")
            && name != "." && name != ".."
    }

    // ---- presets ------------------------------------------------------------

    func listPresets() async -> [RemoteItem] {
        (await listDir("presets")).filter { $0.name.hasSuffix(".pbp") }
    }

    /// Map "NNN.pbp" -> embedded preset name (16-byte ASCII field at offset 16,
    /// space/underscore padded). One ssh call for all files.
    func presetNames() async -> [String: String] {
        let (rc, out, _) = await sh("""
            for f in \(q(root))/presets/*.pbp; do
              printf '%s|' "$(basename $f)"
              dd if="$f" bs=1 skip=16 count=16 2>/dev/null
              echo
            done
            """)
        guard rc == 0 else { return [:] }
        var map: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let kv = line.split(separator: "|", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let n = kv[1].trimmingCharacters(in: .init(charactersIn: " _\0"))
            map[String(kv[0])] = n
        }
        return map
    }

    /// Backup presets to a local folder, renamed "NNN - <name>.pbp" so Finder
    /// shows real preset names. Remote staging + single tar stream.
    func backupPresets(to localDir: URL) async -> Bool {
        pushBusy(); defer { popBusy() }
        try? FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        let (rc, _, e) = await shell(
            "/usr/bin/ssh -o BatchMode=yes root@\(host) \"COPYFILE_DISABLE=1 tar cf - -C '\(root)/presets' .\" | tar xf - -C '\(localDir.path)'")
        if rc != 0 { note(e); return false }
        // rename NNN.pbp -> "NNN - <name>.pbp" from the embedded name field
        let names = await presetNames()
        for (file, pName) in names where !pName.isEmpty {
            let src = localDir.appendingPathComponent(file)
            let num = file.replacingOccurrences(of: ".pbp", with: "")
            let dst = localDir.appendingPathComponent("\(num) - \(pName).pbp")
            try? FileManager.default.moveItem(at: src, to: dst)
        }
        return true
    }

    /// Push a local .pbp to presets/ after snapshotting the remote dir.
    /// Accepts "NNN - name.pbp" archives — the leading number becomes the
    /// slot on-card (restored as NNN.pbp).
    func pushPreset(_ local: URL) async -> Bool {
        pushBusy(); defer { popBusy() }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        _ = await sh("cp -a \(q(root))/presets \(q(root))/presets.bak-\(stamp) 2>/dev/null || true")
        var remote = local.lastPathComponent
        if let dash = remote.firstIndex(of: "-") {
            let num = remote[..<dash].trimmingCharacters(in: .whitespaces)
            if !num.isEmpty && num.allSatisfy(\.isNumber) { remote = num + ".pbp" }
        }
        let (rc, _, e) = await scp(local.path, to: "\(root)/presets/\(remote)")
        if rc != 0 { note(e); return false }
        _ = await sh("sync")
        return true
    }
}
