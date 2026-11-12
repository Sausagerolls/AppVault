import Foundation
import Darwin

/// Deterministic tar (ustar + pax) archive generator.
///
/// The same files always produce the same byte stream, so an upload can be
/// resumed at any byte offset after a pause or a restart: the stream is
/// rebuilt and reading starts at the offset the server already has.
///
/// Extended attributes are written as `LIBARCHIVE.xattr.*` pax records,
/// which macOS `/usr/bin/tar` (libarchive) restores. Together with exact
/// modes and symlinks this keeps app code signatures valid.
public final class TarPlan {
    public enum Kind: UInt8 {
        case file = 0x30      // '0'
        case symlink = 0x32   // '2'
        case directory = 0x35 // '5'
    }

    public struct Entry {
        public let fsPath: String
        public let name: String
        public let kind: Kind
        public let size: Int64
        public let mode: UInt32
        public let mtime: Int64
        public let linkTarget: String?
        public let xattrs: [(String, Data)]
        public internal(set) var headerLength: Int = 0
        public internal(set) var start: Int64 = 0

        var paddedDataLength: Int64 { kind == .file ? (size + 511) / 512 * 512 : 0 }
        var totalLength: Int64 { Int64(headerLength) + paddedDataLength }
    }

    public private(set) var entries: [Entry] = []
    /// Exact length of the archive in bytes.
    public private(set) var totalSize: Int64 = 0
    /// SHA-256 over all headers. Changes if any file is added, removed or changed size/mtime.
    public private(set) var signature: String = ""
    public var fileCount: Int { entries.count }

    /// Attributes that the system manages and that a normal process cannot set.
    static let skippedXattrs: Set<String> = ["com.apple.provenance", "com.apple.macl", "com.apple.rootless"]

    /// - Parameter roots: each root is added recursively under `archiveName`
    ///   (for example `/Applications/Foo.app` as `Foo.app`, or
    ///   `~/Library/Application Support/Foo` as `Library/Application Support/Foo`).
    public init(roots: [(path: String, archiveName: String)]) throws {
        for root in roots {
            try add(path: root.path, name: root.archiveName)
        }
        var offset: Int64 = 0
        let sig = SHA256Stream()
        for i in entries.indices {
            let header = TarPlan.header(for: entries[i])
            entries[i].headerLength = header.count
            entries[i].start = offset
            offset += entries[i].totalLength
            sig.update(header)
        }
        totalSize = offset + 1024 // two zero blocks end the archive
        signature = sig.finalHex()
    }

    private func add(path: String, name: String) throws {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            throw TarError.io("Cannot read \(path): \(String(cString: strerror(errno)))")
        }
        let mode = UInt32(st.st_mode) & 0o7777
        let mtime = max(0, Int64(st.st_mtimespec.tv_sec))
        let xattrs = TarPlan.readXattrs(path)
        switch st.st_mode & S_IFMT {
        case S_IFDIR:
            entries.append(Entry(fsPath: path, name: name + "/", kind: .directory, size: 0, mode: mode,
                                 mtime: mtime, linkTarget: nil, xattrs: xattrs))
            let children = try FileManager.default.contentsOfDirectory(atPath: path)
                .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            for child in children {
                try add(path: path + "/" + child, name: name + "/" + child)
            }
        case S_IFREG:
            entries.append(Entry(fsPath: path, name: name, kind: .file, size: Int64(st.st_size), mode: mode,
                                 mtime: mtime, linkTarget: nil, xattrs: xattrs))
        case S_IFLNK:
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: path)
            entries.append(Entry(fsPath: path, name: name, kind: .symlink, size: 0, mode: mode,
                                 mtime: mtime, linkTarget: target, xattrs: xattrs))
        default:
            break // sockets, fifos, devices: never part of an app
        }
    }

    static func readXattrs(_ path: String) -> [(String, Data)] {
        let listSize = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard listSize > 0 else { return [] }
        var nameBuf = [CChar](repeating: 0, count: listSize)
        guard listxattr(path, &nameBuf, listSize, XATTR_NOFOLLOW) == listSize else { return [] }
        var names: [String] = []
        var startIdx = 0
        for i in 0..<listSize where nameBuf[i] == 0 {
            let bytes = nameBuf[startIdx..<i].map { UInt8(bitPattern: $0) }
            names.append(String(decoding: bytes, as: UTF8.self))
            startIdx = i + 1
        }
        var out: [(String, Data)] = []
        for n in names.sorted() where !skippedXattrs.contains(n) {
            let size = getxattr(path, n, nil, 0, 0, XATTR_NOFOLLOW)
            guard size >= 0 else { continue }
            var buf = [UInt8](repeating: 0, count: size)
            let got = size == 0 ? 0 : getxattr(path, n, &buf, size, 0, XATTR_NOFOLLOW)
            guard got == size else { continue }
            out.append((n, Data(buf)))
        }
        return out
    }

    // MARK: header encoding

    static func header(for e: Entry) -> [UInt8] {
        var pax: [(String, [UInt8])] = []
        let nameBytes = Array(e.name.utf8)
        if nameBytes.count > 100 { pax.append(("path", nameBytes)) }
        if let link = e.linkTarget, link.utf8.count > 100 { pax.append(("linkpath", Array(link.utf8))) }
        if e.size > 0o77777777777 { pax.append(("size", Array(String(e.size).utf8))) }
        for (k, v) in e.xattrs {
            pax.append(("LIBARCHIVE.xattr." + urlEncode(k), Array(v.base64EncodedString().utf8)))
        }

        var out: [UInt8] = []
        if !pax.isEmpty {
            var body: [UInt8] = []
            for (k, v) in pax { body += paxRecord(key: k, value: v) }
            let paxName = "PaxHeader/" + String(decoding: nameBytes.suffix(80), as: UTF8.self)
            out += ustarBlock(name: Array(paxName.utf8.prefix(100)), mode: 0o644, size: Int64(body.count),
                              mtime: e.mtime, type: 0x78 /* 'x' */, link: [])
            out += body
            out += [UInt8](repeating: 0, count: (512 - body.count % 512) % 512)
        }
        let link = e.linkTarget.map { Array($0.utf8) } ?? []
        out += ustarBlock(name: Array(nameBytes.prefix(100)), mode: e.mode,
                          size: e.size > 0o77777777777 ? 0 : e.size,
                          mtime: e.mtime, type: e.kind.rawValue, link: Array(link.prefix(100)))
        return out
    }

    static func paxRecord(key: String, value: [UInt8]) -> [UInt8] {
        let rest = 1 + key.utf8.count + 1 + value.count + 1 // " key=value\n"
        let digits = String(rest).count
        var len = rest + digits
        if String(len).count > digits { len = rest + String(len).count }
        return Array("\(len) \(key)=".utf8) + value + [0x0A]
    }

    static func urlEncode(_ s: String) -> String {
        var out = ""
        for b in s.utf8 {
            if b > 0x20 && b < 0x7F && b != 0x25 /* % */ && b != 0x3D /* = */ {
                out.append(Character(UnicodeScalar(b)))
            } else {
                out += String(format: "%%%02X", b)
            }
        }
        return out
    }

    static func ustarBlock(name: [UInt8], mode: UInt32, size: Int64, mtime: Int64, type: UInt8, link: [UInt8]) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: 512)
        func put(_ bytes: [UInt8], _ at: Int, _ max: Int) {
            for (i, b) in bytes.prefix(max).enumerated() { h[at + i] = b }
        }
        func octal(_ v: Int64, _ at: Int, _ width: Int) {
            put(Array(String(format: "%0\(width - 1)llo", v).utf8), at, width - 1)
        }
        put(name, 0, 100)
        octal(Int64(mode), 100, 8)
        octal(0, 108, 8) // uid
        octal(0, 116, 8) // gid
        octal(size, 124, 12)
        octal(min(mtime, 0o77777777777), 136, 12)
        h[156] = type
        put(link, 157, 100)
        put(Array("ustar".utf8), 257, 6) // "ustar\0"
        put(Array("00".utf8), 263, 2)
        for i in 148..<156 { h[i] = 0x20 }
        let sum = h.reduce(0) { $0 + Int($1) }
        put(Array(String(format: "%06o", sum).utf8), 148, 6)
        h[154] = 0
        h[155] = 0x20
        return h
    }
}

public enum TarError: LocalizedError {
    case io(String)
    case sourceChanged(String)

    public var errorDescription: String? {
        switch self {
        case .io(let m): return m
        case .sourceChanged(let p): return "\(p) changed while it was being sent. Quit the app and try again."
        }
    }
}

/// Sequential reader of a TarPlan, starting at any byte offset.
public final class TarReader {
    private let plan: TarPlan
    public private(set) var position: Int64
    private var index: Int
    private var cachedHeader: (index: Int, bytes: [UInt8])?
    private var handle: (index: Int, fh: FileHandle)?

    public init(plan: TarPlan, offset: Int64 = 0) {
        self.plan = plan
        self.position = min(max(0, offset), plan.totalSize)
        // Binary search for the entry that contains `offset`.
        var lo = 0, hi = plan.entries.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if plan.entries[mid].start + plan.entries[mid].totalLength <= position { lo = mid + 1 } else { hi = mid }
        }
        self.index = lo
    }

    deinit { try? handle?.fh.close() }

    public var isAtEnd: Bool { position >= plan.totalSize }

    /// Returns up to `max` bytes; empty Data at the end of the archive.
    public func read(max: Int) throws -> Data {
        var out = Data()
        out.reserveCapacity(max)
        while out.count < max && position < plan.totalSize {
            let want = max - out.count
            if index >= plan.entries.count {
                let n = Int(min(Int64(want), plan.totalSize - position))
                out.append(Data(count: n))
                position += Int64(n)
                continue
            }
            let e = plan.entries[index]
            let inEntry = position - e.start
            if inEntry < Int64(e.headerLength) {
                if cachedHeader?.index != index { cachedHeader = (index, TarPlan.header(for: e)) }
                let bytes = cachedHeader!.bytes
                let from = Int(inEntry)
                let n = min(want, bytes.count - from)
                out.append(contentsOf: bytes[from..<(from + n)])
                position += Int64(n)
            } else if inEntry < Int64(e.headerLength) + e.size {
                let dataOffset = inEntry - Int64(e.headerLength)
                let n = Int(min(Int64(want), e.size - dataOffset))
                let chunk = try readFile(entryIndex: index, entry: e, at: dataOffset, count: n)
                out.append(chunk)
                position += Int64(n)
            } else {
                let n = Int(min(Int64(want), e.totalLength - inEntry))
                out.append(Data(count: n))
                position += Int64(n)
            }
            if position >= e.start + e.totalLength {
                index += 1
                if let h = handle, h.index < index { try? h.fh.close(); handle = nil }
            }
        }
        return out
    }

    private func readFile(entryIndex: Int, entry: TarPlan.Entry, at offset: Int64, count: Int) throws -> Data {
        if handle?.index != entryIndex {
            try? handle?.fh.close()
            guard let fh = FileHandle(forReadingAtPath: entry.fsPath) else {
                throw TarError.io("Cannot open \(entry.fsPath)")
            }
            handle = (entryIndex, fh)
        }
        let fh = handle!.fh
        try fh.seek(toOffset: UInt64(offset))
        let data = try fh.read(upToCount: count) ?? Data()
        if data.count != count { throw TarError.sourceChanged(entry.fsPath) }
        return data
    }
}
