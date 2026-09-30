import Foundation
import CoreGraphics

/// The colour contract between the Mac's capture and the phone's renderer.
///
/// libwebrtc's `RTCMTLNV12Renderer` (WebRTC 153, read from the shipped binary) converts with fixed
/// BT.601 coefficients and ignores the frame's colour tags. Left unset, ScreenCaptureKit outputs the
/// display's own colour space (Display P3 on recent Macs) with its default matrix, so the phone
/// decoded the wrong matrix and gamut and hues shifted. Pinning sRGB and BT.601 at capture makes the
/// numbers the phone's shader assumes true; VideoToolbox carries the buffers' tags into the stream,
/// so a browser that honours them decodes the same colours.
enum StreamColor {
    /// The exact expression in the renderer's NV12 fragment shader. A WebRTC update that changes it
    /// must revisit the capture settings below (StreamColorTests fails first).
    static let rendererShaderExpression =
        "float4(y + 1.403 * uv.y, y - 0.344 * uv.x - 0.714 * uv.y, y + 1.770 * uv.x, 1.0)"

    #if os(macOS)
    static let captureColorSpaceName: CFString = CGColorSpace.sRGB
    static let captureYCbCrMatrix: CFString = CGDisplayStream.yCbCrMatrix_ITU_R_601_4
    #endif
}
