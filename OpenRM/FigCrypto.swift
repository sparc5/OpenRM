//
//  FigCrypto.swift
//  OpenRM
//
//  AES-256-CBC encryption for the FIG protocol (validated against libpacific-figlib.so).
//
//  Plaintext format: [uint16_le JSON length] [JSON bytes] [zero padding to 16 bytes]
//  Ciphertext format: [16 bytes random IV] [AES-256-CBC(plaintext, sessionKey, IV)]
//  No HMAC, no authentication — pure CBC with zero padding.
//

import Foundation
import CommonCrypto

enum FigCrypto {
    static let blockSize = 16

    /// Encrypt a JSON payload. Returns IV || ciphertext.
    static func encrypt(jsonPayload: Data, sessionKey: Data) throws -> Data {
        // Build plaintext: [uint16_le length][JSON][zero pad to 16-byte block]
        let jsonLen = UInt16(jsonPayload.count)
        var plaintext = Data()
        plaintext.append(contentsOf: withUnsafeBytes(of: jsonLen.littleEndian) { Array($0) })
        plaintext.append(jsonPayload)
        // Zero pad to next multiple of 16
        let remainder = plaintext.count % blockSize
        if remainder != 0 {
            plaintext.append(Data(count: blockSize - remainder))
        }

        // Generate random 16-byte IV
        var iv = Data(count: 16)
        _ = iv.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }

        // AES-256-CBC, no padding (we already zero-padded)
        let ciphertext = try aesCBC(data: plaintext, key: sessionKey, iv: iv, operation: CCOperation(kCCEncrypt))

        var result = Data()
        result.append(iv)
        result.append(ciphertext)
        return result
    }

    /// Decrypt an IV || ciphertext blob. Returns the JSON payload (length-prefix and padding stripped).
    static func decrypt(ivAndCiphertext: Data, sessionKey: Data) throws -> Data {
        guard ivAndCiphertext.count >= 32 else { throw FigCryptoError.tooShort }
        let iv = ivAndCiphertext.prefix(16)
        let ciphertext = ivAndCiphertext.subdata(in: 16..<ivAndCiphertext.count)

        let plaintext = try aesCBC(data: ciphertext, key: sessionKey, iv: iv, operation: CCOperation(kCCDecrypt))

        // Strip length prefix and padding
        guard plaintext.count >= 2 else { throw FigCryptoError.malformed }
        let jsonLen = UInt16(plaintext[0]) | (UInt16(plaintext[1]) << 8)
        guard Int(jsonLen) + 2 <= plaintext.count else { throw FigCryptoError.malformed }
        return plaintext.subdata(in: 2..<(2 + Int(jsonLen)))
    }

    enum FigCryptoError: Error {
        case tooShort
        case malformed
        case cryptoFailure(OSStatus)
    }

    private static func aesCBC(data: Data, key: Data, iv: Data, operation: CCOperation) throws -> Data {
        // Copy to arrays to avoid Swift exclusivity issues with nested withUnsafeBytes
        let dataBytes = [UInt8](data)
        let keyBytes = [UInt8](key)
        let ivBytes = [UInt8](iv)
        let bufferSize = data.count + kCCBlockSizeAES128
        var output = [UInt8](repeating: 0, count: bufferSize)
        var bytesProcessed = 0

        let status = CCCrypt(
            operation,
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(0),  // No padding - we pad with zeros manually
            keyBytes, keyBytes.count,
            ivBytes,
            dataBytes, dataBytes.count,
            &output, bufferSize,
            &bytesProcessed
        )

        guard status == kCCSuccess else { throw FigCryptoError.cryptoFailure(status) }
        return Data(output.prefix(bytesProcessed))
    }
}
