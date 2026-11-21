import QuartzCore

/// Times sections of main-thread work in debug builds, so the automation dump can say which
/// part of a long stall was which (`slowSections`). Compiled to nothing in release builds.
@MainActor
enum MainThreadTiming {
    #if DEBUG
    /// Sections over 4 ms, the latest last; at most 400 are kept.
    static var sections: [(name: String, ms: Double, at: Double)] = []
    #endif

    /// Starts timing a section; call `end()` on the result (in a `defer`).
    @MainActor
    struct Section {
        #if DEBUG
        let name: String
        let start: Double
        #endif

        func end() {
            #if DEBUG
            let end = CACurrentMediaTime()
            let ms = (end - start) * 1000
            if ms > 4 {
                MainThreadTiming.sections.append((name, ms, end))
                if MainThreadTiming.sections.count > 400 { MainThreadTiming.sections.removeFirst(MainThreadTiming.sections.count - 400) }
            }
            #endif
        }
    }

    @inline(__always)
    static func begin(_ name: String) -> Section {
        #if DEBUG
        Section(name: name, start: CACurrentMediaTime())
        #else
        Section()
        #endif
    }

    @inline(__always)
    static func measure<T>(_ name: @autoclosure () -> String, _ body: () throws -> T) rethrows -> T {
        #if DEBUG
        let start = CACurrentMediaTime()
        defer {
            let end = CACurrentMediaTime()
            let ms = (end - start) * 1000
            if ms > 4 {
                sections.append((name(), ms, end))
                if sections.count > 400 { sections.removeFirst(sections.count - 400) }
            }
        }
        #endif
        return try body()
    }
}
