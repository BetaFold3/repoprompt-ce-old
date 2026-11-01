#if canImport(Foundation)
import Foundation
#endif

// RPCE local modification (bounded passkey verifier experiment, 2026-11-01). Reject-only hardening
// of the retained decoder; valid unique-key, well-formed CBOR still decodes unchanged. See
// Vendor/SwiftWebAuthn/PATCHES.md. Changes:
//  - Duplicate map keys are rejected in both map readers before insertion (upstream kept last-wins).
//    Uniqueness is compared by the CBOR enum's value equality; it does NOT canonicalize NaN or
//    cross-width floating-point keys (recorded limitation P2-01) — not a universal guarantee.
//  - Definite-length arrays are built incrementally and never reserve capacity from the declared
//    count (P0-02: a tiny header could declare Int.max elements and abort on allocation).
//  - Break (0xff) handling is context-sensitive: a break is accepted only at an indefinite
//    container's legal termination, never as a value/element/key/tagged item or at top level
//    (P1-01). Chunks of an indefinite byte/text string must be definite-length strings.
public enum CBORError : Error {
    case unfinishedSequence
    case wrongTypeInsideSequence
    case tooLongSequence
    case incorrectUTF8String
    case maximumDepthExceeded
    case duplicateMapKey
}

extension CBOR {
    static public func decode(_ input: [UInt8], options: CBOROptions = CBOROptions()) throws -> CBOR? {
        return try CBORDecoder(input: input, options: options).decodeItem()
    }
}

public class CBORDecoder {
    private var istream : CBORInputStream
    public var options: CBOROptions
    private var currentDepth = 0

    public init(stream: CBORInputStream, options: CBOROptions = CBOROptions()) {
        self.istream = stream
        self.options = options
    }

    public init(input: ArraySlice<UInt8>, options: CBOROptions = CBOROptions()) {
        self.istream = ArraySliceUInt8(slice: input)
        self.options = options
    }

    public init(input: [UInt8], options: CBOROptions = CBOROptions()) {
        self.istream = ArrayUInt8(array: ArraySlice(input))
        self.options = options
    }

    func readBinaryNumber<T>(_ type: T.Type) throws -> T {
        Array(try self.istream.popBytes(MemoryLayout<T>.size).reversed()).withUnsafeBytes { ptr in
            return ptr.load(as: T.self)
        }
    }

    func readVarUInt(_ v: UInt8, base: UInt8) throws -> UInt64 {
        guard v > base + 0x17 else { return UInt64(v - base) }

        switch VarUIntSize(rawValue: v) {
        case .uint8: return UInt64(try readBinaryNumber(UInt8.self))
        case .uint16: return UInt64(try readBinaryNumber(UInt16.self))
        case .uint32: return UInt64(try readBinaryNumber(UInt32.self))
        case .uint64: return UInt64(try readBinaryNumber(UInt64.self))
        }
    }

    func readLength(_ v: UInt8, base: UInt8) throws -> Int {
        let n = try readVarUInt(v, base: base)

        guard n <= Int.max else {
            throw CBORError.tooLongSequence
        }

        return Int(n)
    }

    private func readN(_ n: Int) throws -> [CBOR] {
        // RPCE local modification (P0-02): build the array incrementally and NEVER reserve capacity
        // from `n`. `n` is an attacker-declared element count: a tiny header such as
        // `9b 7f ff ff ff ff ff ff ff` declares up to Int.max elements. The previous
        // `(0..<n).map { ... }` reserved that full count up front (Range's underestimatedCount),
        // which could abort on allocation before the missing elements produced an ordinary
        // `unfinishedSequence`. Appending one decoded item at a time throws as soon as input runs
        // out. A definite-length array element is never a break (decodeItem rejects a stray break).
        var result: [CBOR] = []
        var remaining = n
        while remaining > 0 {
            guard let r = try decodeItem() else { throw CBORError.unfinishedSequence }
            result.append(r)
            remaining -= 1
        }
        return result
    }

    func readUntilBreak() throws -> [CBOR] {
        // RPCE local modification (P1-01): a break (0xff) is legal ONLY at an element position of
        // this indefinite-length array, where it terminates the array. `allowBreak: true` is passed
        // only for the item at the current position; any break nested inside a decoded element is
        // rejected (those inner reads default to `allowBreak: false`).
        var result: [CBOR] = []
        var cur = try decodeItem(allowBreak: true)
        while cur != CBOR.break {
            guard let curr = cur else { throw CBORError.unfinishedSequence }
            result.append(curr)
            cur = try decodeItem(allowBreak: true)
        }
        return result
    }

    // RPCE local modification (P1-01): RFC 8949 §3.2.3 requires every chunk of an indefinite-length
    // byte/text string to be a DEFINITE-length string of the same major type. Read chunks directly
    // from the header byte and reject anything else — a nested indefinite string (0x5f/0x7f), a
    // break anywhere but the terminator, or any other major type. `readLength` + `popBytes` are
    // length-safe (popBytes throws when short; it never reserves from the declared length).
    private func readIndefiniteByteStringChunks() throws -> [UInt8] {
        var result: [UInt8] = []
        while true {
            let b = try istream.popByte()
            if b == 0xff { break } // legal termination of the indefinite byte string
            guard (0x40...0x5b).contains(b) else { throw CBORError.wrongTypeInsideSequence }
            let numBytes = try readLength(b, base: 0x40)
            result.append(contentsOf: try istream.popBytes(numBytes))
        }
        return result
    }

    private func readIndefiniteUTF8StringChunks() throws -> String {
        var result = ""
        while true {
            let b = try istream.popByte()
            if b == 0xff { break } // legal termination of the indefinite text string
            guard (0x60...0x7b).contains(b) else { throw CBORError.wrongTypeInsideSequence }
            let numBytes = try readLength(b, base: 0x60)
            result += try Util.decodeUtf8(try istream.popBytes(numBytes))
        }
        return result
    }

    private func readNPairs(_ n: Int) throws -> [CBOR : CBOR] {
        var result: [CBOR: CBOR] = [:]
        for _ in (0..<n) {
            guard let key  = try decodeItem() else { throw CBORError.unfinishedSequence }
            guard let val  = try decodeItem() else { throw CBORError.unfinishedSequence }
            // RPCE local modification: reject duplicate keys instead of last-wins overwrite.
            guard result[key] == nil else { throw CBORError.duplicateMapKey }
            result[key] = val
        }
        return result
    }

    func readPairsUntilBreak() throws -> [CBOR : CBOR] {
        // RPCE local modification (P1-01): a break (0xff) legally terminates this indefinite-length
        // map only at a KEY position (an even number of items read so far). It is never a valid key,
        // value, or standalone item. The key position passes `allowBreak: true` to detect that
        // terminator; the value position uses `allowBreak: false`, so a break where a value is
        // required (e.g. `bf 61 78 ff ff`) throws instead of being stored as a value. Duplicate keys
        // are still rejected before insertion.
        var result: [CBOR: CBOR] = [:]
        while true {
            guard let key = try decodeItem(allowBreak: true) else { throw CBORError.unfinishedSequence }
            if key == CBOR.break { break }
            guard let val = try decodeItem(allowBreak: false) else { throw CBORError.unfinishedSequence }
            guard result[key] == nil else { throw CBORError.duplicateMapKey }
            result[key] = val
        }
        return result
    }

    public func decodeItem() throws -> CBOR? {
        // RPCE local modification (P1-01): the public entry point never accepts a bare break. A
        // break is only meaningful at an indefinite container's termination, handled internally.
        return try decodeItem(allowBreak: false)
    }

    // RPCE local modification (P1-01): break handling is context-sensitive. `allowBreak` is true
    // ONLY at the position where an indefinite-length array/map may legally terminate; everywhere
    // else (definite element/value, map value, tagged item, top level) a 0xff is malformed input
    // and throws rather than surfacing as a usable `.break` value.
    private func decodeItem(allowBreak: Bool) throws -> CBOR? {
        guard currentDepth <= options.maximumDepth
        else { throw CBORError.maximumDepthExceeded }
        
        currentDepth += 1
        defer { currentDepth -= 1 }
        let b = try istream.popByte()

        switch b {
        // positive integers
        case 0x00...0x1b:
            return CBOR.unsignedInt(try readVarUInt(b, base: 0x00))

        // negative integers
        case 0x20...0x3b:
            return CBOR.negativeInt(try readVarUInt(b, base: 0x20))

        // byte strings
        case 0x40...0x5b:
            let numBytes = try readLength(b, base: 0x40)
            return CBOR.byteString(Array(try istream.popBytes(numBytes)))
        case 0x5f:
            return CBOR.byteString(try readIndefiniteByteStringChunks())

        // utf-8 strings
        case 0x60...0x7b:
            let numBytes = try readLength(b, base: 0x60)
            return CBOR.utf8String(try Util.decodeUtf8(try istream.popBytes(numBytes)))
        case 0x7f:
            return CBOR.utf8String(try readIndefiniteUTF8StringChunks())

        // arrays
        case 0x80...0x9b:
            let numBytes = try readLength(b, base: 0x80)
            return CBOR.array(try readN(numBytes))
        case 0x9f:
            return CBOR.array(try readUntilBreak())

        // pairs
        case 0xa0...0xbb:
            let numBytes = try readLength(b, base: 0xa0)
            let pairs = try readNPairs(numBytes)
            if self.options.dateStrategy == .annotatedMap {
                if let annotatedType = pairs[CBOR.utf8String(AnnotatedMapDateStrategy.typeKey)],
                   annotatedType == CBOR.utf8String(AnnotatedMapDateStrategy.typeValue),
                   let dateEpochTimestampCBOR = pairs[CBOR.utf8String(AnnotatedMapDateStrategy.valueKey)],
                   let date = try? getDateFromTimestamp(dateEpochTimestampCBOR)
                {
                    return CBOR.date(date)
                }
            }
            return CBOR.map(pairs)
        case 0xbf:
            return CBOR.map(try readPairsUntilBreak())

        // tagged values
        case 0xc0...0xdb:
            let tag = try readVarUInt(b, base: 0xc0)
            guard let item = try decodeItem() else { throw CBORError.unfinishedSequence }
            #if canImport(Foundation)
            if tag == 1 {
                let date = try getDateFromTimestamp(item)
                return CBOR.date(date)
            }
            #endif
            return CBOR.tagged(CBOR.Tag(rawValue: tag), item)

        case 0xe0...0xf3: return CBOR.simple(b - 0xe0)
        case 0xf4: return CBOR.boolean(false)
        case 0xf5: return CBOR.boolean(true)
        case 0xf6: return CBOR.null
        case 0xf7: return CBOR.undefined
        case 0xf8: return CBOR.simple(try istream.popByte())

        case 0xf9:
            return CBOR.half(Util.readFloat16(x: try readBinaryNumber(UInt16.self)))
        case 0xfa:
            return CBOR.float(try readBinaryNumber(Float32.self))
        case 0xfb:
            return CBOR.double(try readBinaryNumber(Float64.self))

        case 0xff:
            // RPCE local modification (P1-01): a break is only valid at an indefinite container's
            // legal termination position (handled by the indefinite readers, which call this with
            // allowBreak == true). Anywhere else it is malformed input.
            guard allowBreak else { throw CBORError.unfinishedSequence }
            return CBOR.break
        default: return nil
        }
    }
}

func getDateFromTimestamp(_ item: CBOR) throws -> Date {
    switch item {
    case .double(let d):
        return Date(timeIntervalSince1970: TimeInterval(d))
    case .negativeInt(let n):
        return Date(timeIntervalSince1970: TimeInterval(-1 - Double(n)))
    case .float(let f):
        return Date(timeIntervalSince1970: TimeInterval(f))
    case .unsignedInt(let u):
        return Date(timeIntervalSince1970: TimeInterval(u))
    default:
        throw CBORError.wrongTypeInsideSequence
    }
}

private enum VarUIntSize: UInt8 {
    case uint8 = 0
    case uint16 = 1
    case uint32 = 2
    case uint64 = 3

    init(rawValue: UInt8) {
        switch rawValue & 0b11 {
        case 0: self = .uint8
        case 1: self = .uint16
        case 2: self = .uint32
        case 3: self = .uint64
        default: fatalError() // mask only allows values from 0-3
        }
    }
}
