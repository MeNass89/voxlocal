import Foundation

/// Binary framing shared by every client and backend:
/// UInt32 body length, UInt8 message kind, 36-byte UUID, UInt64 sequence, payload.
public enum RemoteFrameEncoder {
    public static func encode(_ frame: RemoteFrame) throws -> Data {
        guard let uuid = frame.sessionID.uuidString.data(using: .utf8), uuid.count == 36 else {
            throw RemoteScribeError.protocolViolation("UUID illisible")
        }
        let bodyLength = 1 + 36 + 8 + frame.payload.count
        guard bodyLength <= RemoteScribeProtocol.maximumFrameSize else {
            throw RemoteScribeError.protocolViolation("trame trop volumineuse")
        }
        var data = Data()
        append(UInt32(bodyLength), to: &data)
        data.append(frame.kind.rawValue)
        data.append(uuid)
        append(frame.sequence, to: &data)
        data.append(frame.payload)
        return data
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func append(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xff))
        }
    }
}

public final class RemoteFrameDecoder {
    private var buffer = Data()

    public init() {}

    public func append(_ data: Data) throws -> [RemoteFrame] {
        buffer.append(data)
        var frames: [RemoteFrame] = []

        while buffer.count >= 4 {
            let length = Int(readUInt32(buffer.prefix(4)))
            guard length >= 45, length <= RemoteScribeProtocol.maximumFrameSize else {
                throw RemoteScribeError.protocolViolation("longueur de trame \(length)")
            }
            guard buffer.count >= 4 + length else { break }

            let body = buffer.subdata(in: 4..<(4 + length))
            guard let kind = RemoteMessageKind(rawValue: body[body.startIndex]) else {
                throw RemoteScribeError.protocolViolation("type de message inconnu")
            }
            let uuidStart = body.startIndex + 1
            let uuidEnd = uuidStart + 36
            guard let uuidString = String(data: body.subdata(in: uuidStart..<uuidEnd), encoding: .utf8),
                  let uuid = UUID(uuidString: uuidString) else {
                throw RemoteScribeError.protocolViolation("UUID invalide")
            }
            let sequenceStart = uuidEnd
            let sequenceEnd = sequenceStart + 8
            let sequence = readUInt64(body.subdata(in: sequenceStart..<sequenceEnd))
            let payload = body.subdata(in: sequenceEnd..<body.endIndex)
            frames.append(RemoteFrame(kind: kind, sessionID: uuid, sequence: sequence, payload: payload))
            buffer.removeSubrange(0..<(4 + length))
        }
        return frames
    }

    private func readUInt32(_ data: Data.SubSequence) -> UInt32 {
        data.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func readUInt64(_ data: Data) -> UInt64 {
        data.reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
