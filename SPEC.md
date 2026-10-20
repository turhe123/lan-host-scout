# LanHostScout — specification

**Tagline:** Scan your local network and list every device with its IP, name, MAC address, vendor hint and open common ports.

**Category:** Developer & Network

**Inspired by (paid):** LanScan ($4.99 one-time)

**Frameworks:** SwiftUI, AppKit, Network, Foundation, SystemConfiguration

**Donation URL (Support button):** https://ko-fi.com/leodavidai

## Spec

What the paid app does: LanScan is a Mac network scanner that lists the devices on the local subnet with their addresses, host names and manufacturers, and it is a regular answer in threads asking how to find unknown devices on a home or office network. Its Mac App Store listing carries a small price for the full version, and similar tools such as Angry IP Scanner and Fing show how common the need is.

Our clean-room feature set: detect the active interface and its subnet, probe every address in that range, and show a live table of responders. Columns: IP address, host name from reverse lookup or Bonjour, MAC address from the system ARP table, a short vendor hint from a small built-in table of common prefixes, response time, and open ports among a short list such as 22, 53, 80, 443, 445, 548, 631 and 8080. Users can sort, filter by text, copy a row, export the table to CSV, and rescan. A Known Devices list lets the user label a device and highlights newcomers since the last scan. Target about six hundred lines.

UI spec: a single window app. The toolbar has the interface picker, Scan and Stop buttons with a progress bar, a search field and an Export button. The main area is a Table with sortable columns. A details sidebar shows full information for the selected row and a Label field. Settings include the port list, timeout in milliseconds, concurrency level and whether to run a scan on launch. Shortcuts: Command R rescan, Command E export, Command F search. Empty state: the table says press Scan to discover devices on this network. If no network is active, show a warning row with the text that no local network was found.

Technical approach: derive the local IPv4 address and netmask with getifaddrs. Limit scans to a slash twenty-four or smaller range for safety. For each address, open an NWConnection with TCP to a few quick ports or use a UDP probe, and treat both connection success and connection refused as signs of life. A Task group with a bounded concurrency of about sixty handles the sweep. After the sweep, read the ARP cache through a sysctl routing table query on NET_RT_FLAGS, which is permitted for normal users. Host names come from getnameinfo and from NWBrowser Bonjour service discovery. The first launch triggers the Local Network permission prompt, and the Info description string explains why. Persist labels as JSON in Application Support.

Edge cases: if the Local Network permission is denied, show a clear banner with an Open System Settings button. Stop cleanly when the user cancels, closing all pending connections. VPN interfaces and very large subnets should be refused with a message. Devices that block probes may still show via ARP, so merge the sources by IP. MAC randomization on phones means vendor hints can be wrong, and the UI labels them as hints. Respect the timeout so a scan finishes in under thirty seconds on a typical home network, and never scan outside the user's own subnet.
