import WebRTC

/// Independent view-only raw-source registration; inline concealment may detach its own renderer.
/// The root still owns permission to receive this track in the background.
final class LivePiPSource: NSObject, RTCVideoRenderer {
    let track: RTCVideoTrack
    private let identity: VideoPresentationIdentity
    private let fence: VideoPresentationFence
    private let deliver: (VideoFrameEnvelope) -> Void
    init(track: RTCVideoTrack, admission: VideoPresentationAdmission, fence: VideoPresentationFence,
         deliver: @escaping (VideoFrameEnvelope) -> Void) {
        self.track = track; identity = admission.identity; self.fence = fence; self.deliver = deliver
        super.init(); track.add(self)
    }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        _ = fence.withAdmission(identity, at: ProcessInfo.processInfo.systemUptime) {
            deliver(VideoFrameEnvelope(receiptID: UUID(), identity: identity, frame: frame,
                arrivalMs: MachClock.nowMs(), marker: nil, originalSource: true))
        }
    }
    /// Caller has already closed the fence. Late decode callbacks cannot deliver after detach.
    func detach() { track.remove(self) }
}
