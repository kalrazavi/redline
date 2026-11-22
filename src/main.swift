// Copyright (c) 2026 Ali Razavi. All rights reserved. Owned and controlled solely by Ali Razavi: no licence check, no remote control, no backdoor. Terms: see the LICENSE file.
import AppKit
import SwiftUI
import ServiceManagement
import IOKit
import IOKit.pwr_mgt
import CoreWLAN

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

    private static func run(_ path: String, _ args: [String]) -> Data {
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

    /// External USB devices (built-in ones like the keyboard and camera are left out).
    static func usb() -> [USBDev] {
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
                out.append(USBDev(id: (it["location_id"] as? String) ?? "\(out.count)\(name)", name: name,
                                  vendor: (it["manufacturer"] as? String) ?? "", speed: speeds[sp] ?? sp.replacingOccurrences(of: "_", with: " "),
                                  mA: Int((it["bus_power_used"] as? String) ?? "") ?? 0, depth: depth))
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
    @Published var sweep = false          // "ignition": every needle swings to the top once when the panel opens
    @Published var peakCPU = 0.0; @Published var peakGPU = 0.0; @Published var peakMem = 0.0
    @Published var hDown: [Double] = Array(repeating: 0, count: 60); @Published var hUp: [Double] = Array(repeating: 0, count: 60)
    @Published var hRead: [Double] = Array(repeating: 0, count: 60); @Published var hWrite: [Double] = Array(repeating: 0, count: 60)
    @Published var hSys: [Double] = Array(repeating: 0, count: 60); @Published var hIn: [Double] = Array(repeating: 0, count: 60)
    var onTick: ((Double) -> Void)?

    private let probe = Probe(); private let q = DispatchQueue(label: "redline.sample", qos: .utility)
    private var work = Snap(); private var timer: DispatchSourceTimer?; private var open = false; private var n = 0
    private var busySlow = false

    func start() { schedule(2.0) }
    private func schedule(_ every: Double) {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 0.05, repeating: every, leeway: .milliseconds(every > 1 ? 300 : 30))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume(); timer = t
    }
    func setOpen(_ o: Bool) {
        q.async { self.open = o; self.n = 0 }
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
                    let h = Probe.hog(); let u = doUSB ? Probe.usb() : nil
                    self.q.async { (self.work.hog, self.work.hogPct) = h; if let u = u { self.work.usb = u }; self.busySlow = false }
                }
            }
            n += 1
        } else { probe.cpuOnly(into: &work) }
        let snap = work, isOpen = open
        DispatchQueue.main.async {
            self.onTick?(snap.cpu)
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
        (work.hog, work.hogPct) = Probe.hog(); work.usb = Probe.usb(); s = work
        peakCPU = min(1, s.cpu + 0.12); peakGPU = s.gpu; peakMem = s.mem
        hSys = (0..<60).map { (s.sysW ?? 20) * (0.8 + 0.2 * sin(Double($0) / 5)) }; hIn = hSys.map { $0 * 1.1 }
        hDown = (0..<60).map { 400_000 * (1 + sin(Double($0) / 4)) }; hUp = (0..<60).map { 60_000 * (1 + cos(Double($0) / 6)) }
        hRead = (0..<60).map { 900_000 * abs(sin(Double($0) / 7)) }; hWrite = (0..<60).map { 500_000 * abs(cos(Double($0) / 9)) }
    }
}

// ---------- Look ----------
enum Ink {
    static let bg0 = Color(red: 0.035, green: 0.043, blue: 0.055), bg1 = Color(red: 0.063, green: 0.075, blue: 0.094)
    static let tile = Color(red: 0.082, green: 0.098, blue: 0.122), line = Color.white.opacity(0.07)
    static let ice = Color(red: 0.25, green: 0.90, blue: 1.0), amber = Color(red: 1.0, green: 0.72, blue: 0.20)
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
let spring = Animation.interpolatingSpring(stiffness: 110, damping: 13)

// ---------- A dial ----------
struct Dial: View {
    var title: String; var value: Double; var peak: Double; var big: String; var unit: String; var sub: String
    var size: CGFloat; var numbers = false; var redFrom = 0.8
    private func deg(_ f: Double) -> Double { 150 + 240 * min(1, max(0, f)) }
    var body: some View {
        let r = size / 2
        let hot = value >= redFrom
        ZStack {
            Circle().fill(RadialGradient(colors: [Ink.bg1, Ink.bg0], center: .center, startRadius: 0, endRadius: r))
            Circle().strokeBorder(LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.02)], startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
            Canvas { ctx, sz in
                let c = CGPoint(x: sz.width / 2, y: sz.height / 2), rr = sz.width / 2 - 9
                for i in 0...50 {
                    let f = Double(i) / 50, a = deg(f) * .pi / 180, major = i % 5 == 0
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
            // lit arc
            Circle().trim(from: 0, to: 240.0 / 360.0 * min(1, max(0, value)))
                .stroke(hot ? Ink.red : Ink.ice,
                        style: StrokeStyle(lineWidth: size * 0.022, lineCap: .round))
                .rotationEffect(.degrees(150)).padding(size * 0.135)
                .shadow(color: (hot ? Ink.red : Ink.ice).opacity(0.55), radius: 5)
            // peak marker
            Circle().fill(Ink.amber).frame(width: size * 0.028, height: size * 0.028).offset(x: r - size * 0.135)
                .rotationEffect(.degrees(deg(peak))).opacity(peak > 0.005 ? 0.95 : 0)
            // needle
            Capsule().fill(LinearGradient(colors: [Ink.red.opacity(0.0), Ink.red, Color(red: 1, green: 0.55, blue: 0.4)], startPoint: .leading, endPoint: .trailing))
                .frame(width: r * 0.92, height: max(2, size * 0.014)).offset(x: r * 0.30)
                .rotationEffect(.degrees(deg(value))).shadow(color: Ink.red.opacity(0.8), radius: 4)
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
        .frame(width: size, height: size).drawingGroup()
        .animation(spring, value: value).animation(.easeOut(duration: 0.5), value: peak)
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
        }.drawingGroup().animation(.easeOut(duration: 0.3), value: cores)
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
                Capsule().fill(color).frame(width: max(4, g.size.width * CGFloat(min(1, max(0, value)))))
            }
        }.frame(height: 4).frame(maxHeight: .infinity, alignment: .bottom).animation(spring, value: value)
    }
}

// ---------- The panel ----------
struct Panel: View {
    @ObservedObject var m: Model
    @State private var loginOn = SMAppService.mainApp.status == .enabled
    var quit: () -> Void = {}
    private func v(_ x: Double) -> Double { m.sweep ? 1 : x }
    private var odo: String {
        let t = Int(m.s.uptime); return String(format: "%02dd %02dh %02dm", t / 86400, (t % 86400) / 3600, (t % 3600) / 60)
    }
    private func w(_ x: Double?) -> String { x.map { String(format: "%.1f", $0) } ?? "--" }
    var body: some View {
        let s = m.s
        let throttled = s.speedLimit < 100
        VStack(spacing: 12) {
            // header
            HStack(alignment: .center) {
                HStack(spacing: 7) {
                    Image(nsImage: BarIcon.image(load: v(s.cpu), hot: false, scale: 1.0, color: NSColor(Ink.red))).frame(width: 22, height: 16)
                    Text("REDLINE").font(.system(size: 15, weight: .heavy, design: .rounded)).tracking(4).foregroundColor(.white)
                }
                Spacer()
                if throttled {
                    Text("THROTTLED \(s.speedLimit)%").font(.system(size: 9.5, weight: .bold, design: .rounded)).tracking(1.2)
                        .padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(Ink.red)).foregroundColor(.white)
                }
                VStack(alignment: .trailing, spacing: 1) { label("UPTIME", 8); Text(odo).font(digits(12, .semibold)).foregroundColor(Ink.mid) }
            }
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
            // tiles
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
            // USB bay
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    label("USB BAY")
                    Spacer()
                    let total = s.usb.reduce(0) { $0 + $1.mA }
                    Text(String(format: "%d DEVICES · %d mA · %.1f W REQUESTED", s.usb.count, total, Double(total) * 5 / 1000)).font(digits(9.5, .medium)).foregroundColor(Ink.dim)
                }
                if s.usb.isEmpty {
                    Text("Nothing plugged in").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(Ink.dim).frame(maxWidth: .infinity, alignment: .leading).frame(height: 18)
                }
                ForEach(s.usb.prefix(8)) { d in
                    HStack(spacing: 8) {
                        Circle().fill(Ink.green).frame(width: 6, height: 6).shadow(color: Ink.green.opacity(0.8), radius: 3).padding(.leading, CGFloat(min(d.depth, 3)) * 12)
                        Text(d.name).font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(.white).lineLimit(1)
                        Text(d.vendor.uppercased()).font(.system(size: 8.5, weight: .semibold, design: .rounded)).tracking(1).foregroundColor(Ink.dim).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(d.speed).font(digits(9.5, .semibold)).foregroundColor(Ink.ice).frame(width: 70, alignment: .trailing)
                        Text("\(d.mA) mA").font(digits(9.5, .semibold)).foregroundColor(Ink.amber).frame(width: 58, alignment: .trailing)
                    }.frame(height: 18)
                }
            }
            .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Ink.tile)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.line, lineWidth: 1))
            // footer
            HStack(spacing: 10) {
                Button(action: {
                    do { if loginOn { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() } } catch {}
                    loginOn = SMAppService.mainApp.status == .enabled
                }) {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(loginOn ? Ink.ice : Color.clear).frame(width: 11, height: 11)
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(loginOn ? Ink.ice : Ink.dim, lineWidth: 1.2))
                        Text("Start at login").font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(Ink.mid)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                Spacer()
                Text("© 2026 Ali Razavi · All rights reserved").font(.system(size: 9.5, weight: .medium, design: .rounded)).foregroundColor(Ink.dim)
                Spacer()
                Button(action: quit) { Text("Quit").font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(Ink.mid) }.buttonStyle(.plain)
            }
        }
        .padding(16).frame(width: 600)
        .background(LinearGradient(colors: [Ink.bg1, Ink.bg0], startPoint: .top, endPoint: .bottom))
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
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let model = Model(); var item: NSStatusItem!; let pop = NSPopover(); private var lastStep = -1; private var sig: DispatchSourceSignal?; private var host: NSHostingController<Panel>!; private var rows = -1

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = BarIcon.image(load: 0, hot: false)
        item.button?.target = self; item.button?.action = #selector(toggle)
        item.button?.toolTip = "Redline"
        let host = NSHostingController(rootView: Panel(m: model, quit: { NSApp.terminate(nil) }))
        host.sizingOptions = []          // sized by hand in fit(): automatic sizing re-laid-out the window on every animation frame
        self.host = host
        pop.contentViewController = host; pop.behavior = ProcessInfo.processInfo.environment["REDLINE_STICKY"] != nil ? .applicationDefined : .transient;   // sticky is for testing only pop.delegate = self
        pop.appearance = NSAppearance(named: .darkAqua)
        model.onTick = { [weak self] in self?.redraw($0) }
        model.start()
        // `kill -USR1 <pid>` opens or closes the panel from a script on this Mac (local signal only).
        signal(SIGUSR1, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        src.setEventHandler { [weak self] in self?.toggle() }; src.resume(); sig = src
    }
    private func fit() {
        rows = model.s.usb.count
        pop.contentSize = host.sizeThatFits(in: NSSize(width: 600, height: 10_000))
    }
    private func redraw(_ load: Double) {
        if pop.isShown, model.s.usb.count != rows { fit() }
        let step = Int((load * 24).rounded()) + (load >= 0.85 ? 100 : 0)
        guard step != lastStep else { return }
        lastStep = step
        item.button?.image = BarIcon.image(load: load, hot: load >= 0.85)
    }
    @objc func toggle() {
        if pop.isShown { pop.performClose(nil); return }
        guard let b = item.button else { return }
        model.setOpen(true)
        NSApp.activate(ignoringOtherApps: true)
        fit()
        pop.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        pop.contentViewController?.view.window?.makeKey()
    }
    func popoverDidClose(_ n: Notification) { model.setOpen(false) }
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
if args.count >= 3, args[1] == "--render" {
    MainActor.assumeIsolated {
        writePNG(BarIcon.appIcon(), args[2] + "/icon_1024.png", px: 1024)
        writePNG(BarIcon.image(load: 0.35, hot: false, scale: 8, color: .white), args[2] + "/menubar_icon.png", px: 352)
        let m = Model(); m.sampleNow()
        let r = ImageRenderer(content: Panel(m: m)); r.scale = 2
        if let img = r.nsImage { writePNG(img, args[2] + "/panel.png", px: Int(img.size.width * 2)) }
    }
    exit(0)
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
