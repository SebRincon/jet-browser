import AppKit
import CryptoKit
import Darwin
import Foundation

// Process.run runs only in this launcher, before execv replaces it with Flutter/CEF.
// CEF therefore never spawns the controller. The controller is a separate process and
// can stay alive across UI restarts; last-window termination of the GUI is unchanged.
// Helper binaries are only python/bin/python3.12, bin/grok, and bin/JetWorkflow under
// Contents/Resources/jet-runtime. No system Python and no profile or credential writes.
// Logs never include tokens.

func fail(_ text: String) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Jet Browser"
    alert.informativeText = text
    alert.addButton(withTitle: "Quit")
    alert.runModal()
    exit(1)
}

func nest(_ url: URL, under root: URL) -> Bool {
    let path = url.resolvingSymlinksInPath().path
    let base = root.resolvingSymlinksInPath().path
    return path == base || path.hasPrefix(base + "/")
}

func kind(_ url: URL, _ mode: mode_t) -> Bool {
    var st = stat()
    return stat(url.resolvingSymlinksInPath().path, &st) == 0 && (st.st_mode & S_IFMT) == mode
}

func portBusy(_ port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port)).bigEndian
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    var tv = timeval(tv_sec: 0, tv_usec: 200_000)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        }
    }
}

let fm = FileManager.default
let cli = CommandLine.arguments
let contents = URL(fileURLWithPath: cli[0]).resolvingSymlinksInPath()
    .deletingLastPathComponent().deletingLastPathComponent()
guard contents.lastPathComponent == "Contents" else {
    fail("JetLauncher must be the app CFBundleExecutable.")
}
let appURL = contents.deletingLastPathComponent()
guard appURL.pathExtension == "app" else { fail("JetLauncher is not inside an application bundle.") }

let resources = contents.appendingPathComponent("Resources/jet-runtime")
let realExec = contents.appendingPathComponent("MacOS/Jet Browser")
let python = resources.appendingPathComponent("python/bin/python3.12")
let backend = resources.appendingPathComponent("backend")
let servicePkg = resources.appendingPathComponent("packages/service")
let grok = resources.appendingPathComponent("bin/grok")
let workflow = resources.appendingPathComponent("bin/JetWorkflow")
let execPath = realExec.resolvingSymlinksInPath().path
guard nest(realExec, under: appURL), realExec.lastPathComponent == "Jet Browser", kind(realExec, S_IFREG) else {
    fail("The Flutter executable must be Contents/MacOS/Jet Browser in this same app.")
}
for file in [python, grok, workflow] where !nest(file, under: resources) || !kind(file, S_IFREG) {
    fail("Missing bundled runtime file \(file.lastPathComponent).")
}
for dir in [resources, backend, servicePkg] where !nest(dir, under: resources) || !kind(dir, S_IFDIR) {
    fail("Jet runtime resources are incomplete.")
}

let inherited = ProcessInfo.processInfo.environment
let dataRoot: URL = {
    if let raw = inherited["JET_DATA_ROOT"], !raw.isEmpty {
        guard raw.hasPrefix("/") else { fail("JET_DATA_ROOT must be an absolute path.") }
        return URL(fileURLWithPath: raw, isDirectory: true).standardized
    }
    return fm.homeDirectoryForCurrentUser.appendingPathComponent(".jet-browser", isDirectory: true).standardized
}()
let port: Int = {
    guard let raw = inherited["JET_PORT"], !raw.isEmpty else { return 9148 }
    guard let value = Int(raw), (1024...65533).contains(value) else {
        fail("JET_PORT must be an integer from 1024 through 65533.")
    }
    return value
}()

let runtime = dataRoot.appendingPathComponent(".runtime", isDirectory: true)
var link = stat()
if lstat(runtime.path, &link) == 0, (link.st_mode & S_IFMT) == S_IFLNK {
    fail("Refusing a symlinked data/.runtime directory.")
}
do {
    try fm.createDirectory(at: runtime, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtime.path)
} catch { fail("Could not create the runtime directory.") }

let token = runtime.appendingPathComponent("token")
if lstat(token.path, &link) == 0 {
    if (link.st_mode & S_IFMT) == S_IFLNK { fail("The data token must not be a symlink.") }
    if (link.st_mode & 0o777) != 0o600 { fail("The data token must be mode 0600.") }
}

guard let resolvedData = realpath(dataRoot.path, nil) else { fail("Could not resolve the data directory.") }
let canonicalData = String(cString: resolvedData)
free(resolvedData)
let instance = SHA256.hash(data: Data(canonicalData.utf8)).prefix(8)
    .map { String(format: "%02x", $0) }.joined()

struct Health: Decodable { let application: String; let instance: String }
enum Probe { case ours, foreign, down }

func probe() -> Probe {
    let url = URL(string: "http://127.0.0.1:\(port)/health")!
    var request = URLRequest(url: url, timeoutInterval: 1)
    request.httpMethod = "GET"
    let sem = DispatchSemaphore(value: 0)
    var found = Probe.down
    URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, _ in
        defer { sem.signal() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data else { return }
        guard let health = try? JSONDecoder().decode(Health.self, from: data) else { found = .foreign; return }
        found = (health.application == "jet-browser" && health.instance == instance) ? .ours : .foreign
    }.resume()
    _ = sem.wait(timeout: .now() + 1.2)
    return found
}

let initial = probe()
if case .foreign = initial {
    fail("Close the other Jet instance using port \(port), then open Jet Browser again.")
}

var child = inherited
child.removeValue(forKey: "PYTHONHOME")
child.removeValue(forKey: "PYTHONPATH")
for key in child.keys.filter({ $0.hasPrefix("VTEN_") || $0.hasPrefix("VIBECODER_") || $0.hasPrefix("BU_") || $0.hasPrefix("TYPESAFE_") }) {
    child.removeValue(forKey: key)
}
child["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
child["JET_RESOURCE_ROOT"] = resources.path
child["JET_DATA_ROOT"] = dataRoot.path
child["JET_ROOT"] = dataRoot.path
child["JET_PORT"] = String(port)
child["JET_WORKFLOW_PATH"] = workflow.path
child["JET_GROK_PATH"] = grok.path
child["PYTHONPATH"] = "\(backend.path):\(servicePkg.path)"
child["PYTHONNOUSERSITE"] = "1"
child["PYTHONDONTWRITEBYTECODE"] = "1"
child["TEXT_MODEL_API_KEY"] = "local-only"
child["TEXT_MODEL"] = "default_model"
child["TEXT_MODEL_BASE_URL"] = "http://127.0.0.1:\(port + 1)/v1"
child["TEXT_MODEL_REASONING"] = "none"

if initial == .down {
    let busy = portBusy(port)
    if busy { fail("Port \(port) is already in use. Close the other Jet instance first.") }
    let logURL = runtime.appendingPathComponent("service.log")
    if lstat(logURL.path, &link) == 0, (link.st_mode & S_IFMT) == S_IFLNK {
        fail("Refusing a symlinked service log.")
    }
    if !fm.fileExists(atPath: logURL.path) {
        fm.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
    guard let handle = FileHandle(forWritingAtPath: logURL.path) else { fail("Could not open the service log.") }
    handle.seekToEndOfFile()
    let proc = Process()
    proc.executableURL = python
    proc.arguments = ["-m", "jet_browser.service"]
    proc.currentDirectoryURL = dataRoot
    proc.environment = child
    proc.standardInput = FileHandle.nullDevice
    proc.standardOutput = handle
    proc.standardError = handle
    do { try proc.run() } catch { fail("Could not launch the bundled controller.") }
    try? handle.close()
    let pidURL = runtime.appendingPathComponent("service.pid")
    try? Data("\(proc.processIdentifier)\n".utf8).write(to: pidURL, options: .atomic)
    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pidURL.path)
    let deadline = Date().addingTimeInterval(15)
    var started = false
    while Date() < deadline {
        switch probe() {
        case .ours: started = true
        case .foreign:
            fail("Close the other Jet instance using port \(port), then open Jet Browser again.")
        case .down where !proc.isRunning:
            fail("The controller exited before it was healthy. See \(logURL.path).")
        case .down: break
        }
        if started { break }
        Thread.sleep(forTimeInterval: 0.1)
    }
    if !started {
        let extra = busy ? " Port \(port) was already in use, so startup can fail." : ""
        fail("The controller did not become healthy. See \(logURL.path).\(extra) Logs do not include credentials.")
    }
}

for key in Set(inherited.keys).subtracting(child.keys) { unsetenv(key) }
for (key, value) in child { setenv(key, value, 1) }
let dupes = ([execPath] + cli.dropFirst()).map { strdup($0) }
defer { dupes.forEach { free($0) } }
dupes.withUnsafeBufferPointer { buffer in
    var vector: [UnsafeMutablePointer<CChar>?] = buffer.map { $0 }
    vector.append(nil)
    vector.withUnsafeMutableBufferPointer { raw in _ = execv(execPath, raw.baseAddress) }
}
fail("Could not start Jet Browser.")
