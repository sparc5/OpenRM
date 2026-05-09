//
//  FigFrame.swift
//  OpenRM
//
//  FIG protocol frame encoder/decoder.
//  Frame format:
//    [4 bytes magic: CAFEBABE][2 bytes seq][2 bytes length][4 bytes payloadCRC][4 bytes headerCRC][payload]
//

import Foundation

enum FigFrame {
    static let magic: [UInt8] = [0xBE, 0xBA, 0xFE, 0xCA]  // CAFEBABE little-endian
    static let headerSize = 12
    static let totalHeaderSize = 16  // magic + header

    /// Encode a payload into a framed packet with CRC32s.
    /// - Parameters:
    ///   - sequence: Channel/sequence ID (we observed 0x0393 for TX, 0x0392 for RX)
    ///   - payload: Raw payload bytes (the JSON or encrypted blob)
    static func encode(sequence: UInt16, payload: Data) -> Data {
        var header = Data()
        header.append(contentsOf: withUnsafeBytes(of: sequence.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(payload.count).littleEndian) { Array($0) })

        let payloadCRC = CRC32.compute(payload)
        header.append(contentsOf: withUnsafeBytes(of: payloadCRC.littleEndian) { Array($0) })

        let headerCRC = CRC32.compute(header)
        header.append(contentsOf: withUnsafeBytes(of: headerCRC.littleEndian) { Array($0) })

        var frame = Data(magic)
        frame.append(header)
        frame.append(payload)
        return frame
    }

    struct DecodedFrame {
        let sequence: UInt16
        let payload: Data
    }

    /// Decode one or more frames from a byte stream. Returns remaining unparsed bytes.
    static func decode(_ data: Data) -> (frames: [DecodedFrame], remaining: Data) {
        var frames: [DecodedFrame] = []
        var cursor = 0
        let bytes = [UInt8](data)

        while cursor + totalHeaderSize <= bytes.count {
            // Find magic
            guard bytes[cursor] == magic[0],
                  bytes[cursor+1] == magic[1],
                  bytes[cursor+2] == magic[2],
                  bytes[cursor+3] == magic[3] else {
                cursor += 1
                continue
            }

            // Parse header (after magic)
            let h = cursor + 4
            let seq = UInt16(bytes[h]) | (UInt16(bytes[h+1]) << 8)
            let len = UInt16(bytes[h+2]) | (UInt16(bytes[h+3]) << 8)
            let payloadLen = Int(len)

            let frameEnd = cursor + totalHeaderSize + payloadLen
            if frameEnd > bytes.count {
                // Incomplete frame - wait for more data
                break
            }

            let payload = Data(bytes[(cursor + totalHeaderSize)..<frameEnd])
            frames.append(DecodedFrame(sequence: seq, payload: payload))
            cursor = frameEnd
        }

        let remaining = cursor < bytes.count ? Data(bytes[cursor...]) : Data()
        return (frames, remaining)
    }
}

/// Standard CRC32 (zlib/PNG variant, polynomial 0xEDB88320).
enum CRC32 {
    private static let table: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1 != 0) ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            t[i] = c
        }
        return t
    }()

    static func compute(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFFFFFF
    }
}
