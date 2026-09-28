import Foundation
import Testing

@testable import Aseprite

/// Details of the byte-built fixtures that Aseprite's Lua API cannot show (see regenerate.rb).
struct SyntheticFileTests {
  private func sprite(_ name: String) throws -> Aseprite {
    try Fixture.named("Synthetic/\(name)").decode()
  }

  @Test func everyPropertyType() throws {
    let sprite = try sprite("properties_all")
    #expect(sprite.userData.text == "sprite")
    #expect(sprite.userData.color == Aseprite.Color(r: 1, g: 2, b: 3, a: 4))
    #expect(
      sprite.externalFiles == [Aseprite.ExternalFile(id: 5, kind: .extensionProperties, name: "pusewicz/ext")]
    )

    let uuid = Aseprite.UUID(bytes: (0..<16).map { UInt8($0 * 7) })
    let expected: [String: Aseprite.PropertyValue] = [
      "bool": .bool(true), "int8": .int8(-8), "uint8": .uint8(200), "int16": .int16(-1600),
      "uint16": .uint16(60000), "int32": .int32(-2_000_000), "uint32": .uint32(4_000_000_000),
      "int64": .int64(-9_000_000_000), "uint64": .uint64(18_000_000_000_000_000_000),
      "fixed": .fixed(Aseprite.Fixed(rawValue: 0x18000)), "float": .float(1.5), "double": .double(-2.25),
      "string": .string("hi"), "point": .point(Aseprite.Point(x: -1, y: 2)),
      "size": .size(Aseprite.Size(width: 3, height: 4)),
      "rect": .rect(Aseprite.Rect(x: 5, y: 6, width: 7, height: 8)),
      "vector": .vector([.int32(1), .int32(-2), .int32(3)]),
      "mixed": .vector([.string("a"), .bool(false), .float(0.5)]),
      "map": .properties(["inner": .properties(["deep": .uint8(1)])]), "uuid": .uuid(uuid),
    ]
    #expect(sprite.userData.properties[0] == expected)
    #expect(sprite.userData.properties[5] == ["from_extension": .uint16(42)])
    #expect(uuid.description == "00070e15-1c23-2a31-383f-464d545b6269")
    #expect(Aseprite.Fixed(rawValue: 0x18000).doubleValue == 1.5)
  }

  @Test func skippedAndInformationalChunks() throws {
    let sprite = try sprite("skipped_chunks")
    #expect(sprite.colorProfile == Aseprite.ColorProfile(kind: .icc(Array("not really an icc profile".utf8))))
    #expect(sprite.externalFiles.map(\.kind) == [.palette, .tileset, .extensionProperties])
    #expect(sprite.warnings.map(\.message) == ["skipped unknown chunk type 0x7777"])
    #expect(sprite.layers.map(\.name) == ["l"])

    let cel = try #require(sprite.frames[0].cels.first)
    #expect(
      cel.extra
        == Aseprite.Cel.Extra(
          x: Aseprite.Fixed(rawValue: 0x18000),
          y: Aseprite.Fixed(rawValue: -0x8000),
          width: Aseprite.Fixed(rawValue: 0x40000),
          height: Aseprite.Fixed(rawValue: 0x30000)
        )
    )
    #expect(cel.drawPosition == Aseprite.Point(x: 1, y: 0))
    #expect(cel.userData.text == "cel text")
    #expect(cel.userData.properties[3] == ["ext": .string("extension")])
  }

  @Test func linkedCelsAndDroppedCels() throws {
    let sprite = try sprite("linked_cels")
    #expect(
      sprite.warnings.map(\.message) == [
        "cel on group layer 1; cel skipped",
        "cel references missing layer 9; cel skipped",
        "empty cel; cel skipped",
        "linked cel points to frame 5, which has no cel on this layer; cel skipped",
        "linked cel points to frame 0, which has no cel on this layer; cel skipped",
      ]
    )
    #expect(sprite.frames[1].cels.first?.content == .linked(frame: 0))
    // A true link shares the source's data, so user data written after it lands on the source.
    #expect(sprite.frames[0].cels.first?.userData.text == "linked")
    #expect(sprite.cel(layer: 0, frame: 1)?.userData.text == "linked")
    // A link with its own position and opacity is loaded as an independent copy.
    let copy = try #require(sprite.frames[2].cels.first)
    #expect(copy.position == Aseprite.Point(x: 2, y: 0) && copy.opacity == 128 && copy.zIndex == 1)
    #expect(copy.content == sprite.frames[0].cels.first?.content)
    #expect(copy.userData == Aseprite.UserData())
    #expect(sprite.frames[3].cels.isEmpty)
  }

  @Test func chunkCountsAndDurations() throws {
    let sprite = try sprite("chunk_counts")
    #expect(sprite.frames.map(\.duration) == [77, 77, 33])
    // The 16-bit count (1) wins over the 32-bit one (5) unless it is saturated, as in Aseprite.
    #expect(sprite.frames[1].cels.count == 1)
  }

  @Test func tagUserDataAndColors() throws {
    let tags = try sprite("tags_user_data").tags
    #expect(tags.map(\.name) == ["a", "b", "c"])
    #expect(tags.map(\.direction) == [.forward, .forward, .pingPong])
    #expect(tags[0].color == Aseprite.Color(r: 10, g: 20, b: 30, a: 40))
    #expect(tags[1].color == .clear)  // User data without a color clears the deprecated one.
    #expect(tags[2].color == Aseprite.Color(r: 7, g: 8, b: 9, a: 255))
    #expect(tags.map(\.userData.text) == ["tag a", "tag b", nil])
    #expect(tags[2].repeatCount == 4)
  }

  @Test func oldFormatTilesets() throws {
    let sprite = try sprite("tileset_old")
    #expect(sprite.tilesets.map(\.tileCount) == [4, 3])
    #expect(sprite.tilesets.map(\.baseIndex) == [0, 1])
    guard case .tilemap(let a) = sprite.frames[0].cels[0].content,
      case .tilemap(let b) = sprite.frames[0].cels[1].content
    else {
      Issue.record("expected tilemaps")
      return
    }
    #expect(a.tiles == [Aseprite.Tile(index: 1), .empty, Aseprite.Tile(index: 3, flipX: true)])
    #expect(b.tiles == [Aseprite.Tile(index: 1), .empty, Aseprite.Tile(index: 2)])
    #expect(sprite.tileset(id: 7)?.name == "old_empty0")
  }

  @Test func unsupportedTileWidthsAreSkipped() throws {
    let sprite = try sprite("tilemap_bits")
    #expect(sprite.warnings.map(\.message) == ["16-bit tiles are not supported; cel skipped"])
    #expect(sprite.cel(layer: 0, frame: 0) == nil)
    #expect(sprite.cel(layer: 1, frame: 0) != nil)
  }

  @Test func palettesPerFrame() throws {
    let sprite = try sprite("palette_per_frame")
    #expect(sprite.palettes.map(\.frame) == [0, 1, 3])
    #expect(sprite.palette(forFrame: 2) == sprite.palettes[1])
    #expect(sprite.palettes[2].entries.count == 10)
    #expect(
      sprite.palettes[2].entries[9]
        == Aseprite.Palette.Entry(color: Aseprite.Color(r: 5, g: 6, b: 7, a: 8), name: "named")
    )
  }

  @Test func oldPaletteChunks() throws {
    let eightBit = try sprite("old_palette_4").palettes[0].entries.map(\.color)
    #expect(eightBit[0] == Aseprite.Color(r: 10, g: 20, b: 30, a: 255))
    #expect(eightBit[3] == Aseprite.Color(r: 0, g: 0, b: 0, a: 255))  // Packets skip relative to the last skip.
    #expect(eightBit[4] == Aseprite.Color(r: 0, g: 0, b: 200, a: 255))

    let sixBit = try sprite("old_palette_11").palettes[0].entries.map(\.color)
    #expect(sixBit[1] == Aseprite.Color(r: 203, g: 0, b: 0, a: 255))  // 200 / 4 = 50 → 50 << 2 | 50 >> 4.
  }

  @Test func layerFieldsFollowHeaderFlags() throws {
    let noOpacity = try sprite("no_opacity_flag").layers[1]
    #expect(noOpacity.opacity == 255 && noOpacity.blendMode == .screen)

    let background = try sprite("background_blend").layers[0]
    #expect(background.isBackground && background.blendMode == .normal && background.opacity == 255)

    let levels = try sprite("group_levels").layers
    #expect(levels.map(\.parent) == [nil, 0, 1, 0, nil])
  }

  @Test func corruptCelDataIsToleratedLikeAseprite() throws {
    let sprite = try sprite("corrupt_cels")
    #expect(
      sprite.warnings.map(\.message) == [
        "cel image data is corrupt; it was left zero-filled",
        "cel image data is corrupt; it was left zero-filled",
        "cel image data is longer than needed; the extra bytes were ignored",
        "cel image data is corrupt; it was left zero-filled",
      ]
    )
    let pixels = sprite.frames[0].cels.map { cel -> [UInt8] in
      guard case .image(let buffer) = cel.content else { return [] }
      return buffer.bytes
    }
    #expect(pixels == [[0, 0, 0, 0], [0, 0, 0, 0], [255, 0, 0, 255], [0, 0, 0, 0]])
  }

  @Test func droppedLayersKeepLaterIndicesAligned() throws {
    let sprite = try sprite("dropped_layers")
    #expect(sprite.layers.map(\.name) == ["a", "b"])
    #expect(sprite.frames[0].cels.map(\.layer) == [0, 1])
    #expect(sprite.frames[0].cels[0].userData.text == "a cel")
    #expect(
      sprite.warnings.map(\.message) == [
        "layer \"missing tileset\" uses missing tileset 9; layer skipped",
        "layer \"future\" has unknown type 7; layer skipped",
        "cel references missing layer 1; cel skipped",
      ]
    )
  }

  @Test func theFirstCelOfALayerWins() throws {
    let sprite = try sprite("duplicate_cels")
    #expect(sprite.frames[0].cels.count == 2)
    guard case .image(let first) = sprite.frames[0].cels[0].content else {
      Issue.record("expected an image cel")
      return
    }
    #expect(first.bytes == [255, 0, 0, 255])
    #expect(sprite.frames[0].cels[0].userData.text == nil)  // Went to the discarded second cel.
    #expect(
      sprite.warnings.map(\.message) == [
        "second cel for layer 0 in frame 0; cel skipped",
        "second cel for layer 1 in frame 0; cel skipped",
      ]
    )
  }

  @Test func layerUUIDs() throws {
    let sprite = try Fixture.named("Features/layer_uuids").decode()
    #expect(sprite.flags.contains(.layerUUIDs))
    #expect(sprite.layers.allSatisfy { $0.uuid?.bytes.count == 16 })
  }
}
