import Foundation
import Testing

@testable import Aseprite

/// The decoded model must match what Aseprite itself decodes (meta.json, exported through its Lua API).
struct DecoderTests {
  @Test(arguments: Fixture.all)
  func matchesAsepriteModel(_ fixture: Fixture) throws {
    let sprite = try fixture.decode()
    let meta = try fixture.meta()

    #expect(sprite.width == meta["width"].int)
    #expect(sprite.height == meta["height"].int)
    #expect(colorModeNumber(sprite.colorMode) == meta["colorMode"].int)
    #expect(Int(sprite.transparentIndex) == meta["transparentColor"].int)
    #expect(Int(sprite.flags.rawValue) == meta["headerFlags"].int)
    #expect(JSON.numbers(sprite.pixelRatio.width, sprite.pixelRatio.height) == meta["pixelRatio"])
    #expect(sprite.grid.json == meta["gridBounds"])
    #expect(sprite.userData.json == meta["userData"])
    #expect(sprite.frames.map(\.duration) == meta["frames"].array.map { $0["duration"].int ?? -1 })

    try checkLayers(sprite, meta["layers"].array)
    checkTags(sprite, meta["tags"].array)
    checkSlices(sprite, meta["slices"].array)
    checkPalettes(sprite, meta["palettes"].array)
    checkTilesets(sprite, meta["tilesets"].array)
  }

  private func checkLayers(_ sprite: Aseprite, _ layers: [JSON]) throws {
    try #require(sprite.layers.count == layers.count)
    for (index, (layer, expected)) in zip(sprite.layers, layers).enumerated() {
      let label = "layer \(index) \(layer.name)"
      #expect(layer.name == expected["name"].string, "\(label)")
      #expect(kindName(layer.kind) == expected["kind"].string, "\(label)")
      #expect(layer.parent == expected["parent"].int, "\(label)")
      #expect(depth(of: index, in: sprite) == expected["childLevel"].int, "\(label)")
      #expect(layer.isVisible == expected["visible"].bool, "\(label)")
      #expect(layer.isEditable == expected["editable"].bool, "\(label)")
      #expect(layer.isBackground == expected["background"].bool, "\(label)")
      #expect(layer.isReference == expected["reference"].bool, "\(label)")
      // Lua reports no blend mode or opacity for groups that are not composited.
      if expected["blendMode"] != .null {
        #expect(Int(layer.blendMode.rawValue) == expected["blendMode"].int, "\(label)")
        #expect(Int(layer.opacity) == expected["opacity"].int, "\(label)")
      }
      #expect(layer.uuid?.description == expected["uuid"].string, "\(label)")
      #expect(layer.userData.json == expected["userData"], "\(label)")

      let expectedCels = expected["cels"].array
      let actualFrames = sprite.frames.indices.filter { sprite.cel(layer: index, frame: $0) != nil }
      #expect(actualFrames == expectedCels.compactMap { $0["frame"].int }, "\(label) cel frames")
      for expectedCel in expectedCels {
        guard let frame = expectedCel["frame"].int, let cel = sprite.cel(layer: index, frame: frame) else {
          continue
        }
        let celLabel = "\(label) frame \(frame)"
        #expect(JSON.numbers(cel.drawPosition.x, cel.drawPosition.y) == expectedCel["position"], "\(celLabel)")
        #expect(Int(cel.opacity) == expectedCel["opacity"].int, "\(celLabel)")
        #expect(cel.zIndex == expectedCel["zIndex"].int, "\(celLabel)")
        #expect(contentSize(cel.content) == expectedCel["size"], "\(celLabel)")
        #expect(cel.userData.json == expectedCel["userData"], "\(celLabel)")
      }
    }
  }

  private func checkTags(_ sprite: Aseprite, _ tags: [JSON]) {
    #expect(sprite.tags.count == tags.count)
    for (tag, expected) in zip(sprite.tags, tags) {
      #expect(tag.name == expected["name"].string)
      #expect(tag.from == expected["from"].int, "\(tag.name)")
      #expect(tag.to == expected["to"].int, "\(tag.name)")
      #expect(Int(tag.direction.rawValue) == expected["direction"].int, "\(tag.name)")
      #expect(tag.repeatCount == expected["repeatCount"].int, "\(tag.name)")
      #expect(tag.color.json == expected["color"], "\(tag.name)")
      #expect(tag.userData.json["text"] == expected["userData"]["text"], "\(tag.name)")
      #expect(tag.userData.json["properties"] == expected["userData"]["properties"], "\(tag.name)")
    }
  }

  private func checkSlices(_ sprite: Aseprite, _ slices: [JSON]) {
    // Aseprite inserts each loaded slice at the front (Slices::add), so its order is the reverse of the file's.
    #expect(sprite.slices.count == slices.count)
    for (slice, expected) in zip(sprite.slices, slices.reversed()) {
      let key = slice.key(forFrame: 0)
      #expect(slice.name == expected["name"].string)
      #expect((key?.bounds.json ?? .null) == expected["bounds"], "\(slice.name)")
      let center = key?.center.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
      #expect((center?.json ?? .null) == expected["center"], "\(slice.name)")
      #expect((key?.pivot.map { JSON.numbers($0.x, $0.y) } ?? .null) == expected["pivot"], "\(slice.name)")
      #expect(slice.userData.json["text"] == expected["userData"]["text"], "\(slice.name)")
      #expect(slice.userData.json["properties"] == expected["userData"]["properties"], "\(slice.name)")
      if slice.userData.color != nil {
        #expect(slice.userData.json["color"] == expected["userData"]["color"], "\(slice.name)")
      }
    }
  }

  private func checkPalettes(_ sprite: Aseprite, _ palettes: [JSON]) {
    // When an RGB file has only an all-black palette, Aseprite builds one from the pixels on load
    // (FileOp::postLoad); that palette is not in the file.
    let black = Aseprite.Color(r: 0, g: 0, b: 0, a: 255)
    if sprite.colorMode == .rgba, sprite.palettes.count == 1,
      sprite.palettes[0].entries.allSatisfy({ $0.color == black })
    {
      return
    }
    #expect(sprite.palettes.count == palettes.count)
    for (palette, expected) in zip(sprite.palettes, palettes) {
      #expect(palette.frame == expected["frame"].int)
      #expect(JSON.array(palette.entries.map(\.color.json)) == expected["colors"], "palette at \(palette.frame)")
    }
  }

  private func checkTilesets(_ sprite: Aseprite, _ tilesets: [JSON]) {
    #expect(sprite.tilesets.count == tilesets.count)
    for (tileset, expected) in zip(sprite.tilesets, tilesets) {
      #expect(tileset.name == expected["name"].string)
      #expect(JSON.numbers(tileset.tileSize.width, tileset.tileSize.height) == expected["tileSize"])
      #expect(tileset.tileCount == expected["tileCount"].int, "\(tileset.name)")
      #expect(tileset.baseIndex == expected["baseIndex"].int, "\(tileset.name)")
      #expect(tileset.userData.json == expected["userData"], "\(tileset.name)")
      let tiles = (0..<tileset.tileCount).map { index in
        tileset.tileUserData.indices.contains(index) ? tileset.tileUserData[index] : Aseprite.UserData()
      }
      // Lua reports the tileset's own properties for the empty tile 0; compare the rest.
      #expect(
        JSON.array(tiles.dropFirst().map(\.json)) == .array(Array(expected["tiles"].array.dropFirst())),
        "\(tileset.name)"
      )
      #expect(tiles.first?.json["text"] == expected["tiles"][0]["text"], "\(tileset.name)")
    }
  }

  private func colorModeNumber(_ mode: Aseprite.ColorMode) -> Int {
    switch mode {
    case .rgba: 0
    case .grayscale: 1
    case .indexed: 2
    }
  }

  private func kindName(_ kind: Aseprite.Layer.Kind) -> String {
    switch kind {
    case .image: "image"
    case .group: "group"
    case .tilemap: "tilemap"
    }
  }

  private func depth(of layer: Int, in sprite: Aseprite) -> Int {
    var depth = 0
    var parent = sprite.layers[layer].parent
    while let group = parent {
      depth += 1
      parent = sprite.layers[group].parent
    }
    return depth
  }

  private func contentSize(_ content: Aseprite.Cel.Content) -> JSON {
    switch content {
    case .image(let pixels): .numbers(pixels.width, pixels.height)
    case .tilemap(let tilemap): .numbers(tilemap.width, tilemap.height)
    case .linked: .null
    }
  }
}
