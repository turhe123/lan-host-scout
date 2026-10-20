import Darwin
import Foundation
import Network

/// Outcome of a single TCP port probe.
enum PortState { case open, refused, silent, denied }

/// Result of probing one host on several ports.
struct HostProbeResult {
    let ip: UInt32
    let openPorts: [UInt16]
    let responseMs: Double?
    let alive: Bool
    let denied: Bool
}

/// Resumes a continuation exactly once, whichever callback fires first.
private final class OnceBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    init(_ c: CheckedContinuation<T, Never>) { continuation = c }

    func resume(_ value: T) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}

/// Probes hosts with short-lived NWConnections; success and "connection refused" both mean the host is alive.
enum HostProber {
    private static let queue = DispatchQueue(label: "lanhostscout.probe", attributes: .concurrent)

    static func probe(_ ip: UInt32, ports: [UInt16], timeout: TimeInterval) async -> HostProbeResult {
        let start = Date()
        var open: [UInt16] = [], firstResponse: Double?, denied = false, alive = false
        await withTaskGroup(of: (UInt16, PortState, Double).self) { group in
            for port in ports {
                group.addTask {
                    let state = await probePort(ip, port: port, timeout: timeout)
                    return (port, state, Date().timeIntervalSince(start) * 1000)
                }
            }
            for await (port, state, ms) in group {
                switch state {
                case .open: open.append(port); alive = true
                case .refused: alive = true
                case .denied: denied = true
                case .silent: continue
                }
                firstResponse = min(firstResponse ?? ms, ms)
            }
        }
        return HostProbeResult(ip: ip, openPorts: open.sorted(), responseMs: alive ? firstResponse : nil,
                               alive: alive, denied: denied)
    }

    static func probePort(_ ip: UInt32, port: UInt16, timeout: TimeInterval) async -> PortState {
        guard let nwPort = NWEndpoint.Port(rawValue: port), !Task.isCancelled else { return .silent }
        let addr = IPv4Address(withUnsafeBytes(of: ip.bigEndian) { Data($0) })
        guard let addr else { return .silent }
        let params = NWParameters.tcp
        params.preferNoProxies = true
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.connectionTimeout = max(1, Int(timeout.rounded(.up)))
            tcp.noDelay = true
        }
        let connection = NWConnection(host: .ipv4(addr), port: nwPort, using: params)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<PortState, Never>) in
                let box = OnceBox(cont)
                let finish: (PortState) -> Void = { state in
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    box.resume(state)
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: finish(.open)
                    case .waiting(let error), .failed(let error):
                        if case .posix(let code) = error, code == .ECONNREFUSED { finish(.refused) }
                        else if connection.currentPath?.unsatisfiedReason == .localNetworkDenied { finish(.denied) }
                        else { finish(.silent) }
                    case .cancelled: box.resume(.silent)
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) { finish(.silent) }
            }
        } onCancel: {
            connection.cancel()
        }
    }
}

/// Reverse lookups via getnameinfo (which also consults mDNS for .local names), bounded by a timeout.
enum NameResolver {
    static func reverseName(_ ip: String, timeout: TimeInterval = 2) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let box = OnceBox(cont)
            DispatchQueue.global(qos: .utility).async {
                var sin = sockaddr_in()
                sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                sin.sin_family = sa_family_t(AF_INET)
                guard inet_pton(AF_INET, ip, &sin.sin_addr) == 1 else { return box.resume(nil) }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let rc = withUnsafePointer(to: &sin) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
                    }
                }
                box.resume(rc == 0 ? String(cString: host) : nil)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { box.resume(nil) }
        }
    }
}

/// Discovers Bonjour services with NWBrowser and resolves each to an IPv4 address.
final class BonjourScout: @unchecked Sendable {
    static let serviceTypes = ["_http._tcp", "_ssh._tcp", "_smb._tcp", "_afpovertcp._tcp", "_ipp._tcp",
                               "_printer._tcp", "_airplay._tcp", "_raop._tcp", "_device-info._tcp",
                               "_companion-link._tcp", "_googlecast._tcp", "_hap._tcp", "_workstation._tcp"]

    private let queue = DispatchQueue(label: "lanhostscout.bonjour")
    private var browsers: [NWBrowser] = []
    private var resolvers: [NWConnection] = []
    private var names: [String: String] = [:]
    private(set) var policyDenied = false

    func start() {
        queue.async { [self] in
            for type in Self.serviceTypes {
                let browser = NWBrowser(for: .bonjour(type: type, domain: "local."), using: .tcp)
                browser.stateUpdateHandler = { [weak self] state in
                    if case .failed(let error) = state, case .dns(let code) = error, code == -65570 {
                        self?.policyDenied = true   // kDNSServiceErr_PolicyDenied
                    }
                }
                browser.browseResultsChangedHandler = { [weak self] results, _ in
                    results.forEach { self?.resolve($0.endpoint) }
                }
                browser.start(queue: queue)
                browsers.append(browser)
            }
        }
    }

    private func resolve(_ endpoint: NWEndpoint) {
        guard case .service(let name, _, _, _) = endpoint, resolvers.count < 200 else { return }
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let conn = NWConnection(to: endpoint, using: params)
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            switch state {
            case .ready, .preparing:
                if case .hostPort(let host, _)? = conn.currentPath?.remoteEndpoint, case .ipv4(let v4) = host {
                    let ip = "\(v4)".split(separator: "%").first.map(String.init) ?? "\(v4)"
                    if self.names[ip] == nil { self.names[ip] = name }
                    conn.cancel()
                }
            case .failed, .waiting: conn.cancel()
            default: break
            }
        }
        conn.start(queue: queue)
        resolvers.append(conn)
    }

    /// Stops all browsing and returns [IPv4: service name].
    func stop() async -> [String: String] {
        await withCheckedContinuation { cont in
            queue.async { [self] in
                browsers.forEach { $0.cancel() }
                resolvers.forEach { $0.cancel() }
                browsers.removeAll()
                resolvers.removeAll()
                cont.resume(returning: names)
            }
        }
    }
}
