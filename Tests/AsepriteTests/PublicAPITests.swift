import Aseprite
import Foundation
import Testing

/// Uses the package the way a client does: plain `import`, public API only.
struct PublicAPITests {
  private let girl = Fixture.root.appendingPathComponent("Real/girl.aseprite").nativePath

  @Test func typicalClientFlow() throws {
    let sprite = try Aseprite(contentsOf: girl)
    #expect(sprite.warnings.isEmpty)
    for tag in sprite.tags {
      let frames = sprite.renderFrames(tag.frames)
      #expect(frames.count == tag.frames.count)
      #expect(frames.allSatisfy { $0.width == sprite.width && $0.height == sprite.height })
    }
    for (index, layer) in sprite.layers.enumerated() where !layer.isGroup {
      for frame in sprite.frames.indices {
        guard let cel = sprite.cel(layer: index, frame: frame) else { continue }
        #expect(cel.drawPosition == cel.position)  // No precise bounds in this file.
        if case .linked = cel.content {
          Issue.record("cel(layer:frame:) must resolve links")
        }
      }
    }
  }

  @Test func textureUploadLayout() throws {
    #expect(MemoryLayout<Aseprite.Color>.size == 4)
    #expect(MemoryLayout<Aseprite.Color>.stride == 4)
    #expect(MemoryLayout<Aseprite.Color>.alignment == 1)
    let image = try Aseprite(contentsOf: girl).renderFrame(0)
    let bytes = image.pixels.withUnsafeBytes { Array($0) }
    #expect(bytes.count == image.width * image.height * 4)
    #expect(Array(bytes[0..<4]) == [image.pixels[0].r, image.pixels[0].g, image.pixels[0].b, image.pixels[0].a])
  }

  @Test func slicesAndTags() throws {
    let sprite = try Aseprite(contentsOf: Fixture.root.appendingPathComponent("Real/9_slice.ase").nativePath)
    let slice = try #require(sprite.slices.first)
    let key = try #require(slice.key(forFrame: 0))
    let images = sprite.renderFrames(0...0, slice: slice)
    #expect(images.first?.width == key.bounds.width && images.first?.height == key.bounds.height)
    #expect(Aseprite.Tag(name: "backwards", from: 3, to: 1).frames == 1...3)
  }
}
