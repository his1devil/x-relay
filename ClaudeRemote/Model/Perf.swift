import os

/// os_signpost helpers — visible in Instruments (Logging / os_signpost track) and
/// filterable by subsystem `dev.antai.xrelay`. Used to prove where frames go:
/// transcript reparse, adapter rebuild, thread body evals, per-cell hosting.
enum Perf {
    static let log = OSLog(subsystem: "dev.antai.xrelay", category: "perf")

    @inline(__always)
    static func begin(_ name: StaticString) -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return id
    }

    @inline(__always)
    static func end(_ name: StaticString, _ id: OSSignpostID, _ detail: String = "") {
        os_signpost(.end, log: log, name: name, signpostID: id, "%{public}s", detail)
    }

    @inline(__always)
    static func event(_ name: StaticString, _ detail: String = "") {
        os_signpost(.event, log: log, name: name, "%{public}s", detail)
    }
}
