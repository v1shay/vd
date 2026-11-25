import AppKit
import ApplicationServices

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(1)
}
let args = Array(CommandLine.arguments.dropFirst())
func arg(_ i: Int) -> String {
    guard args.indices.contains(i) else { fail("Missing argument \(i)") }
    return args[i]
}
let cmd = arg(0)
if cmd == "apps" {
    let rows = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map {
        ["pid": $0.processIdentifier, "app": $0.localizedName ?? "", "bundle": $0.bundleIdentifier ?? ""] as [String: Any]
    }
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: rows))
    exit(0)
}
let name = arg(1)
let locations = [URL(fileURLWithPath:"/Applications"), URL(fileURLWithPath:"/System/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
let byName = locations.map { $0.appendingPathComponent(name.hasSuffix(".app") ? name : name + ".app") }
    .first { FileManager.default.fileExists(atPath:$0.path) }
let bundle = byName.flatMap { Bundle(url:$0)?.bundleIdentifier } ?? name
if cmd == "launch" {
    guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { fail("Application not installed") }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = false
    config.createsNewApplicationInstance = true
    config.promptsUserIfNeeded = false
    let existing = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundle).map(\.processIdentifier))
    let completion: (NSRunningApplication?, Error?) -> Void = { app, error in
        if let error { fail(error.localizedDescription) }
        guard let app, !existing.contains(app.processIdentifier) else { fail("App requires its existing instance") }
        print(app.processIdentifier)
        exit(0)
    }
    if args.count > 2 {
        let file = URL(fileURLWithPath: arg(2)).standardizedFileURL
        guard FileManager.default.fileExists(atPath: file.path) else { fail("File does not exist") }
        NSWorkspace.shared.open([file], withApplicationAt: application, configuration: config, completionHandler: completion)
    } else {
        NSWorkspace.shared.openApplication(at: application, configuration: config, completionHandler: completion)
    }
    RunLoop.main.run()
}
fail("Expected launch BUNDLE [FILE]")
