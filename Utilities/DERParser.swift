import Foundation

enum DERParser {
    struct TLV {
        let tag: UInt8
        let content: Data
        let totalLength: Int
    }

    static func parseTLV(_ data: Data, at offset: Int = 0) -> TLV? {
        guard offset < data.count else { return nil }
        let base = data.startIndex
        let tag = data[base + offset]
        var idx = offset + 1
        guard idx < data.count else { return nil }
        let firstLen = data[base + idx]; idx += 1
        let len: Int
        if firstLen < 0x80 {
            len = Int(firstLen)
        } else if firstLen == 0x81 {
            guard idx < data.count else { return nil }
            len = Int(data[base + idx]); idx += 1
        } else if firstLen == 0x82 {
            guard idx + 1 < data.count else { return nil }
            len = Int(data[base + idx]) << 8 | Int(data[base + idx + 1]); idx += 2
        } else { return nil }
        guard idx + len <= data.count else { return nil }
        let content = data[(base + idx)..<(base + idx + len)]
        return TLV(tag: tag, content: content, totalLength: idx - offset + len)
    }

    // Parse PKCS#1 RSAPublicKey DER → (modulus, exponent) without leading 0x00
    static func parseRSAPublicKey(_ der: Data) -> (modulus: Data, exponent: Data)? {
        guard let outer = parseTLV(der), outer.tag == 0x30 else { return nil }
        let inner = outer.content
        guard let modTLV = parseTLV(inner, at: 0), modTLV.tag == 0x02 else { return nil }
        let modulus = stripLeadingZero(modTLV.content)
        guard let expTLV = parseTLV(inner, at: modTLV.totalLength), expTLV.tag == 0x02 else { return nil }
        return (modulus, stripLeadingZero(expTLV.content))
    }

    static func stripLeadingZero(_ d: Data) -> Data {
        d.first == 0x00 && d.count > 1 ? d.dropFirst() : d
    }
}
