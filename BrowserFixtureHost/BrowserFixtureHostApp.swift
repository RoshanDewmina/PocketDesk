import SwiftUI
import AppKit
import CoreVideo
import Combine

@main
struct BrowserFixtureHostApp: App {
    @StateObject private var model = BrowserFixtureModel()
    var body: some Scene {
        WindowGroup("PocketDesk synthetic browser test") {
            VStack(alignment:.leading,spacing:12) {
                Text("Synthetic native WebRTC sender").font(.title2)
                Text("Invented content only. No screen capture, no OS input, no persistent trust.")
                Text(model.status).textSelection(.enabled)
                Text("Accepted fixture actions: \(model.accepted)")
                Button("End fixture") { model.stop(); NSApplication.shared.terminate(nil) }
            }.padding(24).frame(width:520)
        }
    }
}

@MainActor
final class BrowserFixtureModel: ObservableObject {
    @Published var status = "Starting synthetic fixture"
    @Published var accepted = 0
    private let controller: BrowserPeerController
    private let gate = BrowserInputGate()
    private var subscriptions = Set<AnyCancellable>()
    private var timer: Timer?
    private var tick = 0
    private var fixtureText = "Change this harmless line from the browser."
    private var offerSaved = false
    private var startedAt = ProcessInfo.processInfo.systemUptime
    private var stale = false
    private var healthy = true
    private var lastRaw: CVPixelBuffer?
    private let receiptPath: String?
    init() {
        var memory: [String:Data] = [:]
        let backend = BrowserPeerStoreBackend(read: { memory[$0] }, write: { memory[$0] = $1 }, delete: { memory.removeValue(forKey:$0) })
        controller = BrowserPeerController(store:BrowserPeerStore(backend:backend),canAcquire:{true},release:{},autoApproveSyntheticEnrollment:true)
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["POCKETDESK_FIXTURE_PID"] {
            try? String(ProcessInfo.processInfo.processIdentifier).write(toFile:path,atomically:true,encoding:.utf8)
        }
        receiptPath = environment["POCKETDESK_FIXTURE_RECEIPT"]
        let server = environment["POCKETDESK_BROWSER_URL"] ?? "ws://127.0.0.1:8788/browser-host"
        controller.onAuthenticated = { [weak self] peer, _ in self?.begin(peer:peer) }
        controller.onEnded = { [weak self] in self?.gate.begin(session:"",revision:1) }
        controller.onControl = { [weak self] bytes in self?.input(bytes) }
        controller.$status.sink { [weak self] value in
            guard let self else { return }; self.status=value
            if value == "Browser access service is ready" && !self.offerSaved {
                self.offerSaved=true
                Task { @MainActor [weak self] in
                    guard let self else { return }; self.controller.makeEnrollment()
                    if let path=environment["POCKETDESK_FIXTURE_OFFER"] {
                        try? self.controller.enrollmentCode.write(toFile:path,atomically:true,encoding:.utf8)
                        try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path)
                    }
                }
            }
        }.store(in:&subscriptions)
        controller.start(serverURL:server,display:"synthetic",revision:1,maximumMode:environment["POCKETDESK_FIXTURE_MODE"] ?? "interactive")
        timer=Timer.scheduledTimer(withTimeInterval:1.0/30,repeats:true) { [weak self] _ in Task { @MainActor in self?.draw() } }
    }
    func stop() { timer?.invalidate(); timer=nil; controller.stop() }
    private func begin(peer:PeerMedia) {
        gate.begin(session:controller.sessionID,revision:1)
        let marker=BrowserFrameMarker(), gate=self.gate
        peer.setFrameTransform { buffer,_ in
            guard let (output,token)=try? marker.mark(buffer) else { return nil }
            gate.record(token:token,at:ProcessInfo.processInfo.systemUptime); return output
        }
        healthy=true; stale=false; publish()
    }
    private func draw() {
        guard ProcessInfo.processInfo.systemUptime-startedAt < 1800 else { stop(); NSApplication.shared.terminate(nil); return }
        guard controller.connected, let peer=controller.peer else { return }
        tick+=1
        if tick % 6 == 0 { publish() }
        guard !stale else { return }
        let width=1280,height=720
        var target:CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault,width,height,kCVPixelFormatType_32BGRA,[kCVPixelBufferCGImageCompatibilityKey:true,kCVPixelBufferCGBitmapContextCompatibilityKey:true] as CFDictionary,&target)
        guard let target else { return }
        CVPixelBufferLockBaseAddress(target,[])
        guard let context=CGContext(data:CVPixelBufferGetBaseAddress(target),width:width,height:height,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(target),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue) else { CVPixelBufferUnlockBaseAddress(target,[]); return }
        context.setFillColor(CGColor(red:0.04,green:0.06,blue:0.09,alpha:1));context.fill(CGRect(x:0,y:0,width:width,height:height))
        context.translateBy(x:0,y:CGFloat(height));context.scaleBy(x:1,y:-1)
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:true)
        let rows=["SYNTHETIC TEST · Native H.264 → browser · frame \(tick)","", "// A harmless edit-and-check fixture", "function add(a, b) {", "    return a + b;", "}", "", "expect(add(2, 3)).toEqual(5);", "✓ Fixture test passed · punctuation: {} [] () ; : ", "", "Browser input: \(fixtureText)", "Accepted actions: \(accepted)", "", "Type FREEZE to stop frames; End and reconnect restores video.","No actual Mac desktop or OS input is used."]
        for (index,row) in rows.enumerated() {
            let color:NSColor = index==0 ? .systemTeal : (index==8 ? .systemGreen : .white)
            (row as NSString).draw(at:NSPoint(x:28,y:24+index*38),withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:22,weight:.regular),.foregroundColor:color])
        }
        NSGraphicsContext.restoreGraphicsState();CVPixelBufferUnlockBaseAddress(target,[])
        peer.pushFrame(target,timeStampNs:Int64(ProcessInfo.processInfo.systemUptime*1_000_000_000));lastRaw=target
    }
    private func input(_ bytes:Data) {
        do {
            let action=try gate.accept(bytes,at:ProcessInfo.processInfo.systemUptime,healthy:healthy,control:controller.mode=="interactive")
            if action.action != "release" { accepted+=1 }
            if action.action=="text" {
                fixtureText=action.text
                if action.text=="FREEZE" { stale=true }
                if action.text=="RESET" { stale=false }
                send(["type":"textResult","key":action.key,"accepted":true])
            }
            if let receiptPath { let receipt:[String:Any]=["accepted":accepted,"lastAction":action.action,"frames":tick,"synthetic":true]; if let data=try? JSONSerialization.data(withJSONObject:receipt) { try? data.write(to:URL(fileURLWithPath:receiptPath),options:.atomic) } }
        } catch { if let receiptPath { try? "{\"rejected\":true,\"synthetic\":true}".write(toFile:receiptPath+".rejection",atomically:true,encoding:.utf8) } }
    }
    private func publish() { send(["type":"status","session":controller.sessionID,"revision":"1","mode":controller.mode,"healthy":healthy,"control":controller.mode=="interactive","width":1280,"height":720]) }
    private func send(_ value:[String:Any]) { if let data=try? JSONSerialization.data(withJSONObject:value) { _=controller.sendStatus(data) } }
}
