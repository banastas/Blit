// SSH private keys from files (PRD R1.1): OpenSSH-format keys
// ("-----BEGIN OPENSSH PRIVATE KEY-----") of type ed25519 or ECDSA
// (nistp256/384/521), and PEM ECDSA keys. Those are the kinds SwiftNIO SSH
// can sign with; RSA keys and passphrase-protected keys are refused with a
// clear message.

import CryptoKit
import Foundation
import NIOSSH

public enum SSHKeyError: Error, CustomStringConvertible, Sendable {
    case unreadable(String)
    case encrypted
    case unsupportedType(String)
    case malformed(String)

    public var description: String {
        switch self {
        case .unreadable(let path): "Couldn't read the key file at \(path)."
        case .encrypted: "This key is protected by a passphrase, which Blit doesn't support yet. Use a key without a passphrase."
        case .unsupportedType(let type): "\(type) keys aren't supported; use an ed25519 or ECDSA key (ssh-keygen -t ed25519)."
        case .malformed(let why): "The key file isn't a valid SSH key (\(why))."
        }
    }
}

public enum SSHKeyFile {
    public static func load(_ path: String) throws -> NIOSSHPrivateKey {
        let expanded = (path as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: expanded, encoding: .utf8) else { throw SSHKeyError.unreadable(expanded) }
        return try parse(text)
    }

    public static func parse(_ text: String) throws -> NIOSSHPrivateKey {
        if text.contains("BEGIN OPENSSH PRIVATE KEY") { return try parseOpenSSH(text) }
        if text.contains("ENCRYPTED") { throw SSHKeyError.encrypted }
        if text.contains("BEGIN RSA PRIVATE KEY") { throw SSHKeyError.unsupportedType("RSA") }
        if text.contains("BEGIN EC PRIVATE KEY") { return try parseSEC1(text) }
        if let key = try? P256.Signing.PrivateKey(pemRepresentation: text) { return NIOSSHPrivateKey(p256Key: key) }
        if let key = try? P384.Signing.PrivateKey(pemRepresentation: text) { return NIOSSHPrivateKey(p384Key: key) }
        if let key = try? P521.Signing.PrivateKey(pemRepresentation: text) { return NIOSSHPrivateKey(p521Key: key) }
        throw SSHKeyError.malformed("not an OpenSSH or PEM ECDSA key")
    }

    /// openssh-key-v1: magic, cipher, kdf, kdf options, key count, public key,
    /// then the private section (checkints, type, key fields, comment, padding).
    private static func parseOpenSSH(_ text: String) throws -> NIOSSHPrivateKey {
        let body = text.split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let data = Data(base64Encoded: body) else { throw SSHKeyError.malformed("bad base64") }
        var reader = Reader(data)
        let magic = Array("openssh-key-v1".utf8) + [0]
        guard reader.bytes(magic.count) == magic else { throw SSHKeyError.malformed("wrong header") }
        let cipher = try reader.string()
        _ = try reader.string()      // kdf name
        _ = try reader.blob()        // kdf options
        guard cipher == "none" else { throw SSHKeyError.encrypted }
        guard try reader.uint32() == 1 else { throw SSHKeyError.malformed("more than one key") }
        _ = try reader.blob()        // public key
        var inner = Reader(try reader.blob())
        guard try inner.uint32() == inner.uint32() else { throw SSHKeyError.malformed("check mismatch") }
        let type = try inner.string()
        switch type {
        case "ssh-ed25519":
            _ = try inner.blob()                      // public key (32)
            let secret = try inner.blob()             // seed (32) + public (32)
            guard secret.count == 64 else { throw SSHKeyError.malformed("ed25519 key length") }
            return NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: secret.prefix(32)))
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            _ = try inner.string()                    // curve name
            _ = try inner.blob()                      // public point
            let scalar = try inner.blob()             // mpint d
            switch type {
            case "ecdsa-sha2-nistp256":
                return NIOSSHPrivateKey(p256Key: try P256.Signing.PrivateKey(rawRepresentation: fixed(scalar, 32)))
            case "ecdsa-sha2-nistp384":
                return NIOSSHPrivateKey(p384Key: try P384.Signing.PrivateKey(rawRepresentation: fixed(scalar, 48)))
            default:
                return NIOSSHPrivateKey(p521Key: try P521.Signing.PrivateKey(rawRepresentation: fixed(scalar, 66)))
            }
        case "ssh-rsa": throw SSHKeyError.unsupportedType("RSA")
        default: throw SSHKeyError.unsupportedType(type)
        }
    }

    /// SEC1 "EC PRIVATE KEY" (ssh-keygen -m PEM): SEQUENCE { INTEGER 1,
    /// OCTET STRING d, [0] curve, [1] public key }. CryptoKit's PEM reader
    /// refuses these when the optional fields are present, so read d directly.
    private static func parseSEC1(_ text: String) throws -> NIOSSHPrivateKey {
        let body = text.split(separator: "\n").filter { !$0.hasPrefix("-----") && !$0.contains(":") }.joined()
        guard let der = Data(base64Encoded: body) else { throw SSHKeyError.malformed("bad base64") }
        var bytes = [UInt8](der)[...]
        func element(_ tag: UInt8) throws -> ArraySlice<UInt8> {
            guard bytes.count >= 2, bytes.removeFirst() == tag else { throw SSHKeyError.malformed("unexpected DER") }
            var length = Int(bytes.removeFirst())
            if length & 0x80 != 0 {
                let n = length & 0x7F
                guard n <= 2, bytes.count >= n else { throw SSHKeyError.malformed("DER length") }
                length = bytes.prefix(n).reduce(0) { $0 << 8 | Int($1) }
                bytes.removeFirst(n)
            }
            guard bytes.count >= length else { throw SSHKeyError.malformed("truncated") }
            defer { bytes.removeFirst(length) }
            return bytes.prefix(length)
        }
        bytes = try element(0x30)              // SEQUENCE
        _ = try element(0x02)                  // version
        let d = Data(try element(0x04))        // private scalar
        switch d.count {
        case 32: return NIOSSHPrivateKey(p256Key: try P256.Signing.PrivateKey(rawRepresentation: d))
        case 48: return NIOSSHPrivateKey(p384Key: try P384.Signing.PrivateKey(rawRepresentation: d))
        case 65, 66: return NIOSSHPrivateKey(p521Key: try P521.Signing.PrivateKey(rawRepresentation: try fixed(d, 66)))
        default: throw SSHKeyError.malformed("key scalar length")
        }
    }

    /// An mpint as a fixed-width big-endian scalar (drops a sign byte, left-pads).
    private static func fixed(_ bytes: Data, _ width: Int) throws -> Data {
        var b = bytes
        while b.count > width, b.first == 0 { b.removeFirst() }
        guard b.count <= width else { throw SSHKeyError.malformed("key scalar length") }
        return Data(repeating: 0, count: width - b.count) + b
    }

    private struct Reader {
        private let data: Data
        private var offset = 0
        init(_ data: Data) { self.data = Data(data) }

        mutating func bytes(_ n: Int) -> [UInt8]? {
            guard n >= 0, offset + n <= data.count else { return nil }
            defer { offset += n }
            return Array(data[data.startIndex + offset ..< data.startIndex + offset + n])
        }
        mutating func uint32() throws -> UInt32 {
            guard let b = bytes(4) else { throw SSHKeyError.malformed("truncated") }
            return b.reduce(0) { $0 << 8 | UInt32($1) }
        }
        mutating func blob() throws -> Data {
            let n = Int(try uint32())
            guard let b = bytes(n) else { throw SSHKeyError.malformed("truncated") }
            return Data(b)
        }
        mutating func string() throws -> String { String(decoding: try blob(), as: UTF8.self) }
    }
}
