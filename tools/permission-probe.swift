import Cocoa
import ApplicationServices

let log = { (s: String) in
    FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!)
}
log("AXIsProcessTrusted = \(AXIsProcessTrusted())")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

var flagCount = 0
var keyCount = 0

// Test 1: global monitor for modifier-key changes (Shift, Cmd, Opt...)
NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { e in
    flagCount += 1
    log("FLAGS  #\(flagCount)  keyCode=\(e.keyCode)  flags=\(e.modifierFlags.rawValue)")
}
// Test 2: global monitor for actual keystrokes (the privacy-sensitive one)
NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { e in
    keyCount += 1
    log("KEYDOWN #\(keyCount) keyCode=\(e.keyCode) chars=\(e.charactersIgnoringModifiers ?? "?")")
}

log("listening 45s — press SHIFT a few times, then type some letters")
Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { _ in
    log("RESULT flagsChanged=\(flagCount) keyDown=\(keyCount)")
    exit(0)
}
app.run()
