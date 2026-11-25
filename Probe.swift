// Separate native AppKit process used only by the live integration test.
import AppKit

final class Probe: NSObject {
    let log: URL
    init(_ path: String) { log = URL(fileURLWithPath: path) }
    @objc func pressed() { try? "pressed".write(to: log, atomically: true, encoding: .utf8) }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let id = UInt32(CommandLine.arguments[1])!
guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }) else { exit(2) }
let probe = Probe(CommandLine.arguments[2])
let rect = NSRect(x: screen.frame.midX-180, y: screen.frame.midY-100, width: 360, height: 200)
let window = NSWindow(contentRect:rect, styleMask:[.titled,.closable], backing:.buffered, defer:false)
window.title = "VD integration fixture"
let button = NSButton(title:"Verify click",target:probe,action:#selector(Probe.pressed))
button.frame = NSRect(x:100,y:70,width:160,height:40)
window.contentView?.addSubview(button)
let field = NSTextField(frame:NSRect(x:40,y:145,width:280,height:28))
field.stringValue = "fixture draft"
window.contentView?.addSubview(field)
window.setFrameOrigin(rect.origin)
window.makeFirstResponder(field)
window.orderFront(nil)
let events = URL(fileURLWithPath:CommandLine.arguments[2] + "-events")
let monitor = NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.leftMouseUp,.leftMouseDragged,.scrollWheel,.keyDown]) { event in
    let entry = "\(event.type.rawValue) \(event.windowNumber) \(Int(event.locationInWindow.x)) \(Int(event.locationInWindow.y))\n"
    if let stream=OutputStream(url:events,append:true) {
        stream.open()
        _ = stream.write(Array(entry.utf8),maxLength:entry.utf8.count)
        stream.close()
    }
    return event
}
let point = button.convert(NSPoint(x:button.bounds.midX,y:button.bounds.midY), to:nil)
print("\(window.windowNumber) \(Int(point.x)) \(Int(window.frame.height-point.y))")
fflush(stdout)
app.run()
