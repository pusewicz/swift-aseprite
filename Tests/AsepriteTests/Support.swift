import Foundation
import Testing

@testable import Aseprite

/// A checked-in fixture file and its Aseprite-exported goldens.
struct Fixture: Sendable, CustomTestStringConvertible {
  /// `Real`, `Features`, or `Synthetic`.
  let category: String
  /// File name without extension.
  let name: String
  /// File name with extension.
  let fileName: String

  var testDescription: String { "\(category)/\(name)" }

  static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

  /// Every fixture that has goldens.
  static let all: [Fixture] = ["Real", "Features", "Synthetic"].flatMap { category in
    let directory = root.appendingPathComponent(category)
    let files = Fixture.fileNames(in: directory)
    return files.filter { $0.hasSuffix(".ase") || $0.hasSuffix(".aseprite") }.sorted().map {
      Fixture(category: category, name: ($0 as NSString).deletingPathExtension, fileName: $0)
    }
  }

  static func named(_ testDescription: String) -> Fixture {
    guard let fixture = all.first(where: { $0.testDescription == testDescription }) else {
      preconditionFailure("no fixture \(testDescription)")
    }
    return fixture
  }

  /// The names of the files in `directory`; empty if it can't be listed (FixtureTests catches that).
  static func fileNames(in directory: URL) -> [String] {
    let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    return (urls ?? []).map(\.lastPathComponent)
  }

  var url: URL { Self.root.appendingPathComponent(category).appendingPathComponent(fileName) }
  var goldens: URL {
    Self.root.appendingPathComponent("Goldens").appendingPathComponent(category).appendingPathComponent(name)
  }

  func bytes() throws -> [UInt8] {
    [UInt8](try Data(contentsOf: url))
  }

  func decode() throws -> Aseprite {
    try Aseprite(bytes: bytes())
  }

  func meta() throws -> JSON {
    try JSONDecoder().decode(JSON.self, from: Data(contentsOf: goldens.appendingPathComponent("meta.json")))
  }

  func frame(_ index: Int) throws -> [UInt8] {
    [UInt8](try Data(contentsOf: goldens.appendingPathComponent("frame-\(index).rgba")))
  }
}

/// A JSON value, compared numerically across integer and floating-point representations.
enum JSON: Decodable, Equatable, CustomStringConvertible {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSON])
  case object([String: JSON])

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int64.self) {
      self = .number(Double(value))
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSON].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSON].self))
    }
  }

  subscript(key: String) -> JSON {
    if case .object(let object) = self, let value = object[key] { return value }
    return .null
  }

  subscript(index: Int) -> JSON {
    if case .array(let array) = self, array.indices.contains(index) { return array[index] }
    return .null
  }

  var array: [JSON] {
    if case .array(let array) = self { return array }
    return []
  }

  var int: Int? {
    if case .number(let value) = self { return Int(value) }
    return nil
  }

  var string: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  var bool: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  var description: String {
    switch self {
    case .null: "null"
    case .bool(let value): "\(value)"
    case .number(let value): value == value.rounded() && abs(value) < 1e15 ? "\(Int(value))" : "\(value)"
    case .string(let value): "\"\(value)\""
    case .array(let value): "[" + value.map(\.description).joined(separator: ",") + "]"
    case .object(let value):
      "{" + value.keys.sorted().map { "\"\($0)\":\(value[$0]?.description ?? "null")" }.joined(separator: ",")
        + "}"
    }
  }

  static func numbers(_ values: Int...) -> JSON {
    .array(values.map { .number(Double($0)) })
  }
}

extension Aseprite.Color {
  var json: JSON { .numbers(Int(r), Int(g), Int(b), Int(a)) }
}

extension Aseprite.Rect {
  var json: JSON { .numbers(x, y, width, height) }
}

extension Aseprite.PropertyValue {
  /// The value the way Aseprite's Lua API (and so meta.json) presents it.
  var json: JSON {
    switch self {
    case .bool(let value): .bool(value)
    case .int8(let value): .number(Double(value))
    case .uint8(let value): .number(Double(value))
    case .int16(let value): .number(Double(value))
    case .uint16(let value): .number(Double(value))
    case .int32(let value): .number(Double(value))
    case .uint32(let value): .number(Double(value))
    case .int64(let value): .number(Double(value))
    case .uint64(let value): .number(Double(Int64(bitPattern: value)))  // Lua integers are signed.
    case .fixed(let value): .number(value.doubleValue)
    case .float(let value): .number(Double(value))
    case .double(let value): .number(value)
    case .string(let value): .string(value)
    case .point(let value): .object(["point": .numbers(value.x, value.y)])
    case .size(let value): .object(["size": .numbers(value.width, value.height)])
    case .rect(let value): .object(["rect": value.json])
    case .vector(let values): values.isEmpty ? .object([:]) : .array(values.map(\.json))
    case .properties(let map): .object(map.mapValues(\.json))
    case .uuid(let value): .object(["uuid": .string(value.description)])
    }
  }
}

extension Aseprite.UserData {
  /// User data as meta.json records it: empty text and a clear color when unset, user properties only.
  var json: JSON {
    .object([
      "text": .string(text ?? ""),
      "color": (color ?? .clear).json,
      "properties": .object(userProperties.mapValues(\.json)),
    ])
  }
}

extension URL {
  /// The path in the platform's native form (a drive letter and backslashes on Windows).
  var nativePath: String {
    withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? path
  }
}

/// Guards the parameterized tests against silently running with no cases.
struct FixtureTests {
  @Test func everyFixtureIsFound() {
    #expect(Fixture.all.count == 52)
    #expect(InflateTests.Vector.all.count == 11)
  }
}
