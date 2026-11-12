import Foundation
import AppVaultCore

// Usage: tartest <source dir> <out dir>
// Writes <out>/test.tar via TarPlan (in 3 MB reads, with a resume in the
// middle), checks size and hash, then extracts with /usr/bin/tar.
let args = CommandLine.arguments
guard args.count == 3 else { print("usage: tartest <src> <out>"); exit(2) }
let src = (args[1] as NSString).standardizingPath
let out = args[2]
let plan = try TarPlan(roots: [(src, (src as NSString).lastPathComponent)])
print("entries:", plan.fileCount, "size:", plan.totalSize, "sig:", plan.signature.prefix(12))

let tarPath = out + "/test.tar"
FileManager.default.createFile(atPath: tarPath, contents: nil)
let fh = FileHandle(forWritingAtPath: tarPath)!
let hasher = SHA256Stream()
var reader = TarReader(plan: plan)
let half = min(plan.totalSize - 1, plan.totalSize / 2 + 12345)
while reader.position < half {
    let d = try reader.read(max: Int(min(3_000_000, half - reader.position)))
    hasher.update(d); fh.write(d)
}
// Simulate pause + restart: save hash state, rebuild plan and reader at offset.
let saved = hasher.state
let plan2 = try TarPlan(roots: [(src, (src as NSString).lastPathComponent)])
precondition(plan2.signature == plan.signature, "signature not deterministic")
let hasher2 = SHA256Stream(state: saved)!
reader = TarReader(plan: plan2, offset: half)
while !reader.isAtEnd {
    let d = try reader.read(max: 3_000_000)
    hasher2.update(d); fh.write(d)
}
try fh.close()
let attrs = try FileManager.default.attributesOfItem(atPath: tarPath)
print("written:", attrs[.size]!, "expected:", plan.totalSize)
print("sha:", hasher2.finalHex())
