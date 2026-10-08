import Foundation

@main
struct PetVisibilityIntentHarness {
    static func main() throws {
        let arguments = CommandLine.arguments
        if arguments.count == 2 && arguments[1] == "selftest" {
            try testDesktopPIDFallback()
            try testJSONRoundTrip()
            print("PetVisibilityIntent PASS")
            return
        }
        guard arguments.count == 4 || arguments.count == 5 else {
            fatalError("Usage: harness selftest | <hide|quit|check|show> <store-path> <comma-separated-pids|->")
        }
        let storeURL = URL(fileURLWithPath: arguments[2])
        let pids: Set<pid_t>
        if arguments[3] == "-" {
            pids = []
        } else {
            let parsed = arguments[3].split(separator: ",").compactMap { pid_t($0) }
            guard parsed.count == arguments[3].split(separator: ",").count else {
                fatalError("Invalid PID list")
            }
            pids = Set(parsed)
        }

        // Every invocation is a new process, just as a watcher relaunch is.
        var intent = PetVisibilityIntent(storeURL: storeURL)
        switch arguments[1] {
        case "hide", "quit":
            try intent.hide(codexPIDs: pids)
            print("HIDDEN")
        case "check":
            let dates: [pid_t: Date]
            if arguments.count == 5, let timestamp = Double(arguments[4]) {
                dates = Dictionary(uniqueKeysWithValues: pids.map { ($0, Date(timeIntervalSince1970: timestamp)) })
            } else { dates = [:] }
            print(try intent.shouldShowOnReopen(codexPIDs: pids, launchDates: dates) ? "SHOW" : "HIDDEN")
        case "show":
            try intent.showExplicitly()
            print("SHOW")
        default:
            fatalError("Unknown action")
        }
    }

    private static func testDesktopPIDFallback() throws {
        let listing = """
          101 /Applications/ChatGPT.app/Contents/MacOS/ChatGPT
          102 /Applications/Codex.app/Contents/MacOS/Codex
          103 /Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Helpers/Codex (Service)
          104 /Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex
          105 /Applications/ChatGPT.app/Contents/MacOS/ChatGPT-helper
          invalid /Applications/ChatGPT.app/Contents/MacOS/ChatGPT
          0 /Applications/ChatGPT.app/Contents/MacOS/ChatGPT
        """
        guard CodexDesktopProcessLookup.pids(in: listing) == [101, 102] else {
            fatalError("Fallback must match only valid main desktop processes")
        }
        let times = CodexDesktopProcessLookup.launchDates(in: "101 Thu Oct  1 16:33:32 2026\n102 invalid", pids: [101, 102])
        guard times.count == 1, times[101] != nil else { fatalError("Launch dates must parse strictly") }
        let recovered = CodexDesktopProcessLookup.resolve(appKitPIDs: [], processListing: { listing })
        guard recovered == [101, 102],
              CodexDesktopProcessLookup.resolve(appKitPIDs: [], processListing: { nil }).isEmpty,
              CodexDesktopProcessLookup.resolve(appKitPIDs: [201], processListing: {
                  fatalError("Known AppKit PID must not launch a process-list query")
              }) == [201] else {
            fatalError("Fallback selection is incorrect")
        }
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("fallback-visibility-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: store) }
        var intent = PetVisibilityIntent(storeURL: store)
        try intent.hide(codexPIDs: recovered)
        var restarted = PetVisibilityIntent(storeURL: store)
        guard try !restarted.shouldShowOnReopen(codexPIDs: recovered),
              try restarted.shouldShowOnReopen(codexPIDs: [202]) else {
            fatalError("Recovered PID must preserve Hide and restore Show on a new desktop PID")
        }
        // Another process's newer Hide must survive a stale auto-show decision.
        try intent.hide(codexPIDs: [101])
        restarted = PetVisibilityIntent(storeURL: store)
        try intent.hide(codexPIDs: [202])
        guard try !restarted.shouldShowOnReopen(codexPIDs: [202]),
              FileManager.default.fileExists(atPath: store.path) else {
            fatalError("Concurrent newer Hide must survive")
        }
    }

    private static func testJSONRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pet-visibility-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("Support/visibility.json")
        var first = PetVisibilityIntent(storeURL: store)
        guard try first.shouldShowOnReopen(codexPIDs: [101]) else {
            fatalError("Missing state should show")
        }
        try first.hide(codexPIDs: [101])
        let data = try Data(contentsOf: store)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let savedPIDs = json?["suppressedCodexPIDs"] as? [Int],
              savedPIDs == [101] else {
            fatalError("Unexpected visibility JSON")
        }

        var restarted = PetVisibilityIntent(storeURL: store)
        guard try !restarted.shouldShowOnReopen(codexPIDs: [101]),
              try !restarted.shouldShowOnReopen(codexPIDs: []) else {
            fatalError("Same Codex process should stay hidden")
        }
        guard try restarted.shouldShowOnReopen(codexPIDs: [202]),
              !FileManager.default.fileExists(atPath: store.path) else {
            fatalError("New Codex process should clear the file")
        }

        try restarted.hide(codexPIDs: [])
        var noPID = PetVisibilityIntent(storeURL: store)
        guard try !noPID.shouldShowOnReopen(codexPIDs: [303]) else {
            fatalError("Empty PID state should remain hidden")
        }
        try noPID.showExplicitly()
        guard !FileManager.default.fileExists(atPath: store.path) else {
            fatalError("Explicit Show should remove the file")
        }
    }
}
