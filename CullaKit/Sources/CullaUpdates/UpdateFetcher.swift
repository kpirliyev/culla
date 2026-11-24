import Foundation

// All of Culla's network code is in this file. The app makes exactly one kind of request: it reads
// one small static file from the project's own site to learn the newest version. Nothing about
// the person, their Mac or their photos is sent, and nothing in the answer is ever used as an
// address. The download itself happens in the browser.

/// The fixed addresses and limits of the update check.
public enum UpdateLimits {
    /// The only address Culla requests. HTTPS, no query string.
    public static let address = URL(string: "https://cullaapp.com/update.json")!
    /// The largest answer read; the real file is well under 1 KB.
    public static let maximumBodyBytes = 64 * 1024
    /// How long the request may take, all told.
    public static let timeout: TimeInterval = 15
    /// The only headers Culla sets, all fixed: the product name with no version or system
    /// information, the kind of answer wanted, and a language. `Accept-Language` is pinned to `en`
    /// because URLSession would otherwise fill it in from the person's language list in System
    /// Settings. On the wire the loading system adds only `Host`, `Cache-Control: no-cache` (from
    /// the cache policy), `Accept-Encoding` and `Connection`.
    public static let headers = ["User-Agent": "Culla", "Accept": "application/json", "Accept-Language": "en"]
}

/// Reads the update file. The app uses `HTTPSUpdateFetcher`; tests and automation stand in
/// for it.
public protocol UpdateFetching: Sendable {
    func fetch() async throws(UpdateCheckError) -> UpdateDocument
}

/// Reads `UpdateLimits.address` with URLSession: an ephemeral session with no cookies, no cache
/// and no credentials, a 15 second timeout, no waiting for connectivity, redirects refused, only
/// status 200 accepted and an answer over 64 KB refused.
///
/// Sendable by hand: `URLSessionConfiguration` is not marked Sendable, but the fetcher holds a
/// private copy that nothing changes after `init`, and each fetch makes its own session from it.
public struct HTTPSUpdateFetcher: UpdateFetching, @unchecked Sendable {
    private let configuration: URLSessionConfiguration

    /// `configuration` is for tests, which add a URLProtocol stub to `makeConfiguration()`.
    public init(configuration: URLSessionConfiguration = HTTPSUpdateFetcher.makeConfiguration()) {
        // URLSession copies its configuration; this copy is never changed after.
        self.configuration = configuration.copy() as! URLSessionConfiguration
    }

    /// The session's settings: nothing is stored, nothing is remembered between checks.
    public static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = UpdateLimits.timeout
        configuration.timeoutIntervalForResource = UpdateLimits.timeout
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 1
        return configuration
    }

    /// The one request: GET, the fixed address and the fixed headers (`UpdateLimits.headers`).
    public static func makeRequest() -> URLRequest {
        var request = URLRequest(url: UpdateLimits.address, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: UpdateLimits.timeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        for (name, value) in UpdateLimits.headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    public func fetch() async throws(UpdateCheckError) -> UpdateDocument {
        let request = Self.makeRequest()
        guard request.url?.scheme == "https" else { throw .unexpectedAddress }
        let session = URLSession(configuration: configuration, delegate: RedirectRefuser(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw Self.transportError(error)
        }
        // A refused redirect is delivered as the 3xx answer itself; any answer not from the fixed
        // address is refused too.
        guard let http = response as? HTTPURLResponse, let url = http.url,
              url.scheme == "https", url.host == UpdateLimits.address.host, url.path == UpdateLimits.address.path
        else { throw .unexpectedAddress }
        guard http.statusCode == 200 else { throw .status(http.statusCode) }
        if http.expectedContentLength > Int64(UpdateLimits.maximumBodyBytes) { throw .tooLarge }

        var body = Data()
        body.reserveCapacity(1024)
        do {
            for try await byte in bytes {
                body.append(byte)
                if body.count > UpdateLimits.maximumBodyBytes { throw UpdateCheckError.tooLarge }
            }
        } catch let error as UpdateCheckError {
            throw error
        } catch {
            throw Self.transportError(error)
        }
        return try UpdateDocument.decode(body)
    }

    private static func transportError(_ error: any Error) -> UpdateCheckError {
        if let error = error as? URLError { return .transport(error.code.rawValue) }
        return .transport(URLError.Code.unknown.rawValue)
    }
}

/// Refuses every redirect: the 3xx answer is then the answer, which `fetch()` refuses.
private final class RedirectRefuser: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
