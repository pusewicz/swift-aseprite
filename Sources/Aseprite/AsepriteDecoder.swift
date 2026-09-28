/// Decodes the Aseprite file format into an ``Aseprite`` value.
///
/// Mirrors Aseprite's own decoder (src/dio/aseprite_decoder.cpp): what Aseprite silently repairs or
/// skips is repaired or skipped here too (and recorded as a warning), so a file renders the way it does
/// in Aseprite. Anything that would make Aseprite read out of bounds is an error instead.
struct AsepriteDecoder {
  private let bytes: [UInt8]
  private var sprite: Aseprite
  private var ignoreOldPalettes = false
  private var target = UserDataTarget.sprite
  private var lastCel: (frame: Int, index: Int)?
  private var previousLayer: Int?
  private var currentLevel = -1
  /// Model index of each layer chunk in file order; `nil` for layers Aseprite drops.
  private var fileLayers: [Int?] = []
  /// Nesting depth of each model layer (0 for top-level layers).
  private var layerDepths: [Int] = []
  /// For each frame, the index in `cels` of each layer's cel.
  private var celIndices: [[Int: Int]] = []

  /// Where the next User Data chunk goes.
  private enum UserDataTarget {
    case none
    case sprite
    case layer(Int)
    case cel(frame: Int, index: Int)
    case slice(Int)
    case tag(Int)
    case tileset(Int)
    case tile(tileset: Int, index: Int)
  }

  private enum ChunkType {
    static let oldPalette8 = UInt16(0x0004)
    static let oldPalette6 = UInt16(0x000B)
    static let layer = UInt16(0x2004)
    static let cel = UInt16(0x2005)
    static let celExtra = UInt16(0x2006)
    static let colorProfile = UInt16(0x2007)
    static let externalFiles = UInt16(0x2008)
    static let mask = UInt16(0x2016)
    static let path = UInt16(0x2017)
    static let tags = UInt16(0x2018)
    static let palette = UInt16(0x2019)
    static let userData = UInt16(0x2020)
    static let slices = UInt16(0x2021)
    static let slice = UInt16(0x2022)
    static let tileset = UInt16(0x2023)
  }

  /// The largest palette accepted; a corrupt size must not become a multi-gigabyte allocation.
  private static let maximumPaletteSize = 1 << 16
  /// The color Aseprite fills new palette entries with.
  private static let black = Aseprite.Palette.Entry(color: Aseprite.Color(r: 0, g: 0, b: 0, a: 255))
  /// Nesting limit for user-data properties, as in Aseprite.
  private static let maximumPropertyDepth = 128
  static let maximumLayerDepth = Aseprite.maximumLayerDepth

  init(bytes: [UInt8]) {
    self.bytes = bytes
    self.sprite = Aseprite(
      width: 0,
      height: 0,
      colorMode: .rgba,
      flags: [],
      transparentIndex: 0,
      colorCount: 0,
      pixelRatio: Aseprite.Size(width: 1, height: 1),
      grid: Aseprite.Rect(x: 0, y: 0, width: 0, height: 0)
    )
  }

  /// Decodes the whole file.
  mutating func decode() throws(AsepriteError) -> Aseprite {
    var reader = ByteReader(bytes)
    var header = try reader.take(128)
    let frameCount = try readHeader(&header)
    for frame in 0..<frameCount {
      try readFrame(&reader, frame: frame)
    }
    return sprite
  }

  // MARK: - Header and frames

  private mutating func readHeader(_ header: inout ByteReader) throws(AsepriteError) -> Int {
    try header.skip(4)  // File size.
    let magic = try header.u16()
    guard magic == 0xA5E0 else { throw .invalidMagic(offset: 4, found: magic) }
    let frameCount = Int(try header.u16())
    let width = Int(try header.u16())
    let height = Int(try header.u16())
    guard width >= 1 else { throw .invalidValue(field: "width", value: width, offset: 8) }
    guard height >= 1 else { throw .invalidValue(field: "height", value: height, offset: 10) }
    let depth = try header.u16()
    let colorMode: Aseprite.ColorMode
    switch depth {
    case 32: colorMode = .rgba
    case 16: colorMode = .grayscale
    case 8: colorMode = .indexed
    default: throw .invalidValue(field: "color depth", value: Int(depth), offset: 12)
    }
    let flags = Aseprite.HeaderFlags(rawValue: try header.u32())
    let speed = Int(try header.u16())
    try header.skip(8)
    let transparentIndex = try header.u8()
    try header.skip(3)
    let colorCount = Int(try header.u16())
    let pixelWidth = Int(try header.u8())
    let pixelHeight = Int(try header.u8())
    let gridX = Int(try header.i16())
    let gridY = Int(try header.i16())
    let gridWidth = Int(try header.u16())
    let gridHeight = Int(try header.u16())

    sprite.width = width
    sprite.height = height
    sprite.colorMode = colorMode
    sprite.flags = flags
    sprite.transparentIndex = colorMode == .indexed ? transparentIndex : 0
    sprite.colorCount = colorCount == 0 ? 256 : colorCount
    sprite.pixelRatio =
      pixelWidth == 0 || pixelHeight == 0
      ? Aseprite.Size(width: 1, height: 1) : Aseprite.Size(width: pixelWidth, height: pixelHeight)
    sprite.grid = Aseprite.Rect(x: gridX, y: gridY, width: gridWidth, height: gridHeight)
    sprite.frames = Array(repeating: Aseprite.Frame(duration: speed), count: frameCount)
    celIndices = Array(repeating: [:], count: frameCount)
    sprite.palettes = [Aseprite.Palette(frame: 0, entries: Array(repeating: Self.black, count: sprite.colorCount))]
    return frameCount
  }

  private mutating func readFrame(_ reader: inout ByteReader, frame: Int) throws(AsepriteError) {
    let start = reader.position
    let size = Int(try reader.u32())
    guard size >= 16 else { throw .invalidValue(field: "frame size", value: size, offset: start) }
    var body = try reader.bounded(to: start + size)
    let magic = try body.u16()
    if magic == 0xF1FA {
      let oldCount = try body.u16()
      let duration = Int(try body.u16())
      try body.skip(2)
      let newCount = try body.u32()
      // Aseprite only trusts the 32-bit count when the 16-bit one is saturated.
      let count = oldCount == 0xFFFF && UInt32(oldCount) < newCount ? Int(newCount) : Int(oldCount)
      if duration > 0 {
        sprite.frames[frame].duration = duration
      }
      for _ in 0..<count {
        try readChunk(&body, frame: frame)
      }
    } else {
      warn(at: start, "frame \(frame) has an invalid magic number and was skipped")
    }
    try reader.seek(to: start + size)
  }

  private mutating func readChunk(_ frameReader: inout ByteReader, frame: Int) throws(AsepriteError) {
    let start = frameReader.position
    let size = Int(try frameReader.u32())
    let type = try frameReader.u16()
    guard size >= 6 else { throw .invalidValue(field: "chunk size", value: size, offset: start) }
    var chunk = try frameReader.bounded(to: start + size)
    if case .tile = target, type != ChunkType.userData {
      target = .none
    }

    switch type {
    case ChunkType.oldPalette8, ChunkType.oldPalette6:
      if !ignoreOldPalettes {
        try readOldPalette(&chunk, frame: frame, sixBit: type == ChunkType.oldPalette6, at: start)
      }
    case ChunkType.palette:
      try readPalette(&chunk, frame: frame, at: start)
      ignoreOldPalettes = true
    case ChunkType.layer: try readLayer(&chunk, at: start)
    case ChunkType.cel: try readCel(&chunk, frame: frame, at: start)
    case ChunkType.celExtra: try readCelExtra(&chunk)
    case ChunkType.colorProfile: try readColorProfile(&chunk, at: start)
    case ChunkType.externalFiles: try readExternalFiles(&chunk, at: start)
    case ChunkType.mask, ChunkType.path: break
    case ChunkType.tags: try readTags(&chunk)
    case ChunkType.userData: try readUserData(&chunk, at: start)
    case ChunkType.slices:
      let count = Int(try chunk.u32())
      try chunk.skip(8)
      for _ in 0..<count {
        guard chunk.remaining > 0 else { break }
        sprite.slices.append(try readSlice(&chunk))
      }
    case ChunkType.slice:
      sprite.slices.append(try readSlice(&chunk))
      target = .slice(sprite.slices.count - 1)
    case ChunkType.tileset: try readTileset(&chunk, at: start)
    default:
      warn(at: start, "skipped unknown chunk type 0x\(String(type, radix: 16))")
    }
    try frameReader.seek(to: start + size)
  }

  // MARK: - Palettes

  private mutating func readOldPalette(
    _ chunk: inout ByteReader,
    frame: Int,
    sixBit: Bool,
    at offset: Int
  ) throws(AsepriteError) {
    var entries = sprite.palette(forFrame: frame).entries
    var skipped = false
    let packets = Int(try chunk.u16())
    var index = 0
    for _ in 0..<packets {
      // Aseprite accumulates the skip counts but not the sizes of previous packets.
      index += Int(try chunk.u8())
      var count = Int(try chunk.u8())
      if count == 0 {
        count = 256
      }
      for entry in index..<index + count {
        var components = [try chunk.u8(), try chunk.u8(), try chunk.u8()]
        if sixBit {
          components = components.map { $0 << 2 | $0 >> 4 }
        }
        guard entry < entries.count else {
          skipped = true
          continue
        }
        entries[entry] = Aseprite.Palette.Entry(
          color: Aseprite.Color(r: components[0], g: components[1], b: components[2], a: 255)
        )
      }
    }
    if skipped {
      warn(at: offset, "palette entries past the palette size were skipped")
    }
    setPalette(entries, frame: frame)
  }

  private mutating func readPalette(_ chunk: inout ByteReader, frame: Int, at offset: Int) throws(AsepriteError) {
    var entries = sprite.palette(forFrame: frame).entries
    let size = Int(try chunk.u32())
    let first = Int(try chunk.u32())
    let last = Int(try chunk.u32())
    try chunk.skip(8)
    guard size <= Self.maximumPaletteSize else {
      throw .invalidValue(field: "palette size", value: size, offset: offset)
    }
    if size > 0 {
      if size < entries.count {
        entries.removeLast(entries.count - size)
      } else {
        entries += Array(repeating: Self.black, count: size - entries.count)
      }
    }
    var skipped = false
    var index = first
    while index <= last {
      let flags = try chunk.u16()
      let color = Aseprite.Color(r: try chunk.u8(), g: try chunk.u8(), b: try chunk.u8(), a: try chunk.u8())
      let name = try flags & 1 != 0 ? chunk.string() : nil
      if index < entries.count {
        entries[index] = Aseprite.Palette.Entry(color: color, name: name)
      } else {
        skipped = true
      }
      index += 1
    }
    if skipped {
      warn(at: offset, "palette entries past the palette size were skipped")
    }
    setPalette(entries, frame: frame)
  }

  /// Records `entries` as the palette from `frame` on, unless the colors are unchanged.
  private mutating func setPalette(_ entries: [Aseprite.Palette.Entry], frame: Int) {
    let current = sprite.palette(forFrame: frame)
    if current.entries.map(\.color) == entries.map(\.color) {
      // Aseprite keeps the existing palette when no color changed; keep any new names on it.
      if let index = sprite.palettes.lastIndex(where: { $0.frame <= frame }) {
        sprite.palettes[index].entries = entries
      }
    } else if let last = sprite.palettes.indices.last, sprite.palettes[last].frame == frame {
      sprite.palettes[last].entries = entries
    } else {
      sprite.palettes.append(Aseprite.Palette(frame: frame, entries: entries))
    }
  }

  // MARK: - Layers and cels

  private mutating func readLayer(_ chunk: inout ByteReader, at offset: Int) throws(AsepriteError) {
    let flags = Aseprite.Layer.Flags(rawValue: try chunk.u16())
    let type = try chunk.u16()
    let childLevel = Int(try chunk.u16())
    try chunk.skip(4)  // Default width and height.
    let blendValue = try chunk.u16()
    let opacityValue = try chunk.u8()
    try chunk.skip(3)
    let name = try chunk.string()

    // Like Aseprite, a layer of unknown type or with a missing tileset is dropped, and so are its cels.
    let kind: Aseprite.Layer.Kind
    switch type {
    case 0: kind = .image
    case 1: kind = .group
    case 2:
      let tileset = Int(try chunk.u32())
      guard sprite.tileset(id: tileset) != nil else {
        return dropLayer(at: offset, "layer \"\(name)\" uses missing tileset \(tileset)")
      }
      kind = .tilemap(tileset: tileset)
    default:
      return dropLayer(at: offset, "layer \"\(name)\" has unknown type \(type)")
    }
    let uuid = try sprite.flags.contains(.layerUUIDs) ? chunk.uuid() : nil

    // Background layers never blend; groups only carry blend data when they're composited.
    let hasBlendInfo = (kind != .group || sprite.flags.contains(.compositeGroups)) && !flags.contains(.background)
    var blendMode = Aseprite.BlendMode.normal
    var opacity: UInt8 = 255
    if hasBlendInfo {
      guard let mode = Aseprite.BlendMode(rawValue: blendValue) else {
        throw .invalidValue(field: "blend mode", value: Int(blendValue), offset: offset)
      }
      blendMode = mode
      if sprite.flags.contains(.layerOpacity) {
        opacity = opacityValue
      }
    }

    let parent = parentForLayer(atLevel: childLevel, at: offset)
    let depth = parent.map { layerDepths[$0] + 1 } ?? 0
    guard depth <= Self.maximumLayerDepth else {
      throw .invalidValue(field: "layer nesting depth", value: depth, offset: offset)
    }
    sprite.layers.append(
      Aseprite.Layer(
        name: name,
        kind: kind,
        flags: flags,
        childLevel: childLevel,
        parent: parent,
        blendMode: blendMode,
        opacity: opacity,
        uuid: uuid
      )
    )
    let index = sprite.layers.count - 1
    layerDepths.append(depth)
    fileLayers.append(index)
    previousLayer = index
    currentLevel = childLevel
    target = .layer(index)
  }

  /// Skips a layer Aseprite would not load; it still takes up a layer index for cels.
  private mutating func dropLayer(at offset: Int, _ message: String) {
    warn(at: offset, "\(message); layer skipped")
    fileLayers.append(nil)
    target = .none
  }

  /// Resolves the parent group of a new layer from its child level (NOTE.1), as Aseprite does.
  private mutating func parentForLayer(atLevel level: Int, at offset: Int) -> Int? {
    guard let previous = previousLayer else { return nil }
    if level > currentLevel {
      if sprite.layers[previous].isGroup {
        return previous
      }
      warn(at: offset, "layer is nested under a layer that is not a group; attached to its parent instead")
      return sprite.layers[previous].parent
    }
    var parent = sprite.layers[previous].parent
    for _ in 0..<(currentLevel - level) {
      guard let group = parent else { break }
      parent = sprite.layers[group].parent
    }
    return parent
  }

  private mutating func readCel(_ chunk: inout ByteReader, frame: Int, at offset: Int) throws(AsepriteError) {
    let fileLayer = Int(try chunk.u16())
    let x = Int(try chunk.i16())
    let y = Int(try chunk.i16())
    let opacity = try chunk.u8()
    let type = try chunk.u16()
    let zIndex = Int(try chunk.i16())
    try chunk.skip(5)

    guard fileLayers.indices.contains(fileLayer), let layerIndex = fileLayers[fileLayer] else {
      return dropCel(at: offset, "cel references missing layer \(fileLayer)")
    }
    let layer = sprite.layers[layerIndex]
    guard !layer.isGroup else {
      return dropCel(at: offset, "cel on group layer \(fileLayer)")
    }
    // Aseprite keeps the first cel of a layer in a frame.
    guard celIndices[frame][layerIndex] == nil else {
      return dropCel(at: offset, "second cel for layer \(fileLayer) in frame \(frame)")
    }

    var cel = Aseprite.Cel(
      layer: layerIndex,
      position: Aseprite.Point(x: x, y: y),
      opacity: opacity,
      zIndex: zIndex,
      content: .linked(frame: 0)
    )
    // Where user data and cel extras for this cel go: linked cels share their source's data.
    var dataOwner: (frame: Int, index: Int)?
    switch type {
    case 0, 2:
      let width = Int(try chunk.u16())
      let height = Int(try chunk.u16())
      guard width > 0, height > 0 else { return dropCel(at: offset, "empty cel") }
      let count = width * height * sprite.colorMode.bytesPerPixel
      let pixels: [UInt8]
      if type == 0 {
        pixels = try chunk.array(count)
      } else {
        guard let decoded = inflate(chunk.rest(), count: count, what: "cel image", at: offset) else {
          return dropCel(at: offset, "cel image data is too short for its size")
        }
        pixels = decoded
      }
      cel.content = .image(
        Aseprite.PixelBuffer(width: width, height: height, colorMode: sprite.colorMode, bytes: pixels)
      )
    case 1:
      let linkedFrame = Int(try chunk.u16())
      guard sprite.frames.indices.contains(linkedFrame), let index = celIndices[linkedFrame][layerIndex] else {
        return dropCel(at: offset, "linked cel points to frame \(linkedFrame), which has no cel on this layer")
      }
      // Links are stored pointing at the cel that holds the content, so they never chain.
      var source = (frame: linkedFrame, index: index)
      if case .linked(let sourceFrame) = sprite.frames[linkedFrame].cels[index].content,
        let sourceIndex = celIndices[sourceFrame][layerIndex]
      {
        source = (sourceFrame, sourceIndex)
      }
      let sourceCel = sprite.frames[source.frame].cels[source.index]
      if sourceCel.drawPosition == cel.position && sourceCel.opacity == opacity {
        cel.content = .linked(frame: source.frame)  // Cel::MakeLink
        dataOwner = source
      } else {
        // An early beta allowed links with their own position or opacity; Aseprite loads those as
        // copies of the pixels only (Cel::MakeCopy), without user data or precise bounds.
        cel.content = sourceCel.content
      }
    case 3:
      guard let tilemap = try readTilemap(&chunk, layer: layer, at: offset) else {
        target = .none
        return
      }
      cel.content = .tilemap(tilemap)
    default:
      return dropCel(at: offset, "unknown cel type \(type)")
    }

    let index = sprite.frames[frame].cels.count
    sprite.frames[frame].cels.append(cel)
    celIndices[frame][layerIndex] = index
    let owner = dataOwner ?? (frame, index)
    lastCel = owner
    target = .cel(frame: owner.frame, index: owner.index)
  }

  private mutating func dropCel(at offset: Int, _ message: String) {
    warn(at: offset, "\(message); cel skipped")
    target = .none
  }

  private mutating func readTilemap(
    _ chunk: inout ByteReader,
    layer: Aseprite.Layer,
    at offset: Int
  ) throws(AsepriteError) -> Aseprite.Tilemap? {
    let width = Int(try chunk.u16())
    let height = Int(try chunk.u16())
    let bitsPerTile = Int(try chunk.u16())
    let idMask = try chunk.u32()
    let xFlipMask = try chunk.u32()
    let yFlipMask = try chunk.u32()
    let diagonalFlipMask = try chunk.u32()
    try chunk.skip(10)

    // Like Aseprite, only 32-bit tiles are supported.
    guard bitsPerTile == 32 else {
      warn(at: offset, "\(bitsPerTile)-bit tiles are not supported; cel skipped")
      return nil
    }
    guard case .tilemap(let tilesetID) = layer.kind, let tileset = sprite.tileset(id: tilesetID) else {
      warn(at: offset, "tilemap cel on a layer without a tileset; cel skipped")
      return nil
    }
    guard width > 0, height > 0 else {
      warn(at: offset, "empty tilemap; cel skipped")
      return nil
    }

    guard let data = inflate(chunk.rest(), count: width * height * 4, what: "tilemap", at: offset) else {
      warn(at: offset, "tilemap data is too short for its size; cel skipped")
      return nil
    }
    let flagsMask = xFlipMask | yFlipMask | diagonalFlipMask
    let idShift = UInt32(idMask == 0 ? 0 : idMask.trailingZeroBitCount)
    let delta: UInt32 = tileset.baseIndex == 0 ? 1 : 0
    let oldFormat = !tileset.flags.contains(.zeroIsEmpty)
    var tiles: [Aseprite.Tile] = []
    tiles.reserveCapacity(width * height)
    for index in 0..<width * height {
      let base = index * 4
      var value =
        UInt32(data[base]) | UInt32(data[base + 1]) << 8 | UInt32(data[base + 2]) << 16
        | UInt32(data[base + 3]) << 24
      if oldFormat {
        // Old files used 0xFFFFFFFF as the empty tile and had no empty tile 0 (fix_old_tilemap).
        value = value == 0xFFFF_FFFF ? 0 : (value & flagsMask) | ((value & idMask) &+ delta)
      }
      let tileIndex = Int((value & idMask) >> idShift)
      // Aseprite drops absurd indices from broken files instead of keeping them.
      if tileIndex > tileset.tileCount, tileIndex > 0xFF_FFFF {
        tiles.append(.empty)
        continue
      }
      tiles.append(
        Aseprite.Tile(
          index: tileIndex,
          flipX: value & xFlipMask == xFlipMask,
          flipY: value & yFlipMask == yFlipMask,
          flipDiagonal: value & diagonalFlipMask == diagonalFlipMask
        )
      )
    }
    return Aseprite.Tilemap(width: width, height: height, tiles: tiles)
  }

  private mutating func readCelExtra(_ chunk: inout ByteReader) throws(AsepriteError) {
    guard let (frame, index) = lastCel else { return }
    let flags = try chunk.u32()
    guard flags & 1 != 0 else { return }
    sprite.frames[frame].cels[index].extra = Aseprite.Cel.Extra(
      x: try chunk.fixed(),
      y: try chunk.fixed(),
      width: try chunk.fixed(),
      height: try chunk.fixed()
    )
  }

  /// Decompresses image data the way Aseprite tolerates it: a stream that produces more bytes than needed
  /// is cut short, and a corrupt stream leaves the image zero-filled (Aseprite zero-initializes images and
  /// keeps going). Returns `nil` only when the data could not produce `count` bytes even in principle.
  private mutating func inflate(
    _ data: ArraySlice<UInt8>,
    count: Int,
    what: String,
    at offset: Int
  ) -> [UInt8]? {
    do {
      return try Inflate.zlib(data, count: count)
    } catch Inflate.Failure.outputOverflow {
      if let bytes = try? Inflate.zlib(data, count: count, ignoringExcess: true) {
        warn(at: offset, "\(what) data is longer than needed; the extra bytes were ignored")
        return bytes
      }
    } catch {}
    let (bound, overflow) = data.count.multipliedReportingOverflow(by: Inflate.maximumRatio)
    guard overflow || count <= bound else { return nil }
    warn(at: offset, "\(what) data is corrupt; it was left zero-filled")
    return [UInt8](repeating: 0, count: count)
  }

  // MARK: - Other chunks

  private mutating func readColorProfile(_ chunk: inout ByteReader, at offset: Int) throws(AsepriteError) {
    let type = try chunk.u16()
    let flags = try chunk.u16()
    let gamma = try chunk.fixed()
    try chunk.skip(8)
    let kind: Aseprite.ColorProfile.Kind
    switch type {
    case 0: kind = .none
    case 1: kind = .sRGB
    case 2: kind = .icc(try chunk.array(Int(try chunk.u32())))
    default:
      warn(at: offset, "unknown color profile type \(type) ignored")
      return
    }
    sprite.colorProfile = Aseprite.ColorProfile(kind: kind, gamma: flags & 1 != 0 ? gamma : nil)
  }

  private mutating func readExternalFiles(_ chunk: inout ByteReader, at offset: Int) throws(AsepriteError) {
    let count = Int(try chunk.u32())
    try chunk.skip(8)
    for _ in 0..<count {
      let id = Int(try chunk.u32())
      let type = try chunk.u8()
      try chunk.skip(7)
      let name = try chunk.string()
      guard let kind = Aseprite.ExternalFile.Kind(rawValue: type) else {
        warn(at: offset, "unknown external file type \(type) skipped")
        continue
      }
      sprite.externalFiles.append(Aseprite.ExternalFile(id: id, kind: kind, name: name))
    }
  }

  private mutating func readTags(_ chunk: inout ByteReader) throws(AsepriteError) {
    let count = Int(try chunk.u16())
    try chunk.skip(8)
    for _ in 0..<count {
      guard chunk.remaining > 0 else { break }
      let from = Int(try chunk.u16())
      let to = Int(try chunk.u16())
      let direction = Aseprite.LoopDirection(rawValue: try chunk.u8()) ?? .forward
      let repeatCount = Int(try chunk.u16())
      try chunk.skip(6)
      let color = Aseprite.Color(r: try chunk.u8(), g: try chunk.u8(), b: try chunk.u8(), a: 255)
      try chunk.skip(1)
      let name = try chunk.string()
      let tag = Aseprite.Tag(
        name: name,
        from: from,
        to: to,
        direction: direction,
        repeatCount: repeatCount,
        color: color
      )
      // Aseprite keeps tags ordered by first frame, longer ranges first (Tags::add).
      let index =
        sprite.tags.firstIndex { $0.from > from || ($0.from == from && $0.to < to) } ?? sprite.tags.count
      sprite.tags.insert(tag, at: index)
    }
    // Tag user data follows in tag order, starting from the first tag.
    target = sprite.tags.isEmpty ? .none : .tag(0)
  }

  private mutating func readSlice(_ chunk: inout ByteReader) throws(AsepriteError) -> Aseprite.Slice {
    let keyCount = Int(try chunk.u32())
    let flags = try chunk.u32()
    try chunk.skip(4)
    let name = try chunk.string()
    var keys: [Aseprite.Slice.Key] = []
    for _ in 0..<keyCount {
      guard chunk.remaining > 0 else { break }
      let frame = Int(try chunk.u32())
      let bounds = try readRect(&chunk)
      let center = try flags & 1 != 0 ? readRect(&chunk) : nil
      let pivot = try flags & 2 != 0 ? Aseprite.Point(x: Int(chunk.i32()), y: Int(chunk.i32())) : nil
      keys.append(Aseprite.Slice.Key(frame: frame, bounds: bounds, center: center, pivot: pivot))
    }
    return Aseprite.Slice(name: name, keys: keys)
  }

  private func readRect(_ chunk: inout ByteReader) throws(AsepriteError) -> Aseprite.Rect {
    Aseprite.Rect(
      x: Int(try chunk.i32()),
      y: Int(try chunk.i32()),
      // Aseprite reads the size into an int, so sizes of 2^31 and up become negative.
      width: Int(try chunk.i32()),
      height: Int(try chunk.i32())
    )
  }

  private mutating func readTileset(_ chunk: inout ByteReader, at offset: Int) throws(AsepriteError) {
    let id = Int(try chunk.u32())
    let flags = Aseprite.Tileset.Flags(rawValue: try chunk.u32())
    var tileCount = Int(try chunk.u32())
    let tileWidth = Int(try chunk.u16())
    let tileHeight = Int(try chunk.u16())
    var baseIndex = Int(try chunk.i16())
    try chunk.skip(14)
    let name = try chunk.string()
    guard tileWidth >= 1, tileHeight >= 1 else {
      return warn(at: offset, "tileset \(id) has an empty tile size and was skipped")
    }

    var external: Aseprite.Tileset.ExternalReference?
    if flags.contains(.externalFile) {
      let reference = Aseprite.Tileset.ExternalReference(
        fileID: Int(try chunk.u32()),
        tilesetID: Int(try chunk.u32())
      )
      if !sprite.externalFiles.contains(where: { $0.id == reference.fileID }) {
        warn(at: offset, "tileset \(id) references missing external file \(reference.fileID)")
      }
      external = reference
    }

    var image: Aseprite.PixelBuffer?
    if flags.contains(.embedded), tileCount > 0 {
      let dataSize = Int(try chunk.u32())
      var data = try chunk.take(min(dataSize, chunk.remaining))
      let tileBytes = tileWidth * tileHeight * sprite.colorMode.bytesPerPixel
      let (count, overflow) = tileBytes.multipliedReportingOverflow(by: tileCount)
      guard !overflow else { throw .invalidValue(field: "tile count", value: tileCount, offset: offset) }
      if var pixels = inflate(data.rest(), count: count, what: "tileset", at: offset) {
        if !flags.contains(.zeroIsEmpty) {
          // Old files had no empty tile 0 (fix_old_tileset).
          let empty = emptyPixels(count: tileWidth * tileHeight)
          if pixels.starts(with: empty) {
            baseIndex = 1
          } else {
            pixels = empty + pixels
            tileCount += 1
            baseIndex = 0
          }
        }
        image = Aseprite.PixelBuffer(
          width: tileWidth,
          height: tileHeight * tileCount,
          colorMode: sprite.colorMode,
          bytes: pixels
        )
      } else {
        warn(at: offset, "tileset \(id) data is too short for its size; its tiles were skipped")
      }
    }

    sprite.tilesets.append(
      Aseprite.Tileset(
        id: id,
        flags: flags,
        tileSize: Aseprite.Size(width: tileWidth, height: tileHeight),
        tileCount: tileCount,
        baseIndex: baseIndex,
        name: name,
        external: external,
        image: image
      )
    )
    target = .tileset(sprite.tilesets.count - 1)
  }

  /// `count` pixels of the transparent color, in the sprite's color mode.
  private func emptyPixels(count: Int) -> [UInt8] {
    let pixel = sprite.colorMode == .indexed ? sprite.transparentIndex : 0
    return [UInt8](repeating: pixel, count: count * sprite.colorMode.bytesPerPixel)
  }

  // MARK: - User data

  private mutating func readUserData(_ chunk: inout ByteReader, at offset: Int) throws(AsepriteError) {
    var userData = Aseprite.UserData()
    let flags = try chunk.u32()
    if flags & 1 != 0 {
      userData.text = try chunk.string()
    }
    if flags & 2 != 0 {
      userData.color = Aseprite.Color(r: try chunk.u8(), g: try chunk.u8(), b: try chunk.u8(), a: try chunk.u8())
    }
    if flags & 4 != 0 {
      userData.properties = try readPropertyMaps(&chunk, at: offset)
    }

    switch target {
    case .none:
      break
    case .sprite:
      sprite.userData = userData
    case .layer(let index):
      sprite.layers[index].userData = userData
    case .cel(let frame, let index):
      sprite.frames[frame].cels[index].userData = userData
    case .slice(let index):
      sprite.slices[index].userData = userData
    case .tag(let index):
      sprite.tags[index].userData = userData
      sprite.tags[index].color = userData.color ?? .clear
      target = index + 1 < sprite.tags.count ? .tag(index + 1) : .none
    case .tileset(let index):
      sprite.tilesets[index].userData = userData
      target = sprite.tilesets[index].tileCount > 0 ? .tile(tileset: index, index: 0) : .none
    case .tile(let tileset, let index):
      while sprite.tilesets[tileset].tileUserData.count < index {
        sprite.tilesets[tileset].tileUserData.append(Aseprite.UserData())
      }
      sprite.tilesets[tileset].tileUserData.append(userData)
      target = index + 1 < sprite.tilesets[tileset].tileCount ? .tile(tileset: tileset, index: index + 1) : .none
    }
  }

  /// Reads property maps; a malformed map is reported and dropped, keeping the maps before it.
  private mutating func readPropertyMaps(
    _ chunk: inout ByteReader,
    at offset: Int
  ) throws(AsepriteError) -> [UInt32: [String: Aseprite.PropertyValue]] {
    let start = chunk.position
    let size = Int(try chunk.u32())
    var reader = try chunk.bounded(to: min(max(start + size, chunk.position), chunk.end))
    var maps: [UInt32: [String: Aseprite.PropertyValue]] = [:]
    do {
      let count = Int(try reader.u32())
      for _ in 0..<count {
        guard reader.remaining > 0 else { break }
        let key = try reader.u32()
        maps[key] = try readProperties(&reader, depth: 0)
      }
    } catch {
      warn(at: offset, "malformed user data properties were skipped")
    }
    try chunk.seek(to: min(max(start + size, chunk.position), chunk.end))
    return maps
  }

  private func readProperties(
    _ reader: inout ByteReader,
    depth: Int
  ) throws(AsepriteError) -> [String: Aseprite.PropertyValue] {
    let count = Int(try reader.u32())
    var properties: [String: Aseprite.PropertyValue] = [:]
    for _ in 0..<count {
      guard reader.remaining > 0 else { break }
      let name = try reader.string()
      let type = try reader.u16()
      properties[name] = try readPropertyValue(&reader, type: type, depth: depth + 1)
    }
    return properties
  }

  private func readPropertyValue(
    _ reader: inout ByteReader,
    type: UInt16,
    depth: Int
  ) throws(AsepriteError) -> Aseprite.PropertyValue {
    guard depth <= Self.maximumPropertyDepth else {
      throw .invalidValue(field: "property depth", value: depth, offset: reader.position)
    }
    switch type {
    case 0x11:
      let count = Int(try reader.u32())
      let elementType = try reader.u16()
      var values: [Aseprite.PropertyValue] = []
      for _ in 0..<count {
        let type = try elementType == 0 ? reader.u16() : elementType
        values.append(try readPropertyValue(&reader, type: type, depth: depth + 1))
      }
      return .vector(values)
    case 0x12:
      return .properties(try readProperties(&reader, depth: depth))
    default:
      return try readScalarProperty(&reader, type: type)
    }
  }

  /// Reads a non-container property value. Kept out of the recursive path so each nesting level costs
  /// little stack, even in debug builds.
  @inline(never)
  private func readScalarProperty(
    _ reader: inout ByteReader,
    type: UInt16
  ) throws(AsepriteError)
    -> Aseprite.PropertyValue
  {
    switch type {
    case 0x01: return .bool(try reader.u8() != 0)
    case 0x02: return .int8(Int8(bitPattern: try reader.u8()))
    case 0x03: return .uint8(try reader.u8())
    case 0x04: return .int16(try reader.i16())
    case 0x05: return .uint16(try reader.u16())
    case 0x06: return .int32(try reader.i32())
    case 0x07: return .uint32(try reader.u32())
    case 0x08: return .int64(try reader.i64())
    case 0x09: return .uint64(try reader.u64())
    case 0x0A: return .fixed(try reader.fixed())
    case 0x0B: return .float(try reader.f32())
    case 0x0C: return .double(try reader.f64())
    case 0x0D: return .string(try reader.string())
    case 0x0E: return .point(Aseprite.Point(x: Int(try reader.i32()), y: Int(try reader.i32())))
    case 0x0F: return .size(Aseprite.Size(width: Int(try reader.i32()), height: Int(try reader.i32())))
    case 0x10:
      return .rect(
        Aseprite.Rect(
          x: Int(try reader.i32()),
          y: Int(try reader.i32()),
          width: Int(try reader.i32()),
          height: Int(try reader.i32())
        )
      )
    case 0x13: return .uuid(try reader.uuid())
    default: throw .invalidValue(field: "property type", value: Int(type), offset: reader.position)
    }
  }

  private mutating func warn(at offset: Int, _ message: String) {
    sprite.warnings.append(Aseprite.Warning(offset: offset, message: message))
  }
}
