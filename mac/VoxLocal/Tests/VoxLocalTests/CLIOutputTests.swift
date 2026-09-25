import XCTest
@testable import VoxLocal

/// `llama-cli` stdout: loading spinner, banner, echoed prompt, answer, "Exiting...".
/// The echo is the prompt in full up to 500 bytes, else its first 500 bytes
/// followed by " ... (truncated)" (llama.cpp tools/cli/cli-ui.h).
final class CLIOutputTests: XCTestCase {
    private let banner = "Loading model... |\u{8} \nbuild : b1234\nmodel : qwen\n\navailable commands:\n  /exit or Ctrl+C     stop or exit\n"

    func testShortPromptKeepsOnlyTheAnswer() {
        let user = "le patient présente une douleur thoracique"
        let output = banner + "\n> \(user)\n\nLe patient présente une douleur thoracique.\n\n\nExiting...\n"
        XCTAssertEqual(LLMEngine.answer(fromCLIOutput: output, user: user), "Le patient présente une douleur thoracique.")
    }

    func testPromptOver500BytesMatchesTheTruncatedEcho() {
        // Multi-byte characters so byte 500 falls inside a scalar.
        let user = String(repeating: "é", count: 300) + " fin de la dictée"
        XCTAssertGreaterThan(user.utf8.count, 500)
        let echoed = String(decoding: Array(user.utf8.prefix(500)), as: UTF8.self)
        let output = banner + "\n> \(echoed) ... (truncated)\n\nTexte corrigé.\n\n\nExiting...\n"
        XCTAssertEqual(LLMEngine.answer(fromCLIOutput: output, user: user), "Texte corrigé.")
    }

    func testTruncatedEchoWithSplitScalarIsStillFound() {
        // 499 ASCII bytes then "é": the 500-byte prefix ends inside "é", which
        // llama-cli prints as a lone lead byte decoded to U+FFFD.
        let user = String(repeating: "a", count: 499) + "é suite"
        let echoed = String(decoding: Array(user.utf8.prefix(500)), as: UTF8.self)
        let output = banner + "\n> \(echoed) ... (truncated)\n\nRéponse.\n\nExiting...\n"
        XCTAssertEqual(LLMEngine.answer(fromCLIOutput: output, user: user), "Réponse.")
    }

    func testNoEchoReturnsEmptySoTheCallerFails() {
        let output = banner + "\nerror: failed to load model\n\nExiting...\n"
        XCTAssertEqual(LLMEngine.answer(fromCLIOutput: output, user: "bonjour docteur"), "")
    }
}
