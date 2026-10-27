import Darwin
import Foundation

struct SQLFolderScanLimits: Sendable {
    var treeEntries = 2_000
    var searchEntries = 25_000
    var searchFiles = 5_000
    var fileBytes = 2 * 1_024 * 1_024
    var totalContentBytes = 64 * 1_024 * 1_024
    var results = 200
    var matchesPerFile = 5
    var directoryDepth = 64

    static let `default` = Self()

    var isValid: Bool {
        treeEntries > 0 && searchEntries > 0 && searchFiles > 0 && fileBytes > 0 &&
            totalContentBytes > 0 && results > 0 && matchesPerFile > 0 && directoryDepth > 0
    }
}

enum SQLFolderSearchMode: String, CaseIterable, Identifiable, Sendable {
    case name, contents, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: "File names"
        case .contents: "Contents"
        case .all: "Names and contents"
        }
    }
}

struct SQLFolderSearchMatch: Identifiable, Equatable, Sendable {
    let attachmentID: UUID
    let url: URL
    let relativePath: String
    let lineNumber: Int?
    let preview: String?
    var id: String { attachmentID.uuidString + "\0" + url.path + "\0" + String(lineNumber ?? 0) }
}

struct SQLFolderSearchBatch: Sendable {
    var matches: [SQLFolderSearchMatch] = []
    var isTruncated = false
    var skippedFiles = 0
    var unavailableFolders = 0
    var inspectedEntries = 0
    var inspectedFiles = 0
    var contentBytes = 0

    var notice: String? {
        var messages: [String] = []
        if isTruncated { messages.append("Search reached its work or result limit. Narrow the search or attach a smaller folder.") }
        if skippedFiles > 0 { messages.append("\(skippedFiles) files could not be searched as bounded UTF-8 text.") }
        if unavailableFolders > 0 { messages.append("\(unavailableFolders) folders were unavailable or changed during the search.") }
        return messages.isEmpty ? nil : messages.joined(separator: " ")
    }
}

enum SQLFolderError: LocalizedError {
    case invalidFolder, unavailable, changed, tooManyFolders

    var errorDescription: String? {
        switch self {
        case .invalidFolder: "Choose an existing local folder. Symbolic links are not attached."
        case .unavailable: "This SQL folder is missing or unreadable. Restore it, refresh, or remove the attachment."
        case .changed: "This folder changed while it was being read. Refresh to load its current contents."
        case .tooManyFolders: "Up to 32 SQL folders can be attached. Remove an attachment before adding another."
        }
    }
}

struct SQLFolderDirectoryEntry: Equatable, Sendable {
    let name: String
    let isDirectory: Bool
}

struct SQLFolderListing: Sendable {
    var entries: [SQLFolderDirectoryEntry]
    var isTruncated: Bool
    var inspectedEntries: Int
}

/// Every directory component is opened without following symbolic links. A
/// checkout or rename cannot redirect a recursive search outside its root.
enum SQLFolderScanner {
    private static let excludedDirectories: Set<String> = [
        ".git", ".hg", ".svn", "build", ".build", "target", "node_modules", "dist", "deriveddata", ".swiftpm", ".cache",
    ]

    static func isLocalFolderURL(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost") &&
            url.user == nil && url.password == nil && url.port == nil && url.query == nil && url.fragment == nil &&
            url.path.hasPrefix("/") && !url.path.contains("\0") && url.path != "/" &&
            url.standardizedFileURL.path == url.path
    }

    static func canonicalDirectory(_ proposed: URL) throws -> URL {
        guard isLocalFolderURL(proposed.standardizedFileURL) else { throw SQLFolderError.invalidFolder }
        var metadata = stat()
        guard lstat(proposed.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else {
            throw SQLFolderError.invalidFolder
        }
        let canonical = proposed.standardizedFileURL.resolvingSymlinksInPath()
        let descriptor = try openDirectory(canonical, relative: [])
        defer { close(descriptor) }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if fcntl(descriptor, F_GETPATH, &path) == 0 {
            return URL(fileURLWithPath: String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        return canonical
    }

    static func validateRoot(_ root: URL) throws {
        let descriptor = try openDirectory(root, relative: [])
        close(descriptor)
    }

    static func children(attachment: SQLFolderAttachment, directory: URL,
                         limit: Int = SQLFolderScanLimits.default.treeEntries) throws -> SQLFolderListing {
        guard let relative = relativeComponents(directory, under: attachment.url), limit > 0 else {
            throw SQLFolderError.invalidFolder
        }
        return try listing(root: attachment.url, relative: relative, limit: limit)
    }

    static func search(attachments: [SQLFolderAttachment], query: String, mode: SQLFolderSearchMode,
                       limits: SQLFolderScanLimits = .default) throws -> SQLFolderSearchBatch {
        try Task.checkCancellation()
        guard limits.isValid, !query.isEmpty else { return SQLFolderSearchBatch() }
        var batch = SQLFolderSearchBatch()
        var seenFiles: Set<String> = []
        for attachment in attachments {
            var pending: [[String]] = [[]]
            while let directory = pending.popLast() {
                try Task.checkCancellation()
                let remaining = limits.searchEntries - batch.inspectedEntries
                guard remaining > 0 else { batch.isTruncated = true; return batch }
                let contents: SQLFolderListing
                do { contents = try listing(root: attachment.url, relative: directory, limit: remaining) }
                catch is CancellationError { throw CancellationError() }
                catch { batch.unavailableFolders += 1; continue }
                batch.inspectedEntries += contents.inspectedEntries
                if contents.isTruncated { batch.isTruncated = true }
                var subdirectories: [[String]] = []
                for entry in contents.entries {
                    try Task.checkCancellation()
                    let components = directory + [entry.name]
                    if entry.isDirectory {
                        if components.count > limits.directoryDepth { batch.isTruncated = true }
                        else { subdirectories.append(components) }
                        continue
                    }
                    let relativePath = components.joined(separator: "/")
                    let url = components.reduce(attachment.url) { $0.appendingPathComponent($1) }
                    guard seenFiles.insert(url.path).inserted else { continue }
                    guard batch.inspectedFiles < limits.searchFiles else { batch.isTruncated = true; return batch }
                    batch.inspectedFiles += 1
                    let nameMatches = relativePath.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                        locale: Locale(identifier: "en_US_POSIX")) != nil
                    if mode != .contents, nameMatches {
                        batch.matches.append(SQLFolderSearchMatch(attachmentID: attachment.id, url: url,
                            relativePath: relativePath, lineNumber: nil, preview: nil))
                    } else if mode != .name {
                        let remainingBytes = limits.totalContentBytes - batch.contentBytes
                        guard remainingBytes > 0 else { batch.isTruncated = true; return batch }
                        do {
                            let data = try read(root: attachment.url, relative: directory, name: entry.name,
                                limit: min(limits.fileBytes, remainingBytes))
                            batch.contentBytes += data.count
                            guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
                                batch.skippedFiles += 1
                                continue
                            }
                            let found = try contentMatches(text, query: query, attachment: attachment, url: url,
                                relativePath: relativePath, limit: min(limits.matchesPerFile, limits.results - batch.matches.count))
                            batch.matches += found.matches
                            batch.isTruncated = batch.isTruncated || found.isTruncated
                        } catch is CancellationError { throw CancellationError() }
                        catch { batch.skippedFiles += 1 }
                    }
                    if batch.matches.count >= limits.results { batch.isTruncated = true; return batch }
                }
                pending.append(contentsOf: subdirectories.reversed())
                if contents.isTruncated { return batch }
            }
        }
        try Task.checkCancellation()
        return batch
    }

    private static func contentMatches(_ text: String, query: String, attachment: SQLFolderAttachment,
                                       url: URL, relativePath: String, limit: Int) throws -> (matches: [SQLFolderSearchMatch], isTruncated: Bool) {
        guard limit > 0 else { return ([], true) }
        let source = text as NSString
        var results: [SQLFolderSearchMatch] = []
        var cursor = text.startIndex
        var seenLines: Set<Int> = []
        while cursor < text.endIndex,
              let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                  range: cursor..<text.endIndex, locale: Locale(identifier: "en_US_POSIX")) {
            try Task.checkCancellation()
            guard !range.isEmpty else { return (results, true) }
            let location = NSRange(range, in: text)
            let lineRange = source.lineRange(for: location)
            let prefix = source.substring(to: lineRange.location)
            var lineNumber = 1
            var priorWasCR = false
            for scalar in prefix.unicodeScalars {
                if scalar == "\r" { lineNumber += 1; priorWasCR = true }
                else if scalar == "\n" { if !priorWasCR { lineNumber += 1 }; priorWasCR = false }
                else if CharacterSet.newlines.contains(scalar) { lineNumber += 1; priorWasCR = false }
                else { priorWasCR = false }
            }
            if seenLines.insert(lineNumber).inserted {
                guard results.count < limit else { return (results, true) }
                let line = source.substring(with: lineRange).trimmingCharacters(in: .newlines)
                let preview = String(line.prefix(240)) + (line.count > 240 ? "…" : "")
                results.append(SQLFolderSearchMatch(attachmentID: attachment.id, url: url, relativePath: relativePath,
                    lineNumber: lineNumber, preview: preview))
            }
            cursor = range.upperBound > cursor ? range.upperBound : text.index(after: cursor)
        }
        return (results, false)
    }

    private static func listing(root: URL, relative: [String], limit: Int) throws -> SQLFolderListing {
        let descriptor = try openDirectory(root, relative: relative)
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw SQLFolderError.unavailable }
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { throw SQLFolderError.unavailable }
        guard let directory = fdopendir(duplicate) else { close(duplicate); throw SQLFolderError.unavailable }
        defer { closedir(directory) }
        var entries: [SQLFolderDirectoryEntry] = []
        var count = 0
        var truncated = false
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let record = readdir(directory) else {
                guard errno == 0 else { throw SQLFolderError.unavailable }
                break
            }
            let name = withUnsafePointer(to: &record.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name == "." || name == ".." { continue }
            if count >= limit { truncated = true; break }
            count += 1
            var metadata = stat()
            guard fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let kind = metadata.st_mode & S_IFMT
            if kind == S_IFDIR, !excludedDirectories.contains(name.lowercased()) {
                entries.append(SQLFolderDirectoryEntry(name: name, isDirectory: true))
            } else if kind == S_IFREG, (name as NSString).pathExtension.lowercased() == "sql" {
                entries.append(SQLFolderDirectoryEntry(name: name, isDirectory: false))
            }
        }
        var after = stat()
        let currentDescriptor = try openDirectory(root, relative: relative)
        defer { close(currentDescriptor) }
        var current = stat()
        guard fstat(descriptor, &after) == 0, fstat(currentDescriptor, &current) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              after.st_dev == current.st_dev, after.st_ino == current.st_ino,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw SQLFolderError.changed }
        entries.sort {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            if $0.name.lowercased() != $1.name.lowercased() { return $0.name.lowercased() < $1.name.lowercased() }
            return $0.name < $1.name
        }
        return SQLFolderListing(entries: entries, isTruncated: truncated, inspectedEntries: count)
    }

    private static func read(root: URL, relative: [String], name: String, limit: Int) throws -> Data {
        let directory = try openDirectory(root, relative: relative)
        defer { close(directory) }
        let descriptor = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw SQLFolderError.unavailable }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, before.st_size <= limit else { throw SQLFolderError.unavailable }
        var data = Data()
        while true {
            try Task.checkCancellation()
            let chunk = try file.read(upToCount: min(64 * 1_024, limit - data.count + 1)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
            guard data.count <= limit else { throw SQLFolderError.unavailable }
        }
        var after = stat()
        var current = stat()
        guard fstat(descriptor, &after) == 0, fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              after.st_dev == current.st_dev, after.st_ino == current.st_ino,
              before.st_size == after.st_size, after.st_size == data.count,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw SQLFolderError.changed }
        return data
    }

    private static func openDirectory(_ root: URL, relative: [String]) throws -> Int32 {
        guard isLocalFolderURL(root), relative.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") }) else {
            throw SQLFolderError.invalidFolder
        }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw SQLFolderError.unavailable }
        for component in root.path.split(separator: "/").map(String.init) + relative {
            do { try Task.checkCancellation() }
            catch { close(descriptor); throw error }
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            close(descriptor)
            guard next >= 0 else { throw SQLFolderError.unavailable }
            descriptor = next
        }
        return descriptor
    }

    private static func relativeComponents(_ directory: URL, under root: URL) -> [String]? {
        guard isLocalFolderURL(directory), isLocalFolderURL(root) else { return nil }
        if directory.path == root.path { return [] }
        guard directory.path.hasPrefix(root.path + "/") else { return nil }
        return String(directory.path.dropFirst(root.path.count + 1)).split(separator: "/").map(String.init)
    }
}
