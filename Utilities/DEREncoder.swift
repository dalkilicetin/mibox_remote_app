import Foundation

enum DEREncoder {
    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        let len = content.count
        if len < 0x80 {
            out.append(UInt8(len))
        } else if len <= 0xFF {
            out.append(contentsOf: [0x81, UInt8(len)])
        } else {
            out.append(contentsOf: [0x82, UInt8(len >> 8), UInt8(len & 0xFF)])
        }
        out.append(content)
        return out
    }

    static func sequence(_ items: Data...) -> Data { tlv(0x30, items.reduce(Data(), +)) }
    static func setOf(_ items: Data...) -> Data    { tlv(0x31, items.reduce(Data(), +)) }

    static func integer(_ bytes: [UInt8]) -> Data {
        var b = bytes
        while b.count > 1 && b[0] == 0 && (b[1] & 0x80) == 0 { b.removeFirst() }
        if let first = b.first, first & 0x80 != 0 { b.insert(0, at: 0) }
        return tlv(0x02, Data(b))
    }

    static func bitString(_ content: Data) -> Data { tlv(0x03, Data([0x00]) + content) }
    static func null() -> Data { Data([0x05, 0x00]) }
    static func oid(_ bytes: [UInt8]) -> Data { tlv(0x06, Data(bytes)) }
    static func utf8String(_ s: String) -> Data { tlv(0x0C, Data(s.utf8)) }

    static func utcTime(_ date: Date) -> Data {
        let f = DateFormatter()
        f.dateFormat = "yyMMddHHmmss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")!
        return tlv(0x17, Data(f.string(from: date).utf8))
    }

    static func contextExplicit(_ tag: UInt8, _ child: Data) -> Data { tlv(0xA0 | tag, child) }

    // OID constants
    static let oidSHA256WithRSA: [UInt8] = [0x2A,0x86,0x48,0x86,0xF7,0x0D,0x01,0x01,0x0B]
    static let oidRSAEncryption: [UInt8] = [0x2A,0x86,0x48,0x86,0xF7,0x0D,0x01,0x01,0x01]
    static let oidCommonName: [UInt8]    = [0x55,0x04,0x03]
}
