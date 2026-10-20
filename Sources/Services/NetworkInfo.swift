import Darwin
import Foundation
import SystemConfiguration

/// An IPv4 network interface and the subnet it is attached to.
struct NetworkInterface: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let address: UInt32   // host byte order
    let netmask: UInt32   // host byte order
    let mac: String
    let isPointToPoint: Bool

    var prefixLength: Int { netmask.nonzeroBitCount }
    var network: UInt32 { address & netmask }
    var addressText: String { IPv4.string(address) }
    var cidrText: String { "\(IPv4.string(network))/\(prefixLength)" }
    var title: String { "\(name) — \(addressText) (\(cidrText))" }

    /// VPN and tunnel interfaces are never scanned.
    var isVPN: Bool {
        isPointToPoint || ["utun", "ipsec", "ppp", "tun", "tap", "gif", "stf"].contains { name.hasPrefix($0) }
    }

    /// Reason the interface cannot be scanned, or nil when it is safe.
    var refusalReason: String? {
        if isVPN { return "\(name) looks like a VPN or tunnel interface; LanHostScout only scans local networks." }
        if prefixLength < 24 { return "The subnet \(cidrText) is larger than /24. Scans are limited to 254 addresses for safety." }
        return nil
    }

    /// Every usable host address in the subnet (excluding network and broadcast).
    var hostAddresses: [UInt32] {
        guard refusalReason == nil else { return [] }
        let broadcast = network | ~netmask
        guard broadcast > network + 1 else { return [address] }
        return Array((network + 1)..<broadcast)
    }
}

/// IPv4 formatting helpers.
enum IPv4 {
    static func string(_ value: UInt32) -> String {
        "\(value >> 24 & 0xFF).\(value >> 16 & 0xFF).\(value >> 8 & 0xFF).\(value & 0xFF)"
    }

    static func value(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 < 256 }) else { return nil }
        return parts.reduce(0) { $0 << 8 | $1 }
    }
}

/// Reads interfaces with getifaddrs and the ARP cache with a sysctl routing-table query.
enum NetworkInfo {
    static func interfaces() -> [NetworkInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var macs: [String: String] = [:]
        var v4: [(String, UInt32, UInt32, Int32)] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr else { continue }
            let name = String(cString: ifa.ifa_name)
            let flags = Int32(ifa.ifa_flags)
            if sa.pointee.sa_family == UInt8(AF_LINK) {
                macs[name] = sa.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { macString(from: $0) }
            } else if sa.pointee.sa_family == UInt8(AF_INET),
                      flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                      let maskPtr = ifa.ifa_netmask {
                let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                let mask = maskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                // Skip link-local 169.254/16 self-assigned addresses.
                if addr >> 16 == 0xA9FE { continue }
                v4.append((name, addr, mask, flags))
            }
        }
        return v4.map {
            NetworkInterface(name: $0.0, address: $0.1, netmask: $0.2, mac: macs[$0.0] ?? "",
                             isPointToPoint: $0.3 & IFF_POINTOPOINT != 0)
        }
    }

    /// The system's primary IPv4 interface name, via SystemConfiguration.
    static func primaryInterfaceName() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "LanHostScout" as CFString, nil, nil),
              let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return dict["PrimaryInterface"] as? String
    }

    /// Returns the ARP cache as [IP: MAC] for complete entries.
    static func arpTable() -> [String: String] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else { return [:] }

        var result: [String: String] = [:]
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            let headerSize = MemoryLayout<rt_msghdr>.size
            while offset + headerSize <= length {
                let msg = base.advanced(by: offset).assumingMemoryBound(to: rt_msghdr.self).pointee
                let msgLen = Int(msg.rtm_msglen)
                guard msgLen > 0 else { break }
                defer { offset += msgLen }
                let inPtr = base.advanced(by: offset + headerSize)
                let sin = inPtr.assumingMemoryBound(to: sockaddr_in.self).pointee
                guard sin.sin_family == UInt8(AF_INET) else { continue }
                // Socket addresses are padded to 4-byte boundaries in routing messages.
                let sinLen = max(4, (Int(sin.sin_len) + 3) & ~3)
                guard headerSize + sinLen + 8 <= msgLen else { continue }
                let dl = inPtr.advanced(by: sinLen).assumingMemoryBound(to: sockaddr_dl.self)
                let mac = macString(from: dl)
                if !mac.isEmpty { result[IPv4.string(UInt32(bigEndian: sin.sin_addr.s_addr))] = mac }
            }
        }
        return result
    }

    private static func macString(from dl: UnsafePointer<sockaddr_dl>) -> String {
        let nameLen = Int(dl.pointee.sdl_nlen), addrLen = Int(dl.pointee.sdl_alen)
        guard addrLen == 6 else { return "" }
        let dataOffset = MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_data) ?? 8
        let bytes = UnsafeRawPointer(dl).advanced(by: dataOffset + nameLen).assumingMemoryBound(to: UInt8.self)
        let octets = (0..<6).map { bytes[$0] }
        guard octets.contains(where: { $0 != 0 }) else { return "" }
        return octets.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
