import XCTest
@testable import App

/// Unit tests for the bridge's hand-rolled HTTP request parser
/// (`HTTPRequest.parse`). This is the one piece of `LocalTaskServer`
/// that's pure logic and easy to get subtly wrong (incremental reads,
/// Content-Length framing, query-string stripping), so it gets
/// deterministic coverage here.
///
/// The networking + supervisor-polling paths are validated by running
/// the actual app and hitting the bridge with curl / the voice bot —
/// they can't be unit-tested without a real `AgentSupervisor` and a
/// live socket.
final class LocalTaskServerTests: XCTestCase {
    private func data(_ string: String) -> Data { Data(string.utf8) }

    // MARK: - Complete requests

    func test_parse_getHealth_returnsMethodAndPathWithEmptyBody() {
        let raw = data("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        let request = HTTPRequest.parse(raw)
        XCTAssertEqual(request?.method, "GET")
        XCTAssertEqual(request?.path, "/health")
        XCTAssertEqual(request?.body.count, 0)
    }

    func test_parse_postTask_returnsBody() {
        let body = #"{"prompt":"create a calendar event"}"#
        let raw = data(
            "POST /task HTTP/1.1\r\nContent-Type: application/json\r\n"
                + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
        )
        let request = HTTPRequest.parse(raw)
        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(request?.path, "/task")
        XCTAssertEqual(request?.body, data(body))
    }

    func test_parse_stripsQueryStringFromPath() {
        let raw = data("GET /health?verbose=1 HTTP/1.1\r\n\r\n")
        XCTAssertEqual(HTTPRequest.parse(raw)?.path, "/health")
    }

    func test_parse_contentLengthIsCaseInsensitive() {
        let body = "hi"
        let raw = data("POST /task HTTP/1.1\r\ncontent-length: 2\r\n\r\n\(body)")
        XCTAssertEqual(HTTPRequest.parse(raw)?.body, data(body))
    }

    // MARK: - Incomplete requests (parser must signal "read more")

    func test_parse_returnsNilWhenHeadersIncomplete() {
        let raw = data("POST /task HTTP/1.1\r\nContent-Length: 5\r\n")
        XCTAssertNil(HTTPRequest.parse(raw), "no header terminator yet")
    }

    func test_parse_returnsNilWhenBodyShorterThanContentLength() {
        // Declares 20 bytes but only 3 arrived — must wait for more.
        let raw = data("POST /task HTTP/1.1\r\nContent-Length: 20\r\n\r\nabc")
        XCTAssertNil(HTTPRequest.parse(raw), "body not fully arrived yet")
    }

    func test_parse_returnsBodyOncePartialBecomesComplete() {
        // Same request as above, now with all 20 body bytes present.
        let body = "01234567890123456789"
        let raw = data("POST /task HTTP/1.1\r\nContent-Length: 20\r\n\r\n\(body)")
        XCTAssertEqual(HTTPRequest.parse(raw)?.body, data(body))
    }
}
