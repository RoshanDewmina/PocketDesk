import XCTest
import MetalKit
import WebRTC
@testable import PocketDeskRemote

final class LoupePresentationTests: XCTestCase {
    @MainActor
    func testLoupeDerivativeSharesExactAdmissionAndGlobalTerminalRetirement() throws {
        VideoPresentationSession.invalidateActive()
        defer { VideoPresentationSession.invalidateActive() }
        let factory = RTCPeerConnectionFactory()
        let track = factory.videoTrack(with: factory.videoSource(), trackId: "loupe")
        let identity = VideoPresentationIdentity(hostRecordID: "host", ownerPairID: "owner", sessionID: UUID(), trackID: UUID(), contentEpoch: 1, geometryEpoch: 2)
        let proof = VideoPresentationAdmission(identity: identity, validUntil: ProcessInfo.processInfo.systemUptime + 10)
        let main = VideoPresentationSession(track: track, admission: proof, onFrame: {})
        XCTAssertFalse(main.view.glassLensEnabled)
        let coordinator = RemoteVideoSurface.Coordinator()
        XCTAssertTrue(coordinator.ensureSession(track: track, admission: proof, onFrame: {}, primary: false))
        let loupe = try XCTUnwrap(coordinator.session)
        loupe.configure(admission: proof, counters: nil, statistics: false, sourceSize: .zero, displayedPixelWidth: 0,
            fillsFrame: true, mode: .off, upscale: false, onSourceFrame: nil,
            sourceCrop: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), glassLens: true)
        XCTAssertTrue(loupe.view.glassLensEnabled)
        XCTAssertFalse(main.view.glassLensEnabled)
        XCTAssertTrue(VideoPresentationSession.active === main)
        VideoPresentationSession.invalidateActive()
        XCTAssertTrue(loupe.isTerminal); XCTAssertTrue(main.isTerminal)
        XCTAssertNil(loupe.fence.withAdmission(identity, at: ProcessInfo.processInfo.systemUptime) { true })
        XCTAssertFalse(loupe.fence.renew(proof), "A stale view update cannot revive its retired session")
        XCTAssertFalse(coordinator.ensureSession(track: track, admission: proof, onFrame: {}, primary: false))
        let newCoordinator = RemoteVideoSurface.Coordinator()
        XCTAssertFalse(newCoordinator.ensureSession(track: track, admission: proof, onFrame: {}, primary: false))
        coordinator.invalidate()
    }

    // Render the shipped fragments into a GPU texture. This catches a missing fragment
    // binding, a rotation-space mistake, or a difference between the bundled and runtime
    // Metal libraries without relying on a screenshot's color management.
    func testGlassLensPreservesCenterAndBendsRimForBothPixelFormatsAndLibraries() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let libraries: [(String, MTLLibrary)] = [
            ("bundled", try XCTUnwrap(device.makeDefaultLibrary())),
            ("runtime", try device.makeLibrary(source: OwnedMetalVideoView.shader, options: nil))
        ]
        for (libraryName, library) in libraries {
            XCTAssertNotNil(library.makeFunction(name: "readingGlassLens"), "\(libraryName) must expose the offline preview shader")
            for bgra in [true, false] {
                let pipeline = try makePipeline(device: device, library: library, bgra: bgra)
                let input = try makeInput(device: device, bgra: bgra)
                for rotation in 0..<4 {
                    let crop = rotation == 0 ? SIMD4<Float>(0, 0, 1, 1) : SIMD4<Float>(0.125, 0.125, 0.75, 0.75)
                    let unbent = try render(device: device, queue: queue, pipeline: pipeline, input: input, bgra: bgra,
                                            rotation: rotation, crop: crop, enabled: false)
                    let bent = try render(device: device, queue: queue, pipeline: pipeline, input: input, bgra: bgra,
                                          rotation: rotation, crop: crop, enabled: true)
                    let restored = try render(device: device, queue: queue, pipeline: pipeline, input: input, bgra: bgra,
                                              rotation: rotation, crop: crop, enabled: false)
                    let context = "\(libraryName) \(bgra ? "BGRA" : "NV12") rotation \(rotation)"
                    XCTAssertTrue(unbent == restored, "Disabling the lens restores the exact primary pixels: \(context)")
                    for x in [28, 32, 36] {
                        XCTAssertEqual(pixel(unbent, x: x, y: 32), pixel(bent, x: x, y: 32),
                                       "The readable center must be unchanged: \(context)")
                    }
                    XCTAssertNotEqual(pixel(unbent, x: 60, y: 32), pixel(bent, x: 60, y: 32),
                                      "The circular rim must refract: \(context)")
                    if bgra && rotation == 0 {
                        XCTAssertTrue(unbent == input.bgraBytes, "The disabled BGRA path must copy the source byte for byte: \(context)")
                    }
                }
            }
        }
    }

    private static let side = 64
    private struct Uniforms {
        var extent = SIMD2<Float>(1, 1)
        var rotation: Int32
        var bgra: Int32
        var crop: SIMD4<Float>
        var color = SIMD4<Float>(0.2126, 0.0722, 0, 1)
        var range = SIMD4<Float>(1, 0.5 / Float(LoupePresentationTests.side), 0.5 / Float(LoupePresentationTests.side), 0)
    }
    private struct Refinement { var rect = SIMD4<Float>.zero; var options = SIMD4<Float>.zero }
    private struct Input { let first: MTLTexture; let second: MTLTexture?; let bgraBytes: [UInt8] }

    private func makePipeline(device: MTLDevice, library: MTLLibrary, bgra: Bool) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = try XCTUnwrap(library.makeFunction(name: "vertexPicture"))
        descriptor.fragmentFunction = try XCTUnwrap(library.makeFunction(name: bgra ? "fragmentBGRA" : "fragmentNV12"))
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private func makeInput(device: MTLDevice, bgra: Bool) throws -> Input {
        let side = Self.side
        if bgra {
            var bytes = [UInt8](repeating: 0, count: side * side * 4)
            for y in 0..<side { for x in 0..<side {
                let i = (y * side + x) * 4
                bytes[i] = 19; bytes[i + 1] = UInt8(y * 4); bytes[i + 2] = UInt8(x * 4); bytes[i + 3] = 255
            } }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: side, height: side, mipmapped: false)
            descriptor.storageMode = .shared; descriptor.usage = .shaderRead
            let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            bytes.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0,
                                                    withBytes: $0.baseAddress!, bytesPerRow: side * 4) }
            return Input(first: texture, second: nil, bgraBytes: bytes)
        }
        let yDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: side, height: side, mipmapped: false)
        yDescriptor.storageMode = .shared; yDescriptor.usage = .shaderRead
        let uvDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg8Unorm, width: side / 2, height: side / 2, mipmapped: false)
        uvDescriptor.storageMode = .shared; uvDescriptor.usage = .shaderRead
        let luma = try XCTUnwrap(device.makeTexture(descriptor: yDescriptor))
        let chroma = try XCTUnwrap(device.makeTexture(descriptor: uvDescriptor))
        var yBytes = [UInt8](repeating: 0, count: side * side)
        for y in 0..<side { for x in 0..<side { yBytes[y * side + x] = UInt8(2 * (x + y)) } }
        let uvBytes = [UInt8](repeating: 128, count: side * side / 2)
        yBytes.withUnsafeBytes { luma.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0,
                                             withBytes: $0.baseAddress!, bytesPerRow: side) }
        uvBytes.withUnsafeBytes { chroma.replace(region: MTLRegionMake2D(0, 0, side / 2, side / 2), mipmapLevel: 0,
                                                withBytes: $0.baseAddress!, bytesPerRow: side) }
        return Input(first: luma, second: chroma, bgraBytes: [])
    }

    private func render(device: MTLDevice, queue: MTLCommandQueue, pipeline: MTLRenderPipelineState, input: Input, bgra: Bool,
                        rotation: Int, crop: SIMD4<Float>, enabled: Bool) throws -> [UInt8] {
        let side = Self.side
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: side, height: side, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = .renderTarget
        let output = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
        var uniforms = Uniforms(rotation: Int32(rotation), bgra: bgra ? 1 : 0, crop: crop)
        var refinement = Refinement()
        var lens = SIMD2<Float>(enabled ? 1 : 0, 1)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&refinement, length: MemoryLayout<Refinement>.stride, index: 1)
        encoder.setFragmentBytes(&lens, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
        encoder.setFragmentTexture(input.first, index: 0)
        encoder.setFragmentTexture(input.second, index: 1)
        encoder.setFragmentTexture(input.first, index: 2)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, "Offscreen Metal render failed: \(String(describing: command.error))")
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        bytes.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: side * 4,
                                                        from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0) }
        return bytes
    }

    private func pixel(_ bytes: [UInt8], x: Int, y: Int) -> [UInt8] {
        Array(bytes[((y * Self.side + x) * 4)..<((y * Self.side + x + 1) * 4)])
    }
}
