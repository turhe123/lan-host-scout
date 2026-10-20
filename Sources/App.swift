import SwiftUI

/// App entry point: a single main window, Settings, and scan/export/search menu commands.
@main
struct LanHostScoutApp: App {
    @StateObject private var scanner = Scanner()
    @AppStorage(Prefs.scanOnLaunchKey) private var scanOnLaunch = true

    var body: some Scene {
        Window("LanHostScout", id: "main") {
            ContentView()
                .environmentObject(scanner)
                .frame(minWidth: 860, minHeight: 440)
                .task { if scanOnLaunch && !scanner.isScanning && scanner.devices.isEmpty { scanner.scan() } }
        }
        .commands {
            CommandMenu("Scan") {
                Button("Rescan") { scanner.scan() }.keyboardShortcut("r", modifiers: .command)
                Button("Stop") { scanner.stop() }.disabled(!scanner.isScanning)
                Divider()
                Button("Export CSV…") { scanner.exportCSV(scanner.devices.values.sorted { $0.ipValue < $1.ipValue }) }
                    .keyboardShortcut("e", modifiers: .command)
            }
            CommandGroup(after: .textEditing) {
                Button("Find") { scanner.focusSearch += 1 }.keyboardShortcut("f", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("Support / Donate ❤️") { Prefs.openDonate() }
            }
        }
        Settings { SettingsView() }
    }
}
