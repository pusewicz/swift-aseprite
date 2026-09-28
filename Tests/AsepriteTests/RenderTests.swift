import Foundation
import Testing

@testable import Aseprite

/// Every frame of every fixture must match Aseprite's own rendering byte for byte.
struct RenderTests {
  @Test(arguments: Fixture.all)
  func matchesAseprite(_ fixture: Fixture) throws {
    let sprite = try fixture.decode()
    for frame in sprite.frames.indices {
      let expected = try fixture.frame(frame)
      let actual = sprite.renderFrame(frame).pixels.flatMap { [$0.r, $0.g, $0.b, $0.a] }
      #expect(
        actual == expected,
        "frame \(frame): \(mismatch(actual, expected, width: sprite.width))"
      )
    }
  }

  @Test func compositeGroupsOverrideMatchesFlatRendering() throws {
    let composed = try Fixture.named("Features/groups_composed").decode()
    let flat = Fixture.named("Features/groups_flat")
    let frames = composed.renderAllFrames(options: .init(compositeGroups: false))
    for (index, image) in frames.enumerated() {
      #expect(image.pixels.flatMap { [$0.r, $0.g, $0.b, $0.a] } == (try flat.frame(index)))
    }
  }

  @Test func layerFilterReplacesVisibility() throws {
    let sprite = try Fixture.named("Features/rgba_basic").decode()
    let onlyHidden = sprite.renderFrame(0, options: .init(layerFilter: { $0.name == "hidden" }))
    #expect(onlyHidden.pixels.allSatisfy { $0 == Aseprite.Color(r: 255, g: 0, b: 0, a: 255) })
    let nothing = sprite.renderFrame(0, options: .init(layerFilter: { _ in false }))
    #expect(nothing.pixels.allSatisfy { $0 == .clear })
  }

  @Test func renderFramesMatchesRenderFrame() throws {
    let sprite = try Fixture.named("Real/girl").decode()
    #expect(sprite.renderAllFrames() == sprite.frames.indices.map { sprite.renderFrame($0) })
    #expect(sprite.renderFrames(1...2) == [sprite.renderFrame(1), sprite.renderFrame(2)])
  }

  @Test func sliceRenderingCropsAndPadsWithTransparency() throws {
    let sprite = try Fixture.named("Features/rgba_basic").decode()
    let full = sprite.renderFrame(0)
    let rect = Aseprite.Rect(x: -2, y: 3, width: 6, height: 4)
    let cropped = try #require(sprite.renderFrames(0...0, croppedTo: rect).first)
    #expect(cropped.width == 6 && cropped.height == 4)
    for y in 0..<4 {
      for x in 0..<6 {
        let expected = x < 2 ? Aseprite.Color.clear : full[x - 2, y + 3]
        #expect(cropped[x, y] == expected)
      }
    }
  }

  @Test func framesOutsideTheSpriteAreTransparent() throws {
    let sprite = try Fixture.named("Real/heart").decode()
    #expect(sprite.renderFrame(sprite.frames.count).pixels.allSatisfy { $0 == .clear })
    #expect(sprite.renderFrame(-1).pixels.allSatisfy { $0 == .clear })
  }

  private func mismatch(_ actual: [UInt8], _ expected: [UInt8], width: Int) -> String {
    guard actual.count == expected.count else { return "size \(actual.count) != \(expected.count)" }
    let differing = stride(from: 0, to: actual.count, by: 4).filter { actual[$0..<$0 + 4] != expected[$0..<$0 + 4] }
    guard let first = differing.first else { return "equal" }
    let pixel = first / 4
    return "\(differing.count) pixels differ, first at (\(pixel % width), \(pixel / width)): "
      + "got \(Array(actual[first..<first + 4])), expected \(Array(expected[first..<first + 4]))"
  }
}
