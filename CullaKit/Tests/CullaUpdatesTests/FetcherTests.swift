import CullaUpdates
import Foundation
import Synchronization
import Testing

/// Answers the fetcher's requests in place of the network: no test reaches a server.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case answer(status: Int, headers: [String: String], body: Data, url: URL? = nil)
        case redirect(to: URL, status: Int)
        case failure(URLError.Code)
    }

    private static let state = Mutex<(reply: Reply?, requests: [URLRequest])>((nil, []))

    static func reply(_ reply: Reply) {
        state.withLock { $0 = (reply, []) }
    }

    static var requests: [URLRequest] { state.withLock { $0.requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply = Self.state.withLock { state -> Reply? in
            state.requests.append(request)
            return state.reply
        }
        guard let client, let url = request.url else { return }
        switch reply {
        case .answer(let status, let headers, let body, let responseURL)?:
            let response = HTTPURLResponse(url: responseURL ?? url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: body)
            client.urlProtocolDidFinishLoading(self)
        case .redirect(let target, let status)?:
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            client.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocolDidFinishLoading(self)
        case .failure(let code)?:
            client.urlProtocol(self, didFailWithError: URLError(code))
        case nil:
            client.urlProtocol(self, didFailWithError: URLError(.unknown))
        }
    }

    override func stopLoading() {}
}

@Suite("Fetching the update file", .serialized)
struct FetcherTests {
    private static let validBody = Data(#"{ "version": "1.1", "minimumSystem": "26.0", "date": "2026-12-01" }"#.utf8)

    private func fetcher() -> HTTPSUpdateFetcher {
        let configuration = HTTPSUpdateFetcher.makeConfiguration()
        configuration.protocolClasses = [StubProtocol.self]
        return HTTPSUpdateFetcher(configuration: configuration)
    }

    private func fetch(_ reply: StubProtocol.Reply) async -> Result<UpdateDocument, UpdateCheckError> {
        StubProtocol.reply(reply)
        do {
            return .success(try await fetcher().fetch())
        } catch {
            return .failure(error)
        }
    }

    @Test func readsTheFile() async {
        let result = await fetch(.answer(status: 200, headers: ["Content-Type": "application/json"], body: Self.validBody))
        #expect(result == .success(UpdateDocument(version: "1.1", minimumSystem: "26.0", date: "2026-12-01")))
    }

    @Test func sendsOnlyTheFixedRequest() async throws {
        _ = await fetch(.answer(status: 200, headers: [:], body: Self.validBody))
        let requests = StubProtocol.requests
        try #require(requests.count == 1)
        let request = requests[0]
        #expect(request.url == URL(string: "https://cullaapp.com/update.json"))
        #expect(request.url?.query == nil)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Culla")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        // Pinned, so the loading system does not fill it in from the person’s languages.
        #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en")
        #expect(Set(request.allHTTPHeaderFields?.keys.map { $0.lowercased() } ?? []) == ["user-agent", "accept", "accept-language"])
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.httpBody == nil)
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
    }

    @Test func storesNoCookies() async throws {
        _ = await fetch(.answer(status: 200, headers: ["Set-Cookie": "id=12345; Path=/; Secure"], body: Self.validBody))
        _ = await fetch(.answer(status: 200, headers: [:], body: Self.validBody))
        let requests = StubProtocol.requests
        try #require(requests.count == 1)
        #expect(requests[0].value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test(arguments: [404, 500, 503, 204, 304])
    func acceptsOnlyStatus200(_ status: Int) async {
        let result = await fetch(.answer(status: status, headers: [:], body: Self.validBody))
        #expect(result == .failure(.status(status)))
    }

    @Test func refusesARedirect() async {
        let elsewhere = URL(string: "https://example.com/update.json")!
        let result = await fetch(.redirect(to: elsewhere, status: 301))
        // The refused redirect is delivered as the 301 itself, which is not a 200.
        #expect(result == .failure(.status(301)))
        #expect(!StubProtocol.requests.contains { $0.url?.host == "example.com" })
    }

    @Test func refusesAnAnswerFromAnotherAddress() async {
        let result = await fetch(.answer(status: 200, headers: [:], body: Self.validBody, url: URL(string: "https://example.com/update.json")))
        #expect(result == .failure(.unexpectedAddress))
        let insecure = await fetch(.answer(status: 200, headers: [:], body: Self.validBody, url: URL(string: "http://cullaapp.com/update.json")))
        #expect(insecure == .failure(.unexpectedAddress))
    }

    @Test func refusesALargeBody() async {
        let large = Data(repeating: 0x20, count: 64 * 1024 + 1)
        #expect(await fetch(.answer(status: 200, headers: [:], body: large)) == .failure(.tooLarge))
        // A body at the limit is read (and here is not a valid file).
        let atLimit = Data(repeating: 0x20, count: 64 * 1024)
        #expect(await fetch(.answer(status: 200, headers: [:], body: atLimit)) == .failure(.invalidDocument))
    }

    @Test func refusesALargeDeclaredLength() async {
        let result = await fetch(.answer(status: 200, headers: ["Content-Length": "10000000"], body: Self.validBody))
        #expect(result == .failure(.tooLarge))
    }

    @Test func refusesAnythingButTheFile() async {
        let result = await fetch(.answer(status: 200, headers: [:], body: Data("<html>Not found</html>".utf8)))
        #expect(result == .failure(.invalidDocument))
    }

    @Test func reportsATransportFailure() async {
        #expect(await fetch(.failure(.notConnectedToInternet)) == .failure(.transport(URLError.Code.notConnectedToInternet.rawValue)))
        #expect(await fetch(.failure(.timedOut)) == .failure(.transport(URLError.Code.timedOut.rawValue)))
    }

    @Test func theSessionKeepsNothing() {
        let configuration = HTTPSUpdateFetcher.makeConfiguration()
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.urlCache == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        #expect(configuration.timeoutIntervalForRequest == 15)
        #expect(configuration.timeoutIntervalForResource == 15)
        #expect(configuration.waitsForConnectivity == false)
    }

    @Test func theAddressIsFixedHTTPS() {
        #expect(UpdateLimits.address.scheme == "https")
        #expect(UpdateLimits.address.host == "cullaapp.com")
        #expect(UpdateLimits.address.query == nil)
        #expect(UpdateLimits.headers == ["User-Agent": "Culla", "Accept": "application/json", "Accept-Language": "en"])
    }
}
