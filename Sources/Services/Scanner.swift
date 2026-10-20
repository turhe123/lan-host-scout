import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

/// Coordinates a subnet sweep: bounded-concurrency probing, Bonjour, ARP merge and name lookups.
@MainActor
final class Scanner: ObservableObject {
    @Published var interfaces: [NetworkInterface] = []
    @Published var selectedInterface = ""
    @Published private(set) var devices: [String: Device] = [:]
    @Published private(set) var isScanning = false
    @Published private(set) var progress = 0.0
    @Published private(set) var status = ""
    @Published var errorMessage: String?
    @Published var localNetworkDenied = false
    @Published var focusSearch = 0

    let known = KnownDevicesStore()
    private var scanTask: Task<Void, Never>?
    private var knownObserver: AnyCancellable?

    var currentInterface: NetworkInterface? { interfaces.first { $0.name == selectedInterface } }

    init() {
        refreshInterfaces()
        knownObserver = known.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func refreshInterfaces() {
        interfaces = NetworkInfo.interfaces()
        if currentInterface == nil {
            let primary = NetworkInfo.primaryInterfaceName()
            selectedInterface = (interfaces.first { $0.name == primary && !$0.isVPN }
                ?? interfaces.first { !$0.isVPN } ?? interfaces.first)?.name ?? ""
        }
    }

    func scan() {
        stop()
        refreshInterfaces()
        errorMessage = nil
        guard let iface = currentInterface else {
            errorMessage = "No local network was found. Connect to Wi-Fi or Ethernet and try again."
            return
        }
        if let reason = iface.refusalReason {
            errorMessage = reason
            return
        }
        let defaults = UserDefaults.standard
        let ports = Prefs.parsePorts(defaults.string(forKey: Prefs.portsKey) ?? Prefs.defaultPorts)
        let timeoutMs = defaults.object(forKey: Prefs.timeoutKey) as? Int ?? Prefs.defaultTimeout
        let concurrency = defaults.object(forKey: Prefs.concurrencyKey) as? Int ?? Prefs.defaultConcurrency
        let timeout = Double(min(max(timeoutMs, 100), 5000)) / 1000

        devices = [:]
        progress = 0
        isScanning = true
        localNetworkDenied = false
        status = "Scanning \(iface.cidrText)…"
        scanTask = Task { [weak self] in
            await self?.run(iface, ports: ports.isEmpty ? [80, 443] : ports, timeout: timeout,
                            concurrency: min(max(concurrency, 1), 256))
        }
    }

    /// Cancels the sweep; child tasks cancel their pending NWConnections.
    func stop() {
        scanTask?.cancel()
        scanTask = nil
        if isScanning {
            isScanning = false
            status = "Scan stopped. \(devices.count) device(s) found."
        }
    }

    private func run(_ iface: NetworkInterface, ports: [UInt16], timeout: TimeInterval, concurrency: Int) async {
        let addresses = iface.hostAddresses
        let bonjour = BonjourScout()
        bonjour.start()
        var deniedCount = 0, done = 0

        await withTaskGroup(of: HostProbeResult.self) { group in
            var pending = addresses.makeIterator()
            for _ in 0..<concurrency {
                guard let ip = pending.next() else { break }
                group.addTask { await HostProber.probe(ip, ports: ports, timeout: timeout) }
            }
            for await result in group {
                if Task.isCancelled { group.cancelAll(); continue }
                done += 1
                progress = Double(done) / Double(max(addresses.count, 1)) * 0.9
                if result.denied { deniedCount += 1 }
                if result.alive {
                    var d = device(for: result.ip)
                    d.openPorts = result.openPorts
                    d.responseMs = result.responseMs
                    d.sources.insert("Probe")
                    devices[d.ip] = d
                }
                if let ip = pending.next() {
                    group.addTask { await HostProber.probe(ip, ports: ports, timeout: timeout) }
                }
            }
        }
        let bonjourNames = await bonjour.stop()
        guard !Task.isCancelled else { return }

        // Devices that ignore probes still answer ARP; merge both sources by IP.
        status = "Reading ARP cache and resolving names…"
        for (ip, mac) in NetworkInfo.arpTable() {
            guard let value = IPv4.value(ip), value & iface.netmask == iface.network,
                  value != (iface.network | ~iface.netmask) else { continue }
            var d = devices[ip] ?? device(for: value)
            d.mac = mac
            d.sources.insert("ARP")
            devices[ip] = d
        }
        do {
            var me = device(for: iface.address)
            me.mac = iface.mac
            me.isThisMac = true
            me.sources.insert("Local")
            devices[me.ip] = me
        }
        for (ip, name) in bonjourNames where devices[ip] != nil {
            devices[ip]?.hostName = name
            devices[ip]?.sources.insert("Bonjour")
        }
        progress = 0.95

        let lookups = devices.values.filter { $0.hostName.isEmpty }.map(\.ip)
        await withTaskGroup(of: (String, String?).self) { group in
            for ip in lookups { group.addTask { (ip, await NameResolver.reverseName(ip)) } }
            for await (ip, name) in group where !Task.isCancelled {
                if let name, !name.isEmpty { devices[ip]?.hostName = name.hasSuffix(".") ? String(name.dropLast()) : name }
            }
        }
        guard !Task.isCancelled else { return }

        let newcomers = known.record(Array(devices.values))
        for key in devices.keys where newcomers.contains(devices[key]?.knownKey ?? "") { devices[key]?.isNew = true }
        localNetworkDenied = bonjour.policyDenied || (deniedCount > 0 && devices.count <= 1)
        progress = 1
        isScanning = false
        let newText = newcomers.isEmpty ? "" : ", \(newcomers.count) new since last scan"
        status = "\(devices.count) device(s) on \(iface.cidrText)\(newText)."
    }

    private func device(for ip: UInt32) -> Device {
        devices[IPv4.string(ip)] ?? Device(ip: IPv4.string(ip), ipValue: ip)
    }

    // MARK: Export & copy

    func rowText(_ d: Device) -> String {
        [d.ip, d.hostName, d.mac, d.vendor, d.responseText, d.portsText, known.label(for: d)]
            .filter { !$0.isEmpty }.joined(separator: "\t")
    }

    func copy(_ list: [Device]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(list.map(rowText).joined(separator: "\n"), forType: .string)
    }

    func exportCSV(_ list: [Device]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "LanHostScout-\(Date().formatted(.iso8601.year().month().day())).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let csv = ([Device.csvHeader] + list.map { $0.csvRow(label: known.label(for: $0)) }).joined(separator: "\n")
        do { try csv.write(to: url, atomically: true, encoding: .utf8) } catch {
            errorMessage = "Could not save CSV: \(error.localizedDescription)"
        }
    }
}
