import AppKit
import CryptoKit
import Foundation

/// Plays verified Minecraft sound assets from the user's local cache. The
/// official recordings are fetched at runtime and are never part of the app
/// bundle or the shareable plugin archive.
@MainActor
final class QuotaSoundPlayer: NSObject, NSSoundDelegate {
    private enum Cue {
        case damage
        case xp
    }

    private struct Asset {
        let fileName: String
        let hash: String

        var url: URL {
            URL(string: "https://resources.download.minecraft.net/\(hash.prefix(2))/\(hash)")!
        }
    }

    private static let damageAsset = Asset(
        fileName: "minecraft-hit1.ogg",
        hash: "c43077ac1f9ceda7e9e1c152f839baf207833aa8"
    )
    private static let xpAsset = Asset(
        fileName: "minecraft-experience-orb.ogg",
        hash: "8a04a60d5c28fc60df472a877ca57f37eabc78d7"
    )
    private var damageSound: NSSound?
    private var xpSound: NSSound?
    private var activeSound: NSSound?
    private var pendingCues: [Cue] = []
    private var didAttemptPreparation = false
    private var isPreparing = false

    /// Start the download/cache check without blocking the pet window.
    /// Failed downloads are tried again by the next app launch or when the
    /// user explicitly presses the matching sound test button.
    func prepare() {
        prepare(retrying: nil)
    }

    private func prepare(retrying cue: Cue?) {
        guard !isPreparing else { return }
        let firstAttempt = !didAttemptPreparation
        if !firstAttempt {
            guard let cue,
                  (cue == .damage ? damageSound : xpSound) == nil else { return }
        }

        let needsDamage = damageSound == nil && (firstAttempt || cue == .damage)
        let needsXP = xpSound == nil && (firstAttempt || cue == .xp)
        didAttemptPreparation = true
        isPreparing = true
        Task { [weak self] in
            guard let self else { return }
            // Keep file I/O and network waiting off the main actor. Each cue
            // is independent: one missing asset does not suppress the other.
            async let damageURL = Self.prepareIfNeeded(needsDamage, asset: Self.damageAsset)
            async let xpURL = Self.prepareIfNeeded(needsXP, asset: Self.xpAsset)
            let (damage, xp) = await (damageURL, xpURL)
            if let damage { self.damageSound = self.makeSound(at: damage) }
            if let xp { self.xpSound = self.makeSound(at: xp) }
            self.isPreparing = false
            self.playNext()
        }
    }

    /// Queues one short hit for each whole percentage point spent.
    func playDamage(count: Int) {
        guard count > 0 else { return }
        prepare()
        pendingCues.append(contentsOf: repeatElement(.damage, count: min(count, 100)))
        playNext()
    }

    func playXP() {
        prepare()
        pendingCues.append(.xp)
        playNext()
    }

    /// The explicit test buttons may retry a failed first-launch download.
    /// Clicks during an existing preparation stay queued until it completes.
    func testDamage() {
        prepare(retrying: .damage)
        pendingCues.append(.damage)
        playNext()
    }

    func testXP() {
        prepare(retrying: .xp)
        pendingCues.append(.xp)
        playNext()
    }

    private func makeSound(at url: URL) -> NSSound? {
        guard let sound = NSSound(contentsOf: url, byReference: false) else { return nil }
        sound.delegate = self
        return sound
    }

    private func playNext() {
        guard activeSound == nil else { return }
        while !pendingCues.isEmpty {
            let cue = pendingCues[0]
            guard let sound = cue == .damage ? damageSound : xpSound else {
                // Preserve new events while assets are still downloading,
                // then discard unavailable cues rather than replaying stale
                // quota changes hours later.
                if isPreparing { return }
                pendingCues.removeFirst()
                continue
            }
            pendingCues.removeFirst()
            activeSound = sound
            if sound.play() { return }
            activeSound = nil
        }
    }

    func sound(_ sound: NSSound, didFinishPlaying finishedPlaying: Bool) {
        guard activeSound === sound else { return }
        activeSound = nil
        playNext()
    }

    /// NSSound can open these OGG files but cannot play them on some macOS
    /// versions. Convert each verified original to a WAV in the user's cache.
    /// Both the filename and the WAV integrity record refer to the original
    /// Mojang content hash, so an unrelated recording cannot be reused.
    nonisolated private static func prepareIfNeeded(_ needed: Bool, asset: Asset) async -> URL? {
        guard needed else { return nil }
        return await preparedPlayableURL(for: asset)
    }

    nonisolated private static func preparedPlayableURL(for asset: Asset) async -> URL? {
        guard let original = await verifiedLocalURL(for: asset) else { return nil }
        let wav = original.deletingLastPathComponent()
            .appendingPathComponent("\(asset.hash).wav")
        let checksum = wav.appendingPathExtension("sha256")
        if let bytes = try? Data(contentsOf: wav),
           let recorded = try? String(contentsOf: checksum, encoding: .utf8),
           isValidWAV(bytes), sha256(bytes) == recorded.trimmingCharacters(in: .whitespacesAndNewlines) {
            return wav
        }

        let temporary = wav.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard await convertToWAV(original: original, destination: temporary),
              let converted = try? Data(contentsOf: temporary),
              isValidWAV(converted) else { return nil }
        do {
            try converted.write(to: wav, options: .atomic)
            try sha256(converted).write(to: checksum, atomically: true, encoding: .utf8)
            guard let saved = try? Data(contentsOf: wav),
                  isValidWAV(saved), sha256(saved) == sha256(converted) else { return nil }
            return wav
        } catch {
            return nil
        }
    }

    nonisolated private static func convertToWAV(original: URL, destination: URL) async -> Bool {
        let converter = Process()
        converter.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        converter.arguments = ["-f", "WAVE", "-d", "LEI16", original.path, destination.path]
        converter.standardOutput = FileHandle.nullDevice
        converter.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            let timeout = DispatchWorkItem {
                if converter.isRunning { converter.terminate() }
            }
            converter.terminationHandler = { process in
                timeout.cancel()
                continuation.resume(returning: process.terminationStatus == 0)
            }
            do {
                try converter.run()
                DispatchQueue.global(qos: .utility)
                    .asyncAfter(deadline: .now() + 20, execute: timeout)
            } catch {
                timeout.cancel()
                continuation.resume(returning: false)
            }
        }
    }

    nonisolated private static func isValidWAV(_ data: Data) -> Bool {
        guard (44...8_000_000).contains(data.count) else { return false }
        return data.prefix(4).elementsEqual("RIFF".utf8)
            && data.dropFirst(8).prefix(4).elementsEqual("WAVE".utf8)
    }

    nonisolated private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Read cache bytes only after checking their content-addressed SHA-1.
    /// Cache corruption is replaced by a fresh verified download atomically.
    nonisolated private static func verifiedLocalURL(for asset: Asset) async -> URL? {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexQuotaPet/Sounds",
                               isDirectory: true)
        let destination = directory.appendingPathComponent(asset.fileName)
        if let cached = try? Data(contentsOf: destination),
           sha1(cached) == asset.hash {
            return destination
        }

        var request = URLRequest(url: asset.url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              data.count <= 1_000_000,
              sha1(data) == asset.hash else { return nil }

        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: destination, options: .atomic)
            // A successful atomic write should match, but verify the path
            // actually handed to NSSound as well.
            guard let saved = try? Data(contentsOf: destination),
                  sha1(saved) == asset.hash else { return nil }
            return destination
        } catch {
            return nil
        }
    }

    nonisolated private static func sha1(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
