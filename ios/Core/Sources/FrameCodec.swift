import Foundation

/// Length-prefixed big-endian framing used by the original RemoteScribeCore.
enum RemoteFrameEncoder {
    static func encode(_ frame: RemoteFrame) throws -> Data {
        let uuid = frame.sessionID.uuidString.data(using: .utf8)!
        guard uuid.count == 36 else { throw RemoteFrameError.invalidUUID }
        var body = Data()
        body.append(frame.kind.rawValue)
        body.append(uuid)
        appendUInt64(frame.sequence, to: &body)
        body.append(frame.payload)
        guard body.count <= RemoteScribeProtocol.maximumFrameSize else {
            throw RemoteFrameError.tooLarge(body.count)
        }
        var result = Data()
        appendUInt32(UInt32(body.count), to: &result)
        result.append(body)
        return result
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff)); data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff)); data.append(UInt8(value & 0xff))
    }

    private static func appendUInt64(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8((value >> UInt64(shift)) & 0xff)) }
    }
}

final class RemoteFrameDecoder {
    private var buffer = Data()

    func reset() { buffer = Data() }

    func append(_ data: Data) throws -> [RemoteFrame] {
        buffer.append(data)
        var frames: [RemoteFrame] = []
        while true {
            guard buffer.count >= 4 else { break }
            let length = Int(readUInt32(buffer, offset: 0))
            guard length >= 45 else { throw RemoteFrameError.invalidLength }
            guard length <= RemoteScribeProtocol.maximumFrameSize else { throw RemoteFrameError.tooLarge(length) }
            guard buffer.count >= 4 + length else { break }
            let body = buffer.subdata(in: 4..<(4 + length))
            buffer.removeSubrange(0..<(4 + length))
            guard let kind = RemoteMessageKind(rawValue: body[body.startIndex]) else {
                throw RemoteFrameError.invalidKind(body[body.startIndex])
            }
            let uuidStart = 1
            let uuidData = body.subdata(in: uuidStart..<(uuidStart + 36))
            guard let uuidString = String(data: uuidData, encoding: .utf8), let uuid = UUID(uuidString: uuidString) else {
                throw RemoteFrameError.invalidUUID
            }
            let sequence = readUInt64(body, offset: 37)
            let payload = body.subdata(in: 45..<body.count)
            frames.append(RemoteFrame(kind: kind, sessionID: uuid, sequence: sequence, payload: payload))
        }
        return frames
    }

    private func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }

    private func readUInt64(_ data: Data, offset: Int) -> UInt64 {
        var result: UInt64 = 0
        for index in 0..<8 { result = (result << 8) | UInt64(data[offset + index]) }
        return result
    }
}
