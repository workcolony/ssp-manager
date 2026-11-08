import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var ssp: SSPService?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let ssp, ssp.busy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Operation in progress"
        alert.informativeText =
            "SSP Manager is transferring or writing to the card. Quitting now may leave a transfer incomplete. Quit anyway?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

@main
struct SSPManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var ssp = SSPService()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(ssp)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear { appDelegate.ssp = ssp }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1100, height: 680)
    }
}

enum Section: String, CaseIterable, Identifiable {
    case files = "Files", plugins = "Plugins", presets = "Presets", device = "Device"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .files: return "folder"
        case .plugins: return "puzzlepiece"
        case .presets: return "doc.on.doc"
        case .device: return "cpu"
        }
    }
}

struct ContentView: View {
    @Environment(SSPService.self) private var ssp
    @State private var section: Section? = .files

    var body: some View {
        @Bindable var s = ssp
        NavigationSplitView {
            List(Section.allCases, selection: $section) { sec in
                Label(sec.rawValue, systemImage: sec.icon).tag(sec)
            }
            .navigationTitle("SSP Manager")
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Circle().fill(ssp.online ? .green : .red).frame(width: 8, height: 8)
                    Text(ssp.host).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if ssp.busy { ProgressView().controlSize(.small) }
                }
                .padding(10)
            }
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch section {
                    case .files: FileBrowserView()
                    case .plugins: PluginsView()
                    case .presets: PresetsView()
                    case .device: DeviceView()
                    case nil: Text("pick a section").foregroundStyle(.secondary)
                    }
                }
                Divider()
                LogView().frame(height: 110)
            }
        }
        .task { await ssp.ping() }
    }
}

struct LogView: View {
    @Environment(SSPService.self) private var ssp
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(ssp.log.enumerated()), id: \.offset) { i, line in
                        Text(line).font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary).id(i)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .textSelection(.enabled)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
            .onChange(of: ssp.log.count) { proxy.scrollTo(ssp.log.count - 1) }
        }
    }
}
