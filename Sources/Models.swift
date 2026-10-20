import Foundation

/// A device discovered on the local network, merged from probe, ARP and Bonjour sources.
struct Device: Identifiable, Hashable {
    var id: String { ip }
    let ip: String
    let ipValue: UInt32
    var hostName: String = ""
    var mac: String = ""
    var openPorts: [UInt16] = []
    var responseMs: Double?
    var sources: Set<String> = []
    var isNew = false
    var isThisMac = false

    var vendor: String { VendorHints.hint(for: mac) }
    var portsText: String { openPorts.map(String.init).joined(separator: ", ") }
    var responseText: String { responseMs.map { String(format: "%.0f ms", $0) } ?? "—" }
    var sortRTT: Double { responseMs ?? .greatestFiniteMagnitude }
    var sourcesText: String { sources.sorted().joined(separator: ", ") }
    /// Key used to remember the device: MAC when known (stable), otherwise IP.
    var knownKey: String { mac.isEmpty ? "ip:\(ip)" : mac }

    func csvRow(label: String) -> String {
        [ip, hostName, mac, vendor, responseText, portsText, label, isNew ? "new" : ""]
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: ",")
    }

    static let csvHeader = "IP,Host Name,MAC,Vendor Hint,Response,Open Ports,Label,Status"
}

/// A device the user has seen before, optionally with a custom label.
struct KnownDevice: Codable, Identifiable, Hashable {
    var id: String { key }
    let key: String
    var label: String
    var lastIP: String
    var firstSeen: Date
    var lastSeen: Date
}

/// Persists known devices and their labels as JSON in Application Support.
@MainActor
final class KnownDevicesStore: ObservableObject {
    @Published private(set) var devices: [String: KnownDevice] = [:]

    private let fileURL: URL? = {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("LanHostScout", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("known-devices.json")
    }()

    init() {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([KnownDevice].self, from: data) else { return }
        devices = Dictionary(list.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func label(for device: Device) -> String { devices[device.knownKey]?.label ?? "" }

    func setLabel(_ label: String, for device: Device) {
        let now = Date()
        var entry = devices[device.knownKey] ?? KnownDevice(key: device.knownKey, label: "", lastIP: device.ip, firstSeen: now, lastSeen: now)
        entry.label = label
        devices[device.knownKey] = entry
        save()
    }

    /// Records the scan results and returns the keys that were never seen before.
    func record(_ found: [Device]) -> Set<String> {
        let firstEver = devices.isEmpty
        let now = Date()
        var newcomers = Set<String>()
        for d in found {
            if var entry = devices[d.knownKey] {
                entry.lastSeen = now
                entry.lastIP = d.ip
                devices[d.knownKey] = entry
            } else {
                if !firstEver { newcomers.insert(d.knownKey) }
                devices[d.knownKey] = KnownDevice(key: d.knownKey, label: "", lastIP: d.ip, firstSeen: now, lastSeen: now)
            }
        }
        save()
        return newcomers
    }

    func remove(_ key: String) {
        devices[key] = nil
        save()
    }

    private func save() {
        guard let url = fileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(Array(devices.values)) { try? data.write(to: url, options: .atomic) }
    }
}

/// A tiny built-in table of common MAC prefixes (OUIs). Results are hints only.
enum VendorHints {
    private static let table: [String: String] = [
        "00:03:93": "Apple", "00:0A:95": "Apple", "00:1B:63": "Apple", "00:1E:C2": "Apple",
        "00:25:00": "Apple", "00:26:BB": "Apple", "00:1C:B3": "Apple", "3C:07:54": "Apple",
        "A4:83:E7": "Apple", "F0:18:98": "Apple", "AC:BC:32": "Apple", "7C:D1:C3": "Apple",
        "B8:27:EB": "Raspberry Pi", "DC:A6:32": "Raspberry Pi", "E4:5F:01": "Raspberry Pi", "28:CD:C1": "Raspberry Pi",
        "00:50:56": "VMware", "00:0C:29": "VMware", "00:05:69": "VMware", "08:00:27": "VirtualBox",
        "52:54:00": "QEMU/KVM", "00:1C:42": "Parallels", "00:15:5D": "Hyper-V",
        "18:B4:30": "Nest", "F4:F5:D8": "Google", "3C:5A:B4": "Google",
        "44:65:0D": "Amazon", "FC:65:DE": "Amazon", "00:17:88": "Philips Hue",
        "B8:E9:37": "Sonos", "00:0E:58": "Sonos", "5C:AA:FD": "Sonos",
        "00:11:32": "Synology", "00:08:9B": "QNAP", "24:5E:BE": "QNAP",
        "50:C7:BF": "TP-Link", "EC:08:6B": "TP-Link", "14:CC:20": "TP-Link", "B0:BE:76": "TP-Link",
        "00:09:5B": "Netgear", "A0:40:A0": "Netgear", "00:1B:2F": "Netgear", "00:24:B2": "Netgear",
        "00:14:BF": "Linksys", "00:22:6B": "Linksys", "00:18:0A": "Cisco Meraki",
        "18:E8:29": "Ubiquiti", "24:A4:3C": "Ubiquiti", "FC:EC:DA": "Ubiquiti", "78:8A:20": "Ubiquiti", "F0:9F:C2": "Ubiquiti",
        "00:80:77": "Brother", "00:1B:A9": "Brother", "3C:2A:F4": "Brother",
        "00:1E:0B": "HP", "3C:D9:2B": "HP", "00:21:5A": "HP",
        "00:16:6C": "Samsung", "8C:77:12": "Samsung", "00:12:FB": "Samsung",
        "00:04:4B": "Nvidia", "48:B0:2D": "Nvidia", "00:E0:4C": "Realtek",
        "00:0D:4B": "Roku", "B0:A7:37": "Roku", "DC:3A:5E": "Roku",
        "5C:CF:7F": "Espressif", "24:0A:C4": "Espressif", "30:AE:A4": "Espressif", "84:F3:EB": "Espressif",
        "00:1B:21": "Intel", "00:15:17": "Intel", "3C:97:0E": "Intel", "A0:36:9F": "Intel",
    ]

    static func hint(for mac: String) -> String {
        let parts = mac.uppercased().split(separator: ":")
        guard parts.count == 6 else { return "" }
        if let vendor = table[parts.prefix(3).joined(separator: ":")] { return vendor }
        // Locally administered bit set: almost always a randomized (private) address.
        if let first = UInt8(parts[0], radix: 16), first & 0x02 != 0 { return "Private (randomized)" }
        return "Unknown"
    }
}
