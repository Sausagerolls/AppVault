import Foundation
import CommonCrypto

/// Incremental SHA-256 whose state can be saved and restored.
/// Saving the state lets a paused upload continue without re-reading
/// everything that was already sent.
public final class SHA256Stream {
    private var ctx = CC_SHA256_CTX()

    public init() { CC_SHA256_Init(&ctx) }

    public init?(state: Data) {
        guard state.count == MemoryLayout<CC_SHA256_CTX>.size else { return nil }
        _ = withUnsafeMutableBytes(of: &ctx) { dst in state.copyBytes(to: dst) }
    }

    public var state: Data { withUnsafeBytes(of: ctx) { Data($0) } }

    public func update(_ data: Data) {
        data.withUnsafeBytes { buf in
            _ = CC_SHA256_Update(&ctx, buf.baseAddress, CC_LONG(buf.count))
        }
    }

    public func update(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { buf in
            _ = CC_SHA256_Update(&ctx, buf.baseAddress, CC_LONG(buf.count))
        }
    }

    /// Returns the hex digest. Does not change this object's state.
    public func finalHex() -> String {
        var copy = ctx
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &copy)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
