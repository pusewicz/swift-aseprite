import Foundation
import Testing

@testable import Aseprite

/// The inflater against zlib-produced vectors covering every block type (see regenerate.rb).
struct InflateTests {
  struct Vector: Sendable, CustomTestStringConvertible {
    let name: String
    var testDescription: String { name }

    static let directory = Fixture.root.appendingPathComponent("Inflate")
    static let all: [Vector] = Fixture.fileNames(in: directory)
      .filter { $0.hasSuffix(".zz") }.sorted().map { Vector(name: ($0 as NSString).deletingPathExtension) }

    func load() throws -> (compressed: [UInt8], expected: [UInt8]) {
      (
        [UInt8](try Data(contentsOf: Self.directory.appendingPathComponent("\(name).zz"))),
        [UInt8](try Data(contentsOf: Self.directory.appendingPathComponent("\(name).bin")))
      )
    }
  }

  @Test(arguments: Vector.all)
  func decompresses(_ vector: Vector) throws {
    let (compressed, expected) = try vector.load()
    #expect(try Inflate.zlib(compressed[...], count: expected.count) == expected)
  }

  @Test(arguments: Vector.all)
  func rejectsEveryTruncation(_ vector: Vector) throws {
    let (compressed, expected) = try vector.load()
    let step = max(1, compressed.count / 500)
    for length in stride(from: 0, to: compressed.count, by: step) {
      #expect(throws: Inflate.Failure.self) {
        try Inflate.zlib(compressed[..<length], count: expected.count)
      }
    }
  }

  @Test(arguments: Vector.all)
  func survivesCorruption(_ vector: Vector) throws {
    let (compressed, expected) = try vector.load()
    var random = SplitMix64(seed: 7)
    for _ in 0..<300 {
      var corrupted = compressed
      let index = Int(random.next() % UInt64(corrupted.count))
      corrupted[index] ^= UInt8(truncatingIfNeeded: random.next() | 1)
      // Must either fail cleanly or (for flips in ignored bits) still produce the right bytes.
      if let output = try? Inflate.zlib(corrupted[...], count: expected.count) {
        #expect(output == expected)
      }
    }
  }

  @Test func rejectsWrongSizes() throws {
    let (compressed, expected) = try Vector(name: "dynamic").load()
    #expect(throws: Inflate.Failure.outputOverflow) {
      try Inflate.zlib(compressed[...], count: expected.count - 1)
    }
    #expect(throws: Inflate.Failure.outputTooShort) {
      try Inflate.zlib(compressed[...], count: expected.count + 1)
    }
    // More output than DEFLATE can possibly produce from this input is rejected before allocating.
    #expect(throws: Inflate.Failure.outputTooShort) {
      try Inflate.zlib(compressed[...], count: compressed.count * Inflate.maximumRatio + 1)
    }
  }

  @Test func rejectsStructuralErrors() throws {
    let (compressed, expected) = try Vector(name: "fixed").load()
    var header = compressed
    header[1] ^= 0x01
    #expect(throws: Inflate.Failure.invalidHeader) {
      try Inflate.zlib(header[...], count: expected.count)
    }

    var checksum = compressed
    checksum[checksum.count - 1] ^= 0xFF
    #expect(throws: Inflate.Failure.checksumMismatch) {
      try Inflate.zlib(checksum[...], count: expected.count)
    }

    // BFINAL = 1, BTYPE = 3.
    #expect(throws: Inflate.Failure.invalidBlockType) {
      try Inflate.zlib([0x78, 0x9C, 0x07][...], count: 1)
    }
    // A stored block whose NLEN is not the complement of LEN.
    #expect(throws: Inflate.Failure.invalidStoredLength) {
      try Inflate.zlib([0x78, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x41][...], count: 1)
    }
  }

  @Test func adler32() {
    #expect(Inflate.adler32(Array("Wikipedia".utf8)) == 0x11E6_0398)
    #expect(Inflate.adler32([]) == 1)
    #expect(Inflate.adler32([UInt8](repeating: 0xFF, count: 100_000)) == 0x149A_302C)
  }
}

/// A small deterministic random number generator for reproducible corruption tests.
struct SplitMix64 {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
