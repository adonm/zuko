import Darwin
import Foundation
import IrohLib

/// In-app, on-device log capture for debugging connection stalls.
///
/// iOS connections occasionally stall mid-dial (relay propagation, NAT, link
/// churn) and there has been no on-device signal for *why*. This captures two
/// log streams into one app-owned file and exposes them to the in-app Logs
/// viewer (copy/shareable):
///
/// 1. **iroh internals** — `IrohLib.setLogLevel(.info)` makes iroh's tracing
///    layer emit to **stdout**. We redirect fd 1/2 to a log file at launch
///    (before any endpoint binds), so iroh's lines land there.
/// 2. **app lifecycle** — `LogCapture.shared.log(...)` calls from
///    `IrohSession`/`ClaimSession` (connecting → connected → reconnecting …)
///    write timestamped context lines to the same file via stdout.
///
/// ## Why a file, not a pipe
///
/// A pipe would risk back-pressuring iroh's writer threads when the reader
/// falls behind — which could *cause* the very connection stalls we're trying
/// to diagnose. A regular file append (kernel page cache) never blocks the
/// writer, so logging is observationally inert.
///
/// ## Why not os_log / LogView (alexejn/LogView) / tracing-oslog
///
/// - `alexejn/LogView` reads the OSLog store filtered by subsystem. iroh's
///   `setLogLevel` writes to stdout, which iOS files under a generic process
///   subsystem — not the app's — so LogView's filter never surfaces iroh lines.
/// - `tracing-oslog` would need to live in the Rust staticlib, which
///   deliberately contains **no iroh** (only Argon2) to keep the Linux→iOS
///   cross-compile clean (`build-ffi.sh`). Adding it re-risks that build for
///   no gain. The stdout-redirect here captures iroh with zero Rust changes.
/// - This app-owned buffer is the only way to show logs **in-app** on iOS
///   (apps can't read their own OSLog store reliably/portably for display).
///
/// The file lives in Caches (disposable; iOS may purge it). We tail only the
/// last `tailBytes` into the viewer so a long session can't blow up memory.
@MainActor
final class LogCapture: ObservableObject {
    static let shared = LogCapture()

    /// Maximum entries retained in memory for the viewer (and copy/share).
    private static let maxEntries = 2000
    /// Tail of the file we parse on each reload. Bounds the read so a long
    /// session's multi-MB file doesn't get loaded whole each tick.
    private static let tailBytes: UInt64 = 512 * 1024
    /// Poll interval while the Logs viewer is open.
    static let pollInterval: Duration = .milliseconds(500)

    @Published private(set) var entries: [LogEntry] = []

    /// Last file size we read up to — `reload()` is a no-op when unchanged,
    /// so idle sessions cost nothing while the viewer is open.
    private var lastSize: UInt64 = 0
    private var fileURL: URL?

    /// Identifier of the line appended by `log(_:level:category:)`. Lets us
    /// pick our own lines out for colouring even though iroh's lines use a
    /// different format.
    private static let appPrefix = "zuko-app"

    private init() {}

    // MARK: - Startup

    /// Redirect stdout/stderr to a fresh log file and enable iroh tracing.
    /// Must run once at app launch, **before** any iroh endpoint is bound, so
    /// every iroh line is captured from the start. Idempotent.
    func start() {
        guard fileURL == nil else { return }
        guard
            let caches = try? FileManager.default.url(
                for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
        else { return }
        let url = caches.appendingPathComponent("zuko-console.log")
        fileURL = url

        // Fresh file per launch — a previous launch's stale logs aren't useful
        // for diagnosing the current one, and Caches may persist between runs.
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: nil)

        // Point fd 1 and 2 at the file in append mode. Rust's `std::io::stdout`
        // writes to fd 1 directly, so iroh's tracing-fmt output now lands here.
        // O_APPEND makes every write() atomic at the byte level, so concurrent
        // app/iroh lines never interleave/corrupt each other mid-line.
        let opened = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard opened >= 0 else { return }

        // Defensive fd hygiene: if iOS launched us with stdin/stdout/stderr
        // closed, `open` can legally return 0, 1, or 2. Duplicating to a safe
        // scratch fd first means the final `close(logFD)` can never close the
        // stdout/stderr descriptors we just installed.
        let logFD: Int32
        if opened <= STDERR_FILENO {
            let duplicated = fcntl(opened, F_DUPFD, STDERR_FILENO + 1)
            close(opened)
            guard duplicated >= 0 else { return }
            logFD = duplicated
        } else {
            logFD = opened
        }

        guard dup2(logFD, STDOUT_FILENO) >= 0, dup2(logFD, STDERR_FILENO) >= 0 else {
            close(logFD)
            return
        }
        close(logFD)

        // Enable iroh tracing → stdout (now the file). setLogLevel calls
        // tracing's global `.init()` once; a second call anywhere is a no-op,
        // so this stays correct even if something else also tries.
        setLogLevel(level: .info)

        log(.info, category: "log", "logging started — iroh level info")
        reload()
    }

    // MARK: - App-level logging

    /// Append an app-level context line. Writes through stdout (the log file),
    /// so app lines interleave chronologically with iroh's own lines.
    func log(_ level: AppLogLevel, category: String, _ message: String) {
        let ts = Self.nowTimestamp()
        // Marked so the viewer can colour our own lines deterministically and
        // so they're easy to grep out of a shared file. The level token also
        // lets the guess heuristic pick iroh lines that don't carry the prefix.
        let line = "\(ts) \(Self.appPrefix) \(level.token) [\(category)] \(message)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    // MARK: - Reader (viewer-facing)

    /// Re-read the log file tail into `entries`. Cheap no-op when nothing new
    /// has been written. Called on a timer by the Logs viewer while open.
    func reload() {
        guard let url = fileURL else { return }
        guard let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }

        let size = fh.seekToEndOfFile()
        // Nothing new since last read → keep the buffer as-is.
        if size == lastSize, !entries.isEmpty { return }
        lastSize = size

        let start = size > Self.tailBytes ? size - Self.tailBytes : 0
        fh.seek(toFileOffset: start)
        let data = fh.readDataToEndOfFile()

        guard let text = String(data: data, encoding: .utf8) else { return }
        var parsed: [LogEntry] = []
        parsed.reserveCapacity(256)
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            parsed.append(LogEntry(text: String(raw)))
        }
        if parsed.count > Self.maxEntries {
            parsed = Array(parsed.suffix(Self.maxEntries))
        }
        entries = parsed
    }

    /// Truncate the file and clear the buffer. Useful before reproducing a
    /// stall so the viewer isn't drowned in old lines.
    func clear() {
        guard let url = fileURL else { return }
        // Truncate IN PLACE, not remove + recreate: fd 1/2 still point at this
        // inode, so iroh/app writes keep flowing to the same file after the
        // clear. O_APPEND makes the next write seek to the new end (0).
        if let fh = try? FileHandle(forWritingTo: url) {
            try? fh.truncate(atOffset: 0)
            try? fh.close()
        }
        lastSize = 0
        entries = []
        // Re-seed so the viewer shows the clear happened rather than going blank.
        log(.info, category: "log", "log cleared")
        reload()
    }

    private static func nowTimestamp() -> String {
        // Compact, sortable, second.precision. Matches iroh's own timestamp
        // column closely enough that interleaved lines read in order.
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}

/// One captured log line (iroh or app). `level` is best-effort guessed from the
/// text so the viewer can tint errors/warnings without a rigid schema.
struct LogEntry: Identifiable, Hashable {
    let id = UUID()
    let text: String
    var level: AppLogLevel { AppLogLevel.guess(from: text) }
}

/// Coarse severity for tinting. App lines carry an explicit token; iroh's
/// tracing-fmt lines spell the level in uppercase so the same heuristic covers
/// both streams.
enum AppLogLevel: String, Hashable {
    case error, warn, info, debug, trace

    var token: String {
        switch self {
        case .error: "ERROR"
        case .warn: "WARN"
        case .info: "INFO"
        case .debug: "DEBUG"
        case .trace: "TRACE"
        }
    }

    static func guess(from line: String) -> AppLogLevel {
        // iroh fmt: `…  ERROR iroh::foo: msg`  / app: `… zuko-app ERROR […]`
        if line.contains(" ERROR ") || line.contains(" error ") { return .error }
        if line.contains(" WARN ") { return .warn }
        if line.contains(" DEBUG ") { return .debug }
        if line.contains(" TRACE ") { return .trace }
        return .info
    }
}
