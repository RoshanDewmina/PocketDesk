import XCTest
import CryptoKit
import CoreVideo

final class BrowserCryptoTests: XCTestCase {
    func testEncryptedEnrollmentBindsBrowserKeyHostAndOrigin() throws {
        struct Fixture: Decodable {
            struct Enrollment: Decodable { let secret:String; let hostID:String; let url:String; let peerID:String; let publicKey:String; let nonce:String; let payload:String }
            let enrollment: Enrollment
        }
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BrowserFixtures/crypto-vector.json")
        let v = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf:path)).enrollment
        let data = try BrowserCrypto.openEnrollment(secret:v.secret,hostID:v.hostID,origin:v.url,nonce:v.nonce,payload:v.payload)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:String])
        XCTAssertEqual(body,["peerID":v.peerID,"publicKey":v.publicKey])
        XCTAssertThrowsError(try BrowserCrypto.openEnrollment(secret:String(repeating:"0",count:64),hostID:v.hostID,origin:v.url,nonce:v.nonce,payload:v.payload))
        XCTAssertThrowsError(try BrowserCrypto.openEnrollment(secret:v.secret,hostID:String(repeating:"0",count:64),origin:v.url,nonce:v.nonce,payload:v.payload))
        XCTAssertThrowsError(try BrowserCrypto.openEnrollment(secret:v.secret,hostID:v.hostID,origin:"https://wrong.invalid",nonce:v.nonce,payload:v.payload))
        let changed = Data(repeating:0,count:128).base64EncodedString()
        XCTAssertThrowsError(try BrowserCrypto.openEnrollment(secret:v.secret,hostID:v.hostID,origin:v.url,nonce:v.nonce,payload:changed))
    }
    func testWebCryptoFixture() throws {
        struct Vector: Decodable { let fields:[String]; let hash:String; let signingPublic:String; let signature:String; let hostScalar:Data; let browserPublic:String; let session:String; let envelope:BrowserEnvelope }
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BrowserFixtures/crypto-vector.json")
        let v = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: path))
        XCTAssertEqual(BrowserCrypto.hash(BrowserCrypto.canonical(v.fields)), v.hash)
        XCTAssertTrue(BrowserCrypto.verify(v.fields, signature:v.signature, publicKey:v.signingPublic))
        XCTAssertFalse(BrowserCrypto.verify(v.fields + ["modified"], signature:v.signature, publicKey:v.signingPublic))
        let privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation:v.hostScalar)
        let key = try BrowserCrypto.sharedKey(privateKey: privateKey, publicKey:v.browserPublic, challenge:v.fields)
        let signal = try BrowserCrypto.open(v.envelope, key:key, session:v.session, direction:"host", challengeHash:v.hash)
        XCTAssertEqual(signal.kind,"ready")
        XCTAssertThrowsError(try BrowserCrypto.open(v.envelope,key:key,session:v.session,direction:"browser",challengeHash:v.hash))
        var changed=v.envelope; changed.sequence="2"
        XCTAssertThrowsError(try BrowserCrypto.open(changed,key:key,session:v.session,direction:"host",challengeHash:v.hash))
        let native=try BrowserCrypto.seal(signal,key:key,session:v.session,direction:"host",sequence:1,challengeHash:v.hash)
        XCTAssertEqual(native.payload,v.envelope.payload)
    }
    func testInputRequiresFreshPixelProofAndScope() throws {
        let gate=BrowserInputGate(); let session=String(repeating:"1",count:64), token=String(repeating:"a",count:32)
        gate.begin(session:session,revision:3); gate.record(token:token,at:10)
        func packet(_ sequence:Int,_ action:String="click",_ revision:String="3") throws -> Data {
            try JSONSerialization.data(withJSONObject:["type":"input","session":session,"sequence":String(sequence),"revision":revision,"frameToken":token,"action":["action":action,"epoch":3,"x":0,"y":0,"text":"","key":"","modifiers":[]]])
        }
        XCTAssertThrowsError(try gate.accept(packet(1),at:10.1,healthy:true,control:false))
        XCTAssertEqual(try gate.accept(packet(2),at:10.5,healthy:true,control:true).action,"click")
        XCTAssertThrowsError(try gate.accept(packet(2),at:10.5,healthy:true,control:true))
        XCTAssertThrowsError(try gate.accept(packet(3),at:10.601,healthy:true,control:true))
        XCTAssertEqual(try gate.accept(packet(4,"release","0"),at:11,healthy:false,control:false).action,"release")
        gate.invalidateFrames()
        XCTAssertThrowsError(try gate.accept(packet(5),at:10.5,healthy:true,control:true))
    }
    func testMarkerCRCVectorAndExactBitCount() {
        XCTAssertEqual(BrowserFrameMarker.crc32c(Array("123456789".utf8)),0xe3069283)
        XCTAssertEqual(BrowserFrameMarker.bits(token:Array(repeating:0,count:16)).count,200)
    }
    func testMarkerPreservesTopAndBottomPixelRows() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 128, 64, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let source = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(source, [])
        let pixels = CVPixelBufferGetBaseAddress(source)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(source)
        for y in 0..<64 { for x in 0..<128 {
            let p = y * stride + x * 4
            pixels[p] = y < 32 ? 0 : 255; pixels[p+1] = 0; pixels[p+2] = y < 32 ? 255 : 0; pixels[p+3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(source, [])
        let (result, _) = try BrowserFrameMarker().mark(source)
        CVPixelBufferLockBaseAddress(result, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(result, .readOnly) }
        let output = CVPixelBufferGetBaseAddress(result)!.assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(output[2], 255, "Top content stays red")
        XCTAssertEqual(output[63 * CVPixelBufferGetBytesPerRow(result)], 255, "Bottom content stays blue")
        XCTAssertEqual(CVPixelBufferGetHeight(result), 112)
    }
    func testMarkerConvertsCaptureYUVWithoutFlipping() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 128, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let source = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(source, [])
        let luma = CVPixelBufferGetBaseAddressOfPlane(source, 0)!
        for y in 0..<64 { memset(luma.advanced(by: y * CVPixelBufferGetBytesPerRowOfPlane(source, 0)), y < 32 ? 235 : 16, 128) }
        memset(CVPixelBufferGetBaseAddressOfPlane(source, 1)!, 128, CVPixelBufferGetBytesPerRowOfPlane(source, 1) * 32)
        CVPixelBufferUnlockBaseAddress(source, [])
        let (result, _) = try BrowserFrameMarker().mark(source)
        CVPixelBufferLockBaseAddress(result, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(result, .readOnly) }
        let output = CVPixelBufferGetBaseAddress(result)!.assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan(output[2], 240, "Top content stays white")
        XCTAssertLessThan(output[63 * CVPixelBufferGetBytesPerRow(result)], 15, "Bottom content stays black")
    }
}
