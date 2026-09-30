import Foundation
import Network

// Compile fixtures for the stand-alone pure state machines, not wire/target verification.
struct LocalPathInterface {
    var name: String
    var index: UInt32
    var type: NWInterface.InterfaceType
}
struct HostStreamSummary {
    var pacerDelayMs: Double?
    var captureGapP90Ms: Double?
    var macLink: String?
}
struct StreamStatsReport {
    var hostFramesEncodedTotal: Int?
    var framesArrivedAtMark: Int?
    var frameMarkAt: TimeInterval?
    var hostSummaryAgeMs: Double?
    var host: HostStreamSummary?
    var jitterBufferMs: Double?
    var decodeMs: Double?
    var rttSampleMs: Double?
    var route: String?
    var routeDetail: String?
    var receivedFPS: Double?
    var renderGapMaxMs: Double?
    var packetLossPercent: Double?
}
