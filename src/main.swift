import Cocoa

let SMC_PATH: String = {
    if let res = Bundle.main.resourcePath {
        return (res as NSString).appendingPathComponent("smc")
    }
    return URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("smc").path
}()
let FIFO_PATH = "/var/run/fcm.fifo"
let LOG_PATH = "/tmp/fanctl.log"

let CPU_KEYS = ["TC0P", "TC0c", "Tp09", "pacc"]
let RAM_KEYS = ["TM0P", "TM0p", "PM0P"]
let SSD_KEYS = ["Ts0P", "Th0P", "NS0P", "PF0P"]
let WIFI_KEYS = ["TW0P", "TP0P", "En0P"]

func readTemp(_ keys: [String]) -> Double? {
    for k in keys {
        if let v = readKey(k), let d = Double(v), d > -100 { return d }
    }
    return nil
}
func cpuTemp() -> Double { readTemp(CPU_KEYS) ?? 40 }
func fmtTemp(_ v: Double?) -> String { v.map { String(format: "%.0f°C", $0) } ?? "—" }

func log(_ msg: String) {
    let line = "[\(Date())] \(msg)\n"
    if let h = FileHandle(forWritingAtPath: LOG_PATH) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        h.closeFile()
    } else {
        try? line.data(using: .utf8)?.write(to: URL(fileURLWithPath: LOG_PATH))
    }
}

func smcRun(_ args: [String]) -> String? {
    let cmd = [SMC_PATH] + args
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cmd[0])
    p.arguments = Array(cmd.dropFirst())
    let out = Pipe()
    let err = Pipe()
    p.standardOutput = out
    p.standardError = err
    do { try p.run() } catch { log("RUN HATA: \(args) \(error)"); return nil }
    p.waitUntilExit()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    let outStr = String(data: data, encoding: .utf8) ?? ""
    let errStr = String(data: errData, encoding: .utf8) ?? ""
    log("\(args.joined(separator: " ")) → rc=\(p.terminationStatus) out=\(outStr.trimmingCharacters(in: .whitespacesAndNewlines)) err=\(errStr.trimmingCharacters(in: .whitespacesAndNewlines))")
    guard p.terminationStatus == 0 else { return nil }
    guard let s = String(data: data, encoding: .utf8) else { return nil }
    for line in s.split(separator: "\n") {
        if let eq = line.firstIndex(of: "=") {
            return String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    return nil
}

func readKey(_ k: String) -> String? { smcRun(["read", k]) }
func sendWrite(_ k: String, _ v: String) {
    if let fh = FileHandle(forWritingAtPath: FIFO_PATH) {
        fh.write("\(k) \(v)\n".data(using: .utf8)!)
        try? fh.close()
        return
    }
    _ = smcRun(["write", k, v])
}
func writeKey(_ k: String, _ v: String) { sendWrite(k, v) }

func ensureDaemon() -> Bool {
    if FileManager.default.fileExists(atPath: FIFO_PATH) { return true }
    guard let res = Bundle.main.resourcePath else { return false }
    let installSh = (res as NSString).appendingPathComponent("install.sh")
    let script = "do shell script \"/bin/bash '\(installSh)' '\(res)' >/tmp/fanctl-install.log 2>&1\" with administrator privileges"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    for _ in 0..<20 {
        if FileManager.default.fileExists(atPath: FIFO_PATH) { return true }
        usleep(250_000)
    }
    return false
}

func detectFans() -> [Int] {
    if let n = readKey("FNum"), let ni = Int(n), ni > 0 {
        return Array(0..<ni)
    }
    var fans: [Int] = []
    for i in 0..<3 {
        if let v = readKey("F\(i)Ac"), let x = Double(v), x > 0 { fans.append(i) }
    }
    return fans.isEmpty ? [0] : fans
}

func fanCurve(_ c: Double) -> Int {
    let maxRpm = Int(readKey("F0Mx") ?? "6500") ?? 6500
    let minRpm = max(1000, maxRpm / 5)
    let lo = 50.0
    let hi = 88.0
    if c <= lo { return minRpm }
    if c >= hi { return maxRpm }
    return minRpm + Int(Double(maxRpm - minRpm) * (c - lo) / (hi - lo))
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var fans: [Int] = []
    var timer: Timer?
    var smcOk = false
    var lastAction = "auto"
    var manualTarget: Int? = nil
    var displayMode = UserDefaults.standard.string(forKey: "displayMode") ?? "both" {
        didSet { UserDefaults.standard.set(displayMode, forKey: "displayMode") }
    }
    var iconMode = UserDefaults.standard.string(forKey: "iconMode") ?? "both" {
        didSet { UserDefaults.standard.set(iconMode, forKey: "iconMode") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = ensureDaemon()
        fans = detectFans()
        smcOk = fans.first != nil && readKey("F0Ac") != nil
        if !smcOk {
            showAlert("SMC unreachable", "Fan speed and temperature could not be read.")
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.title = " -- rpm"
            btn.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        }
        updateIcon()
        statusItem.menu = NSMenu()
        statusItem.menu!.delegate = self
        rebuildMenu()

        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            self.assertFan()
            self.refreshStatus()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func showAlert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.alertStyle = .critical
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    func assertFan() {
        var target: Int
        if let t = manualTarget {
            target = t
        } else if lastAction == "auto" {
            target = fanCurve(cpuTemp())
        } else {
            return
        }
        for i in fans {
            writeKey("F\(i)Md", "1")
            writeKey("F\(i)Mn", "\(target)")
            writeKey("F\(i)Tg", "\(target)")
        }
    }

    func updateIcon() {
        guard let btn = statusItem?.button else { return }
        if iconMode == "text" {
            btn.image = nil
            return
        }
        let name = displayMode == "temp" ? "thermometer" : "fan.fill"
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: "Fan") {
            img.isTemplate = true
            btn.image = img
        }
    }

    func refreshStatus() {
        guard let btn = statusItem?.button else { return }
        let ac = Double(readKey("F0Ac") ?? "0") ?? 0
        let cpu = readTemp(CPU_KEYS) ?? 0
        var text = ""
        switch displayMode {
        case "temp": text = String(format: " %.0f°C", cpu)
        case "rpm": text = String(format: " %.0f rpm", ac)
        default: text = String(format: " %.0f rpm · %.0f°C", ac, cpu)
        }
        btn.title = iconMode == "icon" ? "" : text
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
        refreshStatus()
    }

    func rebuildMenu() {
        guard let m = statusItem?.menu else { return }
        m.removeAllItems()
        for i in fans {
            let ac = readKey("F\(i)Ac") ?? "?"
            let mn = readKey("F\(i)Mn") ?? "?"
            let mxStr = readKey("F\(i)Mx") ?? "?"
            _ = readKey("F\(i)Md")
            let tg = readKey("F\(i)Tg") ?? "0"

            let h = NSMenuItem(title: "Fan \(i)  —  \(ac) rpm", action: nil, keyEquivalent: "")
            h.isEnabled = false
            m.addItem(h)

            let mode = lastAction == "auto" ? "AUTO · temperature curve" : "MANUAL · target \(tg) rpm"
            let mod = NSMenuItem(title: "Mode: \(mode)", action: nil, keyEquivalent: "")
            mod.isEnabled = false
            m.addItem(mod)
            m.addItem(NSMenuItem(title: "min \(mn)  ·  max \(mxStr)  ·  target \(tg) rpm", action: nil, keyEquivalent: ""))
            m.addItem(NSMenuItem(title: "Active: \(self.lastAction.uppercased())", action: nil, keyEquivalent: ""))

            let cpu = readTemp(CPU_KEYS)
            let ram = readTemp(RAM_KEYS)
            let ssd = readTemp(SSD_KEYS)
            let wlan = readTemp(WIFI_KEYS)
            let tItem = NSMenuItem(title: "CPU \(fmtTemp(cpu)) · RAM \(fmtTemp(ram)) · SSD \(fmtTemp(ssd)) · WiFi \(fmtTemp(wlan))",
                                   action: nil, keyEquivalent: "")
            tItem.isEnabled = false
            m.addItem(tItem)

            m.addItem(NSMenuItem.separator())

            let maxItem = NSMenuItem(title: "MAX", action: #selector(setMax), keyEquivalent: "M")
            maxItem.target = self
            if lastAction == "max" { maxItem.state = .on }
            m.addItem(maxItem)

            let minItem = NSMenuItem(title: "MIN", action: #selector(setMin), keyEquivalent: "I")
            minItem.target = self
            if lastAction == "min" { minItem.state = .on }
            m.addItem(minItem)

            let autoItem = NSMenuItem(title: "AUTO", action: #selector(setAuto), keyEquivalent: "A")
            autoItem.target = self
            if lastAction == "auto" { autoItem.state = .on }
            m.addItem(autoItem)

            let subItem = NSMenuItem(title: "Set Speed", action: nil, keyEquivalent: "")
            let sm = NSMenu()
            let mx = Int(readKey("F0Mx") ?? "6500") ?? 6500
            var speeds = Array(stride(from: 1000, through: mx, by: 400))
            if speeds.last != mx { speeds.append(mx) }
            for s in speeds {
                let it = NSMenuItem(title: "\(s) rpm", action: #selector(setSpeed(_:)), keyEquivalent: "")
                it.target = self
                it.tag = s
                if lastAction == "set:\(s)" { it.state = .on }
                sm.addItem(it)
            }
            subItem.submenu = sm
            m.addItem(subItem)

            m.addItem(NSMenuItem.separator())
        }
        let viewItem = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        let vm = NSMenu()
        for (label, key) in [("rpm · °C", "both"), ("rpm only", "rpm"), ("temperature only", "temp")] {
            let it = NSMenuItem(title: label, action: #selector(setDisplayMode(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = key
            if displayMode == key { it.state = .on }
            vm.addItem(it)
        }
        vm.addItem(NSMenuItem.separator())
        for (label, key) in [("Icon + text", "both"), ("Icon only", "icon"), ("Text only", "text")] {
            let it = NSMenuItem(title: label, action: #selector(setIconMode(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = key
            if iconMode == key { it.state = .on }
            vm.addItem(it)
        }
        viewItem.submenu = vm
        m.addItem(viewItem)
        m.addItem(NSMenuItem.separator())
        let aboutItem = NSMenuItem(title: "About FCM", action: #selector(openRepo), keyEquivalent: "")
        aboutItem.target = self
        m.addItem(aboutItem)
        m.addItem(NSMenuItem.separator())
        m.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
    }

    @objc func openRepo() {
        if let url = URL(string: "https://github.com/bymfd/fcm") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func setIconMode(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? String {
            iconMode = key
            updateIcon()
            refreshStatus()
        }
    }

    @objc func setDisplayMode(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? String {
            displayMode = key
            updateIcon()
            refreshStatus()
        }
    }

    @objc func setMax() {
        lastAction = "max"
        for i in fans {
            if let mx = readKey("F\(i)Mx") {
                writeKey("F\(i)Md", "1")
                writeKey("F\(i)Mn", mx)
                writeKey("F\(i)Tg", mx)
            }
        }
        manualTarget = Int(readKey("F0Mx") ?? "6500") ?? 6500
        refreshStatus()
    }
    @objc func setMin() {
        lastAction = "min"
        let t = min(1800, Int(readKey("F0Mx") ?? "1800") ?? 1800)
        for i in fans {
            writeKey("F\(i)Md", "1")
            writeKey("F\(i)Mn", "\(t)")
            writeKey("F\(i)Tg", "\(t)")
        }
        manualTarget = t
        refreshStatus()
    }
    @objc func setAuto() {
        lastAction = "auto"
        manualTarget = nil
        assertFan()
        refreshStatus()
    }
    @objc func setSpeed(_ sender: NSMenuItem) {
        lastAction = "set:\(sender.tag)"
        for i in fans {
            writeKey("F\(i)Md", "1")
            writeKey("F\(i)Mn", "\(sender.tag)")
            writeKey("F\(i)Tg", "\(sender.tag)")
        }
        manualTarget = sender.tag
        refreshStatus()
    }
    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if manualTarget != nil || lastAction == "auto" {
            for i in fans {
                writeKey("F\(i)Md", "0")
                writeKey("F\(i)Tg", "6500")
            }
        }
    }
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
