/*
 vzrun — boot a FreeBSD / NetBSD / Linux / OpenBSD arm64 guest on Apple's
 Virtualization.framework, timestamp every serial console line with a host-side
 monotonic clock, match per-OS boot markers, and emit a timing JSON + dmesg.

 The host timestamp (`[+1.234s]` per line) is the cross-OS timing base: it does
 not depend on whether the guest emits its own printk/dmesg timestamps.

 Usage:
   vzrun --os <freebsd|netbsd|linux|openbsd> --disk <image.raw> [options]
     --kernel <Image> --initrd <initramfs>   (linux direct-kernel boot)
     --cmdline <str>                          (linux; default "console=hvc0")
     --out <dir> --rev <label> --timeout <s> --cpus <n> --mem <GiB>

 Console caveats (measured): Linux -> hvc0; FreeBSD needs the vtcon patch
 (KERNCONF=VZ); OpenBSD/NetBSD console on viogpu (serial blank -> use network).
*/

import Foundation
import Virtualization

func argValue(_ n: String) -> String? {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: n), i + 1 < a.count { return a[i + 1] }; return nil
}
func die(_ m: String) -> Never { FileHandle.standardError.write(Data("vzrun: \(m)\n".utf8)); exit(EXIT_FAILURE) }
func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }

struct Markers { let kernelFirst: NSRegularExpression; let initStart: NSRegularExpression?; let ready: NSRegularExpression }

final class Bench {
    let os, rev: String
    let cpus: Int; let memGiB: UInt64
    let serialLogURL, dmesgURL, jsonURL: URL
    let mk: Markers
    let startNS = DispatchTime.now().uptimeNanoseconds
    var tKernel: Double?, tInit: Double?, tReady: Double?, lines = 0
    var buf = Data()
    let log: FileHandle
    let outPipe = Pipe()

    static let markers: [String: Markers] = [
        "freebsd": Markers(kernelFirst: rx("Copyright .* FreeBSD"), initStart: rx("start_init: trying /sbin/init"), ready: rx("login:")),
        "netbsd":  Markers(kernelFirst: rx("NetBSD .* \\(GENERIC"),  initStart: rx("init: "),                       ready: rx("login:")),
        "openbsd": Markers(kernelFirst: rx("OpenBSD .* GENERIC"),    initStart: rx("init: "),                       ready: rx("login:")),
        "linux":   Markers(kernelFirst: rx("Linux version|Booting Linux"), initStart: rx("Run /init|systemd\\["),   ready: rx("BENCH_READY|login:")),
    ]

    init(os: String, rev: String, outDir: URL, cpus: Int, memGiB: UInt64) {
        self.os = os; self.rev = rev; self.cpus = cpus; self.memGiB = memGiB
        self.mk = Bench.markers[os]!
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        serialLogURL = outDir.appendingPathComponent("\(rev).serial.log")
        dmesgURL = outDir.appendingPathComponent("\(rev).dmesg.txt")
        jsonURL = outDir.appendingPathComponent("\(rev).json")
        FileManager.default.createFile(atPath: serialLogURL.path, contents: nil)
        log = FileHandle(forWritingAtPath: serialLogURL.path)!
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in self?.consume(fh.availableData) }
    }

    func elapsed() -> Double { Double(DispatchTime.now().uptimeNanoseconds - startNS) / 1e9 }

    func consume(_ chunk: Data) {
        if chunk.isEmpty { return }
        buf.append(chunk)
        while let nl = buf.firstIndex(of: 0x0A) {
            let raw = buf.subdata(in: buf.startIndex..<nl)
            buf.removeSubrange(buf.startIndex...nl)
            let line = String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "\r", with: "")
            let t = elapsed(); lines += 1
            log.write(Data(String(format: "[+%8.3f] %@\n", t, line).utf8))
            let r = NSRange(line.startIndex..<line.endIndex, in: line)
            if tKernel == nil, mk.kernelFirst.firstMatch(in: line, range: r) != nil { tKernel = t }
            if tInit == nil, let ir = mk.initStart, ir.firstMatch(in: line, range: r) != nil { tInit = t }
            if tReady == nil, mk.ready.firstMatch(in: line, range: r) != nil {
                tReady = t
                FileHandle.standardError.write(Data("vzrun: ready marker at +\(String(format: "%.3f", t))s\n".utf8))
            }
        }
    }

    func finish(_ status: String) -> Never {
        var p: [String: Any] = [
            "os": os, "rev": rev, "boot_loader": (os == "linux" ? "VZLinuxBootLoader" : "VZEFIBootLoader"),
            "status": status, "cpus": cpus, "mem_gib": memGiB,
            "total_s": elapsed(), "serial_lines": lines,
        ]
        p["t_kernel_first_s"] = tKernel; p["t_init_s"] = tInit; p["t_ready_s"] = tReady
        if let k = tKernel, let rdy = tReady { p["kernel_to_ready_s"] = rdy - k }
        if let data = try? JSONSerialization.data(withJSONObject: p, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: jsonURL)
            FileHandle.standardError.write(data); FileHandle.standardError.write(Data("\n".utf8))
        }
        if let s = try? String(contentsOf: serialLogURL, encoding: .utf8) { try? s.write(to: dmesgURL, atomically: true, encoding: .utf8) }
        exit(status == "ready" || status == "guest_stopped" ? 0 : 2)
    }
}

// MARK: - parse args

guard let os = argValue("--os")?.lowercased(), ["freebsd","netbsd","linux","openbsd"].contains(os) else { die("--os must be freebsd|netbsd|linux|openbsd") }
guard let diskPath = argValue("--disk"), FileManager.default.fileExists(atPath: diskPath) else { die("--disk <image> required and must exist") }
let diskURL = URL(fileURLWithPath: diskPath)
let outDir = URL(fileURLWithPath: argValue("--out") ?? "./results").appendingPathComponent(os)
let rev = argValue("--rev") ?? "unknown"
let timeout = Double(argValue("--timeout") ?? "300") ?? 300
let cpus = Int(argValue("--cpus") ?? "4") ?? 4
let memGiB = UInt64(argValue("--mem") ?? "4") ?? 4
let cmdline = argValue("--cmdline") ?? "console=hvc0"

let bench = Bench(os: os, rev: rev, outDir: outDir, cpus: cpus, memGiB: memGiB)

// MARK: - VM config

let cfg = VZVirtualMachineConfiguration()
cfg.cpuCount = min(max(cpus, VZVirtualMachineConfiguration.minimumAllowedCPUCount), VZVirtualMachineConfiguration.maximumAllowedCPUCount)
cfg.memorySize = min(max(memGiB * 1024*1024*1024, VZVirtualMachineConfiguration.minimumAllowedMemorySize), VZVirtualMachineConfiguration.maximumAllowedMemorySize)
do {
    if os == "linux", let kp = argValue("--kernel") {
        let boot = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: kp))
        if let ip = argValue("--initrd") { boot.initialRamdiskURL = URL(fileURLWithPath: ip) }
        boot.commandLine = cmdline
        cfg.bootLoader = boot
    } else {
        let platform = VZGenericPlatformConfiguration()
        let midURL = diskURL.deletingLastPathComponent().appendingPathComponent(diskURL.lastPathComponent + ".machineid")
        if let d = try? Data(contentsOf: midURL), let id = VZGenericMachineIdentifier(dataRepresentation: d) { platform.machineIdentifier = id }
        else { try platform.machineIdentifier.dataRepresentation.write(to: midURL) }
        cfg.platform = platform
        let loader = VZEFIBootLoader()
        let varURL = diskURL.deletingLastPathComponent().appendingPathComponent(diskURL.lastPathComponent + ".efivars")
        loader.variableStore = FileManager.default.fileExists(atPath: varURL.path) ? VZEFIVariableStore(url: varURL) : try VZEFIVariableStore(creatingVariableStoreAt: varURL)
        cfg.bootLoader = loader
    }
    cfg.storageDevices = [ VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)) ]
    let net = VZVirtioNetworkDeviceConfiguration(); net.attachment = VZNATNetworkDeviceAttachment(); cfg.networkDevices = [net]
    cfg.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    let gfx = VZVirtioGraphicsDeviceConfiguration(); gfx.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1024, heightInPixels: 768)]; cfg.graphicsDevices = [gfx]
    let port = VZVirtioConsoleDeviceSerialPortConfiguration()
    port.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: FileHandle(forReadingAtPath: "/dev/null") ?? FileHandle.nullDevice, fileHandleForWriting: bench.outPipe.fileHandleForWriting)
    cfg.serialPorts = [port]
    try cfg.validate()
} catch { die("configuration failed: \(error)") }

final class Delegate: NSObject, VZVirtualMachineDelegate {
    func guestDidStop(_ vm: VZVirtualMachine) { bench.finish(bench.tReady != nil ? "ready" : "guest_stopped") }
    func virtualMachine(_ vm: VZVirtualMachine, didStopWithError error: Error) {
        FileHandle.standardError.write(Data("vzrun: guest stopped with error: \(error)\n".utf8)); bench.finish("error")
    }
}
let delegate = Delegate()
let vm = VZVirtualMachine(configuration: cfg); vm.delegate = delegate
FileHandle.standardError.write(Data("vzrun: booting \(os) (\(diskURL.lastPathComponent)), timeout \(Int(timeout))s\n".utf8))
vm.start { r in if case let .failure(e) = r { die("failed to start: \(e)") } }
DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { FileHandle.standardError.write(Data("vzrun: watchdog timeout\n".utf8)); bench.finish("timeout") }
RunLoop.main.run(until: .distantFuture)
