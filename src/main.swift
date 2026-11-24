// Copyright (c) 2026 Ali Razavi. All rights reserved. Owned and controlled solely by Ali Razavi: no licence check, no remote control, no backdoor. Terms: see the LICENSE file.
import AppKit
import SwiftUI
import Combine
import ServiceManagement
import IOKit
import IOKit.pwr_mgt
import CoreWLAN
import CoreAudio
import AudioToolbox
import Accelerate
import CoreImage

// Redline: a tuner-style gauge cluster for this Mac, living in the menu bar.
// Everything is read locally from macOS. Nothing is sent anywhere.

// ---------- SMC (the Mac's sensor chip): temperatures, fans, watts ----------
final class SMC {
    private var conn: io_connect_t = 0
    private var info: [String: (size: UInt32, type: UInt32)] = [:]

    init() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return }
        IOServiceOpen(svc, mach_task_self_, 0, &conn)
        IOObjectRelease(svc)
    }

    private static func code(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }

    // The kernel expects an 80-byte record; fields are written at their fixed offsets.
    private func call(_ input: [UInt8]) -> [UInt8]? {
        var inp = input, out = [UInt8](repeating: 0, count: 80), size = 80
        let r = IOConnectCallStructMethod(conn, 2, &inp, 80, &out, &size)
        return (r == kIOReturnSuccess && out[40] == 0) ? out : nil
    }
    private func put(_ v: UInt32, _ at: Int, _ b: inout [UInt8]) { withUnsafeBytes(of: v) { for i in 0..<4 { b[at + i] = $0[i] } } }
    private func get(_ at: Int, _ b: [UInt8]) -> UInt32 { b[at..<at + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }

    func read(_ key: String) -> Double? {
        guard conn != 0 else { return nil }
        var ki = info[key]
        if ki == nil {
            var b = [UInt8](repeating: 0, count: 80)
            put(SMC.code(key), 0, &b); b[42] = 9
            guard let o = call(b) else { info[key] = (0, 0); return nil }
            ki = (get(28, o), get(32, o)); info[key] = ki
        }
        guard let k = ki, k.size > 0, k.size <= 32 else { return nil }
        var b = [UInt8](repeating: 0, count: 80)
        put(SMC.code(key), 0, &b); put(k.size, 28, &b); b[42] = 5
        guard let o = call(b) else { return nil }
        let d = Array(o[48..<48 + Int(k.size)])
        let t = String(bytes: withUnsafeBytes(of: k.type.bigEndian) { Array($0) }, encoding: .ascii) ?? ""
        if t == "flt ", d.count == 4 { return Double(d.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }) }
        if t.hasPrefix("ui") { return Double(d.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }) }
        if (t.hasPrefix("sp") || t.hasPrefix("fp")), d.count == 2, let frac = Int(String(t.last!), radix: 16) {
            let raw = (UInt16(d[0]) << 8) | UInt16(d[1])
            let v = t.hasPrefix("sp") ? Double(Int16(bitPattern: raw)) : Double(raw)
            return v / Double(1 << frac)
        }
        return nil
    }
    func first(_ keys: [String], _ ok: (Double) -> Bool) -> Double? {
        for k in keys { if let v = read(k), ok(v) { return v } }
        return nil
    }
}

// ---------- One snapshot of everything ----------
struct USBDev: Identifiable, Equatable {
    var id: String; var name: String; var vendor: String; var speed: String; var mA: Int; var depth: Int
    var port = 0      // which of the Mac's USB-C sockets (1-4) this hangs off; 0 = unknown
}
struct Wireless: Identifiable, Equatable {
    var id: String; var name: String; var kind: String; var left: Int?; var right: Int?; var box: Int?; var main: Int?
}
struct Snap {
    var cpu = 0.0; var cores: [Double] = Array(repeating: 0, count: ProcessInfo.processInfo.processorCount)
    var gpu = 0.0; var gpuNote = "GPU"
    var mem = 0.0; var memUsedGB = 0.0; var memTotalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    var pressure = 1
    var plugged = false; var charging = false; var adapterW = 0; var adapterName = ""
    var dcInW: Double?; var sysW: Double?; var cpuW: Double?; var gpuW: Double?
    var battPct = 0; var battW = 0.0; var cycles = 0; var health = 0.0; var battTemp = 0.0; var hasBattery = false
    var cpuTemp: Double?; var gpuTemp: Double?; var fans: [Double] = []; var fanMax = 6000.0; var speedLimit = 100
    var down = 0.0; var up = 0.0; var rssi: Int?; var txRate: Double?; var txPower: Int?
    var read = 0.0; var write = 0.0; var readTotal = 0.0; var writeTotal = 0.0
    var usb: [USBDev] = []
    var wireless: [Wireless] = []
    var hog = ""; var hogPct = 0.0
    var uptime: TimeInterval = 0
    var fanTops: [Double] = []
    var fanForced = false     // the sensor chip says the fans are held at a fixed speed
    var chargerSocket = 0     // which USB-C socket (1-4) the charger is in; 0 = none or unknown
}

// ---------- Reading the machine ----------
final class Probe {
    let smc = SMC()
    private var lastTicks: [[UInt32]] = []
    private var lastNet: (i: UInt64, o: UInt64)?; private var lastDisk: (r: UInt64, w: UInt64)?
    private var lastTime = Date()
    private var wifiAt = Date.distantPast; private var wifi: (Int?, Double?, Int?) = (nil, nil, nil)
    private let boot: Date = {
        var tv = timeval(); var sz = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &tv, &sz, nil, 0)
        return Date(timeIntervalSince1970: Double(tv.tv_sec))
    }()

    private func ticks() -> [[UInt32]] {
        var n: natural_t = 0; var arr: processor_info_array_t?; var cnt: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &arr, &cnt) == KERN_SUCCESS, let a = arr else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: a), vm_size_t(cnt) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        return (0..<Int(n)).map { i in (0..<4).map { UInt32(bitPattern: a[i * 4 + $0]) } }
    }

    /// Cheap: only the overall CPU load (used for the menu bar needle while the panel is closed).
    func cpuOnly(into s: inout Snap) {
        let now = ticks()
        if now.count == lastTicks.count, !now.isEmpty {
            var busyAll = 0.0, totalAll = 0.0; var per: [Double] = []
            for (a, b) in zip(lastTicks, now) {
                let d = (0..<4).map { Double(b[$0] &- a[$0]) }
                let total = d.reduce(0, +), busy = total - d[2]
                per.append(total > 0 ? busy / total : 0); busyAll += busy; totalAll += total
            }
            s.cores = per; s.cpu = totalAll > 0 ? busyAll / totalAll : 0
        }
        lastTicks = now
    }

    /// Cheap extras while the card is closed, so the records keep counting: whole-Mac watts and CPU temperature.
    func light(into s: inout Snap) {
        s.fanForced = (smc.read("F0Md") ?? 0) > 0
        s.sysW = smc.first(["PSTR"]) { $0 > 0.05 && $0 < 400 }
        s.cpuTemp = smc.first(["TCXC", "TC0F", "TC0E", "TC0P", "TC0D"]) { $0 > 5 && $0 < 125 }
    }
    /// Forget the last network/disk counters, so the first reading after a pause is not one giant spike.
    func resetRates() { lastNet = nil; lastDisk = nil; lastTime = Date() }

    private func props(_ className: String) -> [[String: Any]] {
        var it: io_iterator_t = 0; var out: [[String: Any]] = []
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        while case let e = IOIteratorNext(it), e != 0 {
            var p: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(e, &p, kCFAllocatorDefault, 0) == KERN_SUCCESS, var d = p?.takeRetainedValue() as? [String: Any] {
                var cn = [CChar](repeating: 0, count: 128); IOObjectGetClass(e, &cn); d["_class"] = String(cString: cn)
                out.append(d)
            }
            IOObjectRelease(e)
        }
        return out
    }

    func full(into s: inout Snap) {
        cpuOnly(into: &s)
        let now = Date(); let dt = max(0.2, now.timeIntervalSince(lastTime)); lastTime = now
        s.uptime = now.timeIntervalSince(boot)

        // GPU
        var amd = 0.0, intel = 0.0, other = 0.0, seenAMD = false, seenIntel = false
        for d in props("IOAccelerator") {
            guard let st = d["PerformanceStatistics"] as? [String: Any] else { continue }
            let u = ((st["Device Utilization %"] ?? st["Device Utilization % at cur p-state"]) as? NSNumber)?.doubleValue ?? 0
            let c = (d["_class"] as? String) ?? ""
            if c.contains("AMD") { amd = max(amd, u); seenAMD = true } else if c.contains("Intel") { intel = max(intel, u); seenIntel = true } else { other = max(other, u) }
        }
        s.gpu = min(1, max(amd, intel, other) / 100)
        s.gpuNote = seenAMD && seenIntel ? String(format: "AMD %02.0f · INTEL %02.0f", amd, intel) : (seenAMD ? "RADEON" : seenIntel ? "INTEL" : "GPU")

        // Memory
        var vm = vm_statistics64(); var c = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &vm) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &c) } }
        if ok == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            let used = (Double(vm.internal_page_count) - Double(vm.purgeable_count) + Double(vm.wire_count) + Double(vm.compressor_page_count)) * page
            s.memUsedGB = used / 1_073_741_824; s.mem = min(1, max(0, s.memUsedGB / s.memTotalGB))
        }
        var lvl: Int32 = 1; var lsz = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &lvl, &lsz, nil, 0) == 0 { s.pressure = Int(lvl) }

        // Battery and charger
        if let b = props("AppleSmartBattery").first {
            func n(_ k: String) -> Double { (b[k] as? NSNumber)?.doubleValue ?? 0 }
            s.hasBattery = true
            let amps = Double((b["Amperage"] as? NSNumber)?.int64Value ?? 0)
            s.battW = n("Voltage") * amps / 1_000_000
            s.plugged = (b["ExternalConnected"] as? Bool) ?? false; s.charging = (b["IsCharging"] as? Bool) ?? false
            s.cycles = Int(n("CycleCount")); s.battTemp = n("Temperature") / 100
            let design = n("DesignCapacity"), rawMax = n("AppleRawMaxCapacity")
            s.health = design > 0 ? rawMax / design : 0
            let soc = ((b["BatteryData"] as? [String: Any])?["UISoc"] as? NSNumber)?.doubleValue
            s.battPct = Int((soc ?? (n("MaxCapacity") > 0 ? 100 * n("CurrentCapacity") / n("MaxCapacity") : 0)).rounded())
            let ad = b["AdapterDetails"] as? [String: Any]
            s.adapterW = s.plugged ? ((ad?["Watts"] as? NSNumber)?.intValue ?? 0) : 0
            s.adapterName = s.plugged ? ((ad?["Name"] as? String) ?? "") : ""
            // one power controller per socket, in socket order; the one with a power contract has the charger
            let pcs = (b["PortControllerInfo"] as? [[String: Any]]) ?? []
            s.chargerSocket = s.plugged ? ((pcs.firstIndex { (($0["PortControllerMaxPower"] as? NSNumber)?.intValue ?? 0) > 0 }).map { $0 + 1 } ?? 0) : 0
        }

        // Sensor chip
        let watts: (Double) -> Bool = { $0 > 0.05 && $0 < 400 }, temp: (Double) -> Bool = { $0 > 5 && $0 < 125 }
        s.sysW = smc.first(["PSTR"], watts); s.dcInW = s.plugged ? smc.first(["PDTR"], watts) : nil
        s.cpuW = smc.first(["PCPT", "PCPC", "PCTR", "PC0R"], watts); s.gpuW = smc.first(["PG0R", "PCPG", "PGTR"], watts)
        s.cpuTemp = smc.first(["TCXC", "TC0F", "TC0E", "TC0P", "TC0D"], temp)
        s.gpuTemp = smc.first(["TG0P", "TGDD", "TG0D", "TG1D"], temp)
        let nf = Int(smc.read("FNum") ?? 0)
        s.fans = (0..<min(nf, 4)).compactMap { smc.read("F\($0)Ac") }
        s.fanForced = (smc.read("F0Md") ?? 0) > 0
        if s.fanTops.count != s.fans.count { s.fanTops = (0..<s.fans.count).map { smc.read("F\($0)Mx") ?? 6000 } }
        if let mx = smc.read("F0Mx"), mx > 1000 { s.fanMax = mx }
        var st: Unmanaged<CFDictionary>?
        if IOPMCopyCPUPowerStatus(&st) == kIOReturnSuccess, let d = st?.takeRetainedValue() as? [String: Any] {
            s.speedLimit = (d["CPU_Speed_Limit"] as? NSNumber)?.intValue ?? 100
        } else { s.speedLimit = 100 }

        // Network throughput (all en* interfaces together)
        var ifa: UnsafeMutablePointer<ifaddrs>?; var ni: UInt64 = 0, no: UInt64 = 0
        if getifaddrs(&ifa) == 0 {
            var p = ifa
            while let q = p {
                if let a = q.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_LINK), String(cString: q.pointee.ifa_name).hasPrefix("en"), let d = q.pointee.ifa_data {
                    let dd = d.assumingMemoryBound(to: if_data.self).pointee
                    ni += UInt64(dd.ifi_ibytes); no += UInt64(dd.ifi_obytes)
                }
                p = q.pointee.ifa_next
            }
            freeifaddrs(ifa)
        }
        if let l = lastNet, ni >= l.i, no >= l.o { s.down = Double(ni - l.i) / dt; s.up = Double(no - l.o) / dt }
        lastNet = (ni, no)
        if now.timeIntervalSince(wifiAt) > 5 {
            wifiAt = now
            if let w = CWWiFiClient.shared().interface(), w.powerOn(), w.rssiValue() != 0 {
                wifi = (w.rssiValue(), w.transmitRate(), w.transmitPower())
            } else { wifi = (nil, nil, nil) }
        }
        (s.rssi, s.txRate, s.txPower) = wifi

        // Disk throughput
        var dr: UInt64 = 0, dw: UInt64 = 0
        for d in props("IOBlockStorageDriver") {
            if let st = d["Statistics"] as? [String: Any] {
                dr += (st["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0; dw += (st["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
        }
        if let l = lastDisk, dr >= l.r, dw >= l.w { s.read = Double(dr - l.r) / dt; s.write = Double(dw - l.w) / dt }
        lastDisk = (dr, dw); s.readTotal = Double(dr); s.writeTotal = Double(dw)
    }

    static func run(_ path: String, _ args: [String]) -> Data {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return Data() }
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); return d
    }

    /// The busiest app right now.
    static func hog() -> (String, Double) {
        let out = String(data: run("/bin/ps", ["-Aceo", "pcpu=,comm=", "-r"]), encoding: .utf8) ?? ""
        guard let line = out.split(separator: "\n").first else { return ("", 0) }
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let sp = t.firstIndex(of: " ") else { return ("", 0) }
        return (String(t[t.index(after: sp)...]).trimmingCharacters(in: .whitespaces), Double(t[..<sp].replacingOccurrences(of: ",", with: ".")) ?? 0)
    }

    /// Which USB-C socket (1-4) each internal USB port belongs to, keyed by the top 12 bits of its location.
    /// The fast (USB 3) ports carry the socket number; the slow (USB 2) ports name their fast companion.
    func socketTable() -> [UInt32: Int] {
        var fast: [String: Int] = [:], table: [UInt32: Int] = [:]
        func portNo(_ d: [String: Any]) -> Int { ((d["port"] as? Data)?.first).map(Int.init) ?? 0 }
        for d in props("AppleUSB30XHCITypeCPort") {
            guard let n = (d["UsbCPortNumber"] as? NSNumber)?.intValue, let loc = (d["locationID"] as? NSNumber)?.uint32Value else { continue }
            table[loc >> 20] = n
            let path = ((d["device-properties"] as? [String: Any])?["acpi-path"] as? String) ?? ""
            if let r = path.range(of: #"XHC\d"#, options: .regularExpression) { fast["\(path[r])-\(portNo(d))"] = n }
        }
        for d in props("AppleUSB20XHCITypeCPort") {
            guard let loc = (d["locationID"] as? NSNumber)?.uint32Value, let c = (d["UsbCompanionSS"] ?? d["UsbCompanionSSP"]) as? [String: Any],
                  let ctl = c["UsbCompanionControllerName"] as? String, let pn = (c["UsbCompanionPortNumber"] as? Data)?.first else { continue }
            if let n = fast["\(ctl)-\(pn)"] { table[loc >> 20] = n }
        }
        return table
    }

    /// External USB devices (built-in ones like the keyboard and camera are left out).
    static func usb(sockets: [UInt32: Int] = [:]) -> [USBDev] {
        guard let root = try? JSONSerialization.jsonObject(with: run("/usr/sbin/system_profiler", ["SPUSBDataType", "-json"])) as? [String: Any],
              let buses = root["SPUSBDataType"] as? [[String: Any]] else { return [] }
        var out: [USBDev] = []
        let speeds = ["low_speed": "1.5 Mb/s", "full_speed": "12 Mb/s", "high_speed": "480 Mb/s", "super_speed": "5 Gb/s", "super_speed_plus": "10 Gb/s", "super_speed_plus_by2": "20 Gb/s"]
        func walk(_ items: [[String: Any]], _ depth: Int) {
            for it in items {
                let loc = (it["location_id"] as? String) ?? ""
                let builtIn = ((it["Built-in_Device"] as? String) ?? "No") == "Yes" || loc.hasPrefix("0x80")   // 0x80… is the Mac's own internal bus
                let kids = (it["_items"] as? [[String: Any]]) ?? []
                if builtIn { continue }
                let name = (it["_name"] as? String) ?? "USB device"
                let sp = (it["device_speed"] as? String) ?? ""
                let hex = loc.split(separator: " ").first.map { String($0.dropFirst(2)) } ?? ""
                let socket = UInt32(hex, radix: 16).flatMap { sockets[$0 >> 20] } ?? 0
                out.append(USBDev(id: (it["location_id"] as? String) ?? "\(out.count)\(name)", name: name,
                                  vendor: (it["manufacturer"] as? String) ?? "", speed: speeds[sp] ?? sp.replacingOccurrences(of: "_", with: " "),
                                  mA: Int((it["bus_power_used"] as? String) ?? "") ?? 0, depth: depth, port: socket))
                walk(kids, depth + 1)
            }
        }
        for b in buses { walk((b["_items"] as? [[String: Any]]) ?? [], 0) }
        // A USB 3 hub shows up twice (its slow half and its fast half). Same socket, same box: show it once, at its faster speed.
        let rank = ["1.5 Mb/s", "12 Mb/s", "480 Mb/s", "5 Gb/s", "10 Gb/s", "20 Gb/s"]
        var firstHub: [Int: Int] = [:], drop = Set<Int>()
        for (i, d) in out.enumerated() where d.depth == 0 && d.port > 0 && d.name.localizedCaseInsensitiveContains("hub") {
            if let f = firstHub[d.port] {
                if (rank.firstIndex(of: d.speed) ?? 0) > (rank.firstIndex(of: out[f].speed) ?? 0) { out[f].speed = d.speed; out[f].name = d.name }
                drop.insert(i)
            } else { firstHub[d.port] = i }
        }
        return out.enumerated().filter { !drop.contains($0.offset) }.map { $0.element }
    }

    /// Connected Bluetooth devices (AirPods, mice, keyboards...) with whatever battery levels they report.
    static func bluetooth() -> [Wireless] {
        guard let root = try? JSONSerialization.jsonObject(with: run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"])) as? [String: Any],
              let first = (root["SPBluetoothDataType"] as? [[String: Any]])?.first, let list = first["device_connected"] as? [[String: Any]] else { return [] }
        var out: [Wireless] = []
        for entry in list { for (name, any) in entry {
            let p = (any as? [String: Any]) ?? [:]
            func pct(_ k: String) -> Int? { (p[k] as? String).flatMap { Int($0.replacingOccurrences(of: "%", with: "")) } }
            out.append(Wireless(id: (p["device_address"] as? String) ?? name, name: name.replacingOccurrences(of: " - Find My", with: ""),
                                kind: (p["device_minorType"] as? String) ?? "Bluetooth", left: pct("device_batteryLevelLeft"), right: pct("device_batteryLevelRight"),
                                box: pct("device_batteryLevelCase"), main: pct("device_batteryLevelMain")))
        } }
        return out.sorted { $0.name < $1.name }
    }
}

// ---------- Plug and unplug ----------
// macOS tells Redline the moment a USB device arrives or leaves. Nothing runs in between.
final class PlugWatch {
    private var port: IONotificationPortRef?; private var its: [io_iterator_t] = []
    var changed: (() -> Void)?
    func start() {
        guard port == nil, let p = IONotificationPortCreate(kIOMainPortDefault) else { return }
        port = p; IONotificationPortSetDispatchQueue(p, DispatchQueue.main)
        let me = Unmanaged.passUnretained(self).toOpaque()
        let cb: IOServiceMatchingCallback = { ref, it in
            var any = false
            while case let o = IOIteratorNext(it), o != 0 { IOObjectRelease(o); any = true }      // must be read to the end, or no more events come
            if any, let ref = ref { Unmanaged<PlugWatch>.fromOpaque(ref).takeUnretainedValue().changed?() }
        }
        for kind in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var it: io_iterator_t = 0
            if IOServiceAddMatchingNotification(p, kind, IOServiceMatching("IOUSBHostDevice"), cb, me, &it) == KERN_SUCCESS {
                while case let o = IOIteratorNext(it), o != 0 { IOObjectRelease(o) }      // what is there already: not news
                its.append(it)
            }
        }
    }
    func stop() { its.forEach { IOObjectRelease($0) }; its = []; if let p = port { IONotificationPortDestroy(p) }; port = nil }
}

// ---------- NOS keeps the Mac awake (the same job the Coffee Mode app does, built in) ----------
// Nothing in System Settings is changed. While NOS is on, Redline holds "stay awake" requests with macOS:
// no display sleep, no idle sleep, no system sleep, no disk spin-down, and a "someone is here" nudge every 30 seconds
// so the screen never dims and the screensaver never starts. Switching NOS off, quitting or a crash drops them all.
// As with Coffee Mode, closing the lid on battery still puts the Mac to sleep.
final class Awake {
    private var ids: [IOPMAssertionID] = []
    private var activity = IOPMAssertionID(0)
    private var poke: Timer?
    func on() {
        guard ids.isEmpty else { return }
        for type in ["PreventUserIdleDisplaySleep", "PreventUserIdleSystemSleep", "PreventSystemSleep", "PreventDiskIdle"] {
            var id = IOPMAssertionID(0)
            if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Redline NOS: keep everything awake" as CFString, &id) == kIOReturnSuccess { ids.append(id) }
        }
        let tick = { [weak self] in
            guard let self = self else { return }
            IOPMAssertionDeclareUserActivity("Redline NOS" as CFString, kIOPMUserActiveLocal, &self.activity)
        }
        tick()
        poke = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in tick() }
    }
    func off() {
        poke?.invalidate(); poke = nil
        ids.forEach { IOPMAssertionRelease($0) }; ids = []
        if activity != 0 { IOPMAssertionRelease(activity); activity = 0 }
    }
    var held: Int { ids.count }
}

// ---------- Fans: automatic or maximum ----------
// Changing fan speed needs administrator rights, so that one job is done by a tiny separate helper (src/fan.c) that knows only
// "max" and "auto". It is installed once, by the owner, with their password ("Enable fan control"). Redline itself never has those rights.
enum Fans {
    static let helper = "/Library/Application Support/Redline/redline-fan"
    /// True once the helper is installed the way it must be: owned by the system and allowed to act for it.
    static var ready: Bool {
        guard let a = try? FileManager.default.attributesOfItem(atPath: helper) else { return false }
        return (a[.ownerAccountID] as? NSNumber)?.intValue == 0 && ((a[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o4000 != 0
    }
    static let version = "3"       // must match VERSION in src/fan.c; an older installed helper is asked to be updated
    /// True when the installed helper is this version.
    static var current: Bool { ready && (String(data: Probe.run(helper, ["version"]), encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == version }
    /// Returns what the helper said when it could not do it (empty = fine).
    @discardableResult static func set(max: Bool) -> String {
        guard ready else { return "" }
        let p = Process(); p.executableURL = URL(fileURLWithPath: helper); p.arguments = [max ? "max" : "auto"]
        let err = Pipe(); p.standardError = err; p.standardOutput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "could not start the helper" }
        let d = err.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return (String(data: d, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// ---------- ECO: as little power as possible, everything still working ----------
// The opposite of NOS, for reading in bed on battery. Switching ECO on remembers how things were, then:
// macOS Low Power Mode on (through the helper), Bluetooth off, screen at 15 %, keyboard light off, fans back to macOS,
// Redline's lights and animations off and its readings slower, the Touch Bar very dim and still.
// Switching ECO off (or quitting Redline) puts every one of those back exactly as it was.
enum Eco {
    // Screen brightness and keyboard light: the same system calls the Touch Bar part uses, looked up at run time.
    private static let display = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static var screen: CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8); var n: UInt32 = 0
        CGGetOnlineDisplayList(8, &ids, &n)
        return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
    }
    static var brightness: Float? {
        get {
            typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
            guard let f = dlsym(display, "DisplayServicesGetBrightness") else { return nil }
            var b: Float = 0; return unsafeBitCast(f, to: Get.self)(screen, &b) == 0 ? b : nil
        }
        set {
            typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
            guard let v = newValue, let f = dlsym(display, "DisplayServicesSetBrightness") else { return }
            _ = unsafeBitCast(f, to: Set.self)(screen, min(1, max(0, v)))
        }
    }
    private static let keyboard: NSObject? = {
        _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
        return (NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type)?.init()
    }()
    private static var keyboardID: UInt64 {
        guard let k = keyboard, k.responds(to: NSSelectorFromString("copyKeyboardBacklightIDs")) else { return 1 }
        return ((k.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeRetainedValue() as? [NSNumber])?.first)?.uint64Value ?? 1
    }
    static var keys: Float? {
        get {
            let sel = NSSelectorFromString("brightnessForKeyboard:")
            guard let k = keyboard, k.responds(to: sel) else { return nil }
            typealias Get = @convention(c) (AnyObject, Selector, UInt64) -> Float
            return unsafeBitCast(k.method(for: sel), to: Get.self)(k, sel, keyboardID)
        }
        set {
            let sel = NSSelectorFromString("setBrightness:forKeyboard:")
            guard let v = newValue, let k = keyboard, k.responds(to: sel) else { return }
            typealias Set = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
            _ = unsafeBitCast(k.method(for: sel), to: Set.self)(k, sel, min(1, max(0, v)), keyboardID)
        }
    }
    // Bluetooth on/off: the same call the Bluetooth menu uses. macOS asks once for the Bluetooth permission.
    private static let bt = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_NOW)
    /// macOS stops a program on the spot ("privacy violation") if it touches Bluetooth without its own permission text. That is the case
    /// when Redline's program file is run from inside another program (a terminal, a script) instead of being opened as an app:
    /// macOS then holds that other program responsible. Twice on 24 Nov 2026 this stopped Redline at the ECO click. Now ECO simply leaves Bluetooth alone there.
    static let bluetoothAllowed: Bool = {
        guard Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil else { return false }
        typealias Who = @convention(c) (pid_t) -> pid_t
        guard let f = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return true }
        return unsafeBitCast(f, to: Who.self)(getpid()) == getpid()
    }()
    /// Bluetooth takes a few seconds to really switch. Asked again within that time (ECO off and straight on again), macOS still reports
    /// the old state, and ECO would note "Bluetooth was off" and never switch it back on. So what was last asked for counts for a while.
    private static var btAsked: (on: Bool, at: Date)?
    static var bluetoothSettled: Bool? { if let a = btAsked, -a.at.timeIntervalSinceNow < 8 { return a.on }; return bluetooth }
    static var bluetooth: Bool? {
        get {
            typealias Get = @convention(c) () -> Int32
            guard bluetoothAllowed, let f = dlsym(bt, "IOBluetoothPreferenceGetControllerPowerState") else { return nil }
            return unsafeBitCast(f, to: Get.self)() != 0
        }
        set {
            typealias Set = @convention(c) (Int32) -> Void
            guard bluetoothAllowed, let v = newValue, let f = dlsym(bt, "IOBluetoothPreferenceSetControllerPowerState") else { return }
            btAsked = (v, Date())
            unsafeBitCast(f, to: Set.self)(v ? 1 : 0)
        }
    }
    // macOS Low Power Mode: reading needs no rights; switching goes through the helper (installed with "Enable fan control").
    static var lowPower: Bool { (String(data: Probe.run("/usr/bin/pmset", ["-g"]), encoding: .utf8) ?? "").range(of: #"lowpowermode\s+1"#, options: .regularExpression) != nil }
    @discardableResult static func setLowPower(_ on: Bool) -> String {
        guard Fans.ready, Fans.current else { return "the helper needs its update (FANS pill)" }
        let p = Process(); p.executableURL = URL(fileURLWithPath: Fans.helper); p.arguments = ["lowpower", on ? "on" : "off"]
        let err = Pipe(); p.standardError = err; p.standardOutput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "could not start the helper" }
        let d = err.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return p.terminationStatus == 0 ? "" : (String(data: d, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    // Low Power Mode is switched in the background (it takes a moment), strictly one switch after the other. Going straight from ECO
    // to NOS or back, the second mode used to note "how it was before" while the first mode's switch-back was still on its way, and
    // then put the wrong state back later (Low Power Mode left on after NOS). So: what a pending switch WILL set counts as the state.
    private static let lpQ = DispatchQueue(label: "redline.lowpower", qos: .userInitiated)
    private static var lpTarget: Bool?        // main thread only
    static func wantLowPower(_ on: Bool) {
        guard Fans.ready else { return }      // no helper, nothing can be switched
        lpTarget = on
        lpQ.async { if lowPower != on { setLowPower(on) }; DispatchQueue.main.async { if lpTarget == on { lpTarget = nil } } }
    }
    /// For quitting: after anything still pending, and finished before this returns.
    static func lowPowerNow(_ on: Bool) { lpQ.sync { if lowPower != on { setLowPower(on) } } }
    static var lowPowerSettled: Bool { lpTarget ?? lowPower }
    static let screenLevel: Float = 0.15
    /// How things were before ECO, kept in Redline's settings so even a crash during ECO can be undone at the next start.
    static func remember() {
        let d = UserDefaults.standard
        d.set(["brightness": brightness ?? -1, "keys": keys ?? -1, "bluetooth": bluetoothSettled ?? true, "lowPower": lowPowerSettled] as [String: Any], forKey: "ecoBefore")
    }
    static func engage() {
        brightness = screenLevel; keys = 0; bluetooth = false
        wantLowPower(true)
    }
    /// Puts everything back the way it was before ECO.
    static func restore(wait: Bool = false) {
        let d = UserDefaults.standard
        guard let b = d.dictionary(forKey: "ecoBefore") else { return }
        if let v = b["brightness"] as? Double, v >= 0 { brightness = Float(v) }
        if let v = b["keys"] as? Double, v >= 0 { keys = Float(v) }
        if (b["bluetooth"] as? Bool) ?? true { bluetooth = true }
        let lp = (b["lowPower"] as? Bool) ?? false
        d.removeObject(forKey: "ecoBefore")
        if !lp { if wait { lowPowerNow(false) } else { wantLowPower(false) } }      // already on before (e.g. from AlDente): left on
    }
}

/// One timing for every part of the NOS switch (card, desktop, needles), so they move together.
enum NOSMove {
    /// The shared moment everything starts moving: set at the click, a fraction later so the big wallpaper pictures are loaded by then.
    static var start: CFTimeInterval = 0
    /// Each part (card, desktop) prepares its layers and leaves its animations here; go() starts them all at one moment.
    static var pending: [(CFTimeInterval) -> Void] = []
    /// Starts everything together and hands it to macOS at once, so it keeps moving smoothly even while Redline
    /// is busy redrawing the card in the new look.
    static func go() {
        start = CACurrentMediaTime() + 0.03
        let all = pending; pending = []
        all.forEach { $0(start) }
        CATransaction.flush()
    }
    static func duration(_ into: Bool) -> CFTimeInterval { into ? 0.7 : 0.85 }
    static func ease(_ into: Bool) -> CAMediaTimingFunction { into ? CAMediaTimingFunction(controlPoints: 0.5, 0, 0.2, 1) : CAMediaTimingFunction(controlPoints: 0.3, 0, 0.25, 1) }
}

// ---------- The desktop's part of the NOS switch ----------
// macOS only crossfades wallpapers. For NOS, a borderless window just above the desktop picture (below the desktop icons and all
// windows) holds the old wallpaper while the new one is set underneath, then a glowing line wipes the old one away, the same move
// as on the card: up in red going into NOS, down in your underglow colour coming out. About a second, then the window is gone.
enum DesktopWipe {
    private static var windows: [NSWindow] = []
    private static var cache: [String: CGImage] = [:]
    private static let lock = NSLock()
    /// The wallpaper pictures, fully decoded once and kept (decoding two full-screen pictures at the switch took a fifth of a second).
    static func picture(_ path: String) -> CGImage? {
        lock.lock(); if let c = cache[path] { lock.unlock(); return c }; lock.unlock()
        guard let src = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              // in the screen's own colour space and pixel order, so macOS can show it without converting it first
              let ctx = CGContext(data: nil, width: src.width, height: src.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: NSScreen.main?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: src.width, height: src.height))
        guard let img = ctx.makeImage() else { return nil }
        lock.lock(); cache[path] = img; lock.unlock(); return img
    }
    /// The two pictures are about 54 MB decoded (and as much again once macOS has shown them), so they are only kept while the card is
    /// open, which is where NOS is switched. Loaded in the background as the card opens, dropped when it closes.
    static var keep = false       // main thread only
    static func warm() { guard keep else { return }; DispatchQueue.global(qos: .utility).async { _ = picture(Boost.wallpaper); _ = picture(Boost.normalWallpaper) } }
    static func forget() { lock.lock(); cache = [:]; lock.unlock() }
    static func hold(_ on: Bool) { keep = on; if on { warm() } else if windows.isEmpty { forget() } }
    /// Takes the wipe windows away and lets go of their full-screen pictures straight away. (Left to themselves, macOS kept about
    /// 100 MB of them until Redline next drew something, which with the card closed could be a long time.)
    private static func clear() {
        guard !windows.isEmpty else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for w in windows { w.contentView?.layer?.sublayers?.forEach { $0.removeAllAnimations(); $0.mask = nil; $0.contents = nil; $0.removeFromSuperlayer() }; w.orderOut(nil) }
        CATransaction.commit()
        windows = []; CATransaction.flush()
    }
    static func run(from: String, to: String, up: Bool, colour: NSColor, set: () -> Void) {
        guard let old = picture(from), let new = picture(to) else { set(); return }
        clear()
        let dur = NOSMove.duration(up)      // exactly the card's timing, so both move as one
        for sc in NSScreen.screens {
            let f = sc.frame
            let w = NSWindow(contentRect: f, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow)) + 1)
            w.isOpaque = false; w.backgroundColor = .clear; w.ignoresMouseEvents = true; w.hasShadow = false
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            let v = NSView(frame: NSRect(origin: .zero, size: f.size)); v.wantsLayer = true; w.contentView = v
            guard let root = v.layer else { continue }
            let b = v.bounds
            CATransaction.begin(); CATransaction.setDisableActions(true)
            // the new picture underneath (carried here, so the wipe never waits for macOS), the old one on top being cut away
            let under = CALayer(); under.frame = b; under.contents = new; under.contentsGravity = .resizeAspectFill; under.masksToBounds = true; root.addSublayer(under)
            let pic = CALayer(); pic.frame = b; pic.contents = old; pic.contentsGravity = .resizeAspectFill; pic.masksToBounds = true
            let cut = CALayer(); cut.backgroundColor = NSColor.white.cgColor
            cut.anchorPoint = up ? CGPoint(x: 0.5, y: 1) : CGPoint(x: 0.5, y: 0); cut.bounds = b
            cut.position = up ? CGPoint(x: b.midX, y: b.maxY) : CGPoint(x: b.midX, y: 0)
            pic.mask = cut; root.addSublayer(pic)
            let lineH = b.height * 0.16
            let line = CAGradientLayer(); line.bounds = CGRect(x: 0, y: 0, width: b.width, height: lineH); line.position = CGPoint(x: b.midX, y: up ? -lineH / 2 : b.maxY + lineH / 2)
            line.colors = [colour.withAlphaComponent(0), colour.withAlphaComponent(0.5), NSColor.white.withAlphaComponent(0.9), colour.withAlphaComponent(0.5), colour.withAlphaComponent(0)].map { $0.cgColor }
            line.locations = [0, 0.42, 0.5, 0.58, 1]; root.addSublayer(line)
            CATransaction.commit()
            w.orderFront(nil); windows.append(w)
            let ease = NOSMove.ease(up)
            NOSMove.pending.append { start in
            let c = CABasicAnimation(keyPath: "bounds.size.height"); c.fromValue = b.height; c.toValue = 0
            let l = CABasicAnimation(keyPath: "position.y"); l.fromValue = up ? -lineH / 2 : b.maxY + lineH / 2; l.toValue = up ? b.maxY + lineH / 2 : -lineH / 2
            for (a, layer, key) in [(c, cut as CALayer, "cut"), (l, line as CALayer, "line")] {
                a.duration = dur; a.beginTime = start; a.timingFunction = ease; a.fillMode = .both; a.isRemovedOnCompletion = false; layer.add(a, forKey: key)
            }
            }
        }
        set()
        DispatchQueue.main.asyncAfter(deadline: .now() + dur + 1.2) { clear(); if !keep { forget() } }      // macOS has finished its own fade underneath by then
    }
}

// ---------- NOS wallpaper: whatever wallpaper is on this Mac, recoloured into NOS reds ----------
// macOS draws the wallpaper in a window of its own, below the desktop icons and every app. Redline photographs only that window
// (so no icons, windows or menu bar end up in it) and maps its light and dark onto the NOS palette: same shapes, NOS reds.
// Made again by itself whenever the wallpaper is changed (checked every 30 seconds, only while NOS is off). Stays on this Mac.
enum NOSPaint {
    private static var timer: Timer?
    /// Runs only while the engine does.
    static func start() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { if timer != nil { check() } }      // once the desktop has settled
        let t = Timer(timeInterval: 30, repeats: true) { _ in check() }; t.tolerance = 10; RunLoop.main.add(t, forMode: .common); timer = t
    }
    static func stop() { timer?.invalidate(); timer = nil }
    private static func check() {
        let fm = FileManager.default
        // only while the real wallpaper is showing: not during NOS, and not while the still copy stands in after NOS
        guard !UserDefaults.standard.bool(forKey: "nos") else { return }
        let changed = (try? fm.attributesOfItem(atPath: Boost.wallStore)[.modificationDate] as? Date) ?? Date.distantPast
        if fm.fileExists(atPath: Boost.wallStoreCopy) {
            // a new wallpaper picked after NOS went off (before the live one was put back): keep it, forget the old one
            guard Date().timeIntervalSince(changed) > 10, !Boost.oursShowing() else { return }
            try? fm.removeItem(atPath: Boost.wallStoreCopy)
        }
        let screen = NSScreen.main.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? ""
        let stamp = "\(Int(changed.timeIntervalSince1970)) \(screen)"
        guard Date().timeIntervalSince(changed) > 10,       // a wallpaper that was just switched may still be fading in
              stamp != UserDefaults.standard.string(forKey: "nosPaintStamp") || !fm.fileExists(atPath: Boost.wallpaper) || !fm.fileExists(atPath: Boost.normalWallpaper)
        else { return }
        DispatchQueue.global(qos: .utility).async {
            guard let normal = wallpaperOnly(), let red = recolour(normal) else { return }
            try? fm.createDirectory(atPath: (Boost.wallpaper as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            guard write(normal, Boost.normalWallpaper), write(red, Boost.wallpaper) else { return }
            DesktopWipe.forget(); DesktopWipe.warm()
            DispatchQueue.main.async { UserDefaults.standard.set(stamp, forKey: "nosPaintStamp") }
        }
    }
    /// Only the wallpaper window of the main screen.
    static func wallpaperOnly() -> CGImage? {
        typealias Grab = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
              let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let size = NSScreen.main?.frame.size ?? .zero
        let walls = list.filter { ($0[kCGWindowOwnerName as String] as? String) == "Dock" && (($0[kCGWindowName as String] as? String) ?? "").hasPrefix("Wallpaper") }
        let main = walls.first { w in
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            return b["X"] == 0 && b["Y"] == 0 && b["Width"] == size.width && b["Height"] == size.height
        } ?? walls.first
        guard let id = main?[kCGWindowNumber as String] as? UInt32 else { return nil }
        let grab = unsafeBitCast(sym, to: Grab.self)
        return grab(.null, 8 /* this window only */, id, 1 | 8 /* no frame, best resolution */)?.takeRetainedValue()
    }
    /// Light and dark mapped onto the NOS palette: near black, deep red, NOS red, hot coral, pale pink.
    static func recolour(_ img: CGImage) -> CGImage? {
        let stops: [(Double, Double, Double)] = [(0.05, 0, 0.02), (0.35, 0.02, 0.07), (0.85, 0.08, 0.18), (1, 0.36, 0.36), (1, 0.80, 0.78)]
        let w = 256; var px = [UInt8](repeating: 255, count: w * 4)
        for i in 0..<w {
            let t = Double(i) / Double(w - 1) * Double(stops.count - 1), a = min(Int(t), stops.count - 2), f = t - Double(a), c0 = stops[a], c1 = stops[a + 1]
            px[i * 4] = UInt8(255 * (c0.0 + (c1.0 - c0.0) * f)); px[i * 4 + 1] = UInt8(255 * (c0.1 + (c1.1 - c0.1) * f)); px[i * 4 + 2] = UInt8(255 * (c0.2 + (c1.2 - c0.2) * f))
        }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let ramp = CIImage(bitmapData: Data(px), bytesPerRow: w * 4, size: CGSize(width: w, height: 1), format: .RGBA8, colorSpace: srgb)
        guard let map = CIFilter(name: "CIColorMap") else { return nil }
        map.setValue(CIImage(cgImage: img), forKey: kCIInputImageKey); map.setValue(ramp, forKey: "inputGradientImage")
        guard let out = map.outputImage else { return nil }
        return CIContext().createCGImage(out, from: CGRect(x: 0, y: 0, width: img.width, height: img.height), format: .RGBA8, colorSpace: srgb)
    }
    private static func write(_ img: CGImage, _ path: String) -> Bool {
        guard let data = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }
}

// ---------- NOS boost: everything at full power, nothing spent on looks ----------
// While NOS is on: Low Power Mode off, screen and keyboard light at maximum, App Nap off (apps started from now on are never
// slowed down in the background), and the Mac dressed in the NOS red (wallpaper, accent and highlight
// colour) with nothing moving. Fans at maximum and "stay awake" are handled by NOS itself. Everything is noted first and put back
// when NOS goes off, when Redline quits, or at the next start if Redline ever stopped during NOS.
enum Boost {
    static let wallpaper = NSHomeDirectory() + "/Library/Application Support/Redline/nos-wallpaper.png"
    static let wallStore = NSHomeDirectory() + "/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
    static let wallStoreCopy = NSHomeDirectory() + "/Library/Application Support/Redline/wallpaper-before-nos.plist"
    /// A still copy of the normal wallpaper. Leaving NOS fades to it (smooth, like going in) instead of restarting macOS's wallpaper
    /// service, which shows a flat grey desktop for a moment. The live wallpaper itself comes back unseen the next time the screen sleeps.
    static let normalWallpaper = NSHomeDirectory() + "/Library/Application Support/Redline/wallpaper-normal.png"
    private static var watching = false
    static func leaveWallpaper() {
        guard FileManager.default.fileExists(atPath: wallStoreCopy) else { return }
        guard FileManager.default.fileExists(atPath: normalWallpaper) else { restoreWallpaper(); return }
        DesktopWipe.run(from: wallpaper, to: normalWallpaper, up: false, colour: NSColor(Ink.glows[Ink.glow])) {
            for sc in NSScreen.screens { try? NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: normalWallpaper), for: sc, options: [:]) }
        }
        guard !watching else { return }
        watching = true
        let ws = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            ws.addObserver(forName: n, object: nil, queue: .main) { _ in if !(UserDefaults.standard.bool(forKey: "nos")) { restoreWallpaper() } }
        }
    }
    /// Is one of Redline's own pictures (the red one, or the still copy after NOS) on the desktop right now?
    static func oursShowing() -> Bool {
        guard let d = FileManager.default.contents(atPath: wallStore) else { return false }
        return ["/Redline/nos-wallpaper.png", "/Redline/wallpaper-normal.png"].contains { d.range(of: Data($0.utf8)) != nil }
    }
    /// Puts the saved wallpaper store back and has macOS reload it. Not if a new wallpaper was picked since NOS went off:
    /// that choice is kept and the old one forgotten.
    static func restoreWallpaper() {
        guard let data = FileManager.default.contents(atPath: wallStoreCopy) else { return }
        guard oursShowing() else { try? FileManager.default.removeItem(atPath: wallStoreCopy); return }
        try? data.write(to: URL(fileURLWithPath: wallStore), options: .atomic)
        _ = Probe.run("/usr/bin/killall", ["WallpaperAgent"])
        try? FileManager.default.removeItem(atPath: wallStoreCopy)
    }
    static func globalValue(_ k: String) -> Any? { UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[k] }
    static func setGlobal(_ k: String, _ v: Any?) {
        var d = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain) ?? [:]
        d[k] = v; UserDefaults.standard.setPersistentDomain(d, forName: UserDefaults.globalDomain)
    }
    /// Tells running apps the accent colour changed, the same way System Settings does.
    static func colourChanged() {
        let c = DistributedNotificationCenter.default()
        c.postNotificationName(Notification.Name("AppleColorPreferencesChangedNotification"), object: nil, userInfo: nil, deliverImmediately: true)
        c.postNotificationName(Notification.Name("AppleAquaColorVariantChanged"), object: nil, userInfo: nil, deliverImmediately: true)
    }
    static func remember() {
        var b: [String: Any] = ["brightness": Eco.brightness ?? -1, "keys": Eco.keys ?? -1, "lowPower": Eco.lowPowerSettled]
        for k in ["AppleAccentColor", "AppleHighlightColor", "NSAppSleepDisabled"] { if let v = globalValue(k) { b[k] = v } }
        // The wallpaper: macOS keeps the real choice (including live ones like Sequoia, which are not picture files) in its
        // wallpaper store. A copy of that store is the only way to put back exactly what was there.
        if FileManager.default.fileExists(atPath: wallpaper), !FileManager.default.fileExists(atPath: wallStoreCopy), let data = FileManager.default.contents(atPath: wallStore) { FileManager.default.createFile(atPath: wallStoreCopy, contents: data) }
        UserDefaults.standard.set(b, forKey: "nosBefore")
    }
    static func engage() {
        Eco.brightness = 1; Eco.keys = 1
        setGlobal("AppleAccentColor", 0); setGlobal("AppleHighlightColor", "1.000000 0.733333 0.721569 Red"); setGlobal("NSAppSleepDisabled", true); colourChanged()
        if FileManager.default.fileExists(atPath: wallpaper) {
            let set = { for sc in NSScreen.screens { try? NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: wallpaper), for: sc, options: [:]) } }
            if FileManager.default.fileExists(atPath: normalWallpaper) { DesktopWipe.run(from: normalWallpaper, to: wallpaper, up: true, colour: NSColor(Ink.nos), set: set) } else { set() }
        }
        Eco.wantLowPower(false)
    }
    /// Never dimmed: macOS's automatic brightness, "dim on battery" and the keyboard light's idle fade all try to lower them,
    /// so while NOS is on they are put back to maximum every couple of seconds.
    static func holdMax() {
        if let b = Eco.brightness, b < 0.999 { Eco.brightness = 1 }
        if let k = Eco.keys, k < 0.999 { Eco.keys = 1 }
    }
    static func restore(wait: Bool = false) {
        let d = UserDefaults.standard
        guard let b = d.dictionary(forKey: "nosBefore") else { return }
        d.removeObject(forKey: "nosBefore")
        if let v = b["brightness"] as? Double, v >= 0 { Eco.brightness = Float(v) }
        if let v = b["keys"] as? Double, v >= 0 { Eco.keys = Float(v) }
        for k in ["AppleAccentColor", "AppleHighlightColor", "NSAppSleepDisabled"] { setGlobal(k, b[k]) }      // absent before = removed again
        colourChanged()
        if wait { restoreWallpaper() } else { leaveWallpaper() }      // quitting: put the live one straight back
        if (b["lowPower"] as? Bool) ?? false { if wait { Eco.lowPowerNow(true) } else { Eco.wantLowPower(true) } }
    }
}

// ---------- The model the panel watches ----------
final class Model: ObservableObject {
    @Published var s = Snap()
    @Published var theme = Ink.glow
    let scale: CGFloat = 1                                              // the card has one fixed size
    @Published var vibe = UserDefaults.standard.bool(forKey: "vibe")    // music-reactive backdrop
    @Published var vibeNote = ""
    @Published var fanMax = UserDefaults.standard.bool(forKey: "fanMax")      // your own choice: false = automatic, true = maximum
    @Published var fanReady = Fans.ready
    @Published var fanStale = false          // an older helper is installed and needs the set-up run once more
    @Published var fanNote = ""              // what the helper said if it could not do it
    /// NOS always means maximum; otherwise it is your choice.
    /// Engine off: macOS runs the fans, unless you press FANS, which holds them at maximum until you press it again or start the engine.
    var fansWanted: Bool { !eco && (engine ? (nos || fanMax) : fanOffMax) }      // ECO = macOS runs the fans
    @Published var fanOffMax = false         // FANS pressed while the engine is off (not saved: every engine start and stop clears it)
    @Published var fanHeld = false           // the fans really are held at maximum right now
    /// The FANS pill. Engine off: a switch of its own, your saved setting is not touched.
    func pressFans() {
        guard !nos, !eco else { return }
        if engine { fanMax.toggle(); UserDefaults.standard.set(fanMax, forKey: "fanMax") } else { fanOffMax.toggle() }
        applyFans()
    }
    private var fanApplied = Date.distantPast
    private let fanQ = DispatchQueue(label: "redline.fans", qos: .userInitiated)      // one fan job at a time, in the order they were asked for
    func applyFans() {
        fanApplied = Date(); let want = fansWanted
        fanQ.async {
            let ok = Fans.ready, fresh = ok && Fans.current
            let said = fresh ? Fans.set(max: want) : ""
            DispatchQueue.main.async {
                if self.fanReady != ok { self.fanReady = ok }; if self.fanStale != (ok && !fresh) { self.fanStale = ok && !fresh }
                if self.fanNote != said { self.fanNote = said }
                let held = fresh && want && said.isEmpty; if self.fanHeld != held { self.fanHeld = held }
                if !said.isEmpty { try? (said + "\n").write(toFile: NSHomeDirectory() + "/Library/Logs/Redline-fans.log", atomically: true, encoding: .utf8) }
            }
        }
    }
    @Published var nos = false { didSet { if nos != oldValue { Ink.nosOn = nos; announce(); applyFans() } } }   // NOS: Redline is holding the Mac awake
    @Published var eco = false          // ECO: as little power as possible (see Eco)
    @Published var ecoNote = ""         // what did not work, if anything
    /// Switches ECO. NOS and ECO never run together: one switches the other off. Call on the main thread.
    func setECO(_ on: Bool) {
        guard on != eco else { return }
        if on {
            if nos { setNOS(false) }
            if !silent { Eco.remember(); Eco.engage(); stopTouchBarCompanion(); sweepTouchBar() }      // ECO: Apple's own Touch Bar, as if Redline were off
            eco = true; UserDefaults.standard.set(true, forKey: "eco")
        } else {
            eco = false; UserDefaults.standard.set(false, forKey: "eco")
            if !silent { Eco.restore(); if engine { startTouchBarCompanion(rev: false) } }
        }
        announce(); applyFans(); schedule(shown ? 1.0 : 2.0); onECO?(on)
        if on, !silent { DispatchQueue.global(qos: .utility).async { let said = Fans.current ? "" : "Low Power Mode needs the helper update: click FANS UPDATE once."; DispatchQueue.main.async { self.ecoNote = said } } }
        else { ecoNote = "" }
    }
    func toggleECO() { setECO(!eco) }
    var onECO: ((Bool) -> Void)?
    /// Tells the Touch Bar app (Glowstrip) which look is on. Local to this Mac: a saved setting plus a notification between the two apps.
    var silent = false      // true while only drawing preview pictures
    func announce() {
        guard !silent else { return }
        UserDefaults.standard.set(nos, forKey: "nos"); UserDefaults.standard.set(eco, forKey: "eco")
        if engine { UserDefaults.standard.set(nos, forKey: "nosLast") }       // what NOS was when the engine last ran; it comes back on the next start
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("local.redline.theme"), object: nil,
                                                                     userInfo: ["glow": Ink.glow, "vibe": vibe, "nos": nos, "eco": eco], deliverImmediately: true)
    }
    /// All-time highs: CPU temperature (°C), whole-Mac draw (W), download speed (bytes/s).
    @Published var records: [Double] = Model.savedRecords()
    private var rec: [Double] = Model.savedRecords()
    static func savedRecords() -> [Double] { (UserDefaults.standard.array(forKey: "records") as? [Double]).flatMap { $0.count == 3 ? $0 : nil } ?? [0, 0, 0] }
    func resetRecords() { rec = [0, 0, 0]; records = rec; UserDefaults.standard.set(rec, forKey: "records") }
    var onNOS: (() -> Void)?, willNOS: ((Bool) -> Void)?
    /// The needles' part of the NOS switch: in = slammed to the redline and back, out = they drop and settle.
    func kick(_ on: Bool) {
        let keys: [(Double, Double?)] = on ? [(0.0, 0.35), (0.12, 1.0), (0.55, nil)] : [(0.0, 0.0), (0.7, nil)]
        let lead = max(0, NOSMove.start - CACurrentMediaTime())
        for (t, v) in keys { DispatchQueue.main.asyncAfter(deadline: .now() + lead + t) { guard self.engine, !self.cranking else { return }; self.rev = v } }
    }
    // ---- NOS and the optional Coffee Mode app ----
    // Redline keeps the Mac awake by itself. If the separate Coffee Mode app is also on this Mac, Redline keeps that app's switch
    // (and its running cup) in step, and follows it when the switch is flipped there. Neither app needs the other.
    let awake = Awake()
    private var coffeeSynced = Date.distantPast
    static let coffeeApp = "/Applications/Coffee Mode.app"
    static var coffeeAllowed: Bool { ProcessInfo.processInfo.environment["REDLINE_NO_COFFEE"] == nil }      // the variable is for testing the "Redline only" case
    static var coffeePID: pid_t? { coffeeAllowed ? NSRunningApplication.runningApplications(withBundleIdentifier: "local.coffeemode").first?.processIdentifier : nil }
    static func coffeeOn() -> Bool { (String(data: Probe.run("/usr/bin/pmset", ["-g", "assertions"]), encoding: .utf8) ?? "").contains("Coffee Mode") }
    /// Switches NOS. Call on the main thread.
    func setNOS(_ on: Bool, tellCoffee: Bool = true) {
        guard on != nos else { return }
        NOSMove.pending = []
        willNOS?(on)                      // the card takes its "before" picture for the transition
        if on, eco { setECO(false) }
        if !silent { if on { awake.on(); Boost.remember(); Boost.engage() } else { awake.off(); Boost.restore() } }
        NOSMove.go()                      // card, desktop and needles all start moving now, together
        nos = on
        if on { onNOS?() }
        if engine, !silent { kick(on) }
        if tellCoffee, !silent { syncCoffee(on) }
    }
    func toggleNOS() { setNOS(!nos) }
    /// Brings the Coffee Mode app (if there is one) to the same state, using the local signal its own menu uses.
    private func syncCoffee(_ on: Bool) {
        coffeeSynced = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            var pid = Model.coffeePID
            if pid == nil, on, Model.coffeeAllowed, FileManager.default.fileExists(atPath: Model.coffeeApp) {
                _ = Probe.run("/usr/bin/open", ["-g", "-a", Model.coffeeApp]); Thread.sleep(forTimeInterval: 1.5); pid = Model.coffeePID
            }
            if let p = pid, Model.coffeeOn() != on { kill(p, SIGUSR1) }
            DispatchQueue.main.async { self.coffeeSynced = Date() }
        }
    }
    /// If Coffee Mode is running and its switch was flipped there, NOS follows.
    func refreshNOS() {
        DispatchQueue.main.async {
            guard self.engine, -self.coffeeSynced.timeIntervalSinceNow > 4 else { return }
            DispatchQueue.global(qos: .utility).async {
                guard Model.coffeePID != nil else { return }
                let on = Model.coffeeOn()
                DispatchQueue.main.async { if -self.coffeeSynced.timeIntervalSinceNow > 4, self.nos != on { self.setNOS(on, tellCoffee: false) } }
            }
        }
    }
    /// Where each socket (1-4) physically sits on this MacBook Pro. Fixed, not adjustable: 0 top-left, 1 bottom-left, 2 top-right, 3 bottom-right ("top" = by the hinge).
    /// So: socket 1 bottom-left, socket 2 top-left, socket 3 top-right, socket 4 bottom-right.
    let portMap = [1, 0, 2, 3]
    /// Where socket `n` sits, or nil for a socket number this map does not know (another Mac model).
    func slot(_ n: Int) -> Int? { n >= 1 && n <= portMap.count ? portMap[n - 1] : nil }
    // ---- The engine ----
    // Engine off = the Mac exactly as Apple ships it: Apple's own Touch Bar, macOS running the fans, nothing held awake.
    // Engine on = Redline takes over again with the settings it had last time (underglow, VIBE, NOS, fans, Touch Bar look).
    // The card and its gauges work either way. At start-up the engine starts by itself (AUTO START) or waits for the
    // push-to-start button (PUSH START); only a push revs the needles and the Touch Bar.
    @Published var engine = false
    @Published var cranking = false       // between the push and the first blip, while the Touch Bar part starts up
    @Published var autoStart = UserDefaults.standard.bool(forKey: "autoStart")
    @Published var rev: Double? = nil     // while revving, every needle shows this instead of its reading
    var onEngine: ((Bool) -> Void)?, onRedline: (() -> Void)?, onPush: (() -> Void)?      // onPush: the start button was pressed (handled by the app)
    func setAutoStart(_ on: Bool) { autoStart = on; UserDefaults.standard.set(on, forKey: "autoStart") }
    func startEngine(rev: Bool) {
        guard !engine else { return }
        engine = true; fanOffMax = false
        q.async { self.n = 0; self.probe.resetRates() }
        schedule(shown ? 1.0 : 2.0)       // the readings start with the engine
        watchPlugs(true); refreshBay()
        if !silent {
            if !eco { startTouchBarCompanion(rev: rev) }
            if UserDefaults.standard.bool(forKey: "nosLast") { setNOS(true) } else { refreshNOS() }
            announce(); applyFans()
        }
        onEngine?(true)
    }
    func stopEngine() {
        guard engine else { return }
        UserDefaults.standard.set(nos, forKey: "nosLast")
        engine = false; cranking = false; rev = nil; fanOffMax = false
        setNOS(false)                     // nothing held awake (and Coffee Mode, if present, switched off with it)
        applyFans(); stopTouchBarCompanion(); sweepTouchBar()
        schedule(0); park()               // no readings at all while the engine is off
        watchPlugs(false); refreshBay()   // one last look, so the list is right as the engine stops
        onEngine?(false)
    }
    /// Engine off: every dial, light and graph at rest, the menu bar needle parked. Only the list of what is plugged in stays (greyed),
    /// so the card keeps its size.
    func park() {
        var p = Snap(); p.usb = s.usb; p.wireless = s.wireless
        s = p; peakCPU = 0; peakGPU = 0; peakMem = 0
        let flat = Array(repeating: 0.0, count: 60); hDown = flat; hUp = flat; hRead = flat; hWrite = flat; hSys = flat; hIn = flat
        onTick?(0)
    }
    /// Engine off (or ECO) means Apple's Touch Bar: if the Touch Bar part was still starting when that was switched, it is stopped a moment later.
    private func sweepTouchBar() {
        guard !silent else { return }
        for t in [2.0, 5.0] { DispatchQueue.main.asyncAfter(deadline: .now() + t) { if !self.engine || self.eco { stopTouchBarCompanion() } } }
    }
    /// The needles rev like a car at key-on: two blips, then all the way to the redline, then they drop to the real readings.
    /// Same timing as the Touch Bar's rev (StripView.revKeys in touchbar.swift); the needles' spring makes the overshoot.
    func revUp() {
        cranking = false
        for (t, v) in [(0.0, 0.42), (0.30, 0.10), (0.58, 0.70), (0.90, 0.22), (1.22, 1.0), (2.0, nil)] as [(Double, Double?)] {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { guard self.engine else { return }; self.rev = v; if v == 1 { self.onRedline?() } }
        }
    }
    @Published var peakCPU = 0.0; @Published var peakGPU = 0.0; @Published var peakMem = 0.0
    @Published var hDown: [Double] = Array(repeating: 0, count: 60); @Published var hUp: [Double] = Array(repeating: 0, count: 60)
    @Published var hRead: [Double] = Array(repeating: 0, count: 60); @Published var hWrite: [Double] = Array(repeating: 0, count: 60)
    @Published var hSys: [Double] = Array(repeating: 0, count: 60); @Published var hIn: [Double] = Array(repeating: 0, count: 60)
    var onTick: ((Double) -> Void)?

    private let probe = Probe(); private let q = DispatchQueue(label: "redline.sample", qos: .utility)
    private var work = Snap(); private var timer: DispatchSourceTimer?; private var open = false, shown = false; private var n = 0
    private var busySlow = false
    private lazy var sockets = probe.socketTable()

    func start() {
        applyFans()
        if !silent {
            sweepTouchBar()
            // macOS takes the fans back after sleep. With the engine running the readings notice; with it off nothing is running, so this does.
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { if let m = self, !m.engine, m.fansWanted { m.applyFans() } }
            }
        }
        if !silent, UserDefaults.standard.dictionary(forKey: "ecoBefore") != nil { Eco.restore() }      // Redline stopped during ECO: undo it now
        if !silent, UserDefaults.standard.dictionary(forKey: "nosBefore") != nil { Boost.restore(wait: true) }    // same for NOS
        else if !silent { Boost.restoreWallpaper() }       // a live wallpaper still waiting to come back after NOS (no-op otherwise)
        if !silent { UserDefaults.standard.set(false, forKey: "eco"); announce() }
    }      // engine still off: the fans go (or stay) with macOS
    private func schedule(_ every: Double) {
        let every = eco ? every * 3 : every      // ECO: readings three times slower
        timer?.cancel(); timer = nil
        guard engine, every > 0 else { return }  // engine off: nothing is read, nothing wakes up
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 0.05, repeating: every, leeway: .milliseconds(every > 1 ? 300 : 30))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume(); timer = t
    }
    func setOpen(_ o: Bool) {
        shown = o
        q.async { self.open = o; self.n = 0; if o { self.probe.resetRates() } }
        if o { refreshNOS(); refreshBay() }
        if o, !engine, !fanReady || fanStale { applyFans() }      // picks up a fresh fan set-up without the engine running
        if o { peakCPU = 0; peakGPU = 0; peakMem = 0 }      // no rev here: the needles only rev when the engine is started with the button
        schedule(o ? 1.0 : 2.0)
    }
    // ---- What is connected ----
    // Looked up when the engine starts, when the card opens, when something is plugged in or pulled out (macOS tells Redline),
    // about once a minute while the card is open, and one last time when the engine stops. Never on a fast timer.
    private let plugs = PlugWatch(); private var plugWait: DispatchWorkItem?
    private var bayBusy = false, bayAgain = false
    func refreshBay() {
        guard !silent else { return }
        if bayBusy { bayAgain = true; return }
        bayBusy = true; let table = sockets
        DispatchQueue.global(qos: .utility).async {
            let u = Probe.usb(sockets: table), w = Probe.bluetooth()
            self.q.async { self.work.usb = u; self.work.wireless = w }
            DispatchQueue.main.async {
                if self.s.usb != u { self.s.usb = u }; if self.s.wireless != w { self.s.wireless = w }
                if !self.engine { self.onTick?(0) }      // engine off: no readings arrive to resize the card, so do it here
                self.bayBusy = false; if self.bayAgain { self.bayAgain = false; self.refreshBay() }
            }
        }
    }
    private func watchPlugs(_ on: Bool) {
        guard !silent else { return }
        plugs.changed = { [weak self] in      // a hub brings several events at once: wait until they stop
            guard let m = self else { return }
            m.plugWait?.cancel(); let w = DispatchWorkItem { m.refreshBay() }; m.plugWait = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
        }
        if on { plugs.start() } else { plugs.stop(); plugWait?.cancel() }
    }
    private func tick() {
        if open {
            probe.full(into: &work)
            if n % 3 == 0, !busySlow {      // the busiest app: a slower reading, off the fast path
                busySlow = true
                DispatchQueue.global(qos: .utility).async {
                    let h = Probe.hog()
                    self.q.async { (self.work.hog, self.work.hogPct) = h; self.busySlow = false }
                }
            }
            if n % 60 == 59 { DispatchQueue.main.async { self.refreshBay() } }      // about once a minute, for wireless devices (they send no plug event)
            n += 1
        } else { probe.cpuOnly(into: &work); probe.light(into: &work); n += 1; if n % 10 == 0 { refreshNOS() } }     // notices Coffee Mode being switched elsewhere
        let snap = work, isOpen = open, settled = n > 2
        DispatchQueue.main.async {
            guard self.engine else { return }      // a reading that was still on its way when the engine went off
            self.onTick?(snap.cpu)
            if self.fanHeld != snap.fanForced { self.fanHeld = snap.fanForced }
            if self.nos, !self.silent { Boost.holdMax() }      // NOS: never dimmed
            // Engine off means Apple's Touch Bar: if the Touch Bar part finished starting after the engine was switched off, stop it.
            if self.eco, !self.silent, !NSRunningApplication.runningApplications(withBundleIdentifier: "local.glowstrip").isEmpty { stopTouchBarCompanion() }
            // macOS takes the fans back after sleep; if what the Mac is doing no longer matches what is wanted, set it again
            if self.fanReady, !self.fanStale, snap.fanForced != self.fansWanted, -self.fanApplied.timeIntervalSinceNow > (self.fanNote.isEmpty ? 6 : 60) { self.applyFans() }
            // while the helper is missing or out of date, look again now and then, so a fresh set-up is picked up without restarting Redline
            else if !self.fanReady || self.fanStale, -self.fanApplied.timeIntervalSinceNow > 8 { self.applyFans() }
            var r = self.rec
            r[0] = max(r[0], snap.cpuTemp ?? 0); r[1] = max(r[1], snap.sysW ?? 0); if isOpen, settled { r[2] = max(r[2], snap.down) }
            if r != self.rec { self.rec = r; UserDefaults.standard.set(r, forKey: "records") }
            if isOpen, self.records != r { self.records = r }
            if isOpen {
                self.s = snap
                self.peakCPU = max(self.peakCPU, snap.cpu); self.peakGPU = max(self.peakGPU, snap.gpu); self.peakMem = max(self.peakMem, snap.mem)
                func push(_ a: inout [Double], _ v: Double) { a.removeFirst(); a.append(v) }
                push(&self.hDown, snap.down); push(&self.hUp, snap.up); push(&self.hRead, snap.read); push(&self.hWrite, snap.write)
                push(&self.hSys, snap.sysW ?? 0); push(&self.hIn, snap.dcInW ?? 0)
            }
        }
    }
    /// One real sample, used for the preview picture.
    func sampleNow() {
        probe.full(into: &work); Thread.sleep(forTimeInterval: 1.0); probe.full(into: &work)
        (work.hog, work.hogPct) = Probe.hog(); work.usb = Probe.usb(sockets: sockets); work.wireless = Probe.bluetooth(); s = work
        peakCPU = min(1, s.cpu + 0.12); peakGPU = s.gpu; peakMem = s.mem
        let w: Double = s.sysW ?? 20
        hSys = (0..<60).map { (i: Int) -> Double in let x: Double = sin(Double(i) / 5); return w * (0.8 + 0.2 * x) }
        hIn = hSys.map { (v: Double) -> Double in v * 1.1 }
        hDown = (0..<60).map { 400_000 * (1 + sin(Double($0) / 4)) }; hUp = (0..<60).map { 60_000 * (1 + cos(Double($0) / 6)) }
        hRead = (0..<60).map { 900_000 * abs(sin(Double($0) / 7)) }; hWrite = (0..<60).map { 500_000 * abs(cos(Double($0) / 9)) }
    }
}

// ---------- Look ----------
enum Ink {
    static let bg0 = Color(red: 0.035, green: 0.043, blue: 0.055), bg1 = Color(red: 0.063, green: 0.075, blue: 0.094)
    static let tile = Color(red: 0.082, green: 0.098, blue: 0.122).opacity(0.90), line = Color.white.opacity(0.07)
    // Four underglows plus NOS. Each has a partner colour it shifts into (the same pairs the Touch Bar uses).
    static let glows: [Color] = [Color(red: 0.25, green: 0.90, blue: 1.0), Color(red: 0.72, green: 0.45, blue: 1.0), Color(red: 0.45, green: 1.0, blue: 0.35),
                                 Color(red: 1.0, green: 0.55, blue: 0.15), Color(red: 1.0, green: 0.36, blue: 0.78), Color(red: 0.40, green: 0.60, blue: 1.0),
                                 Color(red: 1.0, green: 0.84, blue: 0.22), Color(red: 0.90, green: 0.94, blue: 1.0), Color(red: 1.0, green: 0.14, blue: 0.24)]
    static let partners: [Color] = [Color(red: 1.0, green: 0.18, blue: 0.62), Color(red: 0.20, green: 0.92, blue: 1.0), Color(red: 1.0, green: 0.92, blue: 0.10),
                                    Color(red: 1.0, green: 0.16, blue: 0.50), Color(red: 0.25, green: 0.95, blue: 1.0), Color(red: 0.78, green: 0.42, blue: 1.0),
                                    Color(red: 0.20, green: 0.90, blue: 1.0), Color(red: 0.55, green: 0.75, blue: 1.0), Color(red: 0.66, green: 0.30, blue: 1.0)]
    static let glowNames = ["ICE · CDJ", "NITROUS · LASER", "TOXIC · RADAR", "SUNSET · SUNRISE", "VAPOR · GRID", "GALAXY · WARP", "PRISM · SPECTRUM", "MONO · SCOPE"]
    static let blue = Color(red: 0.36, green: 0.62, blue: 1.0)
    // Each look also has its own bodywork: the glass the boxes are made of, their edge, and the shape of the little lights.
    static let glass: [Color] = [tile, Color(red: 0.110, green: 0.080, blue: 0.165).opacity(0.90), Color(red: 0.075, green: 0.110, blue: 0.075).opacity(0.90),
                                 Color(red: 0.150, green: 0.090, blue: 0.090).opacity(0.90), Color(red: 0.105, green: 0.075, blue: 0.175).opacity(0.90),
                                 Color(red: 0.055, green: 0.075, blue: 0.160).opacity(0.90), Color(red: 0.095, green: 0.095, blue: 0.105).opacity(0.90),
                                 Color(red: 0.015, green: 0.015, blue: 0.020).opacity(0.92), Color(red: 0.170, green: 0.045, blue: 0.065).opacity(0.90)]
    static var tileFill: Color { glass[active] }
    static var tileLine: Color { active == 0 ? line : (active == 7 ? Color.white.opacity(0.38) : ice.opacity(active == 8 ? 0.50 : 0.22)) }
    /// How round the little lights are (core LEDs and shift lights): 0 = square, 9 = fully round.
    static var ledRadius: CGFloat { [1.5, 0, 0.5, 9, 0, 9, 1.5, 0, 0][active] }
    /// How far the little lights lean forward, as a shear (NOS leans hard).
    static var ledLean: CGFloat { [0, -0.35, 0, 0, 0, 0, 0, 0, -0.7][active] }
    static let nos = Color(red: 1.0, green: 0.14, blue: 0.24)
    static let eco = Color(red: 0.36, green: 0.92, blue: 0.55)          // hybrid green
    static var glow = min(7, max(0, UserDefaults.standard.integer(forKey: "glow")))     // the underglow you picked
    static var nosOn = false                                                 // NOS overrides it with its own look
    static var active: Int { nosOn ? 8 : glow }
    static var ice: Color { glows[active] }
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.20)
    static let red = Color(red: 1.0, green: 0.27, blue: 0.23), green = Color(red: 0.35, green: 0.92, blue: 0.60)
    static let dim = Color.white.opacity(0.42), mid = Color.white.opacity(0.68)
}
extension NSColor { func mix(_ f: CGFloat, _ other: NSColor) -> NSColor { blended(withFraction: f, of: other) ?? self } }
func label(_ t: String, _ size: CGFloat = 9.5) -> some View {
    Text(t).font(.system(size: size, weight: .semibold, design: .rounded)).tracking(1.6).foregroundColor(Ink.dim)
}
func digits(_ size: CGFloat, _ w: Font.Weight = .semibold) -> Font { .system(size: size, weight: w, design: .rounded).monospacedDigit() }
func rate(_ v: Double) -> (String, String) {
    if v < 999_500 { return (String(format: "%.0f", v / 1000), "KB/s") }
    if v < 999_500_000 { return (String(format: "%.1f", v / 1_000_000), "MB/s") }
    return (String(format: "%.2f", v / 1_000_000_000), "GB/s")
}
let spring = Animation.timingCurve(0.34, 1.45, 0.64, 1, duration: 0.38)

// ---------- A dial ----------
func dialDeg(_ f: Double) -> Double { 150 + 240 * min(1, max(0, f)) }

/// The parts of a dial that never move: drawn once and kept as a picture.
struct DialFace: View, Equatable {
    var size: CGFloat; var numbers: Bool; var redFrom: Double; var hot: Bool; var theme: Int
    var body: some View {
        let r = size / 2
        ZStack {
            Circle().fill(RadialGradient(colors: [Ink.bg1, Ink.bg0], center: .center, startRadius: 0, endRadius: r))
            Circle().strokeBorder(LinearGradient(colors: hot ? [Ink.red, Ink.red.opacity(0.25)] : (theme == 0 ? [Color.white.opacity(0.16), Color.white.opacity(0.02)] : (theme == 7 ? [Color.white.opacity(0.75), Color.white.opacity(0.25)] : [Ink.ice.opacity(0.70), Ink.ice.opacity(0.08)])), startPoint: .top, endPoint: .bottom), lineWidth: hot ? 2.5 : (theme == 0 ? 1.5 : 2))
            Canvas { ctx, sz in
                let c = CGPoint(x: sz.width / 2, y: sz.height / 2), rr = sz.width / 2 - 9
                for i in 0...50 {
                    let f = Double(i) / 50, a = dialDeg(f) * .pi / 180, major = i % 5 == 0
                    let p1 = CGPoint(x: c.x + cos(a) * rr, y: c.y + sin(a) * rr)
                    let len: CGFloat = major ? size * 0.065 : size * 0.032
                    let p2 = CGPoint(x: c.x + cos(a) * (rr - len), y: c.y + sin(a) * (rr - len))
                    var p = Path(); p.move(to: p1); p.addLine(to: p2)
                    let col = f >= redFrom - 0.001 ? Ink.red.opacity(major ? 1 : 0.7) : Color.white.opacity(major ? 0.75 : 0.28)
                    ctx.stroke(p, with: .color(col), style: StrokeStyle(lineWidth: major ? 1.8 : 1, lineCap: .round))
                    if numbers, i % 10 == 0 {
                        let pt = CGPoint(x: c.x + cos(a) * (rr - len - size * 0.065), y: c.y + sin(a) * (rr - len - size * 0.065))
                        ctx.draw(Text("\(i / 5)").font(.system(size: size * 0.062, weight: .bold, design: .rounded)).foregroundColor(f >= redFrom ? Ink.red : Ink.mid), at: pt)
                    }
                }
            }
        }.frame(width: size, height: size).drawingGroup()
    }
}

struct Dial: View {
    var title: String; var value: Double; var peak: Double; var big: String; var unit: String; var sub: String
    var size: CGFloat; var numbers = false; var redFrom = 0.8
    var body: some View {
        let r = size / 2
        let hot = value >= redFrom, col = hot ? Ink.red : Ink.ice
        let frac = 240.0 / 360.0 * min(1, max(0, value))
        ZStack {
            DialFace(size: size, numbers: numbers, redFrom: redFrom, hot: hot, theme: Ink.active).equatable()
            // lit arc: a soft wide stroke under a sharp one gives the glow without a costly blur
            Circle().trim(from: 0, to: frac).stroke(col.opacity(0.22), style: StrokeStyle(lineWidth: size * 0.06, lineCap: .round))
                .rotationEffect(.degrees(150)).padding(size * 0.135)
            Circle().trim(from: 0, to: frac).stroke(col, style: StrokeStyle(lineWidth: size * 0.022, lineCap: .round))
                .rotationEffect(.degrees(150)).padding(size * 0.135)
            // peak marker
            Circle().fill(Ink.amber).frame(width: size * 0.028, height: size * 0.028).offset(x: r - size * 0.135)
                .rotationEffect(.degrees(dialDeg(peak))).opacity(peak > 0.005 ? 0.95 : 0)
            // needle
            ZStack {
                Capsule().fill(Ink.red.opacity(0.22)).frame(width: r * 0.92, height: max(6, size * 0.045)).offset(x: r * 0.30)
                Capsule().fill(LinearGradient(colors: [Ink.red.opacity(0.0), Ink.red, Color(red: 1, green: 0.55, blue: 0.4)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: r * 0.92, height: max(2, size * 0.014)).offset(x: r * 0.30)
            }.rotationEffect(.degrees(dialDeg(value)))
            Circle().fill(RadialGradient(colors: [Color(white: 0.32), Color(white: 0.08)], center: .topLeading, startRadius: 0, endRadius: size * 0.09))
                .frame(width: size * 0.115, height: size * 0.115).overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(big).font(digits(size * 0.145, .bold)).foregroundColor(.white)
                    Text(unit).font(.system(size: size * 0.06, weight: .semibold, design: .rounded)).foregroundColor(Ink.dim)
                }
                label(title, max(9, size * 0.05))
                Text(sub).font(digits(max(8, size * 0.043), .medium)).foregroundColor(Ink.dim).padding(.top, 1).lineLimit(1)
                    .frame(maxWidth: size * 0.56)      // never wider than the circle is at that height
            }.offset(y: size * 0.255)
        }
        .frame(width: size, height: size)
        .animation(spring, value: value).animation(.easeOut(duration: 0.4), value: peak)
    }
}

// ---------- LED columns, one per CPU core ----------
struct CoreStrip: View {
    var cores: [Double]; let segs = 8
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(cores.enumerated()), id: \.offset) { i, v in
                VStack(spacing: 3) {
                    VStack(spacing: 2) {
                        ForEach((0..<segs).reversed(), id: \.self) { k in
                            let on = v * Double(segs) > Double(k) + 0.15
                            RoundedRectangle(cornerRadius: Ink.ledRadius).fill(k >= segs - 2 ? Ink.red : (k >= segs - 4 ? Ink.amber : Ink.ice))
                                .opacity(on ? 1 : 0.10).transformEffect(CGAffineTransform(a: 1, b: 0, c: Ink.ledLean, d: 1, tx: 0, ty: 0))
                                .frame(height: 4)
                        }
                    }
                    Text(String(format: "%02d", i + 1)).font(digits(8, .medium)).foregroundColor(Ink.dim)
                }.frame(maxWidth: .infinity)
            }
        }.drawingGroup()      // LEDs snap, like real ones: animating 96 of them every frame cost far more CPU than the sensors
    }
}

struct Spark: View {
    var data: [Double]; var color: Color; var floor: Double = 1
    var body: some View {
        GeometryReader { g in
            let mx = max(floor, data.max() ?? 1), w = g.size.width, h = g.size.height
            let pts = data.enumerated().map { CGPoint(x: w * CGFloat($0.offset) / CGFloat(max(1, data.count - 1)), y: h - (h - 1.5) * CGFloat($0.element / mx) - 0.75) }
            ZStack {
                Path { p in p.move(to: CGPoint(x: 0, y: h)); pts.forEach { p.addLine(to: $0) }; p.addLine(to: CGPoint(x: w, y: h)); p.closeSubpath() }
                    .fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                Path { p in p.addLines(pts) }.stroke(color, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
            }
        }
    }
}

/// Top view of the laptop with its four sockets; the ones in use glow (green = device, amber = charger).
struct PortMap: View {
    var lit: Set<Int>; var charger: Int?     // positions: 0 top-left, 1 bottom-left, 2 top-right, 3 bottom-right
    static let names = ["TOP · LEFT", "BOTTOM · LEFT", "TOP · RIGHT", "BOTTOM · RIGHT"]
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04))
            RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
            RoundedRectangle(cornerRadius: 1.5).fill(Color.white.opacity(0.10)).frame(width: 52, height: 3).offset(y: -22)      // touch bar
            RoundedRectangle(cornerRadius: 2).strokeBorder(Color.white.opacity(0.12), lineWidth: 1).frame(width: 52, height: 17).offset(y: -9)   // keys
            RoundedRectangle(cornerRadius: 2.5).strokeBorder(Color.white.opacity(0.16), lineWidth: 1).frame(width: 28, height: 16).offset(y: 13) // trackpad
            ForEach(0..<4, id: \.self) { i in
                let col: Color? = charger == i ? Ink.amber : (lit.contains(i) ? Ink.green : nil)
                ZStack {
                    Circle().fill((col ?? .clear).opacity(col == nil ? 0 : 0.28)).frame(width: 13, height: 13)
                    Capsule().fill(col ?? Color.white.opacity(0.22)).frame(width: 4, height: 7)
                }.offset(x: i < 2 ? -38 : 38, y: i % 2 == 0 ? -17 : -6)
            }
        }.frame(width: 76, height: 56).padding(.horizontal, 6)
    }
}

/// The outline of every box on the card. Each look has its own:
/// ice rounded · nitrous all corners cut · toxic two opposite corners cut · sunset very round · vapor crisp · galaxy soft · prism rounded · mono square · NOS the other two corners cut
struct TileShape: Shape {
    func path(in r: CGRect) -> Path {
        func cut(_ tl: CGFloat, _ tr: CGFloat, _ br: CGFloat, _ bl: CGFloat) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.minX + tl, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX - tr, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + tr))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - br)); p.addLine(to: CGPoint(x: r.maxX - br, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX + bl, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY - bl)); p.addLine(to: CGPoint(x: r.minX, y: r.minY + tl)); p.closeSubpath(); return p
        }
        let most = min(r.width, r.height) / 2
        switch Ink.active {
        case 1: return cut(min(9, most), min(9, most), min(9, most), min(9, most))
        case 2: return cut(min(14, most), 2, min(14, most), 2)
        case 3: return Path(roundedRect: r, cornerRadius: min(20, most))
        case 4: return Path(roundedRect: r, cornerRadius: 3)
        case 5: return Path(roundedRect: r, cornerRadius: min(15, most))
        case 7: return Path(r)
        case 8: return cut(2, min(14, most), 2, min(14, most))
        default: return Path(roundedRect: r, cornerRadius: 10)
        }
    }
}

/// A small on/off pill for the footer.
struct Pill: View {
    var text: String; var on: Bool; var tint: Color = Ink.ice; var width: CGFloat? = nil; var tip: String; var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(text).font(.system(size: 9, weight: .heavy, design: .rounded)).tracking(1.5)
                .foregroundColor(on ? .black : Ink.mid).fixedSize().frame(width: width ?? (text.count > 5 ? 58 : 46), height: 18)
                .background(Capsule().fill(on ? tint : Color.white.opacity(0.07))).contentShape(Rectangle())
        }.buttonStyle(.plain).help(tip)
    }
}

struct Tile<Bottom: View>: View {
    var title: String; var big: String; var unit: String; var sub: String; var tint: Color = .white
    @ViewBuilder var bottom: Bottom
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            label(title)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(big).font(digits(22, .bold)).foregroundColor(tint)
                Text(unit).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundColor(Ink.dim)
            }.padding(.top, 4)
            Text(sub).font(digits(10, .medium)).foregroundColor(Ink.dim).lineLimit(1).padding(.top, 2)
            Spacer(minLength: 3)
            bottom.frame(height: 15)
        }
        .padding(.horizontal, 13).padding(.vertical, 10).frame(maxWidth: .infinity, minHeight: 96, maxHeight: 96, alignment: .leading)
        .background(TileShape().fill(Ink.tileFill))
        .overlay(TileShape().stroke(Ink.tileLine, lineWidth: 1))
    }
}
struct Bar: View {
    var value: Double; var color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Rectangle().fill(color).frame(width: g.size.width).scaleEffect(x: CGFloat(min(1, max(0.02, value))), y: 1, anchor: .leading)
            }
        }.frame(height: 4).clipShape(Capsule()).frame(maxHeight: .infinity, alignment: .bottom).animation(spring, value: value)
    }
}

/// The battery bar as ten cells, drawn with Core Animation so its motion costs nothing on the CPU.
///   charging: calm green cells, the next cell to fill breathes slowly, and a soft sheen glides across the charge (2.8 s)
///   plugged in, not charging (held by a charge limit): calm green, still
///   on battery: green cells, still; at 15 % or less they turn red and the last cells blink like a warning light
struct ChargeBar: NSViewRepresentable {
    enum Mode: Equatable { case charging, held, battery, low }
    var value: Double; var mode: Mode
    func makeNSView(context: Context) -> ChargeBarView { ChargeBarView() }
    func updateNSView(_ v: ChargeBarView, context: Context) { v.set(value: value, mode: mode) }
}
/// The same ten cells, still, in plain SwiftUI: only for the preview pictures, which cannot draw the live bar.
struct ChargeCells: View {
    var value: Double; var mode: ChargeBar.Mode
    var body: some View {
        let filled = max(mode == .low ? 1 : 0, min(10, Int((value * 10).rounded(.up))))
        let c = mode == .low ? Ink.red : Ink.green
        HStack(spacing: 3) {
            ForEach(0..<10, id: \.self) { i in
                Capsule().fill(i < filled ? AnyShapeStyle(LinearGradient(colors: [c.opacity(0.8), c], startPoint: .top, endPoint: .bottom))
                                          : AnyShapeStyle(Color.white.opacity(i == filled && mode == .charging ? 0.3 : 0.08)))
                    .shadow(color: i < filled && mode != .battery ? c.opacity(0.55) : .clear, radius: 3)
            }
        }
    }
}
final class ChargeBarView: NSView {
    private var key = ""; private var value = 0.0; private var mode = ChargeBar.Mode.battery
    private let cells = 10
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }
    func set(value: Double, mode: ChargeBar.Mode) { self.value = value; self.mode = mode; needsLayout = true }
    override func layout() {
        super.layout()
        let filled = max(mode == .low ? 1 : 0, min(cells, Int((value * Double(cells)).rounded(.up))))
        let k = "\(filled) \(mode) \(Int(bounds.width)) \(Int(bounds.height))"
        guard k != key, bounds.width > 20, let root = layer else { return }
        key = k
        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        let h: CGFloat = 6, gap: CGFloat = 3, y: CGFloat = 0
        let w = (bounds.width - gap * CGFloat(cells - 1)) / CGFloat(cells)
        let green = NSColor(Ink.green), red = NSColor(Ink.red)
        let base = mode == .low ? red : green
        let charge = CALayer(); charge.frame = bounds; root.addSublayer(charge)      // holds the filled cells, so the sheen stays inside them
        let mask = CALayer(); mask.frame = bounds; charge.mask = mask
        for i in 0..<cells {
            let r = CGRect(x: CGFloat(i) * (w + gap), y: y, width: w, height: h)
            let empty = CALayer(); empty.frame = r; empty.cornerRadius = h / 2; empty.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
            root.insertSublayer(empty, below: charge)
            if i < filled {
                let c = CAGradientLayer(); c.frame = r; c.cornerRadius = h / 2
                c.colors = [base.mix(0.25, .white).cgColor, base.cgColor]; c.startPoint = CGPoint(x: 0.5, y: 1); c.endPoint = CGPoint(x: 0.5, y: 0)
                c.shadowColor = base.cgColor; c.shadowRadius = 3; c.shadowOpacity = mode == .battery ? 0 : 0.55; c.shadowOffset = .zero
                charge.addSublayer(c)
                let m = CALayer(); m.frame = r.insetBy(dx: -1, dy: -4); m.backgroundColor = NSColor.white.cgColor; mask.addSublayer(m)
                if mode == .low, i >= filled - 2 {        // the warning: the last cells blink
                    let a = CABasicAnimation(keyPath: "opacity"); a.fromValue = 1; a.toValue = 0.15; a.duration = 0.45
                    a.autoreverses = true; a.repeatCount = .infinity; a.timingFunction = CAMediaTimingFunction(name: .easeIn); c.add(a, forKey: "warn")
                }
            } else if i == filled, mode == .charging {      // the next cell to fill, breathing in slowly
                let n = CALayer(); n.frame = r; n.cornerRadius = h / 2; n.backgroundColor = green.cgColor
                n.shadowColor = green.cgColor; n.shadowRadius = 4; n.shadowOpacity = 0.8; n.shadowOffset = .zero
                let a = CABasicAnimation(keyPath: "opacity"); a.fromValue = 0.08; a.toValue = 0.75; a.duration = 1.4
                a.autoreverses = true; a.repeatCount = .infinity; a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut); n.add(a, forKey: "breathe")
                root.addSublayer(n)
            }
        }
        if mode == .charging, filled > 0 {      // a soft light gliding across the charge, left to right, again and again
            let end = CGFloat(filled) * (w + gap)
            let sheen = CAGradientLayer(); sheen.bounds = CGRect(x: 0, y: 0, width: 46, height: h + 8); sheen.position = CGPoint(x: -30, y: h / 2)
            sheen.startPoint = CGPoint(x: 0, y: 0.5); sheen.endPoint = CGPoint(x: 1, y: 0.5)
            sheen.colors = [NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0.75).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
            charge.addSublayer(sheen)
            let a = CABasicAnimation(keyPath: "position.x"); a.fromValue = -30; a.toValue = end + 30; a.duration = 1.6
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            let g = CAAnimationGroup(); g.animations = [a]; g.duration = 2.8; g.repeatCount = .infinity      // 1.6 s glide, 1.2 s rest
            sheen.add(g, forKey: "glide")
        }
    }
}

// ---------- The panel ----------
struct Panel: View {
    @ObservedObject var m: Model
    @State private var loginOn = SMAppService.mainApp.status == .enabled
    var quit: () -> Void = {}
    var solid = false      // true only for the preview picture; live, the backdrop view sits behind
    private func v(_ x: Double) -> Double { m.rev ?? x }
    private var parked: Bool { !m.engine || m.cranking }       // engine off: the push-to-start button sits over the gauges
    private var odo: String {
        let t = Int(m.s.uptime); return String(format: "%02dd %02dh %02dm", t / 86400, (t % 86400) / 3600, (t % 3600) / 60)
    }
    private func w(_ x: Double?) -> String { x.map { String(format: "%.1f", $0) } ?? "--" }
    @ViewBuilder private var recordsRow: some View {
            // records
            Button(action: { m.resetRecords() }) {
                HStack(spacing: 0) {
                    HStack(spacing: 6) { Image(systemName: "trophy.fill").font(.system(size: 9)).foregroundColor(Ink.amber); label("RECORDS") }
                    Spacer()
                    ForEach(Array([("HOTTEST", String(format: "%.0f °C", m.records[0])), ("PEAK POWER", String(format: "%.1f W", m.records[1])),
                                   ("TOP DOWNLOAD", { let r = rate(m.records[2]); return "\(r.0) \(r.1)" }())].enumerated()), id: \.offset) { i, e in
                        HStack(spacing: 7) { label(e.0, 8.5); Text(e.1).font(digits(11, .bold)).foregroundColor(Ink.amber) }.frame(width: 172, alignment: .trailing)
                    }
                }
                .padding(.horizontal, 13).frame(height: 30)
                .background(TileShape().fill(Ink.tileFill)).overlay(TileShape().stroke(Ink.tileLine, lineWidth: 1))
                .contentShape(Rectangle())
            }.buttonStyle(.plain).help("All-time highs on this Mac. Click to reset.")
    }
    @ViewBuilder private var usbBay: some View {
        let s = m.s
            // USB bay
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    label("CONNECTED")
                    Spacer()
                    let total = s.usb.reduce(0) { $0 + $1.mA }
                    Text(String(format: "%d USB · %d WIRELESS · %d mA · %.1f W REQUESTED", s.usb.count, s.wireless.count, total, Double(total) * 5 / 1000)).font(digits(9.5, .medium)).foregroundColor(Ink.dim)
                }
                HStack(alignment: .center, spacing: 10) {
                    PortMap(lit: Set(s.usb.compactMap { $0.depth == 0 ? m.slot($0.port) : nil }), charger: m.slot(s.chargerSocket))
                    VStack(alignment: .leading, spacing: 3) {
                        let room = 8 - (s.chargerSocket > 0 ? 1 : 0)       // eight compact rows is what fits the screen
                        if s.chargerSocket > 0 {
                            HStack(spacing: 8) {
                                Circle().fill(Ink.amber).frame(width: 5, height: 5)
                                Text("Charger").font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(.white).lineLimit(1).layoutPriority(1)
                                Text(s.adapterName.replacingOccurrences(of: " Power Adapter", with: "").uppercased()).font(.system(size: 8, weight: .semibold, design: .rounded)).tracking(1).foregroundColor(Ink.dim).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(m.slot(s.chargerSocket).map { PortMap.names[$0] } ?? "USB-C").font(.system(size: 7.5, weight: .bold, design: .rounded)).tracking(0.8).foregroundColor(Ink.amber)
                                    .frame(width: 92, height: 13).background(Capsule().fill(Ink.amber.opacity(0.10)))
                                Text("POWER IN").font(digits(9.5, .semibold)).foregroundColor(Ink.ice).frame(width: 62, alignment: .trailing)
                                Text("\(s.adapterW) W").font(digits(9.5, .semibold)).foregroundColor(Ink.amber).frame(width: 44, alignment: .trailing)
                            }.frame(height: 15)
                        }
                        if s.usb.isEmpty && s.wireless.isEmpty && s.chargerSocket == 0 {
                            Text("Nothing plugged in").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(Ink.dim).frame(maxWidth: .infinity, alignment: .leading).frame(height: 15)
                        }
                        ForEach(s.usb.prefix(room)) { d in
                            HStack(spacing: 8) {
                                Circle().fill(Ink.green).frame(width: 5, height: 5).padding(.leading, CGFloat(min(d.depth, 3)) * 12)
                                Text(d.name).font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(.white).lineLimit(1).layoutPriority(1)
                                Text(d.vendor.uppercased()).font(.system(size: 8, weight: .semibold, design: .rounded)).tracking(1).foregroundColor(Ink.dim).lineLimit(1)
                                Spacer(minLength: 4)
                                if d.depth == 0, let at = m.slot(d.port) {
                                    Text(PortMap.names[at]).font(.system(size: 7.5, weight: .bold, design: .rounded)).tracking(0.8).foregroundColor(Ink.green)
                                        .frame(width: 92, height: 13).background(Capsule().fill(Ink.green.opacity(0.10)))
                                } else { Color.clear.frame(width: 92, height: 13) }
                                Text(d.speed).font(digits(9.5, .semibold)).foregroundColor(Ink.ice).frame(width: 62, alignment: .trailing)
                                Text("\(d.mA) mA").font(digits(9.5, .semibold)).foregroundColor(Ink.amber).frame(width: 44, alignment: .trailing)
                            }.frame(height: 15)
                        }
                        ForEach(s.wireless.prefix(max(0, room - min(room, s.usb.count)))) { d in
                            HStack(spacing: 8) {
                                Circle().fill(Ink.blue).frame(width: 5, height: 5)
                                Text(d.name).font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(.white).lineLimit(1).layoutPriority(1)
                                Text(d.kind.uppercased()).font(.system(size: 8, weight: .semibold, design: .rounded)).tracking(1).foregroundColor(Ink.dim).lineLimit(1)
                                Spacer(minLength: 4)
                                Text("WIRELESS").font(.system(size: 7.5, weight: .bold, design: .rounded)).tracking(0.8).foregroundColor(Ink.blue)
                                    .frame(width: 92, height: 13).background(Capsule().fill(Ink.blue.opacity(0.12)))
                                Text(d.left != nil || d.right != nil ? "L \(d.left.map(String.init) ?? "--") · R \(d.right.map(String.init) ?? "--")" : (d.box.map { "CASE \($0)" } ?? ""))
                                    .font(digits(9.5, .semibold)).foregroundColor(Ink.ice).frame(width: 62, alignment: .trailing)
                                Text((d.main ?? (d.left != nil ? d.box : nil)).map { "\($0) %" } ?? ((d.left ?? d.right).map { _ in "" } ?? "--")).font(digits(9.5, .semibold)).foregroundColor(Ink.amber).frame(width: 44, alignment: .trailing)
                            }.frame(height: 15)
                        }
                    }
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 10).background(TileShape().fill(Ink.tileFill)).overlay(TileShape().stroke(Ink.tileLine, lineWidth: 1))
    }
    @ViewBuilder private var footer: some View {
            // footer
            HStack(spacing: 6) {
                Pill(text: "LOGIN", on: loginOn, tip: "Start Redline when you log in") {
                    do { if loginOn { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() } } catch {}
                    loginOn = SMAppService.mainApp.status == .enabled
                }
                // How the engine starts when Redline loads: by itself, or with the push-to-start button (Mac defaults until then).
                HStack(spacing: 0) {
                    ForEach([true, false], id: \.self) { auto in
                        Button(action: { m.setAutoStart(auto) }) {
                            Text(auto ? "AUTO" : "PUSH").font(.system(size: 9, weight: .heavy, design: .rounded)).tracking(1.3)
                                .foregroundColor(m.autoStart == auto ? .black : Ink.mid).fixedSize().frame(width: 42, height: 18)
                                .background(Capsule().fill(m.autoStart == auto ? Ink.ice : Color.clear)).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        .help(auto ? "Redline starts the engine by itself as soon as it has loaded: your look, Touch Bar, fans and NOS straight away, no rev."
                                   : "Redline loads with the Mac left as Apple made it. Open the card from the needle in the menu bar and press the start button: it revs the engine and switches everything on.")
                    }
                }.background(Capsule().fill(Color.white.opacity(0.07)))
                .overlay(Text("START").font(.system(size: 6.5, weight: .heavy, design: .rounded)).tracking(1.2).foregroundColor(Ink.dim).fixedSize().offset(y: -14))
                Pill(text: "VIBE", on: m.vibe && !m.eco && !m.nos, tip: m.eco ? "Lights are off while ECO is on. Your VIBE setting comes back when ECO goes off." : m.nos ? "Lights are off while NOS is on: every bit of power goes to speed. Your VIBE setting comes back when NOS goes off." : parked ? "Start the engine first" : m.vibeNote.isEmpty ? "Lights move with the music, and the Touch Bar takes the underglow look" : m.vibeNote) { m.vibe.toggle(); UserDefaults.standard.set(m.vibe, forKey: "vibe"); m.announce() }
                    .disabled(m.nos || m.eco || parked).opacity(m.nos || m.eco || parked ? 0.55 : 1)       // NOS and ECO are overrides: shown as on, dimmed, not clickable
                Pill(text: "NOS", on: m.nos, tint: Ink.nos, tip: m.engine ? "Full power: Low Power Mode off, screen and keyboard light at maximum and never dimmed, fans at maximum, Mac kept awake, App Nap off, no moving lights, the Mac in NOS red. Click again and it all comes back." : "Start the engine first") { m.toggleNOS() }
                    .disabled(!m.engine).opacity(m.engine ? 1 : 0.45)
                Pill(text: "ECO", on: m.eco, tint: Ink.eco, width: 40,
                     tip: !m.ecoNote.isEmpty ? m.ecoNote : (m.eco ? "ECO is on: Low Power Mode, Bluetooth off, screen low, keyboard light off, fans on auto, no lights. Click to put everything back."
                                                                  : "As little power as possible, for bed: Low Power Mode, Bluetooth off, screen at 15 %, keyboard light off, fans on auto, no lights, Apple's own Touch Bar. Click again and it all comes back.")) { m.toggleECO() }
                HStack(spacing: 6) {
                    let setUp = !m.fanReady || m.fanStale, held = m.fanHeld
                    Pill(text: !m.fanReady ? "FANS SET UP" : (m.fanStale ? "FANS UPDATE" : (m.fansWanted ? "FANS MAX" : "FANS AUTO")), on: !setUp && m.fansWanted && held, tint: Ink.amber, width: setUp ? 86 : 72,
                         tip: !m.fanReady ? "Fan control needs a one-time set-up with your Mac password. Click to start it."
                              : m.fanStale ? "The fan helper was improved. Click to install the new one (asks for your Mac password once more)."
                              : !m.fanNote.isEmpty ? "The Mac did not accept it: \(m.fanNote)"
                              : (m.eco ? "macOS runs the fans while ECO is on" : m.nos ? "Held at maximum while NOS is on"
                                 : !m.engine ? (m.fanOffMax ? "Engine off, fans held at maximum. Click to hand them back to macOS. Starting the engine goes back to your own fan setting." : "Engine off: macOS controls the fans. Click to run them at maximum anyway.")
                                 : (m.fanMax ? "Both fans at their rated maximum (\(m.s.fanTops.map { String(format: "%.0f", $0) }.joined(separator: " and ")) rpm). Click for automatic." : "macOS controls the fans. Click for maximum."))) {
                        if setUp {
                            if Fans.current { m.applyFans() }
                            else if let r = Bundle.main.resourcePath { NSWorkspace.shared.open(URL(fileURLWithPath: r + "/Enable fan control.command")) }
                        } else { m.pressFans() }
                    }.disabled((m.nos || m.eco) && !setUp).opacity((m.nos || m.eco) && !setUp ? 0.55 : 1)
                }
                HStack(spacing: 4) {
                    ForEach(0..<8, id: \.self) { i in
                        Button(action: { Ink.glow = i; UserDefaults.standard.set(i, forKey: "glow"); m.theme = i; m.announce() }) {
                            Circle().fill(Ink.glows[i]).frame(width: 10, height: 10)
                                .saturation(m.nos ? 0.15 : 1).opacity(m.nos ? (m.theme == i ? 0.60 : 0.25) : 1)        // greyed out while NOS runs
                                .overlay(Circle().strokeBorder(Color.white.opacity(m.theme == i ? (m.nos ? 0.40 : 0.95) : 0), lineWidth: 1.5).padding(-2.5))
                        }.buttonStyle(.plain).disabled(m.nos).help(m.nos ? "Locked while NOS is on. \(Ink.glowNames[i]) comes back when you switch NOS off." : Ink.glowNames[i])
                    }
                }.padding(.leading, 4)
                Spacer(minLength: 4)
                Text("© 2026 Ali Razavi").font(.system(size: 9.5, weight: .medium, design: .rounded)).foregroundColor(Ink.dim)
                Button(action: quit) { Text("Quit").font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(Ink.mid) }.buttonStyle(.plain)
                    .padding(.leading, 8)
            }
    }
    @ViewBuilder private var gauges: some View {
        let s = m.s
        let throttled = s.speedLimit < 100
            // header
            HStack(alignment: .center) {
                HStack(spacing: 7) {
                    Image(nsImage: BarIcon.image(load: v(s.cpu), hot: false, scale: 1.0, color: NSColor(Ink.red))).frame(width: 22, height: 16)
                    Text("REDLINE").font(.system(size: 15, weight: .heavy, design: .rounded)).tracking(4).foregroundColor(.white)
                }
                Spacer()
                HStack(spacing: 6) {
                    label("GEAR", 8)
                    Text(s.cpu < 0.05 ? "N" : "\(min(6, Int((s.cpu * 6).rounded(.up))))").font(digits(15, .heavy)).foregroundColor(s.cpu >= 0.8 ? Ink.red : Ink.ice)
                        .frame(width: 24, height: 22).background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.5)))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Ink.line, lineWidth: 1))
                }
                Spacer()
                if throttled {
                    Text("THROTTLED \(s.speedLimit)%").font(.system(size: 9.5, weight: .bold, design: .rounded)).tracking(1.2)
                        .padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(Ink.red)).foregroundColor(.white)
                }
                VStack(alignment: .trailing, spacing: 1) { label("UPTIME", 8); Text(odo).font(digits(12, .semibold)).foregroundColor(Ink.mid) }
                if m.engine && !m.cranking {
                    Button(action: { m.stopEngine() }) {
                        Image(systemName: "power").font(.system(size: 11, weight: .heavy)).foregroundColor(Ink.red)
                            .frame(width: 26, height: 26).background(Circle().fill(Color.black.opacity(0.55)))
                            .overlay(Circle().strokeBorder(Ink.red.opacity(0.55), lineWidth: 1.2)).contentShape(Circle())
                    }.buttonStyle(.plain).padding(.leading, 10)
                    .help("Engine off: Apple's own Touch Bar, macOS fans and normal sleep come back. Your settings wait for the next start.")
                }
            }
            // shift lights
            HStack(spacing: 5) {
                ForEach(0..<20, id: \.self) { i in
                    RoundedRectangle(cornerRadius: min(2.5, Ink.ledRadius * 2)).fill(i >= 16 ? Ink.red : (i >= 11 ? Ink.amber : Ink.green))
                        .opacity(v(s.cpu) * 20 > Double(i) + 0.3 ? 1 : 0.12).frame(height: 5).transformEffect(CGAffineTransform(a: 1, b: 0, c: Ink.ledLean * 2, d: 1, tx: 0, ty: 0))
                }
            }.drawingGroup()
            // dials
            HStack(alignment: .bottom, spacing: 30) {
                Dial(title: "GPU LAST", value: v(s.gpu), peak: m.peakGPU, big: String(format: "%02.0f", s.gpu * 100), unit: "%", sub: s.gpuNote, size: 158)
                Dial(title: "CPU LAST", value: v(s.cpu), peak: m.peakCPU, big: String(format: "%02.0f", s.cpu * 100), unit: "%",
                     sub: s.cpuW.map { String(format: "%.1f W CHIP", $0) } ?? "x10 %", size: 216, numbers: true)
                Dial(title: "MEMORY", value: v(s.mem), peak: m.peakMem, big: String(format: "%.1f", s.memUsedGB), unit: "GB",
                     sub: String(format: "/ %.0f GB · %@", s.memTotalGB, s.pressure >= 4 ? "CRITICAL" : s.pressure == 2 ? "TIGHT" : "CALM"), size: 158, redFrom: 0.85)
            }
            // cores
            VStack(spacing: 8) {
                HStack {
                    label("CORES")
                    Spacer()
                    if !s.hog.isEmpty {
                        HStack(spacing: 5) {
                            label("TOP"); Text(s.hog).font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(Ink.mid).lineLimit(1)
                            Text(String(format: "%.0f%%", s.hogPct)).font(digits(10.5, .bold)).foregroundColor(Ink.amber)
                        }
                    }
                }
                CoreStrip(cores: s.cores.map { v($0) })
            }
            .padding(.horizontal, 13).padding(.vertical, 10).background(TileShape().fill(Ink.tileFill)).overlay(TileShape().stroke(Ink.tileLine, lineWidth: 1))
    }
    @ViewBuilder private var tiles: some View {
        let s = m.s
            HStack(spacing: 10) {
                Tile(title: "POWER IN", big: s.plugged ? (s.dcInW != nil ? w(s.dcInW) : "\(s.adapterW)") : "0.0", unit: "W",
                     sub: s.plugged ? "CHARGER \(s.adapterW) W" : "ON BATTERY", tint: s.plugged ? Ink.green : .white) { Spark(data: m.hIn, color: Ink.green, floor: 20) }
                Tile(title: "SYSTEM DRAW", big: w(s.sysW ?? (s.plugged ? nil : abs(s.battW))), unit: "W",
                     sub: "CPU \(w(s.cpuW)) · GPU \(w(s.gpuW))", tint: Ink.amber) { Spark(data: m.hSys, color: Ink.amber, floor: 20) }
                // Plugged in = calm and green, whatever the level. Only on battery does a low level turn red and blink.
                let mode: ChargeBar.Mode = s.plugged ? (s.charging || s.battW > 0.2 ? .charging : .held) : (s.hasBattery && s.battPct <= 15 ? .low : .battery)
                Tile(title: "BATTERY", big: s.hasBattery ? String(format: "%02d", s.battPct) : "--", unit: "%",
                     sub: mode == .charging ? String(format: "CHARGING · +%.1f W", abs(s.battW)) : mode == .held ? (s.battW < -0.5 ? String(format: "PLUGGED IN · −%.1f W", abs(s.battW)) : "PLUGGED IN")
                          : String(format: "%@%.1f W · %.0f%% HEALTH", s.battW >= 0 ? "+" : "−", abs(s.battW), s.health * 100),
                     tint: s.plugged ? Ink.green : (mode == .low ? Ink.red : .white)) {
                    if m.silent { ChargeCells(value: Double(s.battPct) / 100, mode: mode).frame(height: 6).frame(maxHeight: .infinity, alignment: .bottom) }      // preview pictures cannot draw the live bar
                    else { ChargeBar(value: Double(s.battPct) / 100, mode: mode).frame(height: 6).frame(maxHeight: .infinity, alignment: .bottom) }
                }
                    .help(String(format: "%d charge cycles · %.0f%% health · battery %.0f °C", s.cycles, s.health * 100, s.battTemp))
                Tile(title: s.fanForced ? "THERMALS · FANS MAX" : "THERMALS", big: s.cpuTemp.map { String(format: "%.0f", $0) } ?? "--", unit: "°C",
                     sub: "GPU \(s.gpuTemp.map { String(format: "%.0f°", $0) } ?? "--") · LIMIT \(s.speedLimit)%",
                     tint: (s.cpuTemp ?? 0) >= 90 ? Ink.red : .white) {
                    // one small gauge per fan: its speed now, as a share of that fan's own rated maximum
                    HStack(spacing: 10) {
                        ForEach(Array(s.fans.prefix(2).enumerated()), id: \.offset) { i, rpm in
                            let top = s.fanTops.count > i ? s.fanTops[i] : s.fanMax
                            VStack(spacing: 2) {
                                HStack(spacing: 0) {
                                    Text(i == 0 ? "L" : "R").font(.system(size: 7.5, weight: .heavy, design: .rounded)).foregroundColor(Ink.dim)
                                    Spacer(minLength: 2)
                                    Text(String(format: "%.0f", rpm)).font(digits(8.5, .bold)).foregroundColor(s.fanForced ? Ink.amber : Ink.mid)
                                }
                                Bar(value: v(rpm / max(1, top)), color: s.fanForced ? Ink.amber : Ink.ice).frame(height: 4)
                            }.help(String(format: "%@ fan: %.0f of %.0f rpm", i == 0 ? "Left" : "Right", rpm, top))
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                let d = rate(s.down), u = rate(s.up), r = rate(s.read), wr = rate(s.write)
                Tile(title: "NET DOWN", big: d.0, unit: d.1, sub: s.rssi.map { "WI-FI \($0) dBm" } ?? "WI-FI OFF", tint: Ink.ice) { Spark(data: m.hDown, color: Ink.ice, floor: 50_000) }
                Tile(title: "NET UP", big: u.0, unit: u.1, sub: s.txRate.map { String(format: "LINK %.0f Mb/s", $0) } ?? "NO LINK", tint: Ink.ice) { Spark(data: m.hUp, color: Ink.ice, floor: 50_000) }
                Tile(title: "DISK READ", big: r.0, unit: r.1, sub: String(format: "%.1f GB SINCE BOOT", s.readTotal / 1e9)) { Spark(data: m.hRead, color: Ink.mid, floor: 500_000) }
                Tile(title: "DISK WRITE", big: wr.0, unit: wr.1, sub: String(format: "%.1f GB SINCE BOOT", s.writeTotal / 1e9)) { Spark(data: m.hWrite, color: Ink.mid, floor: 500_000) }
            }
    }
    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 10) { gauges; tiles; recordsRow; usbBay }
                .saturation(parked ? 0.15 : 1).opacity(parked ? 0.30 : 1)
                .overlay(Group { if parked { StartButton(m: m, size: 150).transition(.opacity.combined(with: .scale(scale: 1.15))) } })
                .animation(.easeOut(duration: 0.45), value: parked)
            footer
        }
        .id(Ink.active * 2 + (m.nos ? 1 : 0))
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12).frame(width: 672)
        .background(ZStack {
            if solid { LinearGradient(colors: [Ink.bg1, Ink.bg0], startPoint: .top, endPoint: .bottom) }
            Canvas { ctx, sz in     // faint carbon weave
                var p = Path(); var x: CGFloat = -sz.height
                while x < sz.width { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x + sz.height, y: sz.height)); x += 7 }
                ctx.stroke(p, with: .color(.white.opacity(0.022)), lineWidth: 2)
            }.drawingGroup()
        })
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }
}

// ---------- Push to start ----------
// A metal start button in a ring of tick marks, in the colour of the current look. At rest its ring breathes; pressed, it sinks,
// the ticks light up one by one while the Touch Bar part starts (the starter cranking), then the engine revs.
struct StartButton: View {
    @ObservedObject var m: Model; var size: CGFloat = 150
    var body: some View {
        let c = Ink.ice, ticks = 36
        VStack(spacing: size * 0.10) {
            ZStack {
                // tick ring: dim at rest, filling up while cranking
                ForEach(0..<ticks, id: \.self) { i in
                    Capsule().fill(m.cranking ? c : c.opacity(0.22)).frame(width: 2, height: i % 3 == 0 ? size * 0.075 : size * 0.045)
                        .offset(y: -size * 0.62).rotationEffect(.degrees(Double(i) * 360 / Double(ticks)))
                        .opacity(m.cranking ? 1 : (i % 3 == 0 ? 0.9 : 0.6))
                        .animation(m.cranking ? .easeIn(duration: 0.05).delay(Double(i) * 0.022) : .easeOut(duration: 0.2), value: m.cranking)
                }
                // breathing halo
                // (drawn by macOS's own animation engine: as a SwiftUI animation it kept Redline at 12 % CPU for as long as the button was on screen)
                if m.silent { Circle().stroke(c.opacity(0.5), lineWidth: size * 0.05).blur(radius: size * 0.05).frame(width: size * 1.02, height: size * 1.02) }
                else { Halo(color: c).frame(width: size * 1.35, height: size * 1.35).allowsHitTesting(false) }
                Button(action: { guard !m.cranking else { return }; m.onPush?() }) {
                    ZStack {
                        Circle().fill(RadialGradient(colors: [Color(white: 0.30), Color(white: 0.11), Color(white: 0.04)], center: UnitPoint(x: 0.35, y: 0.28), startRadius: 0, endRadius: size * 0.62))
                        Circle().strokeBorder(LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0.05), Color.white.opacity(0.30)], startPoint: .top, endPoint: .bottom), lineWidth: size * 0.035)
                        Circle().strokeBorder(c.opacity(m.cranking ? 1 : 0.85), lineWidth: 2).padding(size * 0.075)
                        VStack(spacing: size * 0.012) {
                            Image(systemName: "power").font(.system(size: size * 0.11, weight: .heavy)).foregroundColor(c)
                            Text("ENGINE").font(.system(size: size * 0.062, weight: .heavy, design: .rounded)).tracking(size * 0.016).foregroundColor(Ink.mid)
                            Text("START").font(.system(size: size * 0.15, weight: .black, design: .rounded)).italic().tracking(size * 0.01).foregroundColor(.white)
                            Text("STOP").font(.system(size: size * 0.062, weight: .heavy, design: .rounded)).tracking(size * 0.016).foregroundColor(Ink.dim)
                        }
                    }.frame(width: size, height: size).contentShape(Circle())
                }.buttonStyle(Sink())
            }.frame(width: size * 1.35, height: size * 1.35)
            Text(m.cranking ? "STARTING…" : "PUSH TO START").font(.system(size: 11, weight: .heavy, design: .rounded)).tracking(4).foregroundColor(m.cranking ? c : .white)
        }
    }
}
/// The soft ring around the start button, breathing. One gradient layer whose opacity and size are animated by Core Animation.
struct Halo: NSViewRepresentable {
    var color: Color
    func makeNSView(context: Context) -> HaloView { HaloView() }
    func updateNSView(_ v: HaloView, context: Context) { v.set(NSColor(color)) }
}
final class HaloView: NSView {
    private let ring = CAGradientLayer(); private var tint: NSColor?
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        ring.type = .radial; ring.startPoint = CGPoint(x: 0.5, y: 0.5); ring.endPoint = CGPoint(x: 1, y: 1)
        ring.locations = [0.60, 0.69, 0.755, 0.82, 0.91]      // a blurred ring at the button's edge (the view is 1.35 x the button)
        layer?.addSublayer(ring)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func set(_ c: NSColor) {
        guard c != tint else { return }; tint = c
        ring.colors = [0, 0.22, 0.62, 0.22, 0].map { c.withAlphaComponent($0).cgColor }
    }
    private func breathe() {
        guard window != nil, ring.animation(forKey: "breathe") == nil else { return }
        let o = CABasicAnimation(keyPath: "opacity"); o.fromValue = 0.35; o.toValue = 1
        let z = CABasicAnimation(keyPath: "transform.scale"); z.fromValue = 0.98; z.toValue = 1.03
        let g = CAAnimationGroup(); g.animations = [o, z]; g.duration = 1.6; g.autoreverses = true; g.repeatCount = .infinity
        g.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut); ring.add(g, forKey: "breathe")
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true); ring.frame = bounds; CATransaction.commit()
        breathe()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); breathe() }
}
/// The button sinks a little and darkens while held, like a real one.
struct Sink: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.93 : 1).brightness(configuration.isPressed ? -0.08 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
// ---------- Menu bar needle (drawn in code) ----------
enum BarIcon {
    static func image(load: Double, hot: Bool, scale: CGFloat = 1, color: NSColor = .black) -> NSImage {
        let size = NSSize(width: 22 * scale, height: 16 * scale)
        let img = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.scaleBy(x: scale, y: scale)
            let c = CGPoint(x: 11, y: 4.5), r: CGFloat = 9
            let col = hot ? NSColor(Ink.red) : color
            col.setStroke(); col.setFill(); ctx.setLineCap(.round)
            ctx.setLineWidth(1.6)
            ctx.addArc(center: c, radius: r, startAngle: .pi * 1.02, endAngle: -.pi * 0.02, clockwise: true); ctx.strokePath()
            ctx.setLineWidth(1.1)
            for i in 0...4 {
                let a = CGFloat.pi * (1 - CGFloat(i) / 4)
                ctx.move(to: CGPoint(x: c.x + cos(a) * (r - 1.2), y: c.y + sin(a) * (r - 1.2)))
                ctx.addLine(to: CGPoint(x: c.x + cos(a) * (r - 3.0), y: c.y + sin(a) * (r - 3.0))); ctx.strokePath()
            }
            let a = CGFloat.pi * (1 - CGFloat(min(1, max(0, load))))
            ctx.setLineWidth(1.9)
            ctx.move(to: c); ctx.addLine(to: CGPoint(x: c.x + cos(a) * (r - 3.4), y: c.y + sin(a) * (r - 3.4))); ctx.strokePath()
            ctx.fillEllipse(in: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4))
            return true
        }
        img.isTemplate = !hot && color == .black
        return img
    }
    static func appIcon() -> NSImage {
        NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let box = rect.insetBy(dx: 100, dy: 100)
            let path = CGPath(roundedRect: box, cornerWidth: 185, cornerHeight: 185, transform: nil)
            ctx.addPath(path); ctx.clip()
            let g = CGGradient(colorsSpace: nil, colors: [NSColor(Ink.bg1).cgColor, NSColor(Ink.bg0).cgColor] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
            let c = CGPoint(x: 512, y: 440), r: CGFloat = 290
            ctx.setLineCap(.round)
            for i in 0...24 {
                let f = CGFloat(i) / 24, a = CGFloat.pi * (1.166 - 1.333 * f), major = i % 4 == 0
                ctx.setStrokeColor((f >= 0.8 ? NSColor(Ink.red) : NSColor.white.withAlphaComponent(major ? 0.9 : 0.4)).cgColor)
                ctx.setLineWidth(major ? 16 : 9)
                ctx.move(to: CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r))
                ctx.addLine(to: CGPoint(x: c.x + cos(a) * (r - (major ? 56 : 30)), y: c.y + sin(a) * (r - (major ? 56 : 30)))); ctx.strokePath()
            }
            let a = CGFloat.pi * (1.166 - 1.333 * 0.86)
            ctx.setShadow(offset: .zero, blur: 40, color: NSColor(Ink.red).cgColor)
            ctx.setStrokeColor(NSColor(Ink.red).cgColor); ctx.setLineWidth(22)
            ctx.move(to: CGPoint(x: c.x - cos(a) * 50, y: c.y - sin(a) * 50)); ctx.addLine(to: CGPoint(x: c.x + cos(a) * 215, y: c.y + sin(a) * 215)); ctx.strokePath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setFillColor(NSColor(white: 0.16, alpha: 1).cgColor); ctx.fillEllipse(in: CGRect(x: c.x - 46, y: c.y - 46, width: 92, height: 92))
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.3).cgColor); ctx.setLineWidth(5); ctx.strokeEllipse(in: CGRect(x: c.x - 46, y: c.y - 46, width: 92, height: 92))
            return true
        }
    }
}

// ---------- The Touch Bar is optional ----------
/// True only on a Mac that has a Touch Bar. Everything else in Redline works the same without one.
func macHasTouchBar() -> Bool {
    guard let lib = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW), let sym = dlsym(lib, "DFRGetScreenSize") else { return false }
    typealias SizeCall = @convention(c) () -> CGSize
    return unsafeBitCast(sym, to: SizeCall.self)().width > 0
}
/// The Touch Bar part (Glowstrip) lives inside Redline.app. Redline starts it on a Mac with a Touch Bar and stops it when Redline quits.
let touchBarApp = Bundle.main.bundlePath + "/Contents/Helpers/Glowstrip.app"
func startTouchBarCompanion(rev: Bool) {
    DispatchQueue.global(qos: .utility).async {
        // `defaults write local.redline touchBar -bool false` keeps Apple's own Touch Bar (the restore script sets this).
        guard UserDefaults.standard.object(forKey: "touchBar") as? Bool ?? true else { return }
        guard macHasTouchBar(), FileManager.default.fileExists(atPath: touchBarApp) else { return }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "local.glowstrip").isEmpty else { return }
        _ = Probe.run("/usr/bin/open", ["-g", "-a", touchBarApp] + (rev ? [] : ["--args", "--norev"]))
    }
}
func stopTouchBarCompanion() {
    for a in NSRunningApplication.runningApplications(withBundleIdentifier: "local.glowstrip") { kill(a.processIdentifier, SIGTERM) }
}

// ---------- App ----------
// ---------- Listening to what the Mac is playing (only while VIBE is on and the card is open) ----------
// A read-only system audio tap: the sound itself is not touched, recorded to disk or sent anywhere.
// It is turned into 48 loudness bars and thrown away.
final class AudioTap {
    static let bands = 48
    private var tapID = AudioObjectID(kAudioObjectUnknown), aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let q = DispatchQueue(label: "redline.audio", qos: .userInteractive), lock = NSLock()
    private var ring = [Float](repeating: 0, count: 1024), fill = 0
    private var levels = [Float](repeating: 0, count: AudioTap.bands), peak: Float = 4
    private var rate = 48_000.0
    private var shape = [Float](repeating: 0, count: 64), shapePeak: Float = 0.05
    private let fft = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!
    private let window: [Float] = { var w = [Float](repeating: 0, count: 1024); vDSP_hann_window(&w, 1024, Int32(vDSP_HANN_NORM)); return w }()
    var running: Bool { procID != nil }

    private func addr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    /// Returns nil when it started, otherwise a short reason.
    func start() -> String? {
        guard !running else { return nil }
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice); var dev = AudioObjectID(0); var sz = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &dev) == noErr else { return "No output device" }
        a = addr(kAudioDevicePropertyDeviceUID); var uidRef: Unmanaged<CFString>?; sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &uidRef) == noErr, let uid = uidRef?.takeRetainedValue() as String? else { return "No output device" }

        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID(); desc.name = "Redline"; desc.isPrivate = true; desc.muteBehavior = .unmuted
        guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr else { tapID = AudioObjectID(kAudioObjectUnknown); return "macOS did not allow listening to system audio" }
        a = addr(kAudioTapPropertyFormat); var fmt = AudioStreamBasicDescription(); sz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioObjectGetPropertyData(tapID, &a, 0, nil, &sz, &fmt) == noErr, fmt.mSampleRate > 0 { rate = fmt.mSampleRate }
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Redline", kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: uid, kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID) == noErr else { stop(); return "Could not open the audio tap" }
        let st = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, q) { [weak self] _, inData, _, _, _ in self?.feed(inData) }
        guard st == noErr, let pid = procID, AudioDeviceStart(aggID, pid) == noErr else { stop(); return "Could not start the audio tap" }
        return nil
    }
    func stop() {
        if aggID != kAudioObjectUnknown {
            if let p = procID { AudioDeviceStop(aggID, p); AudioDeviceDestroyIOProcID(aggID, p) }
            AudioHardwareDestroyAggregateDevice(aggID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil; aggID = AudioObjectID(kAudioObjectUnknown); tapID = AudioObjectID(kAudioObjectUnknown)
        lock.lock(); levels = [Float](repeating: 0, count: AudioTap.bands); fill = 0; lock.unlock()
    }
    private func feed(_ inData: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        guard let buf = list.last, let raw = buf.mData else { return }
        let ch = max(1, Int(buf.mNumberChannels)), frames = Int(buf.mDataByteSize) / (4 * ch)
        let p = raw.assumingMemoryBound(to: Float.self)
        var i = 0
        while i < frames {
            let take = min(frames - i, 1024 - fill)
            for k in 0..<take { ring[fill + k] = p[(i + k) * ch] }
            fill += take; i += take
            if fill == 1024 { analyse(); fill = 0 }
        }
    }
    private func analyse() {
        var x = [Float](repeating: 0, count: 1024); vDSP_vmul(ring, 1, window, 1, &x, 1, 1024)
        var re = [Float](repeating: 0, count: 512), im = [Float](repeating: 0, count: 512), mag = [Float](repeating: 0, count: 512)
        re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { ip in
            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            x.withUnsafeBufferPointer { xp in xp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: 512) { vDSP_ctoz($0, 2, &split, 1, 512) } }
            vDSP_fft_zrip(fft, &split, 1, 10, FFTDirection(FFT_FORWARD))
            vDSP_zvabs(&split, 1, &mag, 1, 512)
        } }
        let n = AudioTap.bands, binHz = Float(rate) / 1024
        var out = [Float](repeating: 0, count: n), top: Float = 0
        for b in 0..<n {
            let f0 = 40 * powf(400, Float(b) / Float(n)), f1 = 40 * powf(400, Float(b + 1) / Float(n))
            let lo = min(511, max(1, Int(f0 / binHz))), hi = min(511, max(lo, Int(f1 / binHz)))
            var v: Float = 0; for k in lo...hi { v = max(v, mag[k]) }
            v *= 1 + Float(b) / 10          // music is quieter up high; lift it so the whole skyline moves
            out[b] = v; top = max(top, v)
        }
        var biggest: Float = 0; vDSP_maxmgv(ring, 1, &biggest, 1024)
        lock.lock()
        shapePeak = max(0.03, max(shapePeak * 0.99, biggest)); for i in 0..<64 { shape[i] = ring[i * 16] / shapePeak }      // the raw wave, for the scope look
        peak = max(4, max(peak * 0.997, top))                 // follows the volume, never amplifies silence
        for b in 0..<n { let v = min(1, out[b] / peak); levels[b] = v > levels[b] ? v : levels[b] * 0.80 + v * 0.20 }
        lock.unlock()
    }
    func read() -> [Float] { lock.lock(); defer { lock.unlock() }; return levels }
    func wave() -> [Float] { lock.lock(); defer { lock.unlock() }; return shape }
}

// ---------- The backdrop: club lighting in plain Core Animation layers behind the gauges ----------
// Each underglow is its own lighting rig, and NOS is a sixth-gear overdrive:
//   ICE · CDJ        silky waves, a spinning jog-wheel ring round the big dial, a few beams
//   NITROUS · LASER  a wide fan of laser beams that sweeps, with a strobe on the kick
//   TOXIC · RADAR    a radar sweep turning behind the big dial, rings from all three dials
//   SUNSET · SUNRISE a striped sun rising behind the big dial, warm waves, slow embers
//   VAPOR · GRID     a neon floor grid rushing towards you under a glowing horizon
//   GALAXY · WARP    stars streaking out from behind the big dial, and a tunnel of rings
//   PRISM · SPECTRUM a full rainbow wheel turning behind the big dial
//   MONO · SCOPE     white on black: the actual sound wave drawn as one crisp mirrored line on a fine graticule
//   NOS              everything at once and fast, racing edge lights, pulsing even in silence
// Everything is symmetric about the centre line and fades out completely in silence.
struct Look {
    var wave: [CGFloat] = [0.22, 0.30, 0.44]; var beams = 0; var strobe: Float = 0; var jog = false; var radar = false; var sun = false
    var sideRings = false; var sparks: Float = 1; var aurora: CGFloat = 0.5; var edge = false; var sweep = 5.0
    var grid = false; var warp = false; var prism = false; var scope = false
}
final class Backdrop: NSView {
    static let looks: [Look] = [
        Look(beams: 6, strobe: 0.10, jog: true),                                                                   // ICE · CDJ
        Look(wave: [0.10, 0.14, 0.22], beams: 14, strobe: 0.30, sparks: 0.6, aurora: 0.40, sweep: 2.4),            // NITROUS · LASER
        Look(wave: [0.00, 0.08, 0.16], strobe: 0.08, radar: true, sideRings: true, sparks: 0.4, aurora: 0.35),     // TOXIC · RADAR
        Look(wave: [0.26, 0.36, 0.50], sun: true, sparks: 0.5, aurora: 0.60),                                      // SUNSET · SUNRISE
        Look(wave: [0.08, 0.12, 0.22], strobe: 0.06, sparks: 0.9, aurora: 0.55, grid: true),                       // VAPOR · GRID
        Look(wave: [0.00, 0.00, 0.10], strobe: 0.12, sparks: 0, aurora: 0.45, warp: true),                         // GALAXY · WARP
        Look(strobe: 0.10, jog: true, sideRings: true, sparks: 1.2, prism: true),                                  // PRISM · SPECTRUM
        Look(wave: [0, 0, 0], sparks: 0, aurora: 0.12, scope: true),                                               // MONO · SCOPE
        Look(wave: [0.20, 0.28, 0.42], beams: 14, strobe: 0.42, jog: true, sideRings: true, sparks: 1.6, aurora: 0.65, edge: true, sweep: 1.1),   // NOS
    ]
    private var look: Look { Backdrop.looks[Ink.active] }
    private let grad = CAGradientLayer(), under = CAGradientLayer(), flashLayer = CALayer(), strobe = CAGradientLayer()
    private let waveBox = CALayer(), waveFade = CAGradientLayer(), ringBox = CALayer(), sparks = CAEmitterLayer()
    private let gridLines = CAShapeLayer(), gridFade = CAGradientLayer(), horizon = CAGradientLayer(), warp = CAEmitterLayer(), tunnel = CALayer(), prism = CAGradientLayer()
    private let scopeBox = CALayer(), scopeGrid = CAShapeLayer(), scopeGlow = CAShapeLayer(), scopeLine = CAShapeLayer(); private var gridPhase: CGFloat = 0
    private let stage = CALayer(), mirror = CAReplicatorLayer(); private var toneFast: CGFloat = 0.3, toneSlow: CGFloat = 0.3, loudSlow: CGFloat = 0, burst: CGFloat = 0
    private let beamBox = CALayer(), jog = CAShapeLayer(), jogMark = CAShapeLayer(), radar = CAGradientLayer(), sun = CAGradientLayer(), sunStripes = CAShapeLayer()
    private var fills: [CAGradientLayer] = [], masks: [CAShapeLayer] = [], beams: [CAGradientLayer] = [], edges: [CAShapeLayer] = []
    private var glows: [CAGradientLayer] = [], aurora: [CAGradientLayer] = [], halos: [CALayer] = []
    private var k: CGFloat = 1, tint = -1, bassAvg: CGFloat = 0, beat: CGFloat = 0, lastRing = 0.0
    private static let points = 21
    private var heights = Array(repeating: [CGFloat](repeating: 0, count: Backdrop.points), count: 3)
    // card geometry at scale 1, measured from the top-left: the three dials and the line the waves rise from
    private let cardW: CGFloat = 672, baseline: CGFloat = 292, dials: [(x: CGFloat, y: CGFloat, r: CGFloat)] = [(336, 177, 108), (119, 206, 79), (553, 206, 79)]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        grad.colors = [NSColor(Ink.bg1).cgColor, NSColor(Ink.bg0).cgColor]; grad.startPoint = CGPoint(x: 0.5, y: 1); grad.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(grad)
        func radial() -> CAGradientLayer { let g = CAGradientLayer(); g.type = .radial; g.startPoint = CGPoint(x: 0.5, y: 0.5); g.endPoint = CGPoint(x: 1, y: 1); g.opacity = 0; return g }
        for _ in 0..<2 { let a = radial(); aurora.append(a); layer?.addSublayer(a) }       // two wide, soft colour clouds, mirrored
        sun.startPoint = CGPoint(x: 0.5, y: 1); sun.endPoint = CGPoint(x: 0.5, y: 0); sun.mask = sunStripes; sun.opacity = 0
        sunStripes.fillColor = NSColor.white.cgColor; stage.addSublayer(sun)
        radar.type = .conic; radar.startPoint = CGPoint(x: 0.5, y: 0.5); radar.endPoint = CGPoint(x: 0.5, y: 0); radar.masksToBounds = true; radar.opacity = 0
        stage.addSublayer(radar)
        for _ in 0..<14 {      // laser beams: thin strips that start behind the big dial
            let b = CAGradientLayer(); b.startPoint = CGPoint(x: 0, y: 0.5); b.endPoint = CGPoint(x: 1, y: 0.5); b.anchorPoint = CGPoint(x: 0, y: 0.5)
            beams.append(b); beamBox.addSublayer(b)
        }
        beamBox.opacity = 0; stage.addSublayer(beamBox)
        // VAPOR: floor grid and horizon
        gridLines.fillColor = nil; gridLines.mask = gridFade; gridLines.opacity = 0; stage.addSublayer(gridLines)
        gridFade.startPoint = CGPoint(x: 0.5, y: 1); gridFade.endPoint = CGPoint(x: 0.5, y: 0)
        gridFade.colors = [NSColor.white.withAlphaComponent(0.05).cgColor, NSColor.white.cgColor]          // faint at the horizon, bright up close
        horizon.startPoint = CGPoint(x: 0, y: 0.5); horizon.endPoint = CGPoint(x: 1, y: 0.5); horizon.opacity = 0; stage.addSublayer(horizon)
        // GALAXY: stars thrown outwards from behind the big dial, and a tunnel of rings that never stops
        let star = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in
            NSGradient(starting: .white, ending: NSColor.white.withAlphaComponent(0))?.draw(in: NSBezierPath(ovalIn: r), relativeCenterPosition: .zero); return true
        }
        let sc = CAEmitterCell(); sc.contents = star.cgImage(forProposedRect: nil, context: nil, hints: nil); sc.name = "star"
        sc.birthRate = 150; sc.lifetime = 1.5; sc.velocity = 300; sc.velocityRange = 170; sc.emissionRange = 2 * .pi; sc.scale = 0.06; sc.scaleSpeed = 0.34; sc.alphaSpeed = -0.35
        warp.emitterCells = [sc]; warp.emitterShape = .point; warp.renderMode = .additive; warp.birthRate = 0; stage.addSublayer(warp)
        tunnel.opacity = 0; stage.addSublayer(tunnel)
        // PRISM: the whole spectrum as a wheel
        prism.type = .conic; prism.startPoint = CGPoint(x: 0.5, y: 0.5); prism.endPoint = CGPoint(x: 0.5, y: 0); prism.masksToBounds = true; prism.opacity = 0
        prism.colors = (0...12).map { NSColor(hue: CGFloat($0 % 12) / 12, saturation: 0.95, brightness: 1, alpha: 0.85).cgColor }
        stage.addSublayer(prism)
        // MONO: oscilloscope
        scopeGrid.fillColor = nil; scopeGrid.strokeColor = NSColor.white.withAlphaComponent(0.07).cgColor; scopeGrid.lineWidth = 1
        for l in [scopeGlow, scopeLine] { l.fillColor = nil; l.lineJoin = .round; l.lineCap = .round }
        for l in [scopeGrid, scopeGlow, scopeLine] { scopeBox.addSublayer(l) }
        scopeBox.opacity = 0; stage.addSublayer(scopeBox)
        stage.masksToBounds = true; layer?.addSublayer(stage)      // sun, radar and beams never spill below the dials
        for i in 0..<5 {
            let g = CAGradientLayer(); g.startPoint = CGPoint(x: 0, y: 0.5); g.endPoint = CGPoint(x: 1, y: 0.5); g.locations = [0, 0.25, 0.5, 0.75, 1]
            let m = CAShapeLayer(); m.lineJoin = .round; m.lineCap = .round
            if i < 3 { m.fillColor = NSColor.white.cgColor; m.strokeColor = nil } else { m.fillColor = nil; m.strokeColor = NSColor.white.cgColor }
            g.mask = m; fills.append(g); masks.append(m); waveBox.addSublayer(g)
        }
        waveFade.colors = [NSColor.white.cgColor, NSColor.white.withAlphaComponent(0.18).cgColor]      // waves melt away towards the bottom
        waveFade.startPoint = CGPoint(x: 0.5, y: 1); waveFade.endPoint = CGPoint(x: 0.5, y: 0)
        waveBox.mask = waveFade; waveBox.opacity = 0
        layer?.addSublayer(waveBox)
        let dot = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            NSGradient(starting: .white, ending: NSColor.white.withAlphaComponent(0))?.draw(in: NSBezierPath(ovalIn: r), relativeCenterPosition: .zero); return true
        }
        let cell = CAEmitterCell(); cell.contents = dot.cgImage(forProposedRect: nil, context: nil, hints: nil)
        cell.birthRate = 40; cell.lifetime = 3.2; cell.lifetimeRange = 1.2; cell.velocity = 34; cell.velocityRange = 18
        cell.emissionLongitude = .pi / 2; cell.emissionRange = 0.35; cell.scale = 0.24; cell.scaleRange = 0.14; cell.alphaSpeed = -0.28; cell.alphaRange = 0.3
        cell.name = "spark"
        sparks.emitterCells = [cell]; sparks.emitterShape = .line; sparks.birthRate = 0; sparks.renderMode = .additive
        // the sparks live on the left half only; a replicator draws their exact mirror image on the right, so they are perfectly symmetric
        mirror.instanceCount = 2; mirror.addSublayer(sparks); layer?.addSublayer(mirror)
        strobe.type = .radial; strobe.startPoint = CGPoint(x: 0.5, y: 0.5); strobe.endPoint = CGPoint(x: 1, y: 1); strobe.opacity = 0
        layer?.addSublayer(strobe)
        for _ in 0..<3 { let g = radial(); glows.append(g); layer?.addSublayer(g) }
        for l in [jog, jogMark] { l.fillColor = nil; l.opacity = 0; layer?.addSublayer(l) }
        layer?.addSublayer(ringBox)
        for _ in 0..<2 { let e = CAShapeLayer(); e.fillColor = nil; e.lineCap = .round; e.opacity = 0; edges.append(e); layer?.addSublayer(e) }
        under.startPoint = CGPoint(x: 0, y: 0.5); under.endPoint = CGPoint(x: 1, y: 0.5); under.opacity = 0
        layer?.addSublayer(under)
        for _ in 0..<20 { let h = CALayer(); h.opacity = 0; halos.append(h); layer?.addSublayer(h) }      // glow behind the shift lights, on the beat
        flashLayer.opacity = 0; layer?.addSublayer(flashLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// NOS engaged: one hard flash across the whole card.
    func flash() {
        flashLayer.backgroundColor = NSColor(Ink.nos).cgColor
        let a = CAKeyframeAnimation(keyPath: "opacity"); a.values = [0.75, 0.1, 0.5, 0]; a.keyTimes = [0, 0.18, 0.3, 1]; a.duration = 0.9
        flashLayer.add(a, forKey: "flash")
    }
    private func centre(_ i: Int) -> CGPoint { CGPoint(x: dials[i].x * k, y: bounds.height - dials[i].y * k) }
    /// The accent colour moved part of the way round the colour wheel towards its partner (the short way), so the middle stays vivid.
    private func toward(_ t: CGFloat) -> NSColor {
        guard let a = NSColor(Ink.ice).usingColorSpace(.deviceRGB), let b = NSColor(Ink.partners[Ink.active]).usingColorSpace(.deviceRGB) else { return NSColor(Ink.ice) }
        var d = b.hueComponent - a.hueComponent; if d > 0.5 { d -= 1 }; if d < -0.5 { d += 1 }
        let h = a.hueComponent + d * t
        return NSColor(hue: h - floor(h), saturation: a.saturationComponent + (b.saturationComponent - a.saturationComponent) * t,
                       brightness: a.brightnessComponent + (b.brightnessComponent - a.brightnessComponent) * t, alpha: 1)
    }
    private func spin(_ l: CALayer, seconds: Double, key: String = "spin") {
        l.removeAnimation(forKey: key)
        let a = CABasicAnimation(keyPath: "transform.rotation.z"); a.fromValue = 0; a.toValue = -2 * Double.pi; a.duration = seconds; a.repeatCount = .infinity
        l.add(a, forKey: key)
    }

    func place(scale: CGFloat) {
        k = scale
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for l in [grad, waveBox, ringBox, flashLayer] as [CALayer] { l.frame = bounds }
        for l in fills as [CALayer] + masks as [CALayer] { l.frame = bounds }
        let top = CGRect(x: 0, y: bounds.height - baseline * k, width: bounds.width, height: baseline * k), c = centre(0), r = dials[0].r * k
        waveFade.frame = top
        stage.frame = top; stage.bounds = top          // same coordinates inside as outside
        // floor grid: from a horizon a third of the way up, down to the baseline
        gridLines.frame = bounds; gridLines.lineWidth = 1.1 * k
        let hy = bounds.height - 150 * k
        gridFade.frame = CGRect(x: 0, y: top.minY, width: bounds.width, height: hy - top.minY)
        horizon.frame = CGRect(x: 0, y: hy - 1.5 * k, width: bounds.width, height: 3 * k)
        warp.frame = bounds; warp.emitterPosition = c
        tunnel.frame = bounds; tunnel.sublayers?.forEach { $0.removeFromSuperlayer() }
        for i in 0..<5 {
            let ringL = CAShapeLayer(); ringL.frame = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
            ringL.path = CGPath(ellipseIn: ringL.bounds, transform: nil); ringL.fillColor = nil; ringL.lineWidth = 1.6 * k; ringL.opacity = 0; ringL.name = "t"
            let grow = CABasicAnimation(keyPath: "transform.scale"); grow.fromValue = 1.0; grow.toValue = 3.4
            let fade = CAKeyframeAnimation(keyPath: "opacity"); fade.values = [0, 0.7, 0]; fade.keyTimes = [0, 0.25, 1]
            let g = CAAnimationGroup(); g.animations = [grow, fade]; g.duration = 2.5; g.repeatCount = .infinity; g.timeOffset = Double(i) * 0.5
            g.timingFunction = CAMediaTimingFunction(name: .easeIn)          // accelerates as it comes at you
            ringL.add(g, forKey: "fly"); tunnel.addSublayer(ringL)
        }
        // a rainbow band around the big dial (a ring, not a disc, so it frames the gauge instead of flooding it)
        let pr = r + 86 * k
        prism.frame = CGRect(x: c.x - pr, y: c.y - pr, width: 2 * pr, height: 2 * pr); spin(prism, seconds: 9)
        let band = CGMutablePath(); band.addEllipse(in: prism.bounds); band.addEllipse(in: prism.bounds.insetBy(dx: 62 * k, dy: 62 * k))
        let hole = CAShapeLayer(); hole.frame = prism.bounds; hole.path = band; hole.fillRule = .evenOdd; prism.mask = hole
        // oscilloscope graticule: a fine square grid centred on the big dial
        for l in [scopeBox, scopeGrid, scopeGlow, scopeLine] as [CALayer] { l.frame = bounds }
        let gp = CGMutablePath(), cell = 42 * k
        var gx = c.x.truncatingRemainder(dividingBy: cell); while gx < bounds.width { gp.move(to: CGPoint(x: gx, y: top.minY)); gp.addLine(to: CGPoint(x: gx, y: bounds.height)); gx += cell }
        var gy = c.y - floor((c.y - top.minY) / cell) * cell; while gy < bounds.height { gp.move(to: CGPoint(x: 0, y: gy)); gp.addLine(to: CGPoint(x: bounds.width, y: gy)); gy += cell }
        scopeGrid.path = gp; scopeLine.lineWidth = 1.8 * k; scopeGlow.lineWidth = 8 * k
        masks[3].lineWidth = 10 * k; masks[4].lineWidth = 1.8 * k
        for (i, g) in glows.enumerated() {
            let size = dials[i].r * 5.2 * k, p = centre(i)
            g.frame = CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
        }
        for (i, a) in aurora.enumerated() {
            let w = 640 * k, h = 440 * k, x = (i == 0 ? 150 : cardW - 150) * k
            a.frame = CGRect(x: x - w / 2, y: bounds.height - 250 * k - h / 2, width: w, height: h)
            let drift = CABasicAnimation(keyPath: "transform.translation.x"); drift.fromValue = 0; drift.toValue = (i == 0 ? 46 : -46) * k
            drift.duration = 7; drift.autoreverses = true; drift.repeatCount = .infinity; drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.add(drift, forKey: "drift")
        }
        // the strobe floods the gauge zone from behind the big dial
        strobe.frame = CGRect(x: c.x - 520 * k, y: c.y - 520 * k, width: 1040 * k, height: 1040 * k)
        // beams share one box that pivots on the big dial's centre
        beamBox.bounds = bounds; beamBox.anchorPoint = CGPoint(x: c.x / max(1, bounds.width), y: c.y / max(1, bounds.height)); beamBox.position = c
        for b in beams { b.bounds = CGRect(x: 0, y: 0, width: 470 * k, height: 3.2 * k); b.position = c }
        // jog wheel: a ring of small segments just outside the big dial, with one bright marker, turning at 33 1/3 rpm
        let jr = CGRect(x: c.x - r - 9 * k, y: c.y - r - 9 * k, width: 2 * (r + 9 * k), height: 2 * (r + 9 * k))
        for l in [jog, jogMark] { l.frame = jr; l.path = CGPath(ellipseIn: l.bounds.insetBy(dx: 3 * k, dy: 3 * k), transform: nil); l.lineWidth = 4 * k }
        let around = 2 * CGFloat.pi * (r + 6 * k), seg = around / 96
        jog.lineDashPattern = [NSNumber(value: Double(seg * 0.42)), NSNumber(value: Double(seg * 0.58))]
        jogMark.lineDashPattern = [NSNumber(value: Double(seg * 2.4)), NSNumber(value: Double(around - seg * 2.4))]
        spin(jog, seconds: 1.8); spin(jogMark, seconds: 1.8)
        // radar: a sweep turning behind the big dial
        let rr = r + 104 * k
        radar.frame = CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr); radar.cornerRadius = rr; spin(radar, seconds: 2.6)
        // sun: a disc behind the big dial, cut into bands that get wider towards the bottom
        let sr = r + 54 * k
        sun.frame = CGRect(x: c.x - sr, y: c.y - sr, width: 2 * sr, height: 2 * sr); sun.cornerRadius = sr; sun.masksToBounds = true
        let bands = CGMutablePath(); var y = 2 * sr, gap = 2 * k
        while y > 0 { let h = max(4 * k, 16 * k - gap); bands.addRect(CGRect(x: 0, y: y - h, width: 2 * sr, height: h)); y -= h + gap; gap += 1.5 * k }
        sunStripes.frame = sun.bounds; sunStripes.path = bands
        mirror.frame = bounds; mirror.instanceTransform = CATransform3DConcat(CATransform3DMakeScale(-1, 1, 1), CATransform3DMakeTranslation(bounds.width, 0, 0))
        sparks.frame = bounds; sparks.emitterPosition = CGPoint(x: bounds.width * 0.27, y: bounds.height - (baseline - 40) * k)
        sparks.emitterSize = CGSize(width: bounds.width * 0.42, height: 1)
        // racing lights along the top and bottom edges (NOS)
        for (i, e) in edges.enumerated() {
            e.frame = bounds; let yy = i == 0 ? bounds.height - 2 * k : 2 * k
            let p = CGMutablePath(); p.move(to: CGPoint(x: 18 * k, y: yy)); p.addLine(to: CGPoint(x: bounds.width - 18 * k, y: yy)); e.path = p
            e.lineWidth = 2.4 * k; e.lineDashPattern = [26, 18]
            let run = CABasicAnimation(keyPath: "lineDashPhase"); run.fromValue = 0; run.toValue = i == 0 ? -44 : 44; run.duration = 0.22; run.repeatCount = .infinity
            e.add(run, forKey: "run")
        }
        under.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 3 * k)
        let hw = (cardW - 32 - 95) / 20.0 * k
        for (i, h) in halos.enumerated() {
            h.frame = CGRect(x: 16 * k + CGFloat(i) * (hw + 5 * k) - 2 * k, y: bounds.height - 54.5 * k - 6 * k, width: hw + 4 * k, height: 12 * k); h.cornerRadius = 6 * k
        }
        CATransaction.commit()
        recolor(force: true)
    }
    private func recolor(force: Bool = false) {
        guard force || tint != Ink.active else { return }
        tint = Ink.active
        let c = NSColor(Ink.ice), c1 = toward(0.5), c2 = toward(1), L = look, white = NSColor.white
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (g, a) in zip(fills, L.wave + [0.30, 1.0]) {      // back, middle, front wave, crest glow, crest line
            g.colors = [c2, c1, c, c1, c2].map { $0.withAlphaComponent(a).cgColor }
        }
        glows[0].colors = [c.withAlphaComponent(0.85).cgColor, c.withAlphaComponent(0.25).cgColor, c.withAlphaComponent(0).cgColor]
        for g in glows[1...] { g.colors = [c1.withAlphaComponent(0.80).cgColor, c1.withAlphaComponent(0.22).cgColor, c1.withAlphaComponent(0).cgColor] }
        aurora.forEach { $0.colors = [c2.withAlphaComponent(L.aurora).cgColor, c1.withAlphaComponent(L.aurora * 0.35).cgColor, c1.withAlphaComponent(0).cgColor] }
        strobe.colors = [c.mix(0.7, white).cgColor, c.withAlphaComponent(0.45).cgColor, c.withAlphaComponent(0).cgColor]
        // beams: fanned evenly either side of straight up, alternating the two colours
        let n = L.beams
        for (i, b) in beams.enumerated() {
            b.isHidden = i >= n; guard i < n else { continue }
            let off = (CGFloat(i) - CGFloat(n - 1) / 2) * (CGFloat.pi * 0.80 / CGFloat(max(1, n - 1)))
            b.setAffineTransform(CGAffineTransform(rotationAngle: .pi / 2 + off))
            let col = (i % 2 == 0 ? c : c2).mix(0.25, white)
            b.colors = [col.withAlphaComponent(0.95).cgColor, col.withAlphaComponent(0.55).cgColor, col.withAlphaComponent(0).cgColor]
        }
        beamBox.removeAnimation(forKey: "sweep")
        if n > 0 {
            let sw = CABasicAnimation(keyPath: "transform.rotation.z"); sw.fromValue = -0.16; sw.toValue = 0.16; sw.duration = L.sweep
            sw.autoreverses = true; sw.repeatCount = .infinity; sw.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut); beamBox.add(sw, forKey: "sweep")
        }
        jog.strokeColor = c.withAlphaComponent(0.85).cgColor; jogMark.strokeColor = white.cgColor
        jog.isHidden = !L.jog; jogMark.isHidden = !L.jog; radar.isHidden = !L.radar; sun.isHidden = !L.sun
        spin(jog, seconds: Ink.active == 8 ? 0.7 : 1.8); spin(jogMark, seconds: Ink.active == 8 ? 0.7 : 1.8)
        radar.colors = [c.withAlphaComponent(0.70).cgColor, c1.withAlphaComponent(0.22).cgColor, c.withAlphaComponent(0).cgColor, c.withAlphaComponent(0).cgColor]
        radar.locations = [0, 0.16, 0.42, 1]
        sun.colors = [toward(1).mix(0.2, white).cgColor, c.cgColor, toward(0.6).cgColor]
        edges.forEach { $0.strokeColor = c.mix(0.35, white).cgColor; $0.isHidden = !L.edge }
        gridLines.strokeColor = c.cgColor; gridLines.isHidden = !L.grid; horizon.isHidden = !L.grid
        horizon.colors = [c2.withAlphaComponent(0).cgColor, c2.cgColor, white.cgColor, c2.cgColor, c2.withAlphaComponent(0).cgColor]
        warp.isHidden = !L.warp; tunnel.isHidden = !L.warp; prism.isHidden = !L.prism; scopeBox.isHidden = !L.scope; waveBox.isHidden = L.scope
        warp.emitterCells?.first?.color = c.blended(withFraction: 0.6, of: white)?.cgColor
        tunnel.sublayers?.enumerated().forEach { ($0.element as? CAShapeLayer)?.strokeColor = ($0.offset % 2 == 0 ? c : c2).cgColor }
        scopeLine.strokeColor = white.cgColor; scopeGlow.strokeColor = c2.withAlphaComponent(0.30).cgColor
        sparks.emitterCells?.first?.color = c.blended(withFraction: 0.45, of: white)?.cgColor
        halos.forEach { $0.backgroundColor = c.withAlphaComponent(0.75).cgColor }
        under.colors = [c2.withAlphaComponent(0).cgColor, c1.cgColor, c.cgColor, c1.cgColor, c2.withAlphaComponent(0).cgColor]
        CATransaction.commit()
    }
    /// A smooth curve through evenly spaced heights (Catmull-Rom), optionally closed down to the baseline.
    private func curve(_ h: [CGFloat], gain: CGFloat, closed: Bool) -> CGPath {
        let left = 16 * k, step = (cardW - 32) * k / CGFloat(h.count - 1), base = bounds.height - baseline * k, top = 226 * k      // stays below the header
        let pts = h.enumerated().map { CGPoint(x: left + CGFloat($0.offset) * step, y: base + min(1, $0.element * gain) * top) }
        let p = CGMutablePath(); p.move(to: pts[0])
        for i in 0..<pts.count - 1 {
            let a = pts[max(0, i - 1)], b = pts[i], c = pts[i + 1], d = pts[min(pts.count - 1, i + 2)]
            p.addCurve(to: c, control1: CGPoint(x: b.x + (c.x - a.x) / 6, y: max(base, b.y + (c.y - a.y) / 6)),
                       control2: CGPoint(x: c.x - (d.x - b.x) / 6, y: max(base, c.y - (d.y - b.y) / 6)))
        }
        if closed { p.closeSubpath() }
        return p
    }
    /// A kick: two rings leave the rim of a dial, the second a moment behind and fainter.
    private func ring(_ dial: Int) {
        let c = centre(dial), r = dials[dial].r * k, col = NSColor(Ink.ice)
        for (delay, alpha, width) in [(0.0, 0.80, 2.6), (0.13, 0.40, 1.4)] as [(Double, Float, CGFloat)] {
            let l = CAShapeLayer(); l.frame = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
            l.path = CGPath(ellipseIn: l.bounds.insetBy(dx: 1, dy: 1), transform: nil)
            l.fillColor = nil; l.strokeColor = col.cgColor; l.lineWidth = width * k; l.opacity = 0
            ringBox.addSublayer(l)
            let grow = CABasicAnimation(keyPath: "transform.scale"); grow.fromValue = 1.0; grow.toValue = dial == 0 ? 1.9 : 1.6
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = alpha; fade.toValue = 0.0
            let thin = CABasicAnimation(keyPath: "lineWidth"); thin.fromValue = width * k; thin.toValue = 0.4 * k
            let g = CAAnimationGroup(); g.animations = [grow, fade, thin]; g.duration = Ink.active == 8 ? 0.6 : 1.1; g.beginTime = CACurrentMediaTime() + delay
            g.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)        // fast out, long glide
            CATransaction.begin(); CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
            l.add(g, forKey: "ring"); CATransaction.commit()
        }
    }
    /// Back to silence, so the next time VIBE comes on nothing from before is left over.
    func reset() { for i in heights.indices { for j in heights[i].indices { heights[i][j] = 0 } } }
    /// What shows behind the dials: 0 = the look's full light show (VIBE on), 1 = only a slow, calm wave (VIBE off),
    /// 2 = only the card's plain dark base (NOS, ECO, engine off). Every other layer of every look is hidden.
    private var mode = 0
    func quiet(_ q: Bool) { show(q ? 2 : 0) }
    private func show(_ m: Int) {
        guard m != mode else { return }
        mode = m; reset()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if m == 0 { for l in layer?.sublayers ?? [] { l.isHidden = false } }
        if m != 2 { recolor(force: true) }      // re-apply this look's colours and which layers it uses
        if m != 0 { hideAllButWave() }
        CATransaction.commit()
    }
    private func hideAllButWave() { for l in layer?.sublayers ?? [] where l !== grad { l.isHidden = mode == 2 || l !== waveBox } }
    func set(_ levels: [Float], wave: [Float] = []) {
        recolor()
        let L = look
        // 11 groups from bass to treble, mirrored so the bass sits in the middle and both edges rest on the baseline
        let n = Backdrop.points, half = n / 2, per = max(1, levels.count / (half + 1))
        var group = [CGFloat](repeating: 0, count: half + 1)
        for g in 0...half { let sl = levels[min(levels.count - 1, g * per)..<min(levels.count, (g + 1) * per)]; group[g] = sl.isEmpty ? 0 : CGFloat(sl.reduce(0, +)) / CGFloat(sl.count) }
        var target = [CGFloat](repeating: 0, count: n)
        for j in 0..<n { let g = abs(j - half), edge = CGFloat(g) / CGFloat(half); target[j] = j == 0 || j == n - 1 ? 0 : group[g] * (1 - 0.55 * edge * edge) }
        let raw = target       // soften neighbours into each other so there is never a spike, only hills
        for j in 1..<n - 1 { target[j] = raw[j - 1] * 0.25 + raw[j] * 0.5 + raw[j + 1] * 0.25 }
        let follow: [CGFloat] = [0.10, 0.20, 0.42], gain: [CGFloat] = [1.15, 0.92, 0.68]       // the back wave is tall and lazy, the front one low and quick
        for i in 0..<3 { for j in 0..<n { heights[i][j] += (target[j] - heights[i][j]) * follow[i] } }
        let loud = CGFloat(levels.max() ?? 0), bass = CGFloat(levels.prefix(6).reduce(0, +) / 6)
        let mid = CGFloat(levels[14..<34].reduce(0, +) / 20), high = CGFloat(levels[34...].reduce(0, +)) / CGFloat(max(1, levels.count - 34))
        let swell = heights[0].max() ?? 0, on = Float(min(1, max(swell, loud) * 5))        // everything fades out completely in silence

        CATransaction.begin(); CATransaction.setDisableActions(true)
        for i in 0..<3 { masks[i].path = curve(heights[i], gain: gain[i], closed: true) }
        let line = curve(heights[2], gain: gain[2], closed: false); masks[3].path = line; masks[4].path = line
        waveBox.opacity = on
        CATransaction.commit()

        // a kick drum = bass jumping well above its recent average
        let now = CACurrentMediaTime(); var hit = false
        if bass > 0.22, bass > bassAvg * 1.3 { beat = 1; if now - lastRing > 0.24 { lastRing = now; hit = true } } else { beat *= 0.80 }
        bassAvg = bassAvg * 0.92 + bass * 0.08
        if hit {
            ring(0); if L.sideRings { ring(1); ring(2) }
            if L.strobe > 0 {      // a hard, short flood of light from behind the big dial
                let f = CABasicAnimation(keyPath: "opacity"); f.fromValue = L.strobe; f.toValue = 0; f.duration = 0.22
                f.timingFunction = CAMediaTimingFunction(name: .easeOut); strobe.add(f, forKey: "hit")
            }
        }
        // Sparks follow the music's mood, not chance. "Tone" is where the weight of the sound sits, from bass (0) to treble (1):
        // when it climbs or the track builds, the sparks are thrown higher and keep rising; when it sinks they hang and drift down.
        // They are released in bursts on the kick, so they move in time.
        let total = levels.reduce(0, +), weighted = levels.enumerated().reduce(Float(0)) { $0 + Float($1.offset) * $1.element }
        let tone = total > 0.05 ? CGFloat(weighted / total) / CGFloat(levels.count) : toneSlow
        toneFast += (tone - toneFast) * 0.18; toneSlow += (tone - toneSlow) * 0.02; loudSlow += (loud - loudSlow) * 0.03
        let lift = min(1, max(0, 0.45 + (toneFast - toneSlow) * 7 + (loud - loudSlow) * 0.8))
        if hit { burst = 1 } else { burst *= 0.72 }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if L.grid {      // the floor rushes towards you, faster when the track is louder; cross-lines spread out as they get close
            gridPhase = (gridPhase + 0.010 + 0.045 * loud).truncatingRemainder(dividingBy: 1)
            let hy = bounds.height - 150 * k, base = bounds.height - baseline * k, cx = bounds.midX, p = CGMutablePath()
            for i in -14...14 { p.move(to: CGPoint(x: cx + CGFloat(i) * 10 * k, y: hy)); p.addLine(to: CGPoint(x: cx + CGFloat(i) * 92 * k, y: base)) }
            for j in 0..<9 { let t = (CGFloat(j) + gridPhase) / 9, y = hy - (hy - base) * t * t; p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: bounds.width, y: y)) }
            gridLines.path = p
        }
        if L.warp { warp.birthRate = on * Float(min(1.5, 0.25 + loud * 1.2)); warp.velocity = Float(0.5 + 1.6 * loud + 0.5 * beat) }
        if L.scope {     // the sound wave itself, mirrored about the centre so it is perfectly symmetric
            let cy = bounds.height - 150 * k, amp = 78 * k, halfW = bounds.width / 2 - 16 * k, n = 32, line = CGMutablePath()
            var pts: [CGPoint] = []
            for i in 0..<n { let v = wave.count > i ? CGFloat(wave[i]) : 0, taper = sin(CGFloat(i) / CGFloat(n - 1) * .pi / 2); pts.append(CGPoint(x: 16 * k + halfW * CGFloat(i) / CGFloat(n - 1), y: cy + max(-1, min(1, v)) * amp * taper)) }
            let all = pts + pts.reversed().map { CGPoint(x: bounds.width - $0.x, y: $0.y) }
            line.move(to: all[0])
            for i in 0..<all.count - 1 { let a = all[max(0, i - 1)], b = all[i], d = all[i + 1], e = all[min(all.count - 1, i + 2)]
                line.addCurve(to: d, control1: CGPoint(x: b.x + (d.x - a.x) / 6, y: b.y + (d.y - a.y) / 6), control2: CGPoint(x: d.x - (e.x - b.x) / 6, y: d.y - (e.y - b.y) / 6)) }
            scopeLine.path = line; scopeGlow.path = line
        }
        sparks.birthRate = Float(min(3, 0.18 * high + 2.4 * burst)) * L.sparks * on
        sparks.velocity = Float(0.45 + 1.9 * lift)
        sparks.setValue((lift - 0.38) * 130 * k, forKeyPath: "emitterCells.spark.yAcceleration")
        CATransaction.commit()

        CATransaction.begin(); CATransaction.setAnimationDuration(0.10)
        for (i, g) in glows.enumerated() {
            let v = i == 0 ? bass : mid * 1.25, sc = 0.70 + 0.50 * v
            g.opacity = Float(min(1, v * 1.5)); g.transform = CATransform3DMakeScale(sc, sc, 1)
        }
        aurora.forEach { $0.opacity = Float(min(1, swell * 1.8)) }      // follows the lazy back wave, so it swells and never flickers
        beamBox.opacity = L.beams > 0 ? on * Float(min(1, 0.20 + high * 1.1 + beat * 0.7)) : 0
        let js = Float(min(1, 0.30 + bass * 0.9)) * on
        jog.opacity = js; jogMark.opacity = on
        radar.opacity = on * Float(min(1, 0.45 + mid * 0.9))
        sun.opacity = on * 0.82; sun.transform = CATransform3DMakeScale(0.94 + 0.14 * bass, 0.94 + 0.14 * bass, 1)
        edges.forEach { $0.opacity = on * Float(0.55 + 0.45 * beat) }
        gridLines.opacity = on * Float(min(1, 0.55 + bass * 0.6)); horizon.opacity = on * Float(min(1, 0.5 + beat * 0.5))
        tunnel.opacity = on * Float(min(1, 0.35 + bass * 0.8)); prism.opacity = on * Float(min(0.75, 0.30 + mid * 0.7 + beat * 0.2))
        scopeBox.opacity = on
        under.opacity = Float(min(1, bass * 1.5))
        for (i, h) in halos.enumerated() { h.opacity = Float(max(0, min(1, beat * 1.9 - abs(CGFloat(i) - 9.5) / 9.5 * 0.7))) }
        CATransaction.commit()
    }
    /// A still frame for the preview pictures.
    func demo() { let w = (0..<64).map { Float(sin(Double($0) * 0.55) * 0.7 + sin(Double($0) * 1.7) * 0.25) }
        for _ in 0..<40 { set((0..<AudioTap.bands).map { Float(0.25 + 0.75 * pow(1 - Double($0) / 48, 1.6)) * Float(0.75 + 0.25 * sin(Double($0) * 0.9)) }, wave: w) } }
}

struct Root: View {
    @ObservedObject var m: Model; var quit: () -> Void
    var body: some View {
        Panel(m: m, quit: quit).fixedSize()
            .scaleEffect(m.scale, anchor: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

final class Card: NSPanel { override var canBecomeKey: Bool { true } }
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model(); var item: NSStatusItem!
    private var card: Card!; private var host: NSHostingController<Root>!; private var measure: NSHostingController<Panel>!
    private let backdrop = Backdrop(frame: .zero)
    private let tap = AudioTap(); private var beat: Timer?
    private var lastStep = -1; private var rows = -1; private var sig: DispatchSourceSignal?; private var termSig: DispatchSourceSignal?; private var nosSig: DispatchSourceSignal?; private var hupSig: DispatchSourceSignal?; private var ecoSig: DispatchSourceSignal?; private var fanSig: DispatchSourceSignal?
    private var outside: Any?; private var keys: Any?; private var watch: AnyCancellable?
    private let sticky = ProcessInfo.processInfo.environment["REDLINE_STICKY"] != nil   // testing only: stay open

    func applicationDidFinishLaunching(_ n: Notification) {
        boot()      // start straight away, also at log-in (the old "wait until the Mac is quiet" delay kept it hidden after restarts)
    }
    private func boot() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = BarIcon.image(load: 0, hot: false)
        item.button?.target = self; item.button?.action = #selector(toggle)
        item.button?.toolTip = "Redline"
        host = NSHostingController(rootView: Root(m: model, quit: { NSApp.terminate(nil) }))
        host.sizingOptions = []          // sized by hand in fit(): automatic sizing re-laid-out the window on every animation frame
        measure = NSHostingController(rootView: Panel(m: model))      // never shown; only asked how tall the card wants to be
        card = Card(contentRect: NSRect(x: 0, y: 0, width: 600, height: 840), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        card.isOpaque = false; card.backgroundColor = .clear; card.hasShadow = true; card.level = .statusBar
        card.isMovableByWindowBackground = true        // drag it anywhere by its background
        card.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        card.appearance = NSAppearance(named: .darkAqua)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 840))
        box.wantsLayer = true; box.layer?.cornerRadius = 16; box.layer?.masksToBounds = true
        for v in [backdrop, host.view] as [NSView] { v.frame = box.bounds; v.autoresizingMask = [.width, .height]; box.addSubview(v) }
        card.contentView = box
        model.onTick = { [weak self] in self?.redraw($0) }
        model.onRedline = { [weak self] in self?.backdrop.flash() }
        model.willNOS = { [weak self] on in self?.nosTransition(on) }
        // Engine off: no wallpaper watching, no wallpaper pictures kept in memory, no 30-a-second light timer.
        model.onEngine = { [weak self] on in
            if on { NOSPaint.start(); DesktopWipe.hold(self?.card.isVisible ?? false) } else { NOSPaint.stop(); DesktopWipe.hold(false) }
        }
        watch = Publishers.MergeMany([model.$engine, model.$cranking, model.$nos, model.$eco, model.$vibe].map { $0.map { _ in () }.eraseToAnyPublisher() })
            .sink { [weak self] _ in DispatchQueue.main.async { self?.syncBeat() } }
        model.onPush = { [weak self] in self?.push() }
        model.start()
        // The Touch Bar part says when its rev begins, so the needles blip at the same moment. Local to this Mac.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("local.glowstrip.ignite"), object: nil, queue: .main) { [weak self] _ in self?.ignited() }
        if model.autoStart { model.startEngine(rev: false) }      // PUSH: nothing appears; the start button is on the card
        // `kill -USR1 <pid>` opens or closes the panel from a script on this Mac (local signal only).
        signal(SIGUSR1, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        src.setEventHandler { [weak self] in self?.toggle() }; src.resume(); sig = src
        // Being told to stop from outside (a rebuild, a shutdown script) counts as quitting too, so the fans are always released.
        // `kill -USR2 <pid>` flips NOS from a script on this Mac, e.g. before a long test run (local signal only).
        signal(SIGUSR2, SIG_IGN)
        let two = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        two.setEventHandler { [weak self] in if self?.model.engine == true { self?.model.toggleNOS() } }; two.resume(); nosSig = two
        // `kill -INFO <pid>` flips ECO (testing hook, local signal only).
        signal(SIGINFO, SIG_IGN)
        let info = DispatchSource.makeSignalSource(signal: SIGINFO, queue: .main)
        info.setEventHandler { [weak self] in self?.model.toggleECO() }; info.resume(); ecoSig = info
        // `kill -HUP <pid>` presses the start button, or switches the engine off when it runs (testing hook, local signal only).
        signal(SIGHUP, SIG_IGN)
        let hup = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
        hup.setEventHandler { [weak self] in guard let s = self else { return }; if s.model.engine && !s.model.cranking { s.model.stopEngine() } else { s.push() } }
        hup.resume(); hupSig = hup
        // `kill -WINCH <pid>` presses the FANS pill (testing hook, local signal only).
        let winch = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        winch.setEventHandler { [weak self] in self?.model.pressFans() }; winch.resume(); fanSig = winch
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { NSApp.terminate(nil) }; term.resume(); termSig = term
    }
    private var screenFrame: NSRect { (card.screen ?? item.button?.window?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900) }
    private func baseSize() -> NSSize { measure.sizeThatFits(in: NSSize(width: 672, height: 10_000)) }
    private var rowCount: Int { min(8, model.s.usb.count + model.s.wireless.count + (model.s.chargerSocket > 0 ? 1 : 0)) }
    private func fit(place: Bool) {
        rows = rowCount
        let base = baseSize(), k = model.scale, size = NSSize(width: base.width * k, height: base.height * k), old = card.frame, vis = screenFrame
        var origin = NSPoint(x: old.minX, y: old.maxY - size.height)      // keep the top-left corner where it is
        if place, let b = item.button?.window?.frame {
            let v = (item.button?.window?.screen ?? NSScreen.main)?.visibleFrame ?? vis
            origin = NSPoint(x: min(max(v.minX + 8, b.midX - size.width / 2), v.maxX - size.width - 8), y: b.minY - size.height - 3)
        } else {
            origin.y = max(vis.minY + 4, origin.y)
        }
        card.setFrame(NSRect(origin: origin, size: size), display: true)
        backdrop.place(scale: k)
    }
    private func redraw(_ load: Double) {
        if card.isVisible, rowCount != rows { fit(place: false) }
        let step = Int((load * 24).rounded()) + (load >= 0.85 ? 100 : 0)
        guard step != lastStep else { return }
        lastStep = step
        item.button?.image = BarIcon.image(load: load, hot: load >= 0.85)
    }
    // ---- NOS in / out ----
    /// A one-off transition, about a second, then nothing keeps running (NOS spends nothing on looks).
    /// In: a shockwave leaves the big dial, a red-hot line sweeps up the card and the NOS look fills in behind it, the needles slam to the redline.
    /// Out: the line comes back down in your underglow colour, cooling the card back to your look, and the needles drop and settle.
    /// Redline's own window as a picture, from the window server. (The call is hidden from new SDKs but still in macOS; an app
    /// may always picture its own windows, no permission needed.) Falls back to drawing the layer tree if it is not there.
    private func windowPicture(_ id: CGWindowID) -> CGImage? {
        typealias Call = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let f = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }      // RTLD_DEFAULT
        // .null rect, optionIncludingWindow (8), boundsIgnoreFraming (1) | bestResolution (8)
        return unsafeBitCast(f, to: Call.self)(CGRect.null, 8, id, 1 | 8)?.takeRetainedValue()
    }
    private func layerPicture(_ root: CALayer, _ size: CGSize) -> CGImage? {
        let px = card.backingScaleFactor
        guard let ctx = CGContext(data: nil, width: Int(size.width * px), height: Int(size.height * px), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: px, y: px); root.render(in: ctx); return ctx.makeImage()
    }
    private func nosTransition(_ on: Bool) {
        guard card.isVisible, let box = card.contentView, let root = box.layer, box.bounds.width > 10 else { return }
        // the card as it looks right now, before the switch redraws it
        // straight from the window server (a few milliseconds; drawing the layer tree again took about a third of a second)
        let wp = windowPicture(CGWindowID(card.windowNumber))
        guard let before = wp ?? layerPicture(root, box.bounds.size) else { return }
        if let dir = ProcessInfo.processInfo.environment["REDLINE_FRAMES"], let png = NSBitmapImageRep(cgImage: before).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "\(dir)/before_\(on ? "in" : "out").png"))      // testing only
        }
        let b = box.bounds, k = b.width / 672, hot = NSColor(Ink.nos), cool = NSColor(Ink.glows[Ink.glow])
        let edgeColour = on ? hot : cool, dur = NOSMove.duration(on)      // out: a slower, smooth swipe down; the colour is always the look being switched TO
        let fx = CALayer(); fx.frame = b; fx.masksToBounds = true; fx.zPosition = 100
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // the old look, cut away by the moving line
        let old = CALayer(); old.frame = b; old.contents = before; old.contentsGravity = .resize
        let cut = CALayer(); cut.backgroundColor = NSColor.white.cgColor
        cut.anchorPoint = on ? CGPoint(x: 0.5, y: 1) : CGPoint(x: 0.5, y: 0)          // in: eaten from the bottom up; out: from the top down
        cut.bounds = b; cut.position = on ? CGPoint(x: b.midX, y: b.maxY) : CGPoint(x: b.midX, y: 0)
        // a wash in the new look's colour over the part already revealed (it sits under the old picture, so it never mixes with the old colour)
        let wash = CAGradientLayer(); wash.frame = b; wash.opacity = 0
        wash.colors = [edgeColour.withAlphaComponent(0.28).cgColor, edgeColour.withAlphaComponent(0.04).cgColor]
        wash.startPoint = CGPoint(x: 0.5, y: on ? 0 : 1); wash.endPoint = CGPoint(x: 0.5, y: on ? 1 : 0)
        fx.addSublayer(wash)
        old.mask = cut; fx.addSublayer(old)
        // the hot line riding the cut: a wide glow, a bright band and a white core
        let line = CALayer(); line.bounds = CGRect(x: 0, y: 0, width: b.width, height: 70 * k); line.position = CGPoint(x: b.midX, y: on ? 0 : b.maxY)
        let glow = CAGradientLayer(); glow.frame = line.bounds
        let core = on ? (edgeColour.blended(withFraction: 0.6, of: .white) ?? .white) : .white      // out: the bright white line
        glow.colors = [edgeColour.withAlphaComponent(0), edgeColour.withAlphaComponent(on ? 0.45 : 0.55), core.withAlphaComponent(0.95), edgeColour.withAlphaComponent(on ? 0.45 : 0.55), edgeColour.withAlphaComponent(0)].map { $0.cgColor }
        glow.locations = on ? [0, 0.40, 0.5, 0.60, 1] : [0, 0.38, 0.5, 0.62, 1]
        line.addSublayer(glow); fx.addSublayer(line)
        // shockwave rings from the big dial (in only)
        let centre = CGPoint(x: 336 * k, y: b.maxY - 177 * k)
        var rings: [CAShapeLayer] = []
        do { for i in 0..<2 {
            let r = CAShapeLayer(); let rad = 108 * k
            r.path = CGPath(ellipseIn: CGRect(x: -rad, y: -rad, width: rad * 2, height: rad * 2), transform: nil); r.position = centre
            r.fillColor = nil; r.strokeColor = (i == 0 ? core : edgeColour).cgColor; r.lineWidth = (i == 0 ? 3 : 9) * k; r.opacity = 0
            r.shadowColor = edgeColour.cgColor; r.shadowRadius = 12 * k; r.shadowOpacity = 1; r.shadowOffset = .zero
            fx.addSublayer(r); rings.append(r)
        } }
        root.addSublayer(fx)
        CATransaction.commit()
        let slow = Double(ProcessInfo.processInfo.environment["REDLINE_SLOW"] ?? "") ?? 1      // testing only: slow motion
        if slow > 1 { fx.speed = Float(1 / slow) }

        let ease = NOSMove.ease(on)      // in: a push that launches; out: a long coast
        NOSMove.pending.append { t0 in
        let curve = ease
        func anim(_ key: String, _ from: Any, _ to: Any, _ d: CFTimeInterval, delay: CFTimeInterval = 0, _ f: CAMediaTimingFunction? = nil) -> CABasicAnimation {
            let a = CABasicAnimation(keyPath: key); a.fromValue = from; a.toValue = to; a.duration = d; a.beginTime = t0 + delay
            a.timingFunction = f ?? curve; a.fillMode = .both; a.isRemovedOnCompletion = false; return a
        }
        cut.add(anim("bounds.size.height", b.height, 0, dur), forKey: "cut")
        line.add(anim("position.y", on ? -35 * k : b.maxY + 35 * k, on ? b.maxY + 35 * k : -35 * k, dur), forKey: "line")
        let w = CAKeyframeAnimation(keyPath: "opacity"); w.values = [0, 1, 0]; w.keyTimes = [0, 0.5, 1]; w.duration = dur + 0.45
        w.beginTime = t0; w.fillMode = .both; w.isRemovedOnCompletion = false; wash.add(w, forKey: "wash")
        for (i, r) in rings.enumerated() {
            let d = 0.75 + 0.15 * Double(i), lag = 0.05 * Double(i), out = CAMediaTimingFunction(name: .easeOut)
            r.add(anim("transform.scale", 0.6, 4.2, d, delay: lag, out), forKey: "grow")
            let o = CAKeyframeAnimation(keyPath: "opacity"); o.values = [0, 1, 0]; o.keyTimes = [0, 0.08, 1]; o.duration = d
            o.beginTime = t0 + lag; o.fillMode = .both; o.isRemovedOnCompletion = false; r.add(o, forKey: "fade")
        }
        }
        // gone completely afterwards: nothing left animating
        DispatchQueue.main.asyncAfter(deadline: .now() + (dur + 0.8) * slow) { fx.removeFromSuperlayer() }
    }
    /// 30 times a second while the card is open: move the lights with the music (VIBE).
    private func pulse() {
        var levels = [Float](repeating: 0, count: AudioTap.bands), wave: [Float] = []
        let vibe = model.vibe && model.engine && !model.cranking && !model.eco && !model.nos      // ECO and NOS: no lights, no listening (NOS spends nothing on looks)
        if vibe {
            if !tap.running { let why = tap.start(); if model.vibeNote != (why ?? "") { model.vibeNote = why ?? "" }; if why != nil { model.vibe = false } }
            levels = tap.read(); wave = tap.wave()
        } else if tap.running { tap.stop() }
        // VIBE on: the underglow's own rig, moving with the music, starting from silence.
        // VIBE off, NOS, ECO or engine off: the plain dark base, nothing moving.
        if vibe { backdrop.quiet(false); backdrop.set(levels, wave: wave) } else { backdrop.quiet(true) }
    }
    /// The 30-a-second light timer runs only while the card is open AND something behind the dials moves (VIBE on, engine on, not NOS, not ECO).
    /// Otherwise the backdrop is set to its plain base once and nothing ticks.
    private func syncBeat() {
        guard card != nil else { return }
        let want = card.isVisible && model.vibe && model.engine && !model.cranking && !model.eco && !model.nos
        if want, beat == nil {
            let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.pulse() }
            RunLoop.main.add(t, forMode: .common); beat = t
        } else if !want, beat != nil { beat?.invalidate(); beat = nil }
        if !want, card.isVisible { pulse() }
    }
    @objc func toggle() { card.isVisible ? close() : open() }
    // ---- Push to start ----
    private var crankTimeout: DispatchWorkItem?
    /// The start button on the card was pressed: crank, then rev when the Touch Bar part is up.
    func push() {
        guard !model.engine else { return }
        model.cranking = true
        model.startEngine(rev: true)
        // No Touch Bar (or it is slow to start)? Rev anyway after a moment.
        let w = DispatchWorkItem { [weak self] in self?.ignited() }; crankTimeout = w
        let tb = UserDefaults.standard.object(forKey: "touchBar") as? Bool ?? true
        DispatchQueue.main.asyncAfter(deadline: .now() + (tb && macHasTouchBar() ? 2.5 : 0.9), execute: w)
    }
    private func ignited() {
        crankTimeout?.cancel(); crankTimeout = nil
        guard model.engine, model.cranking else { return }
        model.revUp()
    }
    private func open() {
        model.setOpen(true)
        pulse()                 // backdrop shown or hidden before the card appears
        fit(place: true)
        card.makeKeyAndOrderFront(nil)
        syncBeat()
        if model.engine { DesktopWipe.hold(true) }
        guard !sticky else { return }
        // A click anywhere outside Redline closes the card; so does Esc.
        outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in self?.close() }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.close(); return nil }
            return e
        }
    }
    private func close() {
        card.orderOut(nil); model.setOpen(false); DesktopWipe.hold(false)
        beat?.invalidate(); beat = nil; tap.stop()      // never listens while the card is closed
        if let o = outside { NSEvent.removeMonitor(o); outside = nil }
        if let k = keys { NSEvent.removeMonitor(k); keys = nil }
    }
    func applicationWillTerminate(_ n: Notification) {
        if model.engine { UserDefaults.standard.set(model.nos, forKey: "nosLast") }       // NOS comes back with the next engine start
        if model.eco { Eco.restore(wait: true) }
        if model.nos { Boost.restore(wait: true) }       // never leave the Mac in ECO when Redline is not there to undo it
        tap.stop(); Fans.set(max: false); stopTouchBarCompanion()
    }      // never leave the fans held when Redline is not there to release them
}

@MainActor func writePNG(_ img: NSImage, _ path: String, px: Int) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: Int(CGFloat(px) * img.size.height / img.size.width), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = img.size
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(origin: .zero, size: img.size)); NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

let args = CommandLine.arguments
if args.count >= 2, args[1] == "--probe" {
    // Prints what the sensor chip answers on this Mac.
    let smc = SMC()
    for k in ["PSTR", "PDTR", "PCPT", "PCPC", "PCTR", "PC0R", "PCPG", "PG0R", "PGTR", "PBLC", "TCXC", "TC0F", "TC0E", "TC0P", "TC0D", "TG0P", "TGDD", "TG0D", "TG1D", "TB0T", "FNum", "F0Ac", "F1Ac", "F0Mx", "F0Mn"] {
        print(k, smc.read(k).map { String(format: "%.2f", $0) } ?? "-")
    }
    let m = Model(); m.sampleNow(); var s = m.s; let usb = s.usb; s.usb = []
    print(s); usb.forEach { print($0) }
    exit(0)
}
if args.count >= 2, args[1] == "--hasbar" { print(macHasTouchBar() ? "yes" : "no"); exit(0) }
if args.count >= 2, args[1] == "--audiotest" {
    // Listens for three seconds and prints how loud the loudest bar got (0 = silence or not allowed).
    let t = AudioTap(); if let why = t.start() { print("could not start:", why); exit(1) }
    var top: Float = 0
    for _ in 0..<30 { Thread.sleep(forTimeInterval: 0.1); top = max(top, t.read().max() ?? 0) }
    t.stop(); print(String(format: "started ok, loudest bar %.2f", top)); exit(0)
}
if args.count >= 3, args[1] == "--render" {
    MainActor.assumeIsolated {
        writePNG(BarIcon.appIcon(), args[2] + "/icon_1024.png", px: 1024)
        writePNG(BarIcon.image(load: 0.35, hot: false, scale: 8, color: .white), args[2] + "/menubar_icon.png", px: 352)
        let m = Model(); m.silent = true; m.sampleNow()
        let parked = Model(); parked.silent = true; parked.s = m.s; parked.park()      // engine off: every dial at rest, as in the live app
        let off = ImageRenderer(content: Panel(m: parked, solid: true)); off.scale = 2
        if let img = off.nsImage { writePNG(img, args[2] + "/panel_off.png", px: Int(img.size.width * 2)) }
        m.engine = true
        let r = ImageRenderer(content: Panel(m: m, solid: true)); r.scale = 2
        if let img = r.nsImage { writePNG(img, args[2] + "/panel.png", px: Int(img.size.width * 2)) }
        // every look, with its lighting frozen mid-song
        for (i, name) in ["ice", "nitrous", "toxic", "sunset", "vapor", "galaxy", "prism", "mono", "nos"].enumerated() {
            Ink.glow = min(i, 7); Ink.nosOn = i == 8; m.theme = Ink.glow; m.nos = i == 8
            let clear = ImageRenderer(content: Panel(m: m)); clear.scale = 2
            guard let top = clear.nsImage else { continue }
            let b = Backdrop(frame: NSRect(origin: .zero, size: top.size)); b.layoutSubtreeIfNeeded(); b.place(scale: 1); b.demo()
            let both = NSImage(size: top.size, flipped: false) { rect in
                guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
                b.layer?.render(in: ctx); top.draw(in: rect); return true
            }
            writePNG(both, args[2] + "/look_\(name).png", px: Int(top.size.width * 2))
        }
    }
    exit(0)
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
