import Foundation

enum StreamProbePayload {
    static func isErrorDocument(_ data: Data) -> Bool {
        let prefix = String(decoding: data.prefix(512), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return prefix.hasPrefix("<html") || prefix.hasPrefix("<!doctype html")
            || prefix.hasPrefix("<?xml") || prefix.hasPrefix("<error")
            || prefix.hasPrefix("{\"") || prefix.hasPrefix("[{\"")
    }

    static func isMediaSample(_ data: Data) -> Bool {
        guard !isErrorDocument(data), data.count >= 8 else { return false }
        let bytes = Array(data.prefix(400))
        // MPEG-TS, ISO-BMFF (MP4/fMP4), ID3-prefixed audio or ADTS AAC.
        // Unknown formats stay untested and selectable; this is not a decode proof.
        if bytes.count > 188 && bytes[0] == 0x47 && bytes[188] == 0x47 { return true }
        let box = String(decoding: bytes[4..<8], as: UTF8.self)
        if ["ftyp", "styp", "moof", "sidx", "mdat"].contains(box) { return true }
        if bytes[0...2] == [0x49, 0x44, 0x33][...] { return true }
        return bytes[0] == 0xff && bytes[1] & 0xf6 == 0xf0
    }
}
