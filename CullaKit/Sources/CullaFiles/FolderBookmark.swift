import Foundation
import Synchronization

/// Bookmarks that let the app reach a shoot folder again after a relaunch.
///
/// The sandboxed app needs security-scoped bookmarks (the app-scope bookmarks entitlement), and
/// must start access to the resolved URL before reading the folder and stop it when the shoot
/// closes. Tests and `culla-eval` run unsandboxed and use plain bookmarks.
public enum FolderBookmark {
    /// A bookmark resolved back to a folder.
    public struct Resolved: Sendable, Hashable {
        public var url: URL
        /// True when the system says the bookmark should be made again, for example because the
        /// folder moved. Make a new one with `create(for:securityScoped:)` while access is
        /// started, and save it in place of the old one.
        public var isStale: Bool
    }

    /// Bookmark data for a folder. With `securityScoped` the bookmark grants read and write
    /// access when resolved in the sandboxed app.
    public static func create(for folder: URL, securityScoped: Bool) throws -> Data {
        try folder.bookmarkData(
            options: securityScoped ? [.withSecurityScope] : [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Resolves bookmark data to the folder's current URL, without showing any interface.
    /// Throws when the folder cannot be found, for example on a card that is not inserted.
    public static func resolve(_ data: Data, securityScoped: Bool) throws -> Resolved {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: securityScoped ? [.withSecurityScope, .withoutUI] : [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return Resolved(url: url, isStale: isStale)
    }

    /// Starts access to a URL resolved from a security-scoped bookmark. Returns whether access was
    /// started; false means the URL needs none (or cannot be reached), and there is nothing to
    /// stop. Every `true` must be balanced by one `stopAccess(_:)`.
    @discardableResult
    public static func startAccess(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    /// Ends access started with `startAccess(_:)`.
    public static func stopAccess(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }

    /// Runs `body` with access to the URL started, and stops it afterwards.
    public static func withAccess<T>(to url: URL, _ body: () throws -> T) rethrows -> T {
        let started = startAccess(url)
        defer { if started { stopAccess(url) } }
        return try body()
    }
}

/// Access to a folder held for as long as the value lives: started when made, stopped by `stop()`
/// or when the value goes away. Keep one per open shoot.
public final class FolderAccess: Sendable {
    public let url: URL
    /// True when access was actually started, so `stop()` has something to stop.
    public let isSecurityScoped: Bool
    private let stopped = Synchronization.Atomic<Bool>(false)

    public init(url: URL) {
        self.url = url
        isSecurityScoped = FolderBookmark.startAccess(url)
    }

    /// Stops access. Calling it again does nothing.
    public func stop() {
        guard isSecurityScoped, !stopped.exchange(true, ordering: .relaxed) else { return }
        FolderBookmark.stopAccess(url)
    }

    deinit {
        stop()
    }
}
