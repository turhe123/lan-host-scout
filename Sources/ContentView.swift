import AppKit
import SwiftUI

/// Main window: toolbar controls, sortable device table and a details sidebar.
struct ContentView: View {
    @EnvironmentObject private var scanner: Scanner
    @State private var selection: Set<Device.ID> = []
    @State private var sortOrder = [KeyPathComparator(\Device.ipValue)]
    @State private var searchText = ""
    @State private var showKnown = false
    @FocusState private var searchFocused: Bool

    private var rows: [Device] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let all = scanner.devices.values.filter { d in
            query.isEmpty || [d.ip, d.hostName, d.mac, d.vendor, d.portsText, scanner.known.label(for: d)]
                .contains { $0.lowercased().contains(query) }
        }
        return all.sorted(using: sortOrder)
    }

    private var selectedDevice: Device? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return scanner.devices[id]
    }

    var body: some View {
        VStack(spacing: 0) {
            banners
            HSplitView {
                table.frame(minWidth: 560)
                DetailView(device: selectedDevice).frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            }
            statusBar
        }
        .toolbar { toolbar }
        .sheet(isPresented: $showKnown) { KnownDevicesView().environmentObject(scanner) }
        .onChange(of: scanner.focusSearch) { searchFocused = true }
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("IP Address", value: \.ipValue) { d in
                HStack(spacing: 4) {
                    if d.isNew { Text("NEW").font(.caption2.bold()).padding(.horizontal, 3)
                        .background(.orange, in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(.white) }
                    Text(d.ip).monospacedDigit()
                }
            }.width(min: 110, ideal: 130)
            TableColumn("Name", value: \.hostName) { d in
                let label = scanner.known.label(for: d)
                Text(label.isEmpty ? (d.isThisMac ? "\(d.hostName) (This Mac)" : d.hostName) : label)
                    .fontWeight(label.isEmpty ? .regular : .semibold)
            }.width(min: 120, ideal: 200)
            TableColumn("MAC Address", value: \.mac) { Text($0.mac.isEmpty ? "—" : $0.mac).monospaced() }
                .width(min: 120, ideal: 140)
            TableColumn("Vendor (hint)", value: \.vendor).width(min: 80, ideal: 110)
            TableColumn("Response", value: \.sortRTT) { Text($0.responseText).monospacedDigit() }.width(min: 60, ideal: 70)
            TableColumn("Open Ports", value: \.portsText).width(min: 80, ideal: 140)
        }
        .contextMenu(forSelectionType: Device.ID.self) { ids in
            Button("Copy Row") { scanner.copy(ids.compactMap { scanner.devices[$0] }) }
            Button("Export Selection…") { scanner.exportCSV(ids.compactMap { scanner.devices[$0] }) }
        }
        .onCopyCommand { [NSItemProvider(object: rowsText(selection) as NSString)] }
        .overlay { emptyState }
    }

    private func rowsText(_ ids: Set<Device.ID>) -> String {
        ids.compactMap { scanner.devices[$0] }.map(scanner.rowText).joined(separator: "\n")
    }

    @ViewBuilder private var emptyState: some View {
        if scanner.interfaces.isEmpty {
            ContentUnavailableView("No local network was found", systemImage: "exclamationmark.triangle",
                                   description: Text("Connect to Wi-Fi or Ethernet, then press Scan."))
        } else if rows.isEmpty && !scanner.isScanning {
            if searchText.isEmpty {
                ContentUnavailableView("No Devices Yet", systemImage: "network",
                                       description: Text("Press Scan to discover devices on this network."))
            } else {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    @ViewBuilder private var banners: some View {
        if scanner.localNetworkDenied {
            Banner(icon: "lock.shield", color: .red,
                   text: "Local Network access appears to be denied, so most devices cannot be reached.") {
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        if let message = scanner.errorMessage {
            Banner(icon: "exclamationmark.triangle.fill", color: .orange, text: message) {
                Button("Dismiss") { scanner.errorMessage = nil }
            }
        }
    }

    private var statusBar: some View {
        HStack {
            Text(scanner.status.isEmpty ? "Ready." : scanner.status)
            Spacer()
            Text("Vendors are hints; phones often use randomized MAC addresses.")
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.bar)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Picker("Interface", selection: $scanner.selectedInterface) {
                if scanner.interfaces.isEmpty { Text("No network").tag("") }
                ForEach(scanner.interfaces) { Text($0.title).tag($0.name) }
            }
            .frame(width: 260)
            .disabled(scanner.isScanning)
        }
        ToolbarItemGroup {
            if scanner.isScanning {
                ProgressView(value: scanner.progress).frame(width: 120)
                Button { scanner.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .keyboardShortcut(".", modifiers: .command)
            } else {
                Button { scanner.scan() } label: { Label("Scan", systemImage: "dot.radiowaves.left.and.right") }
            }
            TextField("Search", text: $searchText)
                .textFieldStyle(.roundedBorder).frame(width: 180).focused($searchFocused)
            Button { scanner.exportCSV(rows) } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .disabled(rows.isEmpty)
            Button { showKnown = true } label: { Label("Known Devices", systemImage: "list.star") }
            Button { Prefs.openDonate() } label: { Label("Support / Donate ❤️", systemImage: "heart.fill") }
                .help("Support / Donate ❤️")
        }
    }
}

/// A coloured message strip with an action button.
private struct Banner<Action: View>: View {
    let icon: String, color: Color, text: String
    @ViewBuilder let action: Action

    var body: some View {
        HStack {
            Image(systemName: icon).foregroundStyle(color)
            Text(text)
            Spacer()
            action
        }
        .padding(8)
        .background(color.opacity(0.12))
    }
}

/// Full information for the selected device, plus its editable label.
struct DetailView: View {
    @EnvironmentObject private var scanner: Scanner
    let device: Device?
    @State private var label = ""

    var body: some View {
        if let d = device {
            Form {
                Section("Label") {
                    TextField("Label", text: $label, prompt: Text("e.g. Living room TV"))
                        .onSubmit { scanner.known.setLabel(label, for: d) }
                    Button("Save Label") { scanner.known.setLabel(label, for: d) }
                }
                Section("Details") {
                    LabeledContent("IP Address", value: d.ip)
                    LabeledContent("Host Name", value: d.hostName.isEmpty ? "—" : d.hostName)
                    LabeledContent("MAC Address", value: d.mac.isEmpty ? "—" : d.mac)
                    LabeledContent("Vendor (hint)", value: d.vendor.isEmpty ? "—" : d.vendor)
                    LabeledContent("Response", value: d.responseText)
                    LabeledContent("Open Ports", value: d.portsText.isEmpty ? "None found" : d.portsText)
                    LabeledContent("Seen via", value: d.sourcesText)
                    if d.isNew { LabeledContent("Status", value: "New since last scan") }
                    if d.isThisMac { LabeledContent("Note", value: "This Mac") }
                }
                Button("Copy Row") { scanner.copy([d]) }
            }
            .formStyle(.grouped)
            .textSelection(.enabled)
            .onAppear { label = scanner.known.label(for: d) }
            .onChange(of: d.id) { label = scanner.known.label(for: d) }
        } else {
            ContentUnavailableView("No Selection", systemImage: "sidebar.right",
                                   description: Text("Select a device to see its details."))
        }
    }
}

/// Lists remembered devices and lets the user forget them.
struct KnownDevicesView: View {
    @EnvironmentObject private var scanner: Scanner
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading) {
            Text("Known Devices").font(.title2.bold())
            Table(scanner.known.devices.values.sorted { $0.lastSeen > $1.lastSeen }) {
                TableColumn("Label") { Text($0.label.isEmpty ? "—" : $0.label) }
                TableColumn("Key") { Text($0.key).monospaced() }
                TableColumn("Last IP", value: \.lastIP)
                TableColumn("Last Seen") { Text($0.lastSeen.formatted(date: .abbreviated, time: .shortened)) }
                TableColumn("") { k in Button("Forget") { scanner.known.remove(k.key) } }.width(60)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 360)
    }
}
