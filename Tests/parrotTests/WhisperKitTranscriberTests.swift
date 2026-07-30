import XCTest
@testable import parrot

final class WhisperKitTranscriberTests: XCTestCase {
    func testAuthorizationFailureMessagePointsToHuggingFaceLogin() {
        let message = WhisperKitTranscriber.describeSetupFailure(FakeError("authorizationRequired"))

        XCTAssertTrue(message.contains("Hugging Face authentication failed"))
        XCTAssertTrue(message.contains("hf auth login --force"))
        XCTAssertTrue(message.contains("authorizationRequired"))
    }
}

private struct FakeError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
