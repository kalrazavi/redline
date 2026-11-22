// Copyright (c) 2026 Ali Razavi. All rights reserved. Owned and controlled solely by Ali Razavi: no licence check, no remote control, no backdoor. Terms: see the LICENSE file.
import AppKit
import SwiftUI
import ServiceManagement
import IOKit
import IOKit.pwr_mgt
import CoreWLAN
import CoreAudio
import AudioToolbox
import Accelerate
import AVFoundation

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
    var hog = ""; var hogPct = 0.0
    var uptime: TimeInterval = 0
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
        s.gpuNote = seenAMD && seenIntel ? String(format: "RADEON %02.0f · INTEL %02.0f", amd, intel) : (seenAMD ? "RADEON" : seenIntel ? "INTEL" : "GPU")

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
        return out
    }
}

// ---------- The model the panel watches ----------
final class Model: ObservableObject {
    @Published var s = Snap()
    @Published var theme = Ink.glow
    @Published var wide = false                                         // two-column layout, chosen by how far the corner is dragged
    @Published var scale: CGFloat = 1                                   // card size; always back to 1 when it opens
    @Published var vibe = UserDefaults.standard.bool(forKey: "vibe")    // music-reactive backdrop
    @Published var vibeNote = ""
    @Published var sfx = (UserDefaults.standard.object(forKey: "sfx") as? Bool) ?? true     // ignition sound
    @Published var nos = false                                                              // Coffee Mode is holding the Mac awake
    /// All-time highs: CPU temperature (°C), whole-Mac draw (W), download speed (bytes/s).
    @Published var records: [Double] = Model.savedRecords()
    private var rec: [Double] = Model.savedRecords()
    static func savedRecords() -> [Double] { (UserDefaults.standard.array(forKey: "records") as? [Double]).flatMap { $0.count == 3 ? $0 : nil } ?? [0, 0, 0] }
    func resetRecords() { rec = [0, 0, 0]; records = rec; UserDefaults.standard.set(rec, forKey: "records") }
    var onNOS: (() -> Void)?
    static func coffeeOn() -> Bool { (String(data: Probe.run("/usr/bin/pmset", ["-g", "assertions"]), encoding: .utf8) ?? "").contains("Coffee Mode") }
    func refreshNOS() { DispatchQueue.global(qos: .utility).async { let on = Model.coffeeOn(); DispatchQueue.main.async { if self.nos != on { self.nos = on } } } }
    /// NOS: flips Coffee Mode (the keep-awake app) with the same local signal its own menu uses.
    func toggleNOS() {
        DispatchQueue.global(qos: .userInitiated).async {
            func pid() -> String { (String(data: Probe.run("/usr/bin/pgrep", ["-x", "CoffeeMode"]), encoding: .utf8) ?? "").split(separator: "\n").first.map(String.init) ?? "" }
            if pid().isEmpty { _ = Probe.run("/usr/bin/open", ["-a", "Coffee Mode"]); Thread.sleep(forTimeInterval: 1.5) }
            let p = pid()
            if !p.isEmpty { _ = Probe.run("/bin/kill", ["-USR1", p]); Thread.sleep(forTimeInterval: 0.5) }
            let on = Model.coffeeOn()
            DispatchQueue.main.async { self.nos = on; if on { self.onNOS?() } }
        }
    }
    /// Where each socket (1-4) physically sits: 0 top-left, 1 bottom-left, 2 top-right, 3 bottom-right ("top" = by the hinge). Click a badge to correct it.
    @Published var portMap: [Int] = (UserDefaults.standard.array(forKey: "portMap") as? [Int]).flatMap { $0.count == 4 ? $0 : nil } ?? [1, 0, 2, 3]     // as Ali described his MacBook Pro: sockets 1/2 on the left, 3/4 on the right
    func cyclePort(_ socket: Int) {
        guard (1...4).contains(socket) else { return }
        let next = (portMap[socket - 1] + 1) % 4
        if let other = portMap.firstIndex(of: next) { portMap[other] = portMap[socket - 1] }
        portMap[socket - 1] = next
        UserDefaults.standard.set(portMap, forKey: "portMap")
    }
    @Published var sweep = false          // "ignition": every needle swings to the top once when the panel opens
    @Published var peakCPU = 0.0; @Published var peakGPU = 0.0; @Published var peakMem = 0.0
    @Published var hDown: [Double] = Array(repeating: 0, count: 60); @Published var hUp: [Double] = Array(repeating: 0, count: 60)
    @Published var hRead: [Double] = Array(repeating: 0, count: 60); @Published var hWrite: [Double] = Array(repeating: 0, count: 60)
    @Published var hSys: [Double] = Array(repeating: 0, count: 60); @Published var hIn: [Double] = Array(repeating: 0, count: 60)
    var onTick: ((Double) -> Void)?

    private let probe = Probe(); private let q = DispatchQueue(label: "redline.sample", qos: .utility)
    private var work = Snap(); private var timer: DispatchSourceTimer?; private var open = false; private var n = 0
    private var busySlow = false
    private lazy var sockets = probe.socketTable()

    func start() { schedule(2.0) }
    private func schedule(_ every: Double) {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 0.05, repeating: every, leeway: .milliseconds(every > 1 ? 300 : 30))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume(); timer = t
    }
    func setOpen(_ o: Bool) {
        q.async { self.open = o; self.n = 0; if o { self.probe.resetRates() } }
        if o { refreshNOS() }
        if o {
            peakCPU = 0; peakGPU = 0; peakMem = 0
            sweep = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.sweep = false }
        }
        schedule(o ? 1.0 : 2.0)
    }
    private func tick() {
        if open {
            probe.full(into: &work)
            if n % 3 == 0 || n % 10 == 0, !busySlow {      // slower readings, off the fast path
                busySlow = true; let doUSB = n % 10 == 0
                DispatchQueue.global(qos: .utility).async {
                    let h = Probe.hog(); let u = doUSB ? Probe.usb(sockets: self.sockets) : nil
                    self.q.async { (self.work.hog, self.work.hogPct) = h; if let u = u { self.work.usb = u }; self.busySlow = false }
                }
            }
            n += 1
        } else { probe.cpuOnly(into: &work); probe.light(into: &work) }
        let snap = work, isOpen = open, settled = n > 2
        DispatchQueue.main.async {
            self.onTick?(snap.cpu)
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
        (work.hog, work.hogPct) = Probe.hog(); work.usb = Probe.usb(sockets: sockets); s = work
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
    static let glows: [Color] = [Color(red: 0.25, green: 0.90, blue: 1.0), Color(red: 0.72, green: 0.45, blue: 1.0),
                                 Color(red: 0.45, green: 1.0, blue: 0.35), Color(red: 1.0, green: 0.55, blue: 0.15)]
    static let glowNames = ["ICE", "NITROUS", "TOXIC", "SUNSET"]
    static let nos = Color(red: 0.72, green: 0.45, blue: 1.0)
    static var glow = UserDefaults.standard.integer(forKey: "glow") % 4
    static var ice: Color { glows[glow] }
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.20)
    static let red = Color(red: 1.0, green: 0.27, blue: 0.23), green = Color(red: 0.35, green: 0.92, blue: 0.60)
    static let dim = Color.white.opacity(0.42), mid = Color.white.opacity(0.68)
}
func label(_ t: String, _ size: CGFloat = 9.5) -> some View {
    Text(t).font(.system(size: size, weight: .semibold, design: .rounded)).tracking(1.6).foregroundColor(Ink.dim)
}
func digits(_ size: CGFloat, _ w: Font.Weight = .semibold) -> Font { .system(size: size, weight: w, design: .rounded).monospacedDigit() }
func rate(_ v: Double) -> (String, String) {
    if v < 999_500 { return (String(format: "%.0f", v / 1000), "KB/s") }
    if v < 999_500_000 { return (String(format: "%.1f", v / 1_000_000), "MB/s") }
    return (String(format: "%.2f", v / 1_000_000_000), "GB/s")
}
let spring = Animation.timingCurve(0.34, 1.45, 0.64, 1, duration: 0.5)

// ---------- A dial ----------
func dialDeg(_ f: Double) -> Double { 150 + 240 * min(1, max(0, f)) }

/// The parts of a dial that never move: drawn once and kept as a picture.
struct DialFace: View, Equatable {
    var size: CGFloat; var numbers: Bool; var redFrom: Double; var hot: Bool; var theme: Int
    var body: some View {
        let r = size / 2
        ZStack {
            Circle().fill(RadialGradient(colors: [Ink.bg1, Ink.bg0], center: .center, startRadius: 0, endRadius: r))
            Circle().strokeBorder(LinearGradient(colors: hot ? [Ink.red, Ink.red.opacity(0.25)] : [Color.white.opacity(0.16), Color.white.opacity(0.02)], startPoint: .top, endPoint: .bottom), lineWidth: hot ? 2.5 : 1.5)
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
            DialFace(size: size, numbers: numbers, redFrom: redFrom, hot: hot, theme: Ink.glow).equatable()
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
                    Text(big).font(digits(size * 0.15, .bold)).foregroundColor(.white)
                    Text(unit).font(.system(size: size * 0.06, weight: .semibold, design: .rounded)).foregroundColor(Ink.dim)
                }
                label(title, max(8.5, size * 0.05))
                Text(sub).font(digits(max(8, size * 0.043), .medium)).foregroundColor(Ink.dim).padding(.top, 1).lineLimit(1)
            }.offset(y: size * 0.29)
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
                            RoundedRectangle(cornerRadius: 1.5).fill(k >= segs - 2 ? Ink.red : (k >= segs - 4 ? Ink.amber : Ink.ice))
                                .opacity(on ? 1 : 0.10)
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

/// A small on/off pill for the footer.
struct Pill: View {
    var text: String; var on: Bool; var tint: Color = Ink.ice; var tip: String; var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(text).font(.system(size: 9, weight: .heavy, design: .rounded)).tracking(1.5)
                .foregroundColor(on ? .black : Ink.mid).frame(width: 46, height: 18)
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
            Text(sub).font(digits(9.5, .medium)).foregroundColor(Ink.dim).lineLimit(1).padding(.top, 1)
            Spacer(minLength: 4)
            bottom.frame(height: 16)
        }
        .padding(10).frame(maxWidth: .infinity, minHeight: 96, maxHeight: 96, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Ink.tile))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.line, lineWidth: 1))
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

// ---------- The panel ----------
struct Panel: View {
    @ObservedObject var m: Model
    @State private var loginOn = SMAppService.mainApp.status == .enabled
    var quit: () -> Void = {}
    var solid = false      // true only for the preview picture; live, the backdrop view sits behind
    private func v(_ x: Double) -> Double { m.sweep ? 1 : x }
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
                    ForEach(Array([("HOTTEST", String(format: "%.0f °C", m.records[0])), ("MOST POWER", String(format: "%.1f W", m.records[1])),
                                   ("FASTEST DOWN", { let r = rate(m.records[2]); return "\(r.0) \(r.1)" }())].enumerated()), id: \.offset) { i, e in
                        HStack(spacing: 6) { label(e.0, 8.5); Text(e.1).font(digits(11, .bold)).foregroundColor(Ink.amber) }.frame(width: 150, alignment: .trailing)
                    }
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 10).fill(Ink.tile)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.line, lineWidth: 1))
                .contentShape(Rectangle())
            }.buttonStyle(.plain).help("All-time highs on this Mac. Click to reset.")
    }
    @ViewBuilder private var usbBay: some View {
        let s = m.s
            // USB bay
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    label("USB BAY")
                    Spacer()
                    let total = s.usb.reduce(0) { $0 + $1.mA }
                    Text(String(format: "%d DEVICES · %d mA · %.1f W REQUESTED", s.usb.count, total, Double(total) * 5 / 1000)).font(digits(9.5, .medium)).foregroundColor(Ink.dim)
                }
                HStack(alignment: .center, spacing: 10) {
                    PortMap(lit: Set(s.usb.filter { $0.depth == 0 && $0.port > 0 }.map { m.portMap[$0.port - 1] }), charger: s.chargerSocket > 0 ? m.portMap[s.chargerSocket - 1] : nil)
                    VStack(alignment: .leading, spacing: 7) {
                        if s.chargerSocket > 0 {
                            HStack(spacing: 8) {
                                Circle().fill(Ink.amber).frame(width: 6, height: 6)
                                Text("Charger").font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(.white).lineLimit(1).layoutPriority(1)
                                Text(s.adapterName.uppercased()).font(.system(size: 8.5, weight: .semibold, design: .rounded)).tracking(1).foregroundColor(Ink.dim).lineLimit(1)
                                Spacer(minLength: 4)
                                Button(action: { m.cyclePort(s.chargerSocket) }) {
                                    Text(PortMap.names[m.portMap[s.chargerSocket - 1]]).font(.system(size: 8, weight: .bold, design: .rounded)).tracking(0.8).foregroundColor(Ink.amber)
                                        .frame(width: 92, height: 15).background(Capsule().fill(Ink.amber.opacity(0.10))).contentShape(Rectangle())
                                }.buttonStyle(.plain).help("Socket \(s.chargerSocket). Wrong place? Click to move it to the next position.")
                                Text("POWER IN").font(digits(9.5, .semibold)).foregroundColor(Ink.ice).frame(width: 58, alignment: .trailing)
                                Text("\(s.adapterW) W").font(digits(9.5, .semibold)).foregroundColor(Ink.amber).frame(width: 48, alignment: .trailing)
                            }.frame(height: 18)
                        }
                        if s.usb.isEmpty && s.chargerSocket == 0 {
                            Text("Nothing plugged in").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(Ink.dim).frame(maxWidth: .infinity, alignment: .leading).frame(height: 18)
                        }
                        ForEach(s.usb.prefix(8)) { d in
                            HStack(spacing: 8) {
                                Circle().fill(Ink.green).frame(width: 6, height: 6).padding(.leading, CGFloat(min(d.depth, 3)) * 12)
                                Text(d.name).font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(.white).lineLimit(1).layoutPriority(1)
                                Text(d.vendor.uppercased()).font(.system(size: 8.5, weight: .semibold, design: .rounded)).tracking(1).foregroundColor(Ink.dim).lineLimit(1)
                                Spacer(minLength: 4)
                                if d.depth == 0, d.port > 0 {
                                    Button(action: { m.cyclePort(d.port) }) {
                                        Text(PortMap.names[m.portMap[d.port - 1]]).font(.system(size: 8, weight: .bold, design: .rounded)).tracking(0.8).foregroundColor(Ink.green)
                                            .frame(width: 92, height: 15).background(Capsule().fill(Ink.green.opacity(0.10))).contentShape(Rectangle())
                                    }.buttonStyle(.plain).help("Socket \(d.port). Wrong place? Click to move it to the next position.")
                                } else { Color.clear.frame(width: 92, height: 15) }
                                Text(d.speed).font(digits(9.5, .semibold)).foregroundColor(Ink.ice).frame(width: 58, alignment: .trailing)
                                Text("\(d.mA) mA").font(digits(9.5, .semibold)).foregroundColor(Ink.amber).frame(width: 48, alignment: .trailing)
                            }.frame(height: 18)
                        }
                    }
                }
            }
            .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Ink.tile)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.line, lineWidth: 1))
    }
    @ViewBuilder private var footer: some View {
            // footer
            HStack(spacing: 6) {
                Pill(text: "LOGIN", on: loginOn, tip: "Start Redline when you log in") {
                    do { if loginOn { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() } } catch {}
                    loginOn = SMAppService.mainApp.status == .enabled
                }
                Pill(text: "SFX", on: m.sfx, tip: "Ignition sound when the card opens") { m.sfx.toggle(); UserDefaults.standard.set(m.sfx, forKey: "sfx") }
                Pill(text: "VIBE", on: m.vibe, tip: m.vibeNote.isEmpty ? "Backdrop moves with whatever your Mac is playing" : m.vibeNote) { m.vibe.toggle(); UserDefaults.standard.set(m.vibe, forKey: "vibe") }
                Pill(text: "NOS", on: m.nos, tint: Ink.nos, tip: "Coffee Mode: keep the Mac awake") { m.toggleNOS() }
                HStack(spacing: 6) {
                    label("UNDERGLOW", 8)
                    ForEach(0..<4, id: \.self) { i in
                        Button(action: { Ink.glow = i; UserDefaults.standard.set(i, forKey: "glow"); m.theme = i }) {
                            Circle().fill(Ink.glows[i]).frame(width: 10, height: 10)
                                .overlay(Circle().strokeBorder(Color.white.opacity(m.theme == i ? 0.95 : 0), lineWidth: 1.5).padding(-2.5))
                        }.buttonStyle(.plain).help(Ink.glowNames[i])
                    }
                }.padding(.leading, 10)
                Spacer()
                Text("© 2026 Ali Razavi").font(.system(size: 9.5, weight: .medium, design: .rounded)).foregroundColor(Ink.dim)
                Button(action: quit) { Text("Quit").font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(Ink.mid) }.buttonStyle(.plain)
                    .padding(.leading, 10).padding(.trailing, 16)       // leaves the corner free for the resize grip
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
            }
            // shift lights
            HStack(spacing: 5) {
                ForEach(0..<20, id: \.self) { i in
                    Capsule().fill(i >= 16 ? Ink.red : (i >= 11 ? Ink.amber : Ink.green))
                        .opacity(v(s.cpu) * 20 > Double(i) + 0.3 ? 1 : 0.12).frame(height: 5)
                }
            }.drawingGroup()
            // dials
            HStack(alignment: .bottom, spacing: 14) {
                Dial(title: "GPU LAST", value: v(s.gpu), peak: m.peakGPU, big: String(format: "%02.0f", s.gpu * 100), unit: "%", sub: s.gpuNote, size: 158)
                Dial(title: "CPU LAST", value: v(s.cpu), peak: m.peakCPU, big: String(format: "%02.0f", s.cpu * 100), unit: "%",
                     sub: s.cpuW.map { String(format: "%.1f W PACKAGE", $0) } ?? "x10 %", size: 216, numbers: true)
                Dial(title: "MEMORY", value: v(s.mem), peak: m.peakMem, big: String(format: "%.1f", s.memUsedGB), unit: "GB",
                     sub: String(format: "OF %.0f GB · %@", s.memTotalGB, s.pressure >= 4 ? "CRITICAL" : s.pressure == 2 ? "TIGHT" : "RELAXED"), size: 158, redFrom: 0.85)
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
            .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Ink.tile)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.line, lineWidth: 1))
    }
    @ViewBuilder private var tiles: some View {
        let s = m.s
            HStack(spacing: 10) {
                Tile(title: "POWER IN", big: s.plugged ? (s.dcInW != nil ? w(s.dcInW) : "\(s.adapterW)") : "0.0", unit: "W",
                     sub: s.plugged ? "CHARGER \(s.adapterW) W" : "ON BATTERY", tint: s.plugged ? Ink.green : .white) { Spark(data: m.hIn, color: Ink.green, floor: 20) }
                Tile(title: "SYSTEM DRAW", big: w(s.sysW ?? (s.plugged ? nil : abs(s.battW))), unit: "W",
                     sub: "CPU \(w(s.cpuW)) · GPU \(w(s.gpuW))", tint: Ink.amber) { Spark(data: m.hSys, color: Ink.amber, floor: 20) }
                Tile(title: "BATTERY", big: s.hasBattery ? String(format: "%02d", s.battPct) : "--", unit: "%",
                     sub: String(format: "%@%.1f W · %.0f%% HEALTH", s.battW >= 0 ? "+" : "−", abs(s.battW), s.health * 100),
                     tint: s.battPct <= 15 ? Ink.red : .white) { Bar(value: v(Double(s.battPct) / 100), color: s.battPct <= 15 ? Ink.red : Ink.green) }
                    .help(String(format: "%d charge cycles · battery %.0f °C", s.cycles, s.battTemp))
                Tile(title: "THERMALS", big: s.cpuTemp.map { String(format: "%.0f", $0) } ?? "--", unit: "°C",
                     sub: "GPU \(s.gpuTemp.map { String(format: "%.0f°", $0) } ?? "--") · \(s.fans.isEmpty ? "--" : String(format: "%.0f", s.fans.max() ?? 0)) RPM",
                     tint: (s.cpuTemp ?? 0) >= 90 ? Ink.red : .white) { Bar(value: v(((s.cpuTemp ?? 30) - 30) / 70), color: (s.cpuTemp ?? 0) >= 90 ? Ink.red : Ink.ice) }
            }
            HStack(spacing: 10) {
                let d = rate(s.down), u = rate(s.up), r = rate(s.read), wr = rate(s.write)
                Tile(title: "NET DOWN", big: d.0, unit: d.1, sub: s.rssi.map { "WI-FI \($0) dBm" } ?? "WI-FI OFF", tint: Ink.ice) { Spark(data: m.hDown, color: Ink.ice, floor: 50_000) }
                Tile(title: "NET UP", big: u.0, unit: u.1, sub: s.txRate.map { String(format: "LINK %.0f Mb/s", $0) } ?? "NO LINK", tint: Ink.ice) { Spark(data: m.hUp, color: Ink.ice, floor: 50_000) }
                Tile(title: "DISK READ", big: r.0, unit: r.1, sub: String(format: "%.1f GB SINCE BOOT", s.readTotal / 1e9)) { Spark(data: m.hRead, color: Ink.mid, floor: 500_000) }
                Tile(title: "DISK WRITE", big: wr.0, unit: wr.1, sub: String(format: "%.1f GB SINCE BOOT", s.writeTotal / 1e9)) { Spark(data: m.hWrite, color: Ink.mid, floor: 500_000) }
            }
    }
    var layout: Bool? = nil        // nil = follow the model; set only for measuring and the preview pictures
    private var wide: Bool { layout ?? m.wide }
    var body: some View {
        Group {
            if wide {      // two columns: gauges left, numbers right
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 12) { gauges; Spacer(minLength: 0); recordsRow }.frame(width: 568).frame(maxHeight: .infinity, alignment: .top)
                    VStack(spacing: 12) { tiles; usbBay; Spacer(minLength: 0); footer }.frame(width: 568).frame(maxHeight: .infinity, alignment: .top)
                }.fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 12) { gauges; tiles; recordsRow; usbBay; footer }
            }
        }
        .id(m.theme)
        .padding(16).frame(width: wide ? 1184 : 600)
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
        lock.lock()
        peak = max(4, max(peak * 0.997, top))                 // follows the volume, never amplifies silence
        for b in 0..<n { let v = min(1, out[b] / peak); levels[b] = v > levels[b] ? v : levels[b] * 0.80 + v * 0.20 }
        lock.unlock()
    }
    func read() -> [Float] { lock.lock(); defer { lock.unlock() }; return levels }
}

// ---------- The backdrop: plain Core Animation layers behind the gauges, so it costs almost nothing ----------
final class Backdrop: NSView {
    private let grad = CAGradientLayer(), glow = CAGradientLayer(), under = CAGradientLayer()
    private var bars: [CALayer] = []; private var k: CGFloat = 1; private var tint = -1
    private var halos: [CALayer] = []; private let flashLayer = CALayer(); private var bassAvg: CGFloat = 0, beat: CGFloat = 0
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        grad.colors = [NSColor(Ink.bg1).cgColor, NSColor(Ink.bg0).cgColor]; grad.startPoint = CGPoint(x: 0.5, y: 1); grad.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(grad)
        glow.type = .radial; glow.startPoint = CGPoint(x: 0.5, y: 0.5); glow.endPoint = CGPoint(x: 1, y: 1); glow.opacity = 0
        layer?.addSublayer(glow)
        for _ in 0..<AudioTap.bands { let b = CALayer(); b.anchorPoint = CGPoint(x: 0.5, y: 0); b.cornerRadius = 1.5; bars.append(b); layer?.addSublayer(b) }
        under.startPoint = CGPoint(x: 0, y: 0.5); under.endPoint = CGPoint(x: 1, y: 0.5); under.opacity = 0
        layer?.addSublayer(under)
        for _ in 0..<20 { let h = CALayer(); h.opacity = 0; halos.append(h); layer?.addSublayer(h) }      // glow behind the shift lights, on the beat
        flashLayer.backgroundColor = NSColor(Ink.nos).cgColor; flashLayer.opacity = 0; layer?.addSublayer(flashLayer)
    }
    /// NOS: one purple flash across the whole card.
    func flash() {
        let a = CABasicAnimation(keyPath: "opacity"); a.fromValue = 0.6; a.toValue = 0; a.duration = 0.8
        a.timingFunction = CAMediaTimingFunction(name: .easeOut); flashLayer.add(a, forKey: "flash")
    }
    required init?(coder: NSCoder) { fatalError() }
    func place(scale: CGFloat) {
        k = scale
        CATransaction.begin(); CATransaction.setDisableActions(true)
        grad.frame = bounds
        let base = bounds.height - 296 * k, w = 568 * k / CGFloat(bars.count)      // the skyline stays behind the dials, also in the wide layout
        for (i, b) in bars.enumerated() {
            b.position = CGPoint(x: 16 * k + w * (CGFloat(i) + 0.5), y: base); b.bounds = CGRect(x: 0, y: 0, width: max(2, w - 3 * k), height: b.bounds.height)
        }
        let g = 520 * k
        glow.frame = CGRect(x: 300 * k - g / 2, y: bounds.height - 181 * k - g / 2, width: g, height: g)
        under.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 3 * k)
        flashLayer.frame = bounds
        let hw = (568 - 95) / 20.0 * k
        for (i, h) in halos.enumerated() {
            h.frame = CGRect(x: 16 * k + CGFloat(i) * (hw + 5 * k) - 2 * k, y: bounds.height - 56.5 * k - 6 * k, width: hw + 4 * k, height: 12 * k); h.cornerRadius = 6 * k
        }
        CATransaction.commit()
        recolor(force: true)
    }
    private func recolor(force: Bool = false) {
        guard force || tint != Ink.glow else { return }
        tint = Ink.glow
        let c = NSColor(Ink.ice)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bars.forEach { $0.backgroundColor = c.withAlphaComponent(0.42).cgColor }
        halos.forEach { $0.backgroundColor = c.withAlphaComponent(0.55).cgColor }
        glow.colors = [c.withAlphaComponent(0.55).cgColor, c.withAlphaComponent(0).cgColor]
        under.colors = [c.withAlphaComponent(0).cgColor, c.cgColor, c.withAlphaComponent(0).cgColor]
        CATransaction.commit()
    }
    func set(_ levels: [Float]) {
        recolor()
        let maxH = 268 * k
        let bass = CGFloat(levels.prefix(6).reduce(0, +) / 6)
        CATransaction.begin(); CATransaction.setAnimationDuration(0.06)
        for (b, v) in zip(bars, levels) { b.bounds.size.height = max(0, CGFloat(v) * maxH) }
        glow.opacity = Float(min(1, bass * 1.1)); glow.transform = CATransform3DMakeScale(0.75 + 0.45 * bass, 0.75 + 0.45 * bass, 1)
        under.opacity = Float(min(1, bass * 1.3))
        // a kick drum = bass jumping well above its recent average; the glow ripples out from the middle
        if bass > 0.22, bass > bassAvg * 1.3 { beat = 1 } else { beat *= 0.80 }
        bassAvg = bassAvg * 0.92 + bass * 0.08
        for (i, h) in halos.enumerated() { h.opacity = Float(max(0, min(1, beat * 1.7 - abs(CGFloat(i) - 9.5) / 9.5 * 0.7))) }
        CATransaction.commit()
    }
}

// ---------- Sounds, made in code (no audio files) ----------
enum Sound {
    private static var players: [AVAudioPlayer] = []
    /// Wraps raw samples in a WAV header and plays them.
    private static func play(_ f: [Float], volume: Float) {
        let rate = 44_100; var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + f.count * 2)); d.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(f.count * 2))
        for v in f { u16(UInt16(bitPattern: Int16(max(-1, min(1, v)) * 32_000))) }
        guard let p = try? AVAudioPlayer(data: d) else { return }
        p.volume = volume; p.play(); players.append(p)
        if players.count > 3 { players.removeFirst() }
    }
    /// A short engine rev that settles, with a little blow-off hiss at the end.
    static func ignition() {
        let rate: Float = 44_100; var out: [Float] = []; var phase: Float = 0; var lp: Float = 0
        let n = Int(rate * 0.95)
        for i in 0..<n {
            let t = Float(i) / rate
            let hz: Float = t < 0.38 ? 62 + 250 * powf(t / 0.38, 1.6) : 312 - 190 * min(1, (t - 0.38) / 0.35)
            phase += hz / rate; let ph = phase - floorf(phase)
            let engine = (2 * ph - 1) * 0.5 + sinf(2 * .pi * ph) * 0.5 + sinf(4 * .pi * ph) * 0.2
            let env = min(1, t / 0.03) * (t > 0.6 ? max(0, 1 - (t - 0.6) / 0.35) : 1)
            let noise = Float.random(in: -1...1); lp += 0.35 * (noise - lp)
            let hiss = t > 0.40 && t < 0.72 ? (noise - lp) * 0.5 * (1 - (t - 0.40) / 0.32) : 0
            out.append(engine * env * 0.5 + hiss)
        }
        play(out, volume: 0.30)
    }
    /// Nitrous: a rising hiss.
    static func nos() {
        let rate: Float = 44_100; var out: [Float] = []; var lp: Float = 0
        for i in 0..<Int(rate * 0.7) {
            let t = Float(i) / rate, noise = Float.random(in: -1...1)
            lp += (0.08 + 0.5 * t) * (noise - lp)
            out.append((noise - lp) * min(1, t / 0.05) * max(0, 1 - t / 0.7) * 0.9)
        }
        play(out, volume: 0.30)
    }
}

struct Root: View {
    @ObservedObject var m: Model; var quit: () -> Void
    var body: some View {
        Panel(m: m, quit: quit).fixedSize()
            .scaleEffect(m.scale, anchor: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The corner you drag to make the card bigger or smaller.
final class Grip: NSView {
    var onDrag: ((CGFloat) -> Void)?       // wanted card width, in points
    private var startX: CGFloat = 0, startY: CGFloat = 0, startW: CGFloat = 0
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    // Positions come from the events themselves (not the live pointer), so every step of a drag is counted exactly once.
    private func spot(_ e: NSEvent) -> NSPoint { window?.convertPoint(toScreen: e.locationInWindow) ?? NSEvent.mouseLocation }
    override func mouseDown(with e: NSEvent) { let p = spot(e); startX = p.x; startY = p.y; startW = window?.frame.width ?? 600 }
    override func mouseDragged(with e: NSEvent) {
        let p = spot(e), f = window?.frame ?? .zero
        let dx = p.x - startX, down = (startY - p.y) * (f.height > 0 ? min(1, f.width / f.height) : 0.7)
        // sideways is exact; pulling down adds to it, so a big size is reachable even when the card starts near the screen edge
        onDrag?(startW + (abs(dx) >= abs(down) ? dx + down * 0.5 : down + dx * 0.5))
    }
    override func draw(_ r: NSRect) {
        NSColor.white.withAlphaComponent(0.35).setStroke()
        for i in 0..<3 {
            let o = CGFloat(5 + i * 4), path = NSBezierPath(); path.lineWidth = 1.2; path.lineCapStyle = .round
            path.move(to: NSPoint(x: bounds.maxX - 5, y: o)); path.line(to: NSPoint(x: bounds.maxX - o, y: 5)); path.stroke()
        }
    }
}

final class Card: NSPanel { override var canBecomeKey: Bool { true } }

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model(); var item: NSStatusItem!
    private var card: Card!; private var host: NSHostingController<Root>!; private var measure: NSHostingController<Panel>!; private var measureWide: NSHostingController<Panel>!
    private let backdrop = Backdrop(frame: .zero); private let grip = Grip(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
    private let tap = AudioTap(); private var beat: Timer?
    private var lastStep = -1; private var rows = -1; private var sig: DispatchSourceSignal?
    private var outside: Any?; private var keys: Any?
    private let sticky = ProcessInfo.processInfo.environment["REDLINE_STICKY"] != nil   // testing only: stay open

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = BarIcon.image(load: 0, hot: false)
        item.button?.target = self; item.button?.action = #selector(toggle)
        item.button?.toolTip = "Redline"
        host = NSHostingController(rootView: Root(m: model, quit: { NSApp.terminate(nil) }))
        host.sizingOptions = []          // sized by hand in fit(): automatic sizing re-laid-out the window on every animation frame
        measure = NSHostingController(rootView: Panel(m: model, layout: false))      // never shown; only asked how big each layout wants to be
        measureWide = NSHostingController(rootView: Panel(m: model, layout: true))
        card = Card(contentRect: NSRect(x: 0, y: 0, width: 600, height: 840), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        card.isOpaque = false; card.backgroundColor = .clear; card.hasShadow = true; card.level = .statusBar
        card.isMovableByWindowBackground = true        // drag it anywhere by its background
        card.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        card.appearance = NSAppearance(named: .darkAqua)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 840))
        box.wantsLayer = true; box.layer?.cornerRadius = 16; box.layer?.masksToBounds = true
        for v in [backdrop, host.view] as [NSView] { v.frame = box.bounds; v.autoresizingMask = [.width, .height]; box.addSubview(v) }
        grip.frame.origin = NSPoint(x: box.bounds.maxX - 22, y: 0); grip.autoresizingMask = [.minXMargin, .maxYMargin]; box.addSubview(grip)
        grip.onDrag = { [weak self] w in self?.dragTo(width: w) }
        card.contentView = box
        model.onTick = { [weak self] in self?.redraw($0) }
        model.onNOS = { [weak self] in self?.backdrop.flash(); if self?.model.sfx == true { Sound.nos() } }
        model.start()
        // `kill -USR1 <pid>` opens or closes the panel from a script on this Mac (local signal only).
        signal(SIGUSR1, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        src.setEventHandler { [weak self] in self?.toggle() }; src.resume(); sig = src
    }
    private var screenFrame: NSRect { (card.screen ?? item.button?.window?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900) }
    private func baseSize(wide: Bool) -> NSSize { (wide ? measureWide : measure).sizeThatFits(in: NSSize(width: 4_000, height: 10_000)) }
    private var rowCount: Int { model.s.usb.count + (model.s.chargerSocket > 0 ? 1 : 0) }
    /// Dragging the corner, like a responsive web page: narrow = the tall single column; once that no longer fits
    /// the screen and you keep pulling, it reflows into two columns and keeps growing.
    private func dragTo(width req: CGFloat) {
        let vis = screenFrame, old = card.frame, availH = old.maxY - vis.minY
        let tb = baseSize(wide: false), wb = baseSize(wide: true)
        let tallMax = tb.width * max(1, min(2.2, availH / tb.height))
        let wideMax = wb.width * min(2.2, min(availH / wb.height, (vis.width - 8) / wb.width))
        let wideMin = max(900, tallMax)
        var wide = false, w = min(tallMax, max(tb.width * 0.55, req))
        if req > tallMax, wideMax >= wideMin, req >= (tallMax + wideMin) / 2 { wide = true; w = min(wideMax, max(wideMin, req)) }
        let base = wide ? wb : tb, k = w / base.width
        guard wide != model.wide || abs(k - model.scale) > 0.002 else { return }
        model.wide = wide; model.scale = k
        let size = NSSize(width: (base.width * k).rounded(), height: (base.height * k).rounded())
        let x = max(vis.minX + 4, min(old.minX, vis.maxX - size.width - 4))       // slides left only if it would leave the screen
        card.setFrame(NSRect(x: x, y: old.maxY - size.height, width: size.width, height: size.height), display: true)
        backdrop.place(scale: k)
    }
    private func fit(place: Bool) {
        rows = rowCount
        let base = baseSize(wide: model.wide), k = model.scale, size = NSSize(width: base.width * k, height: base.height * k), old = card.frame, vis = screenFrame
        var origin = NSPoint(x: old.minX, y: old.maxY - size.height)      // keep the top-left corner where it is
        if place, let b = item.button?.window?.frame {
            let v = (item.button?.window?.screen ?? NSScreen.main)?.visibleFrame ?? vis
            origin = NSPoint(x: min(max(v.minX + 8, b.midX - size.width / 2), v.maxX - size.width - 8), y: b.minY - size.height - 6)
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
    /// 30 times a second while the card is open: move the backdrop with the music (if VIBE is on).
    private func pulse() {
        if model.vibe {
            if !tap.running { let why = tap.start(); if model.vibeNote != (why ?? "") { model.vibeNote = why ?? "" }; if why != nil { model.vibe = false } }
            backdrop.set(tap.read())
        } else if tap.running { tap.stop(); backdrop.set([Float](repeating: 0, count: AudioTap.bands)) }
    }
    @objc func toggle() { card.isVisible ? close() : open() }
    private func open() {
        model.wide = false; model.scale = 1            // always opens at the standard size and layout
        model.setOpen(true)
        fit(place: true)
        card.makeKeyAndOrderFront(nil)
        if model.sfx { Sound.ignition() }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.pulse() }
        RunLoop.main.add(t, forMode: .common); beat = t
        guard !sticky else { return }
        // A click anywhere outside Redline closes the card; so does Esc.
        outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in self?.close() }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.close(); return nil }
            return e
        }
    }
    private func close() {
        card.orderOut(nil); model.setOpen(false)
        beat?.invalidate(); beat = nil; tap.stop()      // never listens while the card is closed
        if let o = outside { NSEvent.removeMonitor(o); outside = nil }
        if let k = keys { NSEvent.removeMonitor(k); keys = nil }
    }
    func applicationWillTerminate(_ n: Notification) { tap.stop() }
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
        let m = Model(); m.sampleNow()
        let r = ImageRenderer(content: Panel(m: m, solid: true)); r.scale = 2
        if let img = r.nsImage { writePNG(img, args[2] + "/panel.png", px: Int(img.size.width * 2)) }
        let rw = ImageRenderer(content: Panel(m: m, solid: true, layout: true)); rw.scale = 2
        if let img = rw.nsImage { writePNG(img, args[2] + "/panel_wide.png", px: Int(img.size.width * 2)) }
    }
    exit(0)
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
