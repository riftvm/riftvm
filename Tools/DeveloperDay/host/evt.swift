import AppKit
import CoreGraphics
import Foundation

// evt move X Y | click X Y [right|middle] | down X Y | up X Y | drag X1 Y1 X2 Y2
//     | key CODE [cmd,shift,ctrl,alt] | type TEXT | scroll DY [DX] | pos | clicks N X Y
let a = CommandLine.arguments
let src = CGEventSource(stateID: .hidSystemState)
// Refuse to send anything unless the target app (EVT_PID) is frontmost, so
// keystrokes never land in another app.
let guardPID = ProcessInfo.processInfo.environment["EVT_PID"].flatMap { Int32($0) }
func checkFront() {
    guard let pid = guardPID else { FileHandle.standardError.write("EVT_PID not set\n".data(using: .utf8)!); exit(4) }
    if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
        FileHandle.standardError.write("target not frontmost; refusing\n".data(using: .utf8)!); exit(3)
    }
}
func post(_ e: CGEvent?) { checkFront(); e?.post(tap: .cghidEventTap); usleep(12_000) }
func pt(_ i: Int) -> CGPoint { CGPoint(x: Double(a[i])!, y: Double(a[i + 1])!) }
func mouse(_ t: CGEventType, _ p: CGPoint, _ b: CGMouseButton = .left) {
    post(CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: b))
}
func flags(_ s: String) -> CGEventFlags {
    var f: CGEventFlags = []
    for p in s.split(separator: ",") {
        switch p { case "cmd": f.insert(.maskCommand); case "shift": f.insert(.maskShift)
        case "ctrl": f.insert(.maskControl); case "alt": f.insert(.maskAlternate); default: break }
    }
    return f
}
switch a[1] {
case "move": mouse(.mouseMoved, pt(2))
case "pos": print(CGEvent(source: nil)!.location)
case "click":
    let b: CGMouseButton = a.count > 4 ? (a[4] == "right" ? .right : .center) : .left
    let (d, u): (CGEventType, CGEventType) = b == .left ? (.leftMouseDown, .leftMouseUp) : b == .right ? (.rightMouseDown, .rightMouseUp) : (.otherMouseDown, .otherMouseUp)
    mouse(.mouseMoved, pt(2)); mouse(d, pt(2), b); mouse(u, pt(2), b)
case "clicks":
    let n = Int(a[2])!; let p = CGPoint(x: Double(a[3])!, y: Double(a[4])!)
    mouse(.mouseMoved, p)
    for _ in 0..<n { mouse(.leftMouseDown, p); mouse(.leftMouseUp, p); usleep(40_000) }
case "down": mouse(.leftMouseDown, pt(2))
case "up": mouse(.leftMouseUp, pt(2))
case "drag":
    let s = pt(2), e = pt(4)
    mouse(.mouseMoved, s); mouse(.leftMouseDown, s)
    for i in 1...30 { let t = Double(i) / 30
        mouse(.leftMouseDragged, CGPoint(x: s.x + (e.x - s.x) * t, y: s.y + (e.y - s.y) * t)) }
    mouse(.leftMouseUp, e)
case "key":
    let code = CGKeyCode(Int(a[2])!); let f = a.count > 3 ? flags(a[3]) : []
    let d = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true); d?.flags = f; post(d)
    let u = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false); u?.flags = f; post(u)
case "type":
    // US layout: character -> (virtual key, shift)
    let base: [Character: Int] = ["a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"=":24,"9":25,"7":26,"-":27,"8":28,"0":29,"]":30,"o":31,"u":32,"[":33,"i":34,"p":35,"l":37,"j":38,"'":39,"k":40,";":41,"\\":42,",":43,"/":44,"n":45,"m":46,".":47,"`":50," ":49,"\n":36,"\t":48]
    let shifted: [Character: Character] = ["!":"1","@":"2","#":"3","$":"4","%":"5","^":"6","&":"7","*":"8","(":"9",")":"0","_":"-","+":"=","{":"[","}":"]","|":"\\",":":";","\"":"'","<":",",">":".","?":"/","~":"`"]
    for ch in a[2] {
        var key = ch; var shift = false
        if let s = shifted[ch] { key = s; shift = true }
        else if ch.isUppercase { key = Character(ch.lowercased()); shift = true }
        guard let code = base[key] else { continue }
        let f: CGEventFlags = shift ? .maskShift : []
        if shift { let s = CGEvent(keyboardEventSource: src, virtualKey: 56, keyDown: true); s?.flags = .maskShift; post(s) }
        let d = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: true); d?.flags = f; post(d)
        let u = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: false); u?.flags = f; post(u)
        if shift { let s = CGEvent(keyboardEventSource: src, virtualKey: 56, keyDown: false); post(s) }
    }
case "scroll":
    let dy = Int32(a[2])!, dx = a.count > 3 ? Int32(a[3])! : 0
    let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
    // A trackpad: continuous, precise deltas.
    if a.count > 4 { e?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1) }
    post(e)
default: print("unknown")
}
