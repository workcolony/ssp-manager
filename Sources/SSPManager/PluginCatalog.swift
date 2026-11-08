import Foundation

/// One entry in the embedded SSP plugin cheat sheet.
struct CatalogPlugin: Identifiable, Hashable, Codable {
    var id: String { code }
    let code: String
    /// `.so` filename on the card; nil for factory Synthor modules.
    let file: String?
    let name: String
    let summary: String
    let author: String
    let kind: String
    let docsURL: String?
    /// `card` (third-party / shipped .so) or `factory` (built into Synthor).
    let source: String

    var isFactory: Bool { source == "factory" }

    var docs: URL? {
        guard let docsURL, let u = URL(string: docsURL) else { return nil }
        return u
    }
}

enum PluginCatalog {
    static let all: [CatalogPlugin] = load()

    static var authors: [String] {
        Array(Set(all.map(\.author))).sorted()
    }

    static var kinds: [String] {
        Array(Set(all.map(\.kind))).sorted()
    }

    private static func load() -> [CatalogPlugin] {
        let urls: [URL?] = [
            Bundle.main.url(forResource: "PluginCatalog", withExtension: "json"),
            Bundle.module.url(forResource: "PluginCatalog", withExtension: "json"),
        ]
        for url in urls.compactMap({ $0 }) {
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode([CatalogPlugin].self, from: data) {
                return decoded.sorted { $0.code < $1.code }
            }
        }
        // Fallback when running without a resource bundle (swift run / Xcode quirks).
        if let path = Self.sourceTreeJSON(),
           let data = try? Data(contentsOf: path),
           let decoded = try? JSONDecoder().decode([CatalogPlugin].self, from: data) {
            return decoded.sorted { $0.code < $1.code }
        }
        return []
    }

    private static func sourceTreeJSON() -> URL? {
        let this = URL(fileURLWithPath: #filePath)
        let cand = this.deletingLastPathComponent().appendingPathComponent("PluginCatalog.json")
        return FileManager.default.fileExists(atPath: cand.path) ? cand : nil
    }
}
