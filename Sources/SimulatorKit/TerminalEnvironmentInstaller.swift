import Darwin
import Foundation

public struct TerminalEnvironmentInstallation: Sendable {
    public let environmentFile: URL
    public let profileURLs: [URL]
    public let backupURLs: [URL]
    public let changed: Bool
}

public enum TerminalEnvironmentError: LocalizedError, Equatable {
    case invalidPath(String)
    case unsafeFile(String)
    case unrelatedFile(String)
    case malformedBlock(String)
    case changedDuringInstall(String)
    case installationInProgress
    case rollbackIncomplete

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let path): return "DroidDock cannot configure this terminal path: \(path)"
        case .unsafeFile(let path): return "Terminal setup preserved an unsupported, unreadable, or read-only file at \(path)."
        case .unrelatedFile(let path): return "Terminal setup found an existing file owned by another setup at \(path) and preserved it."
        case .malformedBlock(let path): return "The DroidDock section in \(path) is incomplete or duplicated. Correct that section before trying again."
        case .changedDuringInstall(let path): return "\(path) changed during terminal setup. Its new contents were preserved; try again."
        case .installationInProgress: return "Another DroidDock terminal setup is already running."
        case .rollbackIncomplete: return "Terminal setup could not finish. Some files changed concurrently and were preserved. Original shell profiles are backed up in DroidDock’s Terminal/Backups folder."
        }
    }
}

/// Configures user-owned shell startup files. The application decides when its
/// installation location permits automatic setup; this service has no UI policy.
public struct TerminalEnvironmentInstaller: Sendable {
    static let environmentMarker = "# DroidDock managed terminal environment — generated file.\n"
    static let blockStart = "# >>> DroidDock terminal environment >>>"
    static let blockEnd = "# <<< DroidDock terminal environment <<<"
    private static let maximumBytes = 1_048_576

    private let homeDirectory: URL
    private let environment: [String: String]
    private let beforeWrite: @Sendable (URL) throws -> Void
    public var environmentFile: URL {
        homeDirectory.appendingPathComponent("Library/Application Support/DroidDock/Terminal/environment.sh")
    }

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(homeDirectory: homeDirectory, environment: environment, beforeWrite: { _ in })
    }

    init(homeDirectory: URL, environment: [String: String], beforeWrite: @escaping @Sendable (URL) throws -> Void) {
        self.homeDirectory = homeDirectory.standardizedFileURL.resolvingSymlinksInPath()
        self.environment = environment
        self.beforeWrite = beforeWrite
    }

    public func install(appBundle: URL, sdk: SDKInstallation?) throws -> TerminalEnvironmentInstallation {
        let executable = appBundle.appendingPathComponent("Contents/MacOS/droiddock").standardizedFileURL
        try Self.validatePath(homeDirectory)
        try Self.validatePath(executable)
        var executableInfo = stat()
        guard lstat(executable.path, &executableInfo) == 0, executableInfo.st_mode & S_IFMT == S_IFREG,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw TerminalEnvironmentError.unsafeFile(executable.path)
        }
        let terminal = homeDirectory.appendingPathComponent("Library/Application Support/DroidDock/Terminal", isDirectory: true)
        let environmentFile = self.environmentFile
        let bin = homeDirectory.appendingPathComponent(".local/bin", isDirectory: true)
        let link = bin.appendingPathComponent("droiddock")
        let zshDirectory: URL
        if let directory = environment["ZDOTDIR"], directory.hasPrefix("/") {
            zshDirectory = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        } else { zshDirectory = homeDirectory }
        let loginNames = [".bash_profile", ".bash_login", ".profile"]
        let login = loginNames.map { homeDirectory.appendingPathComponent($0) }
            .first(where: { Self.exists($0) }) ?? homeDirectory.appendingPathComponent(".bash_profile")
        let profiles = [zshDirectory.appendingPathComponent(".zshrc"), login, homeDirectory.appendingPathComponent(".bashrc")]
        let directories = [terminal, bin, zshDirectory]
        for directory in directories { try Self.validateDirectoryChain(directory) }
        try Self.validateLink(link, target: executable)
        let previousEnvironment = try Self.snapshot(environmentFile)
        if let previousEnvironment, !previousEnvironment.bytes.starts(with: Data(Self.environmentMarker.utf8)) {
            throw TerminalEnvironmentError.unrelatedFile(environmentFile.path)
        }
        var edits = [Edit(url: environmentFile, original: previousEnvironment,
                          bytes: try Self.environmentScript(bin: bin, executable: executable, sdk: sdk), isProfile: false)]
        for profile in profiles {
            try Self.validatePath(profile)
            try Self.validateDirectoryChain(profile.deletingLastPathComponent())
            let original = try Self.snapshot(profile)
            let bytes = try Self.profileContents(original?.bytes ?? Data(), environmentFile: environmentFile, profile: profile)
            edits.append(Edit(url: profile, original: original, bytes: bytes, isProfile: true))
        }
        edits.removeAll { $0.original?.bytes == $0.bytes }
        for edit in edits {
            if let original = edit.original, original.permissions & 0o222 == 0 {
                throw TerminalEnvironmentError.unsafeFile(edit.url.path)
            }
        }
        let backups = terminal.appendingPathComponent("Backups", isDirectory: true)
        if edits.contains(where: { $0.isProfile && $0.original != nil }) { try Self.validateDirectoryChain(backups) }
        let needsLink = !Self.exists(link)
        if edits.isEmpty && !needsLink {
            return .init(environmentFile: environmentFile, profileURLs: profiles, backupURLs: [], changed: false)
        }

        // All conflicts have been checked before creating directories or files.
        var createdDirectories: [URL] = []
        var committed: [(Edit, Snapshot)] = []
        var backupURLs: [URL] = []
        var linkCreated = false
        var installLock: InstallLock?
        defer { installLock?.release() }
        do {
            for directory in directories { try Self.createDirectories(directory, recording: &createdDirectories) }
            installLock = try InstallLock(directory: terminal)
            try Self.validateLink(link, target: executable)
            for edit in edits { try Self.requireUnchanged(edit.url, expected: edit.original) }
            for edit in edits {
                if edit.isProfile, let original = edit.original {
                    try Self.createDirectories(backups, recording: &createdDirectories)
                    let backup = backups.appendingPathComponent(edit.url.lastPathComponent + "." + UUID().uuidString + ".bak")
                    try Self.write(original.bytes, to: backup, permissions: original.permissions, replacing: nil)
                    backupURLs.append(backup)
                }
                try beforeWrite(edit.url)
                try Self.write(edit.bytes, to: edit.url, permissions: edit.original?.permissions ?? 0o600, replacing: edit.original)
                guard let written = try Self.snapshot(edit.url) else { throw TerminalEnvironmentError.changedDuringInstall(edit.url.path) }
                committed.append((edit, written))
            }
            if needsLink {
                guard symlink(executable.path, link.path) == 0 else {
                    throw TerminalEnvironmentError.changedDuringInstall(link.path)
                }
                linkCreated = true
            }
            return .init(environmentFile: environmentFile, profileURLs: profiles, backupURLs: backupURLs,
                         changed: !edits.isEmpty || linkCreated)
        } catch {
            var rollbackFailed = false
            // The command link is created last, after every throwing write.
            for (edit, installed) in committed.reversed() {
                do {
                    try Self.requireUnchanged(edit.url, expected: installed)
                    if let original = edit.original {
                        try Self.write(original.bytes, to: edit.url, permissions: original.permissions, replacing: installed)
                    } else if unlink(edit.url.path) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                } catch { rollbackFailed = true }
            }
            // rmdir removes only empty directories; concurrent files are safe.
            for directory in createdDirectories.reversed() { _ = rmdir(directory.path) }
            if rollbackFailed { throw TerminalEnvironmentError.rollbackIncomplete }
            throw error
        }
    }

    private static func environmentScript(bin: URL, executable: URL, sdk: SDKInstallation?) throws -> Data {
        func prepend(_ directory: URL) throws -> String {
            try validatePath(directory)
            guard !directory.path.contains(":") else { throw TerminalEnvironmentError.invalidPath(directory.path) }
            return "__droiddock_prepend_path \(quote(directory.path))\n"
        }
        var script = environmentMarker + "# Applies to new Terminal sessions.\n"
        // Clear only values still equal to those exported by an earlier run of
        // this script. Inherited user overrides must survive a managed/external
        // SDK switch, while inherited DroidDock-private AVD variables must not.
        let androidKeys = ["ANDROID_HOME", "ANDROID_SDK_ROOT", "ANDROID_AVD_HOME", "ANDROID_USER_HOME",
                           "ANDROID_EMULATOR_HOME", "ANDROID_SDK_HOME"]
        for key in androidKeys {
            let marker = "_DROIDDOCK_OWNED_" + key
            script += "if [ \"${\(marker)+set}\" = set ]; then\n  if [ \"${\(key)-}\" = \"$\(marker)\" ]; then unset \(key); fi\n  unset \(marker)\nfi\n"
        }
        script += #"""
        # Move our chosen directories first; inherited entries elsewhere in PATH
        # must not let an older Android SDK win in a nested Terminal session.
        __droiddock_prepend_path() {
          local remaining="${PATH-}" part result="" kept=0 more
          if [ -n "$remaining" ]; then
            while :; do
              case "$remaining" in
                *:*) part="${remaining%%:*}"; remaining="${remaining#*:}"; more=1 ;;
                *) part="$remaining"; more=0 ;;
              esac
              if [ "$part" != "$1" ]; then
                if [ "$kept" = 1 ]; then result="$result:$part"; else result="$part"; kept=1; fi
              fi
              [ "$more" = 1 ] || break
            done
          fi
          if [ "$kept" = 1 ]; then PATH="$1:$result"; else PATH="$1"; fi
        }

        """#
        script += try prepend(bin)
        if let sdk {
            for url in [sdk.root, sdk.adb, sdk.emulator] { try validatePath(url) }
            script += "if [ -x \(quote(executable.path)) ] && [ -x \(quote(sdk.adb.path)) ] && [ -x \(quote(sdk.emulator.path)) ]; then\n"
            for (key, value) in sdk.environmentOverrides.sorted(by: { $0.key < $1.key }) {
                guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw TerminalEnvironmentError.invalidPath(value)
                }
                script += "  export \(key)=\(quote(value))\n"
                script += "  export _DROIDDOCK_OWNED_\(key)=\(quote(value))\n"
            }
            script += try prepend(sdk.root.appendingPathComponent("emulator"))
            script += try prepend(sdk.root.appendingPathComponent("platform-tools"))
            script += "fi\n"
        }
        script += "unset -f __droiddock_prepend_path\nexport PATH\n"
        return Data(script.utf8)
    }

    private static func profileContents(_ bytes: Data, environmentFile: URL, profile: URL) throws -> Data {
        guard let text = String(data: bytes, encoding: .utf8), !bytes.contains(0) else { throw TerminalEnvironmentError.unsafeFile(profile.path) }
        let lines = linesKeepingEndings(text)
        let starts = lines.indices.filter { lines[$0].body == blockStart }
        let ends = lines.indices.filter { lines[$0].body == blockEnd }
        guard !lines.contains(where: { ($0.body.contains(blockStart) && $0.body != blockStart) || ($0.body.contains(blockEnd) && $0.body != blockEnd) }),
              (starts.isEmpty && ends.isEmpty) || (starts.count == 1 && ends.count == 1 && starts[0] < ends[0]) else {
            throw TerminalEnvironmentError.malformedBlock(profile.path)
        }
        let newline = lines.first(where: { !$0.ending.isEmpty })?.ending ?? "\n"
        let quoted = quote(environmentFile.path)
        let block = [blockStart, "if [ -r \(quoted) ]; then", "  . \(quoted)", "fi", blockEnd].joined(separator: newline) + newline
        let updated: String
        if let start = starts.first, let end = ends.first {
            updated = lines[..<start].map(\.full).joined() + block + lines[(end + 1)...].map(\.full).joined()
        } else {
            updated = text + (text.isEmpty || text.hasSuffix("\n") || text.hasSuffix("\r") ? "" : newline) + block
        }
        guard updated.utf8.count <= maximumBytes else { throw TerminalEnvironmentError.unsafeFile(profile.path) }
        return Data(updated.utf8)
    }

    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private struct Line {
        let body: String
        let ending: String
        var full: String { body + ending }
    }

    private static func linesKeepingEndings(_ text: String) -> [Line] {
        var lines: [Line] = [], body = ""
        for character in text {
            if character == "\n" || character == "\r" || character == "\r\n" {
                lines.append(.init(body: body, ending: String(character))); body = ""
            } else { body.append(character) }
        }
        if !body.isEmpty { lines.append(.init(body: body, ending: "")) }
        return lines
    }

    private struct Edit { let url: URL; let original: Snapshot?; let bytes: Data; let isProfile: Bool }
    private struct Snapshot: Equatable {
        let bytes: Data
        let device: UInt64
        let inode: UInt64
        let permissions: mode_t
    }

    private static func snapshot(_ url: URL) throws -> Snapshot? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw TerminalEnvironmentError.unsafeFile(url.path)
        }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, before.st_size <= maximumBytes else { throw TerminalEnvironmentError.unsafeFile(url.path) }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 && errno == EINTR { continue }
            guard count > 0, bytes.count + count <= maximumBytes else { throw TerminalEnvironmentError.unsafeFile(url.path) }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, before.st_size == after.st_size, bytes.count == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw TerminalEnvironmentError.changedDuringInstall(url.path) }
        return .init(bytes: bytes, device: UInt64(after.st_dev), inode: UInt64(after.st_ino), permissions: after.st_mode & 0o7777)
    }

    private static func requireUnchanged(_ url: URL, expected: Snapshot?) throws {
        guard try snapshot(url) == expected else { throw TerminalEnvironmentError.changedDuringInstall(url.path) }
    }

    private static func write(_ bytes: Data, to url: URL, permissions: mode_t, replacing original: Snapshot?) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".droiddock-terminal-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor); _ = unlink(temporary.path) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
        guard fchmod(descriptor, permissions) == 0, fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try requireUnchanged(url, expected: original)
        let flags = original == nil ? UInt32(RENAME_EXCL) : 0
        guard renamex_np(temporary.path, url.path, flags) == 0 else { throw TerminalEnvironmentError.changedDuringInstall(url.path) }
    }

    private static func validateLink(_ url: URL, target: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw TerminalEnvironmentError.unsafeFile(url.path)
        }
        guard info.st_mode & S_IFMT == S_IFLNK,
              let link = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else {
            throw TerminalEnvironmentError.unrelatedFile(url.path)
        }
        let resolved = link.hasPrefix("/") ? URL(fileURLWithPath: link) : url.deletingLastPathComponent().appendingPathComponent(link)
        guard resolved.standardizedFileURL == target.standardizedFileURL else { throw TerminalEnvironmentError.unrelatedFile(url.path) }
    }

    private static func validatePath(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw TerminalEnvironmentError.invalidPath(url.path)
        }
    }

    private static func exists(_ url: URL) -> Bool {
        var info = stat(); return lstat(url.path, &info) == 0
    }

    private static func validateDirectoryChain(_ url: URL) throws {
        try validatePath(url)
        var directory = url
        while directory.path != "/" {
            var info = stat()
            if lstat(directory.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR || isVerifiedSystemAlias(directory, mode: info.st_mode) else {
                    throw TerminalEnvironmentError.unsafeFile(directory.path)
                }
            } else if errno != ENOENT { throw TerminalEnvironmentError.unsafeFile(directory.path) }
            directory.deleteLastPathComponent()
        }
    }

    private static func isVerifiedSystemAlias(_ directory: URL, mode: mode_t) -> Bool {
        // Foundation can retain /var and /tmp after resolving symlinks. Permit
        // only macOS's exact system aliases; user-controlled parent links still
        // fail the directory preflight instead of redirecting profile writes.
        let aliases = ["/var": "/private/var", "/tmp": "/private/tmp", "/etc": "/private/etc"]
        guard mode & S_IFMT == S_IFLNK, let target = aliases[directory.path],
              let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: directory.path),
              destination == target || destination == String(target.dropFirst()) else { return false }
        var parentInfo = stat(), targetInfo = stat()
        return lstat("/private", &parentInfo) == 0 && parentInfo.st_mode & S_IFMT == S_IFDIR
            && lstat(target, &targetInfo) == 0 && targetInfo.st_mode & S_IFMT == S_IFDIR
    }

    private static func createDirectories(_ directory: URL, recording created: inout [URL]) throws {
        try validateDirectoryChain(directory)
        if exists(directory) { return }
        try createDirectories(directory.deletingLastPathComponent(), recording: &created)
        guard mkdir(directory.path, 0o700) == 0 else {
            if errno == EEXIST { try validateDirectoryChain(directory); return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        created.append(directory)
    }

    private final class InstallLock {
        private var descriptor: Int32
        init(directory: URL) throws {
            descriptor = open(directory.appendingPathComponent(".droiddock-terminal-install.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
            guard descriptor >= 0 else { throw TerminalEnvironmentError.unsafeFile(directory.path) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                close(descriptor); descriptor = -1; throw TerminalEnvironmentError.unsafeFile(directory.path)
            }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                close(descriptor); descriptor = -1; throw TerminalEnvironmentError.installationInProgress
            }
        }
        func release() { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 } }
        deinit { release() }
    }
}
