import Foundation
import Testing

@testable import Aseprite

/// Malformed input must produce an error or a usable document, never a crash. A crash here takes the
/// whole test process down, so these tests pass by finishing.
struct MalformedInputTests {
  /// Largest canvas rendered after decoding a mutated file; a mutated header can legitimately ask for
  /// a 65535×65535 canvas, which is an allocation problem, not a decoding one.
  private static let maximumRenderedPixels = 1 << 20
  /// Mutated copies per fixture; debug builds are ~20× slower, so they run fewer.
  #if DEBUG
  private static let mutations = 100
  #else
  private static let mutations = 1000
  #endif

  @Test(arguments: Fixture.all)
  func truncatedFiles(_ fixture: Fixture) throws {
    let bytes = try fixture.bytes()
    // Every prefix of small files; about 2000 evenly spread prefixes of larger ones.
    let step = max(1, bytes.count / 2000)
    for length in stride(from: 0, to: bytes.count, by: step) {
      exercise(Array(bytes[..<length]))
    }
  }

  @Test(arguments: Fixture.all)
  func corruptedBytes(_ fixture: Fixture) throws {
    let bytes = try fixture.bytes()
    var random = SplitMix64(seed: UInt64(bytes.count))
    for _ in 0..<Self.mutations {
      var corrupted = bytes
      for _ in 0..<(1 + Int(random.next() % 3)) {
        let index = Int(random.next() % UInt64(corrupted.count))
        corrupted[index] = UInt8(truncatingIfNeeded: random.next())
      }
      exercise(corrupted)
    }
  }

  @Test func rejectsNonAsepriteData() {
    #expect(throws: AsepriteError.truncated(offset: 0)) { try Aseprite(bytes: [UInt8]()) }
    #expect(throws: AsepriteError.invalidMagic(offset: 4, found: 0)) {
      try Aseprite(bytes: [UInt8](repeating: 0, count: 128))
    }
  }

  @Test func reportsUnreadableFiles() {
    let error = #expect(throws: AsepriteError.self) { try Aseprite(contentsOf: "/nonexistent.aseprite") }
    guard case .unreadableFile(let path, let reason) = error else {
      Issue.record("unexpected error \(String(describing: error))")
      return
    }
    #expect(path == "/nonexistent.aseprite" && !reason.isEmpty)
  }

  @Test func loadsFromDisk() throws {
    let fixture = Fixture.named("Real/girl")
    #expect(try Aseprite(contentsOf: fixture.url.nativePath) == fixture.decode())
  }

  private func exercise(_ bytes: [UInt8]) {
    guard let sprite = try? Aseprite(bytes: bytes) else { return }
    guard sprite.width * sprite.height <= Self.maximumRenderedPixels else { return }
    for frame in sprite.frames.indices.prefix(4) {
      _ = sprite.renderFrame(frame)
    }
    for layer in sprite.layers.indices {
      _ = sprite.cel(layer: layer, frame: 0)
    }
    for tag in sprite.tags.prefix(4) {
      _ = sprite.renderFrames(tag.frames.clamped(to: tag.frames.lowerBound...tag.frames.lowerBound + 3))
    }
    for slice in sprite.slices.prefix(4) {
      _ = slice.key(forFrame: 0)
      _ = sprite.renderFrames(0...1, slice: slice)
    }
    _ = sprite.renderFrames(0...1, options: .init(compositeGroups: !sprite.flags.contains(.compositeGroups)))
  }
}
