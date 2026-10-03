import Foundation
import Compression

/// Minimal reader for .zip containers, enough to pull `word/document.xml` out of a .docx
/// without a third-party package.
enum ZipReader {
    static func readEntry(named target: String, from data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 22 else { return nil }

        func u16(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 2 <= bytes.count else { return nil }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        }
        func u32(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            return Int(bytes[offset])
                | Int(bytes[offset + 1]) << 8
                | Int(bytes[offset + 2]) << 16
                | Int(bytes[offset + 3]) << 24
        }

        // End of central directory record: scan backwards for its signature.
        var eocd: Int?
        var index = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - 65_535)
        while index >= lowest {
            if u32(index) == 0x0605_4b50 {
                eocd = index
                break
            }
            index -= 1
        }
        guard let eocd,
              let entryCount = u16(eocd + 10),
              let directoryOffset = u32(eocd + 16) else { return nil }

        var cursor = directoryOffset
        for _ in 0..<entryCount {
            guard u32(cursor) == 0x0201_4b50,
                  let method = u16(cursor + 10),
                  let compressedSize = u32(cursor + 20),
                  let uncompressedSize = u32(cursor + 24),
                  let nameLength = u16(cursor + 28),
                  let extraLength = u16(cursor + 30),
                  let commentLength = u16(cursor + 32),
                  let localOffset = u32(cursor + 42),
                  cursor + 46 + nameLength <= bytes.count else { return nil }

            let name = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            if name == target {
                guard u32(localOffset) == 0x0403_4b50,
                      let localNameLength = u16(localOffset + 26),
                      let localExtraLength = u16(localOffset + 28) else { return nil }
                let start = localOffset + 30 + localNameLength + localExtraLength
                let end = start + compressedSize
                guard start >= 0, end <= bytes.count else { return nil }
                let payload = Array(bytes[start..<end])

                switch method {
                case 0:
                    return Data(payload)
                case 8:
                    return inflate(payload, expectedSize: uncompressedSize)
                default:
                    return nil
                }
            }
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return nil
    }

    /// Zip uses raw deflate, which is what COMPRESSION_ZLIB decodes.
    private static func inflate(_ payload: [UInt8], expectedSize: Int) -> Data? {
        guard expectedSize > 0, !payload.isEmpty else { return nil }
        var output = [UInt8](repeating: 0, count: expectedSize)
        let written = payload.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                compression_decode_buffer(destination.baseAddress!, expectedSize,
                                          source.baseAddress!, payload.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return Data(output.prefix(written))
    }
}
