import Foundation

// Native entry point for ctrlSPEAK.app.
//
// macOS attributes TCC permissions to the *responsible process*, which is the
// root of the process tree rather than whichever binary happens to call the
// API. Running ctrlSPEAK straight from a LaunchAgent made that root /bin/bash,
// so Microphone, Accessibility and Input Monitoring had to be granted to bash
// or to the Homebrew Python symlink — a versioned Cellar path that Input
// Monitoring will not accept and that breaks on every Python upgrade.
//
// This launcher is that root instead. It is a real Mach-O binary inside a
// bundle, so the permission panes show "ctrlSPEAK", and every child it spawns
// inherits it as the responsible process.
//
// It deliberately spawns the wrapper as a child rather than exec'ing it:
// exec would replace this image, and the responsible process would become the
// shell again. For the same reason it holds no configuration of its own —
// paths are read from Resources/launch.conf so the binary stays byte-identical
// across machines and keeps its ad-hoc code signature, and with it its
// permissions, stable between installs.

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("ctrlSPEAK: \(message)\n".utf8))
    exit(code)
}

guard let configURL = Bundle.main.url(forResource: "launch", withExtension: "conf"),
      let rawConfig = try? String(contentsOf: configURL, encoding: .utf8) else {
    fail("launch.conf is missing from the app bundle; re-run install.sh", code: 78)
}

var config: [String: String] = [:]
for line in rawConfig.split(separator: "\n") {
    let entry = line.trimmingCharacters(in: .whitespaces)
    guard !entry.isEmpty, !entry.hasPrefix("#"),
          let separator = entry.firstIndex(of: "=") else { continue }
    config[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
}

guard let command = config["command"] else {
    fail("launch.conf has no 'command' entry; re-run install.sh", code: 78)
}

guard FileManager.default.isExecutableFile(atPath: command) else {
    fail("\(command) is missing or not executable; re-run install.sh", code: 72)
}

let child = Process()
child.executableURL = URL(fileURLWithPath: command)
child.arguments = Array(CommandLine.arguments.dropFirst())

var environment = ProcessInfo.processInfo.environment
if let path = config["path"] {
    environment["PATH"] = path
}
if let overlay = config["overlay"] {
    environment["CTRLSPEAK_OVERLAY_PATH"] = overlay
}
child.environment = environment

// launchctl bootout signals this process; the child has to come down with it
// or KeepAlive would restart into an orphaned transcription worker.
// The sources must outlive this setup, so they are kept in a global.
var terminationSources: [DispatchSourceSignal] = []
for terminationSignal in [SIGTERM, SIGINT, SIGHUP] {
    signal(terminationSignal, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: terminationSignal, queue: .main)
    source.setEventHandler {
        if child.isRunning {
            child.terminate()
        }
    }
    source.resume()
    terminationSources.append(source)
}

child.terminationHandler = { finished in
    exit(finished.terminationStatus)
}

do {
    try child.run()
} catch {
    fail("could not start \(command): \(error.localizedDescription)", code: 70)
}

dispatchMain()
