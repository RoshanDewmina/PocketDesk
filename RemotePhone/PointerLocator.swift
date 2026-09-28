import SwiftUI
import Combine

/// A temporary location aid. It never predicts or changes the actual remote pointer.
@MainActor
final class PointerLocator: ObservableObject {
    @Published private(set) var point: CGPoint?
    private var state = PointerProbeState()
    private var lastMotion: TimeInterval = -.infinity

    let followUpdates = PassthroughSubject<CGPoint, Never>()
    private var followingMotion = false

    func moved(at now: TimeInterval) {
        if !followingMotion { state = PointerProbeState() }
        lastMotion = now
        followingMotion = true
    }

    func stopFollowing() {
        followingMotion = false
        state = PointerProbeState()
    }

    func poll(at now: TimeInterval, available: Bool) -> String? {
        guard available, now >= lastMotion, now - lastMotion < 0.8 else {
            clear()
            return nil
        }
        state.expire(at: now)
        point = state.point
        return state.begin(at: now)
    }

    func receive(_ action: RemoteAction, at now: TimeInterval, sourceSize: CGSize) {
        guard now >= lastMotion, now - lastMotion < 0.8, let probe = action.pointerProbe else { return }
        let accepted = state.receive(probe: probe, location: action.pointerLocation, at: now, sourceSize: sourceSize)
        point = state.point
        // The challenge already rejects responses older than 250 ms. Requiring
        // another 80 ms from the last touch discarded ordinary round trips.
        if accepted, followingMotion, let point {
            followUpdates.send(point)
        }
    }

    func clear() {
        followingMotion = false
        state = PointerProbeState()
        point = nil
        lastMotion = -.infinity
    }
}

/// Set `showsRing` to false to remove the ring; locating and edge-follow keep working.
enum PointerLocatorAppearance {
    static let showsRing = false
}

struct PointerLocatorOverlay: View {
    @ObservedObject var locator: PointerLocator
    let viewport: ViewportTransform

    var body: some View {
        if PointerLocatorAppearance.showsRing, let point = locator.point {
            let mapped = viewport.viewPoint(fromSource: point)
            if mapped.x >= 0, mapped.y >= 0,
               mapped.x <= viewport.canvasSize.width, mapped.y <= viewport.canvasSize.height {
                Circle()
                    .stroke(.black.opacity(0.9), lineWidth: 5)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .frame(width: 38, height: 38)
                    .position(mapped)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}
