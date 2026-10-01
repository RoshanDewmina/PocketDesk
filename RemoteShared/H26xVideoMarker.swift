import Foundation

/// Bounded user_data_unregistered SEI. Tokens survive packetization with their exact access unit.
enum H26xVideoMarker {
    private static let identifier: [UInt8] = [0x46,0x41,0x52,0x53,0x49,0x44,0x45,0x56,0x49,0x44,0x45,0x4f,0x30,0x30,0x30,0x31]
    static let maximumJSONBytes = 1024
    static func append(_ tag: VideoFrameTag, to data: Data, hevc: Bool = false) -> Data? {
        guard (try? tag.validate()) != nil, let encoded = try? JSONEncoder().encode(tag), encoded.count <= maximumJSONBytes,
              data.count <= H264AnnexB.maximumBytes - 2048 else { return nil }
        var rbsp: [UInt8] = [5], size = encoded.count + identifier.count
        while size >= 255 { rbsp.append(255); size -= 255 }; rbsp.append(UInt8(size))
        rbsp += identifier; rbsp += encoded; rbsp.append(0x80)
        var escaped: [UInt8] = [], zeros = 0
        for byte in rbsp {
            if zeros >= 2 && byte <= 3 { escaped.append(3); zeros = 0 }
            escaped.append(byte); zeros = byte == 0 ? zeros + 1 : 0
        }
        return Data([0,0,0,1] + (hevc ? [0x4e,1] : [6]) + escaped) + data
    }
    static func read(_ data: Data, hevc: Bool = false) -> VideoFrameTag? {
        guard let nals = H26xAnnexB.split(data) else { return nil }
        var found: VideoFrameTag?
        for nal in nals {
            guard nal.count <= 4096, nal.count > (hevc ? 2 : 1),
                  hevc ? ((nal[0] >> 1) & 63 == 39) : (nal[0] & 31 == 6) else { continue }
            let bytes = H26xAnnexB.rbsp(nal.dropFirst(hevc ? 2 : 1)); var at = 0, messages = 0
            while at < bytes.count, bytes[at] != 0x80, messages < 32 {
                messages += 1; var type = 0, size = 0
                while at < bytes.count, bytes[at] == 255 { type += 255; at += 1 }
                guard at < bytes.count else { return nil }; type += Int(bytes[at]); at += 1
                while at < bytes.count, bytes[at] == 255 { size += 255; at += 1 }
                guard at < bytes.count else { return nil }; size += Int(bytes[at]); at += 1
                guard size <= 2048, at + size <= bytes.count else { return nil }
                defer { at += size }
                if type == 5, size > identifier.count, Array(bytes[at..<(at + identifier.count)]) == identifier {
                    guard size - identifier.count <= maximumJSONBytes, found == nil, let tag = try? JSONDecoder().decode(VideoFrameTag.self, from: Data(bytes[(at + identifier.count)..<(at + size)])),
                          (try? tag.validate()) != nil else { return nil }
                    found = tag
                }
            }
        }
        return found
    }
}
