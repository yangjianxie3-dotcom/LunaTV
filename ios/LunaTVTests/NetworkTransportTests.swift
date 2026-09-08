import XCTest
@testable import LunaTV

private final class FixtureURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class NetworkTransportTests: XCTestCase {
    @MainActor private func transport() -> NetworkTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureURLProtocol.self]
        return NetworkTransport(configuration: config)
    }
    private let request = URLRequest(url: URL(string: "https://fixture.example.test/catalog")!)

    @MainActor func testDroppedConnectionRetriesOnceOnFreshPool() async throws {
        var calls = 0
        let lock = NSLock()
        FixtureURLProtocol.handler = { _ in
            lock.lock(); defer { lock.unlock() }
            calls += 1
            if calls == 1 { throw URLError(.networkConnectionLost) }
            return (200, Data("ok".utf8))
        }
        defer { FixtureURLProtocol.handler = nil }
        let (data, _) = try await transport().data(for: request)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "ok")
        XCTAssertEqual(calls, 2)
    }
    @MainActor func testRepeatedFailureStopsAfterTwoRequests() async {
        var calls = 0
        FixtureURLProtocol.handler = { _ in calls += 1; throw URLError(.timedOut) }
        defer { FixtureURLProtocol.handler = nil }
        do { _ = try await transport().data(for: request); XCTFail("Expected failure") } catch {}
        XCTAssertEqual(calls, 2)
    }
    @MainActor func testHTTPAuthenticationFailureIsNotRetried() async throws {
        var calls = 0
        FixtureURLProtocol.handler = { _ in calls += 1; return (401, Data()) }
        defer { FixtureURLProtocol.handler = nil }
        let (_, response) = try await transport().data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
        XCTAssertEqual(calls, 1)
    }
    @MainActor func testOfflineDoesNotStartRequest() async {
        var calls = 0
        FixtureURLProtocol.handler = { _ in calls += 1; return (200, Data()) }
        defer { FixtureURLProtocol.handler = nil }
        let client = transport()
        client.update(NetworkSnapshot(kind: .offline, isConnected: false, generation: 1))
        do { _ = try await client.data(for: request); XCTFail("Expected offline") }
        catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        XCTAssertEqual(calls, 0)
    }
    @MainActor func testCancelledCallerDoesNotRetry() async {
        var calls = 0
        FixtureURLProtocol.handler = { _ in calls += 1; throw URLError(.networkConnectionLost) }
        defer { FixtureURLProtocol.handler = nil }
        let client = transport()
        let task = Task { try await client.data(for: request) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch {}
        XCTAssertEqual(calls, 0)
    }
}
