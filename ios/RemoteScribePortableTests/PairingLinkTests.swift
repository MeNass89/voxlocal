import XCTest
@testable import RemoteScribePortable

final class PairingLinkTests: XCTestCase {
    /// 32 bytes whose base64 form contains `+` and `/`, the characters a QR
    /// generator may or may not percent-encode.
    private let fingerprint = Data((0..<32).map { UInt8(truncatingIfNeeded: 0xFB &+ $0 &* 7) })
    private var fingerprintBase64: String { fingerprint.base64EncodedString() }
    private var encodedFingerprint: String {
        fingerprintBase64.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    }

    func testValidLinkWithPercentEncodedValues() throws {
        XCTAssertTrue(fingerprintBase64.contains("+") || fingerprintBase64.contains("/"))
        let url = try XCTUnwrap(URL(string: "remotescribe://pair?name=Poste%20Cardiologie&code=ABCD2345&fp=\(encodedFingerprint)"))
        let link = try XCTUnwrap(PairingLink(url: url))
        XCTAssertEqual(link.serverName, "Poste Cardiologie")
        XCTAssertEqual(link.code, "ABCD2345")
        XCTAssertEqual(link.fingerprint, fingerprint)
    }

    func testValidLinkWithRawBase64AndPastedWhitespace() throws {
        let link = try XCTUnwrap(PairingLink(string: "  remotescribe://pair?name=VoxLocal&code=test-only-123456&fp=\(fingerprintBase64)\n"))
        XCTAssertEqual(link.serverName, "VoxLocal")
        XCTAssertEqual(link.code, "test-only-123456")
        XCTAssertEqual(link.fingerprint, fingerprint)
    }

    func testMissingFingerprintIsRejected() {
        XCTAssertNil(PairingLink(string: "remotescribe://pair?name=VoxLocal&code=ABCD2345"))
        XCTAssertNil(PairingLink(string: "remotescribe://pair?name=VoxLocal&code=ABCD2345&fp="))
    }

    func testBadBase64IsRejected() {
        XCTAssertNil(PairingLink(string: "remotescribe://pair?name=VoxLocal&code=ABCD2345&fp=not*base64"))
        // Valid base64 but not a SHA-256 digest.
        XCTAssertNil(PairingLink(string: "remotescribe://pair?name=VoxLocal&code=ABCD2345&fp=\(Data(count: 16).base64EncodedString())"))
    }

    func testWrongSchemeOrActionIsRejected() {
        XCTAssertNil(PairingLink(string: "https://pair?name=VoxLocal&code=ABCD2345&fp=\(encodedFingerprint)"))
        XCTAssertNil(PairingLink(string: "remotescribe://connect?name=VoxLocal&code=ABCD2345&fp=\(encodedFingerprint)"))
    }

    func testInvalidCodeIsRejected() {
        XCTAssertNil(PairingLink(string: "remotescribe://pair?name=VoxLocal&code=ABC&fp=\(encodedFingerprint)"))
        XCTAssertNil(PairingLink(string: "remotescribe://pair?name=VoxLocal&code=ABCD%202345&fp=\(encodedFingerprint)"))
        XCTAssertNil(PairingLink(string: "remotescribe://pair?name=VoxLocal&code=\(String(repeating: "A", count: 65))&fp=\(encodedFingerprint)"))
    }

    func testAmbiguousOrMalformedNameIsRejected() {
        XCTAssertNil(PairingLink(string: "remotescribe://pair?name=A&name=B&code=ABCD2345&fp=\(encodedFingerprint)"))
        XCTAssertNil(PairingLink(string: "remotescribe://pair?name=%20Poste&code=ABCD2345&fp=\(encodedFingerprint)"))
        XCTAssertNil(PairingLink(string: "remotescribe://pair?code=ABCD2345&fp=\(encodedFingerprint)"))
    }

    func testPairingLinkNeverReplacesADifferentPin() {
        let other = Data(repeating: 0x11, count: 32)
        XCTAssertFalse(PortableClientModel.pinConflict(previous: nil, incoming: fingerprint))
        XCTAssertFalse(PortableClientModel.pinConflict(previous: fingerprint, incoming: fingerprint))
        XCTAssertTrue(PortableClientModel.pinConflict(previous: other, incoming: fingerprint))
    }
}
