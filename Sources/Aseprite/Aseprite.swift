// Decoding and rendering semantics follow Aseprite's own implementation (src/dio/aseprite_decoder.cpp,
// src/doc/render_plan.cpp, src/render/render.cpp, src/doc/blend_funcs.cpp), which is released under the
// MIT license: Copyright (c) 2018-present Igara Studio S.A., Copyright (c) 2001-2018 David Capello.

/// A decoded Aseprite document (`.ase` / `.aseprite`).
///
/// The whole file is decoded up front into value types that mirror the file format: frames hold cels,
/// cels reference layers by index, and cel pixels stay in the sprite's color mode so indexed data and
/// per-frame palettes survive. ``renderFrame(_:options:)`` composites a frame the way Aseprite does,
/// including blend modes, group compositing, z-index ordering, and tilemaps.
///
/// ```swift
/// let sprite = try Aseprite(contentsOf: "player.aseprite")
/// for tag in sprite.tags {
///     let frames = sprite.renderFrames(tag.frames)
/// }
/// ```
public struct Aseprite: Sendable, Equatable {
  /// The deepest layer nesting accepted: a layer inside this many groups. Aseprite has no limit, but
  /// rendering takes one level of recursion (and, for composited groups, one canvas-sized buffer) per
  /// level; this bound keeps rendering safe on a 512 KB thread stack (the default for secondary threads on
  /// Apple platforms), with room to spare even in debug builds. Deeper files are rejected with
  /// ``AsepriteError/invalidValue(field:value:offset:)``.
  public static let maximumLayerDepth = 64

  /// Canvas width in pixels.
  public var width: Int
  /// Canvas height in pixels.
  public var height: Int
  /// How pixels are stored in cels and tilesets.
  public var colorMode: ColorMode
  /// Header flags describing which layer fields are meaningful.
  public var flags: HeaderFlags
  /// Palette index treated as transparent in non-background layers (indexed sprites only, otherwise 0).
  public var transparentIndex: UInt8
  /// Number of palette colors declared in the header.
  public var colorCount: Int
  /// Pixel aspect ratio; 1:1 for square pixels.
  public var pixelRatio: Size
  /// Grid bounds; width and height are 0 when there is no grid.
  public var grid: Rect
  /// The animation frames, in order.
  public var frames: [Frame]
  /// Every layer, in file order: a cel's ``Cel/layer`` indexes into this array.
  public var layers: [Layer]
  /// Animation tags.
  public var tags: [Tag]
  /// Slices, in file order. (Aseprite itself holds them in reverse: it inserts each loaded slice at the front.)
  public var slices: [Slice]
  /// Palettes, sorted by ``Palette/frame``; each one applies from its frame until the next.
  ///
  /// These are the palettes stored in the file. RGB files often store only an all-black palette; Aseprite
  /// replaces that with one built from the pixels when it opens the file, which is not reproduced here.
  public var palettes: [Palette]
  /// Tilesets used by tilemap layers.
  public var tilesets: [Tileset]
  /// External files referenced by tilesets, palettes, and extension properties.
  public var externalFiles: [ExternalFile]
  /// The color profile, if the file declares one.
  public var colorProfile: ColorProfile?
  /// User data attached to the sprite itself.
  public var userData: UserData
  /// Recoverable problems found while decoding: things Aseprite skips rather than rejecting the file.
  public var warnings: [Warning]

  /// Decodes an Aseprite file from its bytes.
  ///
  /// Problems Aseprite tolerates are handled the way Aseprite handles them and listed in ``warnings``.
  /// Memory use is bounded by the input: decompressed pixels can be at most about 1000 times the size of
  /// the file, the most DEFLATE can expand.
  ///
  /// - Throws: ``AsepriteError`` if the data is not a valid Aseprite file.
  @inlinable
  public init(bytes: some Collection<UInt8>) throws(AsepriteError) {
    // Inlinable so the copy into an array is specialized for the caller's collection type.
    try self.init(decoding: Array(bytes))
  }

  /// Decodes an Aseprite file from a byte array.
  @usableFromInline
  init(decoding bytes: [UInt8]) throws(AsepriteError) {
    var decoder = AsepriteDecoder(bytes: bytes)
    self = try decoder.decode()
  }

  /// Creates a document from its parts. Used by the decoder; the arguments mirror the stored properties.
  init(
    width: Int,
    height: Int,
    colorMode: ColorMode,
    flags: HeaderFlags,
    transparentIndex: UInt8,
    colorCount: Int,
    pixelRatio: Size,
    grid: Rect
  ) {
    self.width = width
    self.height = height
    self.colorMode = colorMode
    self.flags = flags
    self.transparentIndex = transparentIndex
    self.colorCount = colorCount
    self.pixelRatio = pixelRatio
    self.grid = grid
    self.frames = []
    self.layers = []
    self.tags = []
    self.slices = []
    self.palettes = []
    self.tilesets = []
    self.externalFiles = []
    self.colorProfile = nil
    self.userData = UserData()
    self.warnings = []
  }

  /// Returns the palette in effect at `frame`.
  public func palette(forFrame frame: Int) -> Palette {
    palettes.last { $0.frame <= frame } ?? palettes.first ?? Palette(frame: 0, entries: [])
  }

  /// Returns the tileset with the file ID `id`, as referenced by ``Layer/Kind/tilemap(tileset:)``.
  public func tileset(id: Int) -> Tileset? {
    tilesets.last { $0.id == id }
  }

  /// Returns the cel of `layer` in `frame`, with a linked cel resolved to the cel it links to.
  ///
  /// Linked cels share their source's content, user data, and precise bounds (as in Aseprite, where
  /// they share one `CelData`); position, opacity, and z-index are the linked cel's own.
  public func cel(layer: Int, frame: Int) -> Cel? {
    guard frames.indices.contains(frame), let cel = frames[frame].cels.first(where: { $0.layer == layer }) else {
      return nil
    }
    return resolved(cel)
  }

  /// Resolves a linked cel to its source's content, user data, and precise bounds.
  func resolved(_ cel: Cel) -> Cel? {
    var cel = cel
    var visited = 0
    while case .linked(let target) = cel.content {
      visited += 1
      guard visited <= frames.count, frames.indices.contains(target),
        let source = frames[target].cels.first(where: { $0.layer == cel.layer })
      else { return nil }
      cel.content = source.content
      cel.userData = source.userData
      cel.extra = source.extra
    }
    return cel
  }

  /// Renders one frame to straight-alpha RGBA8, the way Aseprite composites it. Frames outside the
  /// sprite render fully transparent.
  ///
  /// Rendering allocates `width × height` pixels, plus one more canvas per level of composited groups
  /// being drawn. `width` and `height` come from the file (up to 65535 each), so check them before
  /// rendering files from untrusted sources.
  public func renderFrame(_ frame: Int, options: RenderOptions = RenderOptions()) -> Image {
    Renderer(sprite: self, options: options).render(frame: frame)
  }

  /// Renders the frames of `frames` that exist in the sprite (a tag's range is inclusive, like this one).
  public func renderFrames(_ frames: ClosedRange<Int>, options: RenderOptions = RenderOptions()) -> [Image] {
    guard !self.frames.isEmpty, frames.overlaps(0...self.frames.count - 1) else { return [] }
    let renderer = Renderer(sprite: self, options: options)
    return frames.clamped(to: 0...self.frames.count - 1).map { renderer.render(frame: $0) }
  }

  /// Renders every frame.
  public func renderAllFrames(options: RenderOptions = RenderOptions()) -> [Image] {
    guard !frames.isEmpty else { return [] }
    return renderFrames(0...frames.count - 1, options: options)
  }

  /// Renders the frames of `frames` that exist, each cropped to `rect` (canvas coordinates). The images
  /// are `rect`'s size; parts outside the canvas are transparent.
  public func renderFrames(
    _ frames: ClosedRange<Int>,
    croppedTo rect: Rect,
    options: RenderOptions = RenderOptions()
  ) -> [Image] {
    renderFrames(frames, options: options).map { $0.cropped(to: rect) }
  }

  /// Renders the frames of `frames` that exist, each cropped to `slice`'s key for that frame.
  ///
  /// A key's bounds are clipped to the canvas first, so a slice reaching outside the canvas yields a
  /// smaller image, and a frame whose key is hidden (zero-sized), missing, or off-canvas yields an empty
  /// image. Clip the key's bounds against ``Image/width`` × ``Image/height`` yourself if you need the
  /// image's offset within the slice.
  public func renderFrames(
    _ frames: ClosedRange<Int>,
    slice: Slice,
    options: RenderOptions = RenderOptions()
  ) -> [Image] {
    guard !self.frames.isEmpty, frames.overlaps(0...self.frames.count - 1) else { return [] }
    let renderer = Renderer(sprite: self, options: options)
    let canvas = Rect(x: 0, y: 0, width: width, height: height)
    return frames.clamped(to: 0...self.frames.count - 1).map { frame in
      let bounds =
        slice.key(forFrame: frame)?.bounds.intersection(canvas) ?? Rect(x: 0, y: 0, width: 0, height: 0)
      return renderer.render(frame: frame).cropped(to: bounds)
    }
  }
}

extension Aseprite.Cel {
  /// Where the cel is drawn: its ``position``, or, when it has precise bounds (``extra``) with a non-zero
  /// size, their origin truncated toward zero, which Aseprite applies to cels of any layer
  /// (`CelData::setBoundsF`). The image keeps its own size either way.
  public var drawPosition: Aseprite.Point {
    guard let extra, extra.width.rawValue != 0, extra.height.rawValue != 0 else { return position }
    return Aseprite.Point(
      x: Int(extra.x.doubleValue.rounded(.towardZero)),
      y: Int(extra.y.doubleValue.rounded(.towardZero))
    )
  }
}

extension Aseprite.Rect {
  /// The overlap of two rectangles; zero-sized when they don't overlap.
  func intersection(_ other: Aseprite.Rect) -> Aseprite.Rect {
    let left = max(x, other.x)
    let top = max(y, other.y)
    let right = min(x + max(width, 0), other.x + max(other.width, 0))
    let bottom = min(y + max(height, 0), other.y + max(other.height, 0))
    guard left < right, top < bottom else { return Aseprite.Rect(x: 0, y: 0, width: 0, height: 0) }
    return Aseprite.Rect(x: left, y: top, width: right - left, height: bottom - top)
  }
}
