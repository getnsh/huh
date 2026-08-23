import OSLog

/// Unified logging subsystems. Stream live with:
///   log stream --predicate 'subsystem == "com.getnsh.murmur"' --style compact
/// or after the fact with:
///   log show --last 5m --predicate 'subsystem == "com.getnsh.murmur"' --style compact
enum Log {
    static let app = Logger(subsystem: Brand.bundleID, category: "app")
    static let audio = Logger(subsystem: Brand.bundleID, category: "audio")
    static let asr = Logger(subsystem: Brand.bundleID, category: "asr")
    static let inject = Logger(subsystem: Brand.bundleID, category: "inject")
}
