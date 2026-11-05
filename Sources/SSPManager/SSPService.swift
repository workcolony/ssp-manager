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
@MainActor @Observable
final class SSPService {
    var host = "192.168.1.6"
    var root = "/media/BOOT"
    var busy = false
    var online = false
    var log: [String] = []

    private func note(_ s: String) { log.append(s); if log.count > 500 { log.removeFirst() } }

    // ---- primitives ---------------------------------------------------------

    @discardableResult
    func sh(_ script: String) async -> (Int32, String, String) {
        note("$ ssh \(script)")
        return await Self.run("/usr/bin/ssh",
            ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
             "root@\(host)", script])
    }

    /// Run a local shell pipeline (for tar streams).
    @discardableResult
    func shell(_ cmd: String) async -> (Int32, String, String) {
        note("$ \(cmd)")
        return await Self.run("/bin/bash", ["-c", cmd])
    }

    func scp(_ local: String, to remote: String) async -> (Int32, String, String) {
        note("$ scp -O \(local) -> \(remote)")
        return await Self.run("/usr/bin/scp",
            ["-O", "-q", local, "root@\(host):\(remote)"])
    }

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
    private func abs(_ p: String) -> String { p.hasPrefix("/") ? p : "\(root)/\(p)" }

    // ---- device -------------------------------------------------------------

    func ping() async {
        busy = true; defer { busy = false }
        let (rc, out, _) = await sh("echo PONG")
        online = rc == 0 && out.contains("PONG")
    }

    func df() async -> String {
        busy = true; defer { busy = false }
        let (_, out, _) = await sh("df -h \(q(root)) | tail -1")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func restartSynthor() async {
        busy = true; defer { busy = false }
        let (_, out, _) = await sh("/etc/init.d/S90synthor restart")
        note(out)
    }

    // ---- file manager -------------------------------------------------------

    func listDir(_ path: String) async -> [RemoteItem] {
        busy = true; defer { busy = false }
        let p = abs(path)
        let (rc, out, _) = await sh("ls -lA \(q(p))")
        guard rc == 0 else { return [] }
        var items: [RemoteItem] = []
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 9, f[0].hasPrefix("d") || f[0].hasPrefix("-") || f[0].hasPrefix("l") || f[0].hasPrefix("r") else { continue }
            let name = f[8...].joined(separator: " ")
            guard name != "." && name != ".." && !name.hasPrefix(".") else { continue }
            items.append(RemoteItem(name: name, path: "\(p)/\(name)",
                                    isDir: f[0].hasPrefix("d"), size: String(f[4])))
        }
        return items.sorted { $0.isDir == $1.isDir ? $0.name < $1.name : $0.isDir }
    }

    func mkdir(_ path: String) async { busy = true; defer { busy = false }; _ = await sh("mkdir -p \(q(abs(path)))") }
    func move(_ src: String, _ dst: String) async { busy = true; defer { busy = false }; _ = await sh("mv \(q(abs(src))) \(q(abs(dst)))") }

    /// Safe delete: move to /media/BOOT/.trash
    func deleteToTrash(_ path: String) async {
        busy = true; defer { busy = false }
        _ = await sh("mkdir -p \(q(root))/.trash && mv \(q(abs(path))) \(q(root))/.trash/")
    }
    func emptyTrash() async {
        busy = true; defer { busy = false }
        _ = await sh("rm -rf \(q(root))/.trash && mkdir -p \(q(root))/.trash && sync")
    }

    /// Upload file or directory into remote dir.
    func upload(local: URL, remoteDir: String) async -> Bool {
        busy = true; defer { busy = false }
        let dst = abs(remoteDir)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: local.path, isDirectory: &isDir), isDir.boolValue {
            let (rc, _, e) = await shell(
                "COPYFILE_DISABLE=1 tar cf - -C '\(local.path)' . | /usr/bin/ssh -o BatchMode=yes root@\(host) \"mkdir -p '\(dst)/\(local.lastPathComponent)' && tar xf - -C '\(dst)/\(local.lastPathComponent)' && sync\"")
            if rc != 0 { note(e) }
            return rc == 0
        }
        _ = await sh("mkdir -p \(q(dst))")
        let (rc, _, e) = await scp(local.path, to: dst + "/" + local.lastPathComponent)
        if rc == 0 { _ = await sh("sync") } else { note(e) }
        return rc == 0
    }

    /// Download remote file/dir to local dir.
    func download(remotePath: String, localDir: URL) async -> Bool {
        busy = true; defer { busy = false }
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
        let (rc2, _, e) = await Self.run("/usr/bin/scp",
            ["-O", "-q", "root@\(host):\(r)", destDir.path + "/"])
        note("$ scp -O \(r) -> \(destDir.path)")
        if rc2 != 0 { note(e) }
        return rc2 == 0
    }

    // ---- plugins ------------------------------------------------------------

    func listPlugins() async -> [RemoteItem] {
        (await listDir("plugins")).filter { $0.name.hasSuffix(".so") }
    }

    func installPlugin(_ local: URL) async -> Bool {
        busy = true; defer { busy = false }
        let (rc, _, e) = await scp(local.path, to: "\(root)/plugins/\(local.lastPathComponent)")
        if rc != 0 { note(e); return false }
        _ = await sh("sync")
        return true
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
        busy = true; defer { busy = false }
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
        busy = true; defer { busy = false }
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
