//
//  SRPClient.swift
//  OpenRM
//
//  ResMed AirSense 11 SRP-6a client.
//
//  Protocol details (reverse-engineered from libpacific-figlib.so):
//    - N: custom 2048-bit safe prime (constant below)
//    - g = 2
//    - Hash = SHA-256
//    - u = H(PAD256(A) || PAD256(B))
//    - k = H(PAD256(N) || PAD256(g))
//    - x = H(salt || H(pinBytes))           -- no username, no ":"
//    - S = (B - k*g^x)^(a + u*x) mod N
//    - masterPairKey = H(PAD256(S))
//    - M1 = H(H(N) XOR H(g) || salt || PAD256(A) || PAD256(B) || masterPairKey)
//    - M2 = H(PAD256(A) || M1 || masterPairKey)
//    - sessionKey = H(masterPairKey || serverNonce)
//

import Foundation
import CryptoKit
import BigInt

struct SRPClient {
    static let N_hex = "AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB56050A37329CBB4A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA04FD50E8083969EDB767B0CF6095179A163AB3661A05FBD5FAAAE82918A9962F0B93B855F97993EC975EEAA80D740ADBF4FF747359D041D5C33EA71D281E446B14773BCA97B43A23FB801676BD207A436C6481F1D2B9078717461A5B9D32E688F87748544523B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB3786160279004E57AE6AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DBFBB694B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F9E4AFF73"
    static let keyLength = 256   // bytes, matches N size

    let N: BigUInt
    let g: BigUInt = 2
    let k: BigUInt
    let a: BigUInt
    let A: BigUInt

    init() {
        self.N = BigUInt(Self.N_hex, radix: 16)!

        // k = H(PAD256(N) || PAD256(g))
        var kInput = Data()
        kInput.append(Self.pad(self.N.serialize(), to: Self.keyLength))
        kInput.append(Self.pad(BigUInt(2).serialize(), to: Self.keyLength))
        self.k = BigUInt(Data(SHA256.hash(data: kInput)))

        // Random 32-byte private exponent a
        var aBytes = Data(count: 32)
        _ = aBytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        self.a = BigUInt(aBytes)

        // A = g^a mod N
        self.A = self.g.power(self.a, modulus: self.N)
    }

    /// Given server's B, salt, and the PIN, compute the full SRP state.
    func computeSession(B: BigUInt, salt: Data, pin: String) -> SRPSession? {
        guard B % N != 0 else { return nil }

        let aPad = Self.pad(A.serialize(), to: Self.keyLength)
        let bPad = Self.pad(B.serialize(), to: Self.keyLength)

        // u = H(PAD(A) || PAD(B))
        var uInput = Data()
        uInput.append(aPad)
        uInput.append(bPad)
        let u = BigUInt(Data(SHA256.hash(data: uInput)))
        guard u != 0 else { return nil }

        // h_pin = H(pin_ascii_bytes)
        let hPin = Data(SHA256.hash(data: pin.data(using: .utf8)!))

        // x = H(salt || h_pin)
        var xInput = Data()
        xInput.append(salt)
        xInput.append(hPin)
        let x = BigUInt(Data(SHA256.hash(data: xInput)))

        // S = (B - k*g^x)^(a + u*x) mod N
        let gx = g.power(x, modulus: N)
        let kgx = (k * gx) % N
        let base = (B + N - kgx) % N  // handle modular subtraction
        let exp = a + u * x
        let S = base.power(exp, modulus: N)

        // masterPairKey = H(PAD256(S))
        let sPadded = Self.pad(S.serialize(), to: Self.keyLength)
        let masterPairKey = Data(SHA256.hash(data: sPadded))

        // hN = H(PAD256(N))
        let hN = Data(SHA256.hash(data: Self.pad(N.serialize(), to: Self.keyLength)))
        // hG = H(PAD256(g))
        let hG = Data(SHA256.hash(data: Self.pad(g.serialize(), to: Self.keyLength)))

        // hN XOR hG
        var hNxG = Data(count: 32)
        for i in 0..<32 {
            hNxG[i] = hN[i] ^ hG[i]
        }

        // M1 = H(hN XOR hG || salt || PAD(A) || PAD(B) || masterPairKey)
        //   Note: NO H(identity) unlike standard SRP-6a
        var m1Input = Data()
        m1Input.append(hNxG)
        m1Input.append(salt)
        m1Input.append(aPad)
        m1Input.append(bPad)
        m1Input.append(masterPairKey)
        let M1 = Data(SHA256.hash(data: m1Input))

        // Expected M2 = H(PAD(A) || M1 || masterPairKey)
        var m2Input = Data()
        m2Input.append(aPad)
        m2Input.append(M1)
        m2Input.append(masterPairKey)
        let expectedM2 = Data(SHA256.hash(data: m2Input))

        return SRPSession(
            A: A,
            B: B,
            salt: salt,
            masterPairKey: masterPairKey,
            M1: M1,
            expectedM2: expectedM2
        )
    }

    /// Derive the session key from masterPairKey and the server-provided nonce.
    /// Used by both initial pair and session resume — the formula is the same.
    static func deriveSessionKey(masterPairKey: Data, nonce: Data) -> Data {
        var input = Data()
        input.append(masterPairKey)
        input.append(nonce)
        return Data(SHA256.hash(data: input))
    }

    /// Compute the challenge response for session resume.
    /// response = HMAC-SHA256(key=masterPairKey, data=challenge)
    static func challengeResponse(challenge: Data, masterPairKey: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(
            for: challenge,
            using: SymmetricKey(data: masterPairKey)
        )
        return Data(mac)
    }

    // MARK: - Padding helper

    /// Left-pad a big-endian byte representation to the given length.
    /// BigUInt.serialize() gives minimal big-endian bytes; we zero-pad on the left.
    static func pad(_ data: Data, to length: Int) -> Data {
        if data.count >= length {
            // If longer (e.g. has a leading zero from serialization), trim
            return data.suffix(length)
        }
        var padded = Data(count: length - data.count)
        padded.append(data)
        return padded
    }
}

struct SRPSession {
    let A: BigUInt
    let B: BigUInt
    let salt: Data
    let masterPairKey: Data     // H(PAD(S)) - 32 bytes
    let M1: Data                // Client proof we send
    let expectedM2: Data        // What we verify server against
}
