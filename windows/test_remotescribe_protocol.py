import unittest
from uuid import UUID

from remotescribe_protocol import (
    BODY_HEADER_SIZE,
    FrameDecoder,
    MessageKind,
    ProtocolError,
    decode_frame,
    encode_audio_frame,
    encode_json_frame,
)


SESSION = UUID("12345678-1234-5678-1234-567812345678")


class ProtocolTests(unittest.TestCase):
    def test_json_frame_matches_wire_layout_and_round_trips(self) -> None:
        raw = encode_json_frame(MessageKind.PAIR, SESSION, 9, {"protocolVersion": 1, "deviceName": "poste-01"})
        self.assertEqual(int.from_bytes(raw[:4], "big"), len(raw) - 4)
        self.assertEqual(raw[4], 1)
        self.assertEqual(raw[5:41], str(SESSION).upper().encode("ascii"))
        self.assertEqual(int.from_bytes(raw[41:49], "big"), 9)
        frame = decode_frame(raw)
        self.assertIs(frame.kind, MessageKind.PAIR)
        self.assertEqual(frame.session_id, SESSION)
        self.assertEqual(frame.sequence, 9)
        self.assertEqual(frame.json(), {"protocolVersion": 1, "deviceName": "poste-01"})


    def test_incremental_decoder_handles_fragmentation_and_coalescing(self) -> None:
        one = encode_audio_frame(SESSION, 1, b"\x00\x00" * 100)
        two = encode_json_frame(MessageKind.PING, SESSION, 2, {"timestamp": 3})
        decoder = FrameDecoder()
        self.assertEqual(decoder.feed(one[:7]), [])
        frames = decoder.feed(one[7:] + two)
        self.assertEqual([f.kind for f in frames], [MessageKind.AUDIO_CHUNK, MessageKind.PING])
        self.assertEqual(frames[0].payload, b"\x00\x00" * 100)
        self.assertEqual(decoder.buffered_bytes, 0)


    def test_rejects_odd_pcm_and_oversized_frames(self) -> None:
        with self.assertRaises(ProtocolError):
            encode_audio_frame(SESSION, 0, b"\x00")
        # Declared body length is larger than the protocol maximum; no payload
        # is allocated while parsing it.
        with self.assertRaises(ProtocolError):
            decode_frame((1_048_577).to_bytes(4, "big") + b"\x00" * BODY_HEADER_SIZE)


if __name__ == "__main__":
    unittest.main()
