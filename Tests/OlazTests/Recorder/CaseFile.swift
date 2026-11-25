import Foundation

/// Lossless JSON AST preserving exact 64-bit integers and canonical key ordering (`utf8` / scalar order).
enum CaseJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case double(Double, raw: String)
    case string(String)
    case array([CaseJSON])
    case object([String: CaseJSON])

    static func == (lhs: CaseJSON, rhs: CaseJSON) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.uint(let a), .uint(let b)): return a == b
        case (.int(let a), .uint(let b)): return a >= 0 && UInt64(a) == b
        case (.uint(let a), .int(let b)): return b >= 0 && a == UInt64(b)
        case (.double(let a, _), .double(let b, _)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.object(let a), .object(let b)): return a == b
        default: return false
        }
    }

    var objectValue: [String: CaseJSON]? {
        if case .object(let m) = self { return m }
        return nil
    }

    var arrayValue: [CaseJSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var int64Value: Int64? {
        switch self {
        case .int(let v): return v
        case .uint(let v): return Int64(exactly: v)
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    subscript(key: String) -> CaseJSON? {
        objectValue?[key]
    }

    func canonicalString() -> String {
        var out = ""
        writeCanonical(to: &out)
        return out
    }

    func prettyString(indent: Int = 0) -> String {
        var out = ""
        writePretty(to: &out, indent: indent)
        return out
    }

    private func writeCanonical(to out: inout String) {
        switch self {
        case .null:
            out.append("null")
        case .bool(let b):
            out.append(b ? "true" : "false")
        case .int(let v):
            out.append(String(v))
        case .uint(let v):
            out.append(String(v))
        case .double(_, let raw):
            out.append(raw)
        case .string(let s):
            Self.appendEscapedString(s, to: &out)
        case .array(let items):
            out.append("[")
            for (idx, item) in items.enumerated() {
                if idx > 0 { out.append(",") }
                item.writeCanonical(to: &out)
            }
            out.append("]")
        case .object(let dict):
            out.append("{")
            let keys = dict.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            for (idx, key) in keys.enumerated() {
                if idx > 0 { out.append(",") }
                Self.appendEscapedString(key, to: &out)
                out.append(":")
                dict[key]!.writeCanonical(to: &out)
            }
            out.append("}")
        }
    }

    private func writePretty(to out: inout String, indent: Int) {
        let pad = String(repeating: "  ", count: indent)
        let childPad = String(repeating: "  ", count: indent + 1)
        switch self {
        case .array(let items):
            if items.isEmpty { out.append("[]"); return }
            out.append("[\n")
            for (idx, item) in items.enumerated() {
                out.append(childPad)
                item.writePretty(to: &out, indent: indent + 1)
                if idx + 1 < items.count { out.append(",") }
                out.append("\n")
            }
            out.append(pad)
            out.append("]")
        case .object(let dict):
            if dict.isEmpty { out.append("{}"); return }
            out.append("{\n")
            let keys = dict.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            for (idx, key) in keys.enumerated() {
                out.append(childPad)
                Self.appendEscapedString(key, to: &out)
                out.append(": ")
                dict[key]!.writePretty(to: &out, indent: indent + 1)
                if idx + 1 < keys.count { out.append(",") }
                out.append("\n")
            }
            out.append(pad)
            out.append("}")
        default:
            writeCanonical(to: &out)
        }
    }

    static func appendEscapedString(_ s: String, to out: inout String) {
        out.append("\"")
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x22: out.append("\\\"")
            case 0x5C: out.append("\\\\")
            case 0x08: out.append("\\b")
            case 0x0C: out.append("\\f")
            case 0x0A: out.append("\\n")
            case 0x0D: out.append("\\r")
            case 0x09: out.append("\\t")
            case 0x00..<0x20:
                let hex = String(scalar.value, radix: 16, uppercase: false)
                out.append("\\u" + String(repeating: "0", count: 4 - hex.count) + hex)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out.append("\"")
    }

    static func parse(_ string: String) throws -> CaseJSON {
        try parse(Data(string.utf8))
    }

    static func parse(_ data: Data) throws -> CaseJSON {
        var parser = JSONParser(bytes: Array(data))
        let val = try parser.parseValue()
        parser.skipWhitespace()
        if parser.index < parser.bytes.count {
            throw CaseJSONError.trailingCharacters
        }
        return val
    }

    static func fromAny(_ value: Any) -> CaseJSON {
        if type(of: value) == Bool.self, let b = value as? Bool {
            return .bool(b)
        }
        if type(of: value) == UInt64.self, let u = value as? UInt64 {
            return .uint(u)
        }
        switch value {
        case is NSNull:
            return .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            }
            if CFNumberIsFloatType(n) {
                let d = n.doubleValue
                return .double(d, raw: String(d))
            }
            return .int(n.int64Value)
        case let s as String:
            return .string(s)
        case let arr as [Any]:
            return .array(arr.map(fromAny))
        case let dict as [String: Any]:
            var out: [String: CaseJSON] = [:]
            for (k, v) in dict {
                out[k] = fromAny(v)
            }
            return .object(out)
        default:
            return .string(String(describing: value))
        }
    }

    func toFoundation() -> Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let v): return v
        case .uint(let v): return v
        case .double(let d, _): return d
        case .string(let s): return s
        case .array(let a): return a.map { $0.toFoundation() }
        case .object(let o):
            var d: [String: Any] = [:]
            for (k, v) in o { d[k] = v.toFoundation() }
            return d
        }
    }

    func replacingString(_ target: String, with replacement: String) -> CaseJSON {
        switch self {
        case .string(let s):
            return .string(s.replacingOccurrences(of: target, with: replacement))
        case .array(let a):
            return .array(a.map { $0.replacingString(target, with: replacement) })
        case .object(let o):
            var out: [String: CaseJSON] = [:]
            for (k, v) in o {
                out[k] = v.replacingString(target, with: replacement)
            }
            return .object(out)
        default:
            return self
        }
    }

    static func firstDiff(expected: CaseJSON, actual: CaseJSON, path: String = "$") -> String? {
        if expected == actual { return nil }
        switch (expected, actual) {
        case (.object(let eDict), .object(let aDict)):
            let allKeys = Set(eDict.keys).union(aDict.keys).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            for k in allKeys {
                let childPath = "\(path).\(k)"
                guard let eVal = eDict[k] else {
                    return "\(childPath): expected absent, got \(aDict[k]!.canonicalString())"
                }
                guard let aVal = aDict[k] else {
                    return "\(childPath): expected \(eVal.canonicalString()), got absent"
                }
                if let d = firstDiff(expected: eVal, actual: aVal, path: childPath) {
                    return d
                }
            }
            return nil
        case (.array(let eArr), .array(let aArr)):
            let count = min(eArr.count, aArr.count)
            for i in 0..<count {
                if let d = firstDiff(expected: eArr[i], actual: aArr[i], path: "\(path)[\(i)]") {
                    return d
                }
            }
            if eArr.count != aArr.count {
                return "\(path).length: expected \(eArr.count), got \(aArr.count)"
            }
            return nil
        default:
            return "\(path): expected \(expected.canonicalString()), got \(actual.canonicalString())"
        }
    }
}

enum CaseJSONError: Error {
    case unexpectedEOF
    case invalidToken(String)
    case trailingCharacters
}

private struct JSONParser {
    let bytes: [UInt8]
    var index: Int = 0

    mutating func skipWhitespace() {
        while index < bytes.count {
            let b = bytes[index]
            if b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 {
                index += 1
            } else {
                break
            }
        }
    }

    mutating func parseValue() throws -> CaseJSON {
        skipWhitespace()
        guard index < bytes.count else { throw CaseJSONError.unexpectedEOF }
        switch bytes[index] {
        case 0x7B: return try parseObject()
        case 0x5B: return try parseArray()
        case 0x22: return .string(try parseString())
        case 0x74:
            try expectLiteral("true")
            return .bool(true)
        case 0x66:
            try expectLiteral("false")
            return .bool(false)
        case 0x6E:
            try expectLiteral("null")
            return .null
        case 0x2D, 0x30...0x39:
            return try parseNumber()
        default:
            throw CaseJSONError.invalidToken(String(bytes[index]))
        }
    }

    mutating func expectLiteral(_ lit: String) throws {
        let utf8 = Array(lit.utf8)
        guard index + utf8.count <= bytes.count, Array(bytes[index..<(index + utf8.count)]) == utf8 else {
            throw CaseJSONError.invalidToken(lit)
        }
        index += utf8.count
    }

    mutating func parseObject() throws -> CaseJSON {
        index += 1 // '{'
        skipWhitespace()
        var out: [String: CaseJSON] = [:]
        if index < bytes.count && bytes[index] == 0x7D {
            index += 1
            return .object(out)
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 0x22 else {
                throw CaseJSONError.invalidToken("expected object key")
            }
            let key = try parseString()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 0x3A else {
                throw CaseJSONError.invalidToken("expected :")
            }
            index += 1
            let val = try parseValue()
            out[key] = val
            skipWhitespace()
            guard index < bytes.count else { throw CaseJSONError.unexpectedEOF }
            if bytes[index] == 0x7D {
                index += 1
                return .object(out)
            }
            guard bytes[index] == 0x2C else {
                throw CaseJSONError.invalidToken("expected , or }")
            }
            index += 1
        }
    }

    mutating func parseArray() throws -> CaseJSON {
        index += 1 // '['
        skipWhitespace()
        var out: [CaseJSON] = []
        if index < bytes.count && bytes[index] == 0x5D {
            index += 1
            return .array(out)
        }
        while true {
            out.append(try parseValue())
            skipWhitespace()
            guard index < bytes.count else { throw CaseJSONError.unexpectedEOF }
            if bytes[index] == 0x5D {
                index += 1
                return .array(out)
            }
            guard bytes[index] == 0x2C else {
                throw CaseJSONError.invalidToken("expected , or ]")
            }
            index += 1
        }
    }

    mutating func parseString() throws -> String {
        let start = index
        index += 1 // '"'
        while index < bytes.count {
            let b = bytes[index]
            if b == 0x5C {
                index += 2
                continue
            }
            if b == 0x22 {
                index += 1
                let slice = Data(bytes[start..<index])
                guard let decoded = try JSONSerialization.jsonObject(with: slice, options: [.fragmentsAllowed]) as? String else {
                    throw CaseJSONError.invalidToken("string")
                }
                return decoded
            }
            index += 1
        }
        throw CaseJSONError.unexpectedEOF
    }

    mutating func parseNumber() throws -> CaseJSON {
        let start = index
        if bytes[index] == 0x2D { index += 1 }
        while index < bytes.count && (0x30...0x39).contains(bytes[index]) { index += 1 }
        var isFloat = false
        if index < bytes.count && bytes[index] == 0x2E {
            isFloat = true
            index += 1
            while index < bytes.count && (0x30...0x39).contains(bytes[index]) { index += 1 }
        }
        if index < bytes.count && (bytes[index] == 0x65 || bytes[index] == 0x45) {
            isFloat = true
            index += 1
            if index < bytes.count && (bytes[index] == 0x2B || bytes[index] == 0x2D) { index += 1 }
            while index < bytes.count && (0x30...0x39).contains(bytes[index]) { index += 1 }
        }
        let raw = String(decoding: bytes[start..<index], as: UTF8.self)
        if isFloat {
            guard let d = Double(raw) else { throw CaseJSONError.invalidToken(raw) }
            return .double(d, raw: raw)
        }
        if let i = Int64(raw) {
            return .int(i)
        }
        if let u = UInt64(raw) {
            return .uint(u)
        }
        throw CaseJSONError.invalidToken(raw)
    }
}

/// Case file loader / writer (`rust/crates/olaz-core/cases/<domain>.jsonl`).
enum CaseFile {
    static func repoRoot(from filePath: String = #filePath) -> URL {
        // Tests/OlazTests/Recorder/CaseFile.swift -> repo root
        URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    struct KnownDiff {
        let domain: String
        let name: String
        let path: String
        let actual: CaseJSON
        let reason: String
    }

    struct LeafDiff {
        let path: String
        let expected: CaseJSON
        let actual: CaseJSON
    }

    static func casesURL(domain: String, from filePath: String = #filePath) -> URL {
        repoRoot(from: filePath)
            .appendingPathComponent("rust/crates/olaz-core/cases/\(domain).jsonl")
    }

    static func knownDiffsURL(from filePath: String = #filePath) -> URL {
        repoRoot(from: filePath)
            .appendingPathComponent("rust/crates/olaz-core/cases/known-diffs.jsonl")
    }

    static func loadKnownDiffs(from filePath: String = #filePath) throws -> [KnownDiff] {
        let url = knownDiffsURL(from: filePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        return try loadKnownDiffs(url: url)
    }

    static func loadKnownDiffs(url: URL) throws -> [KnownDiff] {
        let content = try String(contentsOf: url, encoding: .utf8)
        var out: [KnownDiff] = []
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let obj = try CaseJSON.parse(line)
            guard let domain = obj["domain"]?.stringValue,
                  let name = obj["name"]?.stringValue,
                  let path = obj["path"]?.stringValue,
                  let actual = obj["actual"] else {
                throw CaseJSONError.invalidToken("known-diffs entry missing required fields")
            }
            let reason = obj["reason"]?.stringValue ?? ""
            out.append(KnownDiff(domain: domain, name: name, path: path, actual: actual, reason: reason))
        }
        return out
    }

    /// Collects all leaf diffs matching Rust `tests/common/mod.rs::diff_json` path and `"<missing>"` conventions.
    static func collectLeafDiffs(expected: CaseJSON, actual: CaseJSON, prefix: String = "") -> [LeafDiff] {
        if expected == actual { return [] }
        switch (expected, actual) {
        case (.object(let eDict), .object(let aDict)):
            var out: [LeafDiff] = []
            let allKeys = Set(eDict.keys).union(aDict.keys).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            for k in allKeys {
                let childPath = prefix.isEmpty ? k : "\(prefix).\(k)"
                switch (eDict[k], aDict[k]) {
                case let (eVal?, aVal?):
                    out.append(contentsOf: collectLeafDiffs(expected: eVal, actual: aVal, prefix: childPath))
                case let (eVal?, nil):
                    out.append(LeafDiff(path: childPath, expected: eVal, actual: .string("<missing>")))
                case let (nil, aVal?):
                    out.append(LeafDiff(path: childPath, expected: .string("<missing>"), actual: aVal))
                case (nil, nil):
                    break
                }
            }
            return out
        case (.array(let eArr), .array(let aArr)):
            var out: [LeafDiff] = []
            let count = max(eArr.count, aArr.count)
            for i in 0..<count {
                let childPath = "\(prefix)[\(i)]"
                if i < eArr.count && i < aArr.count {
                    out.append(contentsOf: collectLeafDiffs(expected: eArr[i], actual: aArr[i], prefix: childPath))
                } else if i < eArr.count {
                    out.append(LeafDiff(path: childPath, expected: eArr[i], actual: .string("<missing>")))
                } else {
                    out.append(LeafDiff(path: childPath, expected: .string("<missing>"), actual: aArr[i]))
                }
            }
            return out
        default:
            return [LeafDiff(path: prefix, expected: expected, actual: actual)]
        }
    }

    /// Compares a recorded case against a fresh Swift run, accepting ONLY leaf diffs under `expect`
    /// that match a `known-diffs.jsonl` entry by `(domain, name, path)` AND exact canonical `actual`.
    static func compareCase(
        domain: String,
        name: String,
        expected: CaseJSON,
        actual: CaseJSON,
        knownDiffs: [KnownDiff],
        usedKnownDiffs: inout [Bool]
    ) -> [String] {
        guard case .object(var expObj) = expected, case .object(var actObj) = actual else {
            if let d = CaseJSON.firstDiff(expected: expected, actual: actual) {
                return [d]
            }
            return []
        }

        let expExpect = expObj.removeValue(forKey: "expect") ?? .null
        let actExpect = actObj.removeValue(forKey: "expect") ?? .null

        var errors: [String] = []
        if let metaDiff = CaseJSON.firstDiff(expected: .object(expObj), actual: .object(actObj)) {
            errors.append(metaDiff)
        }

        let leafDiffs = collectLeafDiffs(expected: expExpect, actual: actExpect, prefix: "")
        for diff in leafDiffs {
            let actualCanon = diff.actual.canonicalString()
            var matched = false
            for (idx, kd) in knownDiffs.enumerated() {
                if kd.domain == domain
                    && kd.name == name
                    && kd.path == diff.path
                    && kd.actual.canonicalString() == actualCanon
                {
                    if idx < usedKnownDiffs.count {
                        usedKnownDiffs[idx] = true
                    }
                    matched = true
                    break
                }
            }
            if !matched {
                errors.append("\(diff.path): expected \(diff.expected.canonicalString()), got \(actualCanon)")
            }
        }
        return errors
    }

    /// Returns failure descriptions for any `known-diffs.jsonl` entry in `domain` that did not match
    /// an executed case (either the case no longer differs from the recording, or its `actual` drifted,
    /// or the case name does not exist in `<domain>.jsonl`).
    static func staleKnownDiffs(
        domain: String,
        executedNames: Set<String>,
        allCaseNames: Set<String>,
        knownDiffs: [KnownDiff],
        usedKnownDiffs: [Bool]
    ) -> [String] {
        var stale: [String] = []
        for (idx, kd) in knownDiffs.enumerated() where kd.domain == domain {
            if !allCaseNames.contains(kd.name) {
                stale.append("stale known diff (unknown case): \(kd.domain)/\(kd.name) \(kd.path)")
            } else if executedNames.contains(kd.name), !(idx < usedKnownDiffs.count && usedKnownDiffs[idx]) {
                stale.append("stale known diff (case no longer differs or actual changed): \(kd.domain)/\(kd.name) \(kd.path)")
            }
        }
        return stale
    }

    static func load(url: URL) throws -> [CaseJSON] {
        let content = try String(contentsOf: url, encoding: .utf8)
        var cases: [CaseJSON] = []
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            cases.append(try CaseJSON.parse(String(line)))
        }
        return cases
    }

    static func write(_ cases: [CaseJSON], to url: URL) throws {
        let sorted = cases.sorted {
            let a = $0["name"]?.stringValue ?? ""
            let b = $1["name"]?.stringValue ?? ""
            return a.utf8.lexicographicallyPrecedes(b.utf8)
        }
        let body = sorted.map { $0.canonicalString() }.joined(separator: "\n") + (sorted.isEmpty ? "" : "\n")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
    }
}
