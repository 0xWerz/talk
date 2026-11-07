import Foundation
import OSLog

enum Log {
    private static let logger = Logger(subsystem: "com.talk.dictation", category: "talk")

    static func info(_ scope: String, _ message: String) {
        // .notice, not .info: info messages are never written to disk, so
        // `log show` after the fact would find nothing.
        logger.notice("[\(scope, privacy: .public)] \(message, privacy: .public)")
    }

    static func error(_ scope: String, _ message: String) {
        logger.error("[\(scope, privacy: .public)] \(message, privacy: .public)")
    }
}
