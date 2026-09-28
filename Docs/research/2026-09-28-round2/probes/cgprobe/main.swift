import Foundation
import CoreGraphics
import ApplicationServices
func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e3 }
print("AXIsProcessTrusted: \(AXIsProcessTrusted())")
let loc = CGEvent(source: nil)!.location
var create: [Double] = [], lookup: [Double] = [], post: [Double] = []
for _ in 0..<2000 {
    let t0 = now(); let l = CGEvent(source: nil)?.location ?? .zero; lookup.append(now() - t0)
    let t1 = now(); let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: l, mouseButton: .left)!; create.append(now() - t1)
    if AXIsProcessTrusted() { let t2 = now(); e.post(tap: .cghidEventTap); post.append(now() - t2) }
}
func pct(_ a: [Double], _ p: Double) -> String { let s = a.sorted(); return s.isEmpty ? "-" : String(format: "%.0f", s[min(s.count - 1, Int(Double(s.count) * p))]) }
print("CGEvent(source:nil).location  p50 \(pct(lookup, 0.5)) us  p99 \(pct(lookup, 0.99)) us")
print("CGEvent(mouseEventSource:) create p50 \(pct(create, 0.5)) us p99 \(pct(create, 0.99)) us")
print("post(cghidEventTap) same-location mouseMoved p50 \(pct(post, 0.5)) us p99 \(pct(post, 0.99)) us n=\(post.count)")
