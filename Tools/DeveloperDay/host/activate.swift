import AppKit
let pid = Int32(CommandLine.arguments[1])!
guard let app = NSRunningApplication(processIdentifier: pid) else { exit(2) }
app.activate(options: [.activateAllWindows])
for _ in 0..<40 {
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { print("front"); exit(0) }
    usleep(100_000)
}
print("not front"); exit(3)
