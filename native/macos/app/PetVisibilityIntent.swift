import Foundation

/// The watcher and companion must recognize the same main desktop executables.
/// AppKit can momentarily omit an app; a process-list fallback avoids persisting
/// an unknown-PID Hide when the desktop process is still identifiable.
enum CodexDesktopProcessLookup {
    static let executablePaths: Set<String> = [
        "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
        "/Applications/Codex.app/Contents/MacOS/Codex",
    ]

    static func pids(in processListing: String) -> Set<pid_t> {
        Set(processListing.split(separator: "\n").compactMap { row in
            let fields = row.split(maxSplits: 1, omittingEmptySubsequences: true,
                                   whereSeparator: { $0.isWhitespace })
            guard fields.count == 2,
                  executablePaths.contains(String(fields[1])),
                  let pid = pid_t(fields[0]), pid > 0 else { return nil }
            return pid
        })
    }

    static func resolve(appKitPIDs: Set<pid_t>,
                        processListing: () -> String?) -> Set<pid_t> {
        guard appKitPIDs.isEmpty else { return appKitPIDs }
        guard let listing = processListing() else { return [] }
        return pids(in: listing)
    }

    static func readProcessListing() -> String? {
        readPS(arguments: ["-ww", "-axo", "pid=,comm="])
    }

    static func launchDates(in listing: String, pids: Set<pid_t>) -> [pid_t: Date] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        formatter.isLenient = false
        var dates: [pid_t: Date] = [:]
        for row in listing.split(separator: "\n") {
            let fields = row.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard fields.count == 2, let pid = pid_t(fields[0]), pids.contains(pid) else { continue }
            let text = fields[1].split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard let date = formatter.date(from: text), formatter.string(from: date) == text else { continue }
            dates[pid] = date
        }
        return dates
    }

    static func readLaunchDates(pids: Set<pid_t>) -> [pid_t: Date] {
        guard !pids.isEmpty,
              let listing = readPS(arguments: ["-ww", "-p", pids.sorted().map(String.init).joined(separator: ","),
                                               "-o", "pid=,lstart="]) else { return [:] }
        return launchDates(in: listing, pids: pids)
    }

    private static func readPS(arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"], uniquingKeysWith: { _, new in new })
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // Drain before waiting: a long process list can exceed pipe capacity.
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

/// Records an explicit Hide or Quit across pet process restarts. The watcher
/// may reopen the app on each Codex activation, so panel visibility alone
/// cannot tell us whether the user wants the pet shown.
struct PetVisibilityIntent {
    private struct SavedState: Codable {
        let suppressedCodexPIDs: [Int]
        let recordedAt: Double?
    }

    static let defaultStoreURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CodexQuotaPet/visibility.json")

    private let storeURL: URL
    private(set) var hiddenForCodexPIDs: Set<pid_t>?
    private var recordedAt: Date?
    private var savedData: Data?
    private var savedAttributes: NSDictionary?

    init(storeURL: URL = defaultStoreURL) {
        self.storeURL = storeURL
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: storeURL.path)
            savedAttributes = attributes as NSDictionary
            recordedAt = attributes[.modificationDate] as? Date
            let data = try Data(contentsOf: storeURL)
            savedData = data
            let state = try JSONDecoder().decode(SavedState.self, from: data)
            if let time = state.recordedAt, time.isFinite {
                recordedAt = Date(timeIntervalSince1970: max(recordedAt?.timeIntervalSince1970 ?? time, time))
            }
            let pids = state.suppressedCodexPIDs
            guard pids.allSatisfy({ $0 > 0 && pid_t(exactly: $0) != nil }) else {
                // A present but unusable file must not silently undo Hide.
                hiddenForCodexPIDs = []
                return
            }
            hiddenForCodexPIDs = Set(pids.compactMap(pid_t.init(exactly:)))
        } catch {
            // Malformed stays hidden unless a reliable later launch proves
            // this record belongs to an earlier desktop session.
            hiddenForCodexPIDs = []
        }
    }

    mutating func hide(codexPIDs: Set<pid_t>) throws {
        let state = SavedState(suppressedCodexPIDs: codexPIDs.map(Int.init).sorted(),
                               recordedAt: Date().timeIntervalSince1970)
        let data = try JSONEncoder().encode(state)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: storeURL, options: .atomic)
        hiddenForCodexPIDs = codexPIDs
        // Refresh the exact generation used by automatic guarded removal.
        self = PetVisibilityIntent(storeURL: storeURL)
    }

    mutating func showExplicitly() throws {
        if FileManager.default.fileExists(atPath: storeURL.path) {
            try FileManager.default.removeItem(at: storeURL)
        }
        hiddenForCodexPIDs = nil
    }

    mutating func shouldShowOnReopen(codexPIDs: Set<pid_t>, launchDates: [pid_t: Date] = [:]) throws -> Bool {
        guard let hiddenForCodexPIDs else { return true }
        if hiddenForCodexPIDs.isEmpty {
            // An activation or watcher restart supplies no proof of a launch.
            // ps has second precision, so require a conservative two-second gap.
            guard let recordedAt,
                  codexPIDs.contains(where: { pid in
                      guard let launch = launchDates[pid] else { return false }
                      return launch.timeIntervalSince(recordedAt) >= 2
                  }) else { return false }
        } else {
            guard !codexPIDs.subtracting(hiddenForCodexPIDs).isEmpty else { return false }
        }
        // Preserve a newer Hide written after this object took its snapshot.
        guard let savedData, let savedAttributes,
              let latestData = try? Data(contentsOf: storeURL), latestData == savedData,
              let latestAttributes = try? FileManager.default.attributesOfItem(atPath: storeURL.path),
              savedAttributes.isEqual(latestAttributes as NSDictionary) else { return false }
        // A newly launched Codex process restores the auto-open behavior.
        try showExplicitly()
        return true
    }
}
