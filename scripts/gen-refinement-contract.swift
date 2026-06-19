#!/usr/bin/env swift
// Generates Sources/Voice/Generated/RefinementContract.swift from
// Resources/refinement-contract.json. Run after editing the JSON:
//
//     swift scripts/gen-refinement-contract.swift
//
// The generated file is checked in; scripts/smoke-test.sh guards against drift.

import Foundation

struct Profile: Decodable {
    let id: String
    let title: String
    let description: String
    let instructions: String
    let contentRule: String
}

struct Contract: Decodable {
    let promptTemplate: String
    let defaultProfile: String
    let llamaArguments: [String]
    let sentinelLines: [String]
    let headerSkipPrefixes: [String]
    let profiles: [Profile]
}

// Resolve repo root relative to this script (scripts/..).
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let jsonURL = repoRoot.appendingPathComponent("Resources/refinement-contract.json")
let outputURL = repoRoot.appendingPathComponent("Sources/Voice/Generated/RefinementContract.swift")

let data = try Data(contentsOf: jsonURL)
let contract = try JSONDecoder().decode(Contract.self, from: data)

// Emit a Swift double-quoted string literal for an arbitrary value.
func lit(_ s: String) -> String {
    var out = "\""
    for ch in s.unicodeScalars {
        switch ch {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default: out.unicodeScalars.append(ch)
        }
    }
    out += "\""
    return out
}

func arrayLit(_ items: [String]) -> String {
    "[" + items.map(lit).joined(separator: ", ") + "]"
}

let cases = contract.profiles.map { "    case \($0.id)" }.joined(separator: "\n")

func mapped(_ keyPath: (Profile) -> String) -> String {
    contract.profiles
        .map { "        case .\($0.id): \(lit(keyPath($0)))" }
        .joined(separator: "\n")
}

let source = """
// Generated from Resources/refinement-contract.json — do not edit.
// Regenerate with: swift scripts/gen-refinement-contract.swift

import Foundation

enum RefinementProfile: String, CaseIterable, Identifiable {
\(cases)

    var id: String { rawValue }

    var title: String {
        switch self {
\(mapped { $0.title })
        }
    }

    var description: String {
        switch self {
\(mapped { $0.description })
        }
    }

    var instructions: String {
        switch self {
\(mapped { $0.instructions })
        }
    }

    var contentRule: String {
        switch self {
\(mapped { $0.contentRule })
        }
    }
}

enum RefinementContract {
    static let defaultProfile = RefinementProfile.\(contract.defaultProfile)
    static let promptTemplate = \(lit(contract.promptTemplate))
    static let llamaArguments: [String] = \(arrayLit(contract.llamaArguments))
    static let sentinelLines: [String] = \(arrayLit(contract.sentinelLines))
    static let headerSkipPrefixes: [String] = \(arrayLit(contract.headerSkipPrefixes))

    static func prompt(rawText: String, profile: RefinementProfile) -> String {
        promptTemplate
            .replacingOccurrences(of: "{contentRule}", with: profile.contentRule)
            .replacingOccurrences(of: "{instructions}", with: profile.instructions)
            .replacingOccurrences(of: "{rawText}", with: rawText)
    }
}

"""

try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try source.write(to: outputURL, atomically: true, encoding: .utf8)
print("Wrote \(outputURL.path)")
