import Foundation
import Testing

@testable import Aseprite

/// Hostile inputs built in memory: each must decode (or fail) quickly, within bounded memory, and render
/// on a 512 KB stack. Time limits are generous; before the fixes they guard, these took 30 s or more.
struct AdversarialTests {
  private static let red: [UInt8] = [255, 0, 0, 255]

  @Test(arguments: [UInt32(1), 3])
  func nestingAtTheLimitRendersOnASmallStack(flags: UInt32) throws {
    let sprite = try Aseprite(bytes: nested(depth: Aseprite.maximumLayerDepth, flags: flags))
    let pixel = onSmallStack { sprite.renderFrame(0)[0, 0] }
    #expect(pixel == Aseprite.Color(r: 255, g: 0, b: 0, a: 255))
  }

  @Test func nestingPastTheLimitIsRejected() {
    let depth = Aseprite.maximumLayerDepth + 1
    let error = #expect(throws: AsepriteError.self) { try Aseprite(bytes: nested(depth: depth, flags: 3)) }
    guard case .invalidValue(field: "layer nesting depth", value: depth, offset: _) = error else {
      Issue.record("unexpected error \(String(describing: error))")
      return
    }
  }

  @Test func propertyNestingIsLimitedAndParsesOnASmallStack() throws {
    let deepest = try Aseprite(bytes: userDataFile(properties: map(nesting: 128)))
    #expect(deepest.warnings.isEmpty)
    let decoded = onSmallStack { try? Aseprite(bytes: userDataFile(properties: map(nesting: 128))) }
    #expect(decoded != nil)

    let tooDeep = try Aseprite(bytes: userDataFile(properties: map(nesting: 129)))
    #expect(tooDeep.warnings.map(\.message) == ["malformed user data properties were skipped"])
    #expect(tooDeep.userData.properties.isEmpty)
  }

  @Test func hugeCountsStopAtTheEndOfTheChunk() throws {
    let everything = 0xFFFF_FFFF
    let slice: TestFile.Chunk = (
      0x2022, TestFile.dword(everything) + TestFile.dword(0) + TestFile.dword(0) + TestFile.string("s")
    )
    let slices: TestFile.Chunk = (0x2021, TestFile.dword(everything) + [UInt8](repeating: 0, count: 8))
    var file = TestFile()
    file.frames = [[slice, slices]]
    let bytes = file.bytes
    try expectQuick { try Aseprite(bytes: bytes) }

    let manyMaps = TestFile.dword(everything)
    let manyProperties = TestFile.dword(1) + TestFile.dword(0) + TestFile.dword(everything)
    let nestedCounts =
      TestFile.dword(1) + TestFile.dword(0) + TestFile.dword(everything) + TestFile.string("")
      + TestFile.word(0x12) + TestFile.dword(everything)
    for properties in [manyMaps, manyProperties, nestedCounts] {
      let bytes = userDataFile(properties: properties)
      try expectQuick { try Aseprite(bytes: bytes) }
    }
  }

  @Test func manyCelsDecodeInLinearTime() throws {
    let count = 20_000
    var file = TestFile()
    file.frames = [
      (0..<count).map { _ in TestFile.layer() } + (0..<count).map { TestFile.rawCel(layer: $0, pixels: Self.red) }
    ]
    let bytes = file.bytes
    let sprite = try expectQuick { try Aseprite(bytes: bytes) }
    #expect(sprite.frames[0].cels.count == count)
    _ = try expectQuick { sprite.renderFrame(0) }
  }

  @Test func linkChainsAreStoredPointingAtTheirSource() throws {
    let count = 20_000
    var file = TestFile()
    file.frames = [[TestFile.layer(), TestFile.rawCel(layer: 0, pixels: Self.red)]]
    file.frames += (1..<count).map { [TestFile.linkedCel(layer: 0, frame: $0 - 1)] }
    let bytes = file.bytes
    let sprite = try expectQuick { try Aseprite(bytes: bytes) }
    #expect(sprite.frames[count - 1].cels.first?.content == .linked(frame: 0))
    #expect(sprite.renderFrame(count - 1)[0, 0] == Aseprite.Color(r: 255, g: 0, b: 0, a: 255))
  }

  @Test func oldPalettesNeverGrow() throws {
    let packets = 2000
    var payload = TestFile.word(packets)
    for _ in 0..<packets {
      payload += [255, 1, 1, 2, 3]
    }
    var file = TestFile()
    file.frames = [[(0x0004, payload)]]
    let sprite = try Aseprite(bytes: file.bytes)
    #expect(sprite.palettes.map(\.entries.count) == [256])
    #expect(sprite.warnings.map(\.message) == ["palette entries past the palette size were skipped"])
  }

  @Test func impossibleCelSizesAreSkippedWithoutAllocating() throws {
    var file = TestFile()
    let data = [UInt8](repeating: 0, count: 16)
    file.frames = [[TestFile.layer(), TestFile.compressedCel(layer: 0, width: 65535, height: 4000, data: data)]]
    let bytes = file.bytes
    let sprite = try expectQuick { try Aseprite(bytes: bytes) }
    #expect(sprite.frames[0].cels.isEmpty)
    #expect(sprite.warnings.map(\.message) == ["cel image data is too short for its size; cel skipped"])
  }

  @Test func sliceRenderingClipsBoundsFromTheFile() throws {
    var file = TestFile()
    file.width = 4
    file.height = 3
    file.frames = [[TestFile.layer(), TestFile.rawCel(layer: 0, pixels: Self.red)]]
    let sprite = try Aseprite(bytes: file.bytes)
    let huge = Aseprite.Slice(
      name: "huge",
      keys: [Aseprite.Slice.Key(frame: 0, bounds: Aseprite.Rect(x: -5, y: 1, width: Int(Int32.max), height: 9))]
    )
    let images = sprite.renderFrames(0...0, slice: huge)
    #expect(images.map(\.width) == [4] && images.map(\.height) == [2])
    let negative = Aseprite.Slice(
      name: "negative",
      keys: [Aseprite.Slice.Key(frame: 0, bounds: Aseprite.Rect(x: 1, y: 1, width: -1, height: -1))]
    )
    #expect(sprite.renderFrames(0...0, slice: negative).map(\.pixels.count) == [0])
    #expect(sprite.renderFrames(5...9).isEmpty)
    #expect(sprite.renderFrames(-3...0).count == 1)
  }

  // MARK: - Helpers

  /// A file whose only image layer sits inside `depth` nested groups.
  private func nested(depth: Int, flags: UInt32) -> [UInt8] {
    var file = TestFile()
    file.flags = flags
    var chunks = (0..<depth).map { TestFile.layer("g", type: 1, level: $0) }
    chunks.append(TestFile.layer("l", level: depth))
    chunks.append(TestFile.rawCel(layer: depth, pixels: Self.red))
    file.frames = [chunks]
    return file.bytes
  }

  /// A property map with `nesting` maps nested inside it.
  private func map(nesting: Int) -> [UInt8] {
    var map = TestFile.dword(0)
    for _ in 0..<nesting {
      map = TestFile.dword(1) + TestFile.string("") + TestFile.word(0x12) + map
    }
    return TestFile.dword(1) + TestFile.dword(0) + map
  }

  /// A file whose sprite user data holds `properties` (the part after the properties size field).
  private func userDataFile(properties: [UInt8]) -> [UInt8] {
    var file = TestFile()
    file.frames = [[(0x2020, TestFile.dword(4) + TestFile.dword(4 + properties.count) + properties)]]
    return file.bytes
  }

  /// Runs `body` on a thread with a 512 KB stack, the default for secondary threads on Apple platforms.
  private func onSmallStack<T: Sendable>(_ body: @escaping @Sendable () -> T) -> T {
    let result = ResultBox<T>()
    let thread = Thread {
      result.value = body()
      result.done.signal()
    }
    thread.stackSize = 512 * 1024
    thread.start()
    result.done.wait()
    guard let value = result.value else { preconditionFailure("the thread produced no result") }
    return value
  }

  /// Runs `body`, expecting it to take well under the time the unfixed code needed. Build inputs outside
  /// `body`: only the code under test should be timed.
  @discardableResult
  private func expectQuick<T>(_ body: () throws -> T) throws -> T {
    let start = ContinuousClock.now
    let value = try body()
    let elapsed = ContinuousClock.now - start
    #expect(elapsed < .seconds(5), "took \(elapsed)")
    return value
  }
}

/// Carries a value out of a thread; the semaphore orders the write before the read.
private final class ResultBox<T: Sendable>: @unchecked Sendable {
  var value: T?
  let done = DispatchSemaphore(value: 0)
}
