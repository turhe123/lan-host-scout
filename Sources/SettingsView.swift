import AppKit
import SwiftUI

/// UserDefaults keys and defaults shared by the scanner and the Settings window.
enum Prefs {
    static let portsKey = "ports", timeoutKey = "timeoutMs", concurrencyKey = "concurrency", scanOnLaunchKey = "scanOnLaunch"
    static let defaultPorts = "22, 53, 80, 443, 445, 548, 631, 8080"
    static let defaultTimeout = 600
    static let defaultConcurrency = 60

    /// Parses "22, 80 443" into unique valid TCP ports (max 32 to keep scans fast).
    static func parsePorts(_ text: String) -> [UInt16] {
        let ports = text.split(whereSeparator: { !$0.isNumber }).compactMap { UInt16($0) }.filter { $0 > 0 }
        return Array(NSOrderedSet(array: ports).array.compactMap { $0 as? UInt16 }.prefix(32))
    }

    static func openDonate() { NSWorkspace.shared.open(URL(string: "https://ko-fi.com/leodavidai")!) }
}

/// The Settings window: probe ports, timeout, concurrency, scan-on-launch and support link.
struct SettingsView: View {
    @AppStorage(Prefs.portsKey) private var ports = Prefs.defaultPorts
    @AppStorage(Prefs.timeoutKey) private var timeoutMs = Prefs.defaultTimeout
    @AppStorage(Prefs.concurrencyKey) private var concurrency = Prefs.defaultConcurrency
    @AppStorage(Prefs.scanOnLaunchKey) private var scanOnLaunch = true

    var body: some View {
        Form {
            Section("Probing") {
                TextField("Ports", text: $ports, prompt: Text(Prefs.defaultPorts))
                Text("Parsed: \(Prefs.parsePorts(ports).map(String.init).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("Timeout: \(timeoutMs) ms", value: $timeoutMs, in: 100...5000, step: 100)
                Stepper("Concurrency: \(concurrency) hosts", value: $concurrency, in: 1...256, step: 10)
                Toggle("Scan on launch", isOn: $scanOnLaunch)
                Button("Restore Defaults") {
                    ports = Prefs.defaultPorts
                    timeoutMs = Prefs.defaultTimeout
                    concurrency = Prefs.defaultConcurrency
                }
            }
            Section("About") {
                Text("LanHostScout only scans your own subnet (/24 or smaller) and never contacts the internet.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Support / Donate ❤️") { Prefs.openDonate() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
