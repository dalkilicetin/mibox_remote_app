import Foundation

final class ProtoWriter {
    private var buf = Data()

    func writeVarint(field: Int, value: Int) {
        writeRaw(UInt64((field << 3) | 0))
        writeRaw(UInt64(bitPattern: Int64(value)))
    }

    func writeString(field: Int, value: String) {
        let bytes = Data(value.utf8)
        writeRaw(UInt64((field << 3) | 2))
        writeRaw(UInt64(bytes.count))
        buf.append(bytes)
    }

    func writeBytes(field: Int, value: Data) {
        writeRaw(UInt64((field << 3) | 2))
        writeRaw(UInt64(value.count))
        buf.append(value)
    }

    func toData() -> Data { buf }

    private func writeRaw(_ v: UInt64) {
        var v = v
        repeat {
            let byte = UInt8(v & 0x7F)
            v >>= 7
            buf.append(v > 0 ? byte | 0x80 : byte)
        } while v > 0
    }
}

func encodeVarint(_ value: Int) -> Data {
    var v = UInt64(bitPattern: Int64(value))
    var out = Data()
    repeat {
        let byte = UInt8(v & 0x7F)
        v >>= 7
        out.append(v > 0 ? byte | 0x80 : byte)
    } while v > 0
    return out
}

func decodeVarint(_ data: Data, at offset: Int) -> (value: Int, bytesRead: Int)? {
    var result = 0; var shift = 0; var idx = offset
    while idx < data.count && shift < 35 {
        let b = Int(data[data.startIndex + idx]); idx += 1
        result |= (b & 0x7F) << shift
        if b & 0x80 == 0 { return (result, idx - offset) }
        shift += 7
    }
    return nil
}
