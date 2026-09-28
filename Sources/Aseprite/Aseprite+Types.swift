extension Aseprite {
  /// How pixels are stored.
  public enum ColorMode: Sendable, Hashable {
    /// 4 bytes per pixel: red, green, blue, alpha.
    case rgba
    /// 2 bytes per pixel: value, alpha.
    case grayscale
    /// 1 byte per pixel: a palette index.
    case indexed

    /// Bytes per pixel.
    public var bytesPerPixel: Int {
      switch self {
      case .rgba: 4
      case .grayscale: 2
      case .indexed: 1
      }
    }
  }

  /// Header flags.
  public struct HeaderFlags: OptionSet, Sendable, Hashable {
    /// The raw flag bits.
    public var rawValue: UInt32

    /// Creates flags from raw bits.
    public init(rawValue: UInt32) {
      self.rawValue = rawValue
    }

    /// Layer opacity fields are valid.
    public static let layerOpacity = HeaderFlags(rawValue: 1)
    /// Group layers have a valid blend mode and opacity and are composited separately.
    public static let compositeGroups = HeaderFlags(rawValue: 2)
    /// Layers carry a UUID.
    public static let layerUUIDs = HeaderFlags(rawValue: 4)
  }

  /// An integer point.
  public struct Point: Sendable, Hashable {
    /// Horizontal coordinate.
    public var x: Int
    /// Vertical coordinate.
    public var y: Int

    /// Creates a point.
    public init(x: Int, y: Int) {
      self.x = x
      self.y = y
    }
  }

  /// An integer size.
  public struct Size: Sendable, Hashable {
    /// Width.
    public var width: Int
    /// Height.
    public var height: Int

    /// Creates a size.
    public init(width: Int, height: Int) {
      self.width = width
      self.height = height
    }
  }

  /// An integer rectangle.
  public struct Rect: Sendable, Hashable {
    /// Left edge.
    public var x: Int
    /// Top edge.
    public var y: Int
    /// Width.
    public var width: Int
    /// Height.
    public var height: Int

    /// Creates a rectangle.
    public init(x: Int, y: Int, width: Int, height: Int) {
      self.x = x
      self.y = y
      self.width = width
      self.height = height
    }
  }

  /// A signed 16.16 fixed-point number (`FIXED`).
  public struct Fixed: Sendable, Hashable {
    /// The raw 16.16 bits.
    public var rawValue: Int32

    /// Creates a fixed-point number from its raw bits.
    public init(rawValue: Int32) {
      self.rawValue = rawValue
    }

    /// The value as a `Double`.
    public var doubleValue: Double { Double(rawValue) / 65536 }
  }

  /// A 16-byte universally unique identifier.
  public struct UUID: Sendable, Hashable, CustomStringConvertible {
    /// The 16 bytes, in file order.
    public var bytes: [UInt8]

    /// Creates a UUID from 16 bytes.
    public init(bytes: [UInt8]) {
      precondition(bytes.count == 16, "a UUID has 16 bytes")
      self.bytes = bytes
    }

    /// The canonical `8-4-4-4-12` hexadecimal form.
    public var description: String {
      let digits = Array("0123456789abcdef")
      var result = ""
      for (index, byte) in bytes.enumerated() {
        if [4, 6, 8, 10].contains(index) {
          result.append("-")
        }
        result.append(digits[Int(byte >> 4)])
        result.append(digits[Int(byte & 0xF)])
      }
      return result
    }
  }

  /// A straight-alpha RGBA8 color. Its memory layout is four bytes in R, G, B, A order.
  public struct Color: Sendable, Hashable {
    /// Red.
    public var r: UInt8
    /// Green.
    public var g: UInt8
    /// Blue.
    public var b: UInt8
    /// Alpha.
    public var a: UInt8

    /// Creates a color.
    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
      self.r = r
      self.g = g
      self.b = b
      self.a = a
    }

    /// Fully transparent black.
    public static let clear = Color(r: 0, g: 0, b: 0, a: 0)
  }

  /// A rendered image: straight-alpha RGBA8, row-major, top row first.
  public struct Image: Sendable, Hashable {
    /// Width in pixels.
    public var width: Int
    /// Height in pixels.
    public var height: Int
    /// `width * height` pixels; `pixels.withUnsafeBytes` yields tightly packed RGBA8 bytes.
    public var pixels: [Color]

    /// Creates a transparent image. `width` and `height` must not be negative.
    public init(width: Int, height: Int) {
      precondition(width >= 0 && height >= 0, "image size must not be negative")
      precondition(!width.multipliedReportingOverflow(by: height).overflow, "image size overflows")
      self.width = width
      self.height = height
      self.pixels = [Color](repeating: .clear, count: width * height)
    }

    /// The color at (`x`, `y`).
    public subscript(x: Int, y: Int) -> Color {
      get { pixels[y * width + x] }
      set { pixels[y * width + x] = newValue }
    }

    /// Returns an image of `rect`'s size (negative sizes count as zero) holding the part of this image inside
    /// `rect`; areas outside this image are transparent.
    public func cropped(to rect: Rect) -> Image {
      var result = Image(width: max(rect.width, 0), height: max(rect.height, 0))
      let left = max(rect.x, 0)
      let right = min(rect.x + rect.width, width)
      let top = max(rect.y, 0)
      let bottom = min(rect.y + rect.height, height)
      guard left < right, top < bottom else { return result }
      for y in top..<bottom {
        let source = y * width
        let destination = (y - rect.y) * result.width - rect.x
        for x in left..<right {
          result.pixels[destination + x] = pixels[source + x]
        }
      }
      return result
    }
  }

  /// Pixels in the sprite's color mode, as stored in cels and tilesets.
  public struct PixelBuffer: Sendable, Hashable {
    /// Width in pixels.
    public var width: Int
    /// Height in pixels.
    public var height: Int
    /// Pixel format of ``bytes``.
    public var colorMode: ColorMode
    /// `width * height * colorMode.bytesPerPixel` bytes, row-major, top row first.
    public var bytes: [UInt8]

    /// Creates a pixel buffer.
    public init(width: Int, height: Int, colorMode: ColorMode, bytes: [UInt8]) {
      self.width = width
      self.height = height
      self.colorMode = colorMode
      self.bytes = bytes
    }
  }

  /// A layer blend mode.
  public enum BlendMode: UInt16, Sendable, Hashable, CaseIterable {
    /// Normal.
    case normal = 0
    /// Multiply.
    case multiply
    /// Screen.
    case screen
    /// Overlay.
    case overlay
    /// Darken.
    case darken
    /// Lighten.
    case lighten
    /// Color dodge.
    case colorDodge
    /// Color burn.
    case colorBurn
    /// Hard light.
    case hardLight
    /// Soft light.
    case softLight
    /// Difference.
    case difference
    /// Exclusion.
    case exclusion
    /// HSL hue.
    case hue
    /// HSL saturation.
    case saturation
    /// HSL color.
    case color
    /// HSL luminosity.
    case luminosity
    /// Addition.
    case addition
    /// Subtract.
    case subtract
    /// Divide.
    case divide
  }

  /// A layer.
  public struct Layer: Sendable, Hashable {
    /// The layer name.
    public var name: String
    /// What the layer holds.
    public var kind: Kind
    /// Layer flags.
    public var flags: Flags
    /// Nesting depth as stored in the file (NOTE.1 in the spec).
    public var childLevel: Int
    /// Index of the parent group in ``Aseprite/layers``, or `nil` for top-level layers.
    public var parent: Int?
    /// Blend mode (always ``BlendMode/normal`` for background layers, and for groups unless the header
    /// has ``HeaderFlags/compositeGroups``).
    public var blendMode: BlendMode
    /// Opacity (255 unless the header has ``HeaderFlags/layerOpacity``).
    public var opacity: UInt8
    /// The layer's UUID, when the header has ``HeaderFlags/layerUUIDs``.
    public var uuid: UUID?
    /// User data.
    public var userData: UserData

    /// Creates a layer.
    public init(
      name: String,
      kind: Kind,
      flags: Flags,
      childLevel: Int = 0,
      parent: Int? = nil,
      blendMode: BlendMode = .normal,
      opacity: UInt8 = 255,
      uuid: UUID? = nil,
      userData: UserData = UserData()
    ) {
      self.name = name
      self.kind = kind
      self.flags = flags
      self.childLevel = childLevel
      self.parent = parent
      self.blendMode = blendMode
      self.opacity = opacity
      self.uuid = uuid
      self.userData = userData
    }

    /// What a layer holds.
    public enum Kind: Sendable, Hashable {
      /// Image cels.
      case image
      /// Child layers.
      case group
      /// Tilemap cels drawing from the tileset with this file ID (see ``Aseprite/tileset(id:)``).
      case tilemap(tileset: Int)
    }

    /// Layer flags.
    public struct Flags: OptionSet, Sendable, Hashable {
      /// The raw flag bits.
      public var rawValue: UInt16

      /// Creates flags from raw bits.
      public init(rawValue: UInt16) {
        self.rawValue = rawValue
      }

      /// Visible.
      public static let visible = Flags(rawValue: 1)
      /// Editable.
      public static let editable = Flags(rawValue: 2)
      /// Movement locked.
      public static let lockMovement = Flags(rawValue: 4)
      /// The background layer.
      public static let background = Flags(rawValue: 8)
      /// New cels are linked by default.
      public static let preferLinkedCels = Flags(rawValue: 16)
      /// A group shown collapsed.
      public static let collapsed = Flags(rawValue: 32)
      /// A reference layer (not part of the rendered sprite).
      public static let reference = Flags(rawValue: 64)
    }

    /// Whether the layer's own visibility flag is set (ancestors may still hide it).
    public var isVisible: Bool { flags.contains(.visible) }
    /// Whether the layer is editable.
    public var isEditable: Bool { flags.contains(.editable) }
    /// Whether the layer is the background layer.
    public var isBackground: Bool { flags.contains(.background) }
    /// Whether the layer is a reference layer.
    public var isReference: Bool { flags.contains(.reference) }
    /// Whether the layer is a group.
    public var isGroup: Bool { kind == .group }
  }

  /// An animation frame.
  public struct Frame: Sendable, Hashable {
    /// Duration in milliseconds.
    public var duration: Int
    /// The frame's cels, in file order; at most one per layer.
    public var cels: [Cel]

    /// Creates a frame.
    public init(duration: Int, cels: [Cel] = []) {
      self.duration = duration
      self.cels = cels
    }
  }

  /// The content of one layer in one frame.
  public struct Cel: Sendable, Hashable {
    /// Index of the layer in ``Aseprite/layers``.
    public var layer: Int
    /// Position of the top-left corner on the canvas.
    public var position: Point
    /// Cel opacity.
    public var opacity: UInt8
    /// Z-index: moves this cel `zIndex` layers up (or down) in this frame's stacking order.
    public var zIndex: Int
    /// Pixels, a tilemap, or a link to another frame's cel on the same layer.
    public var content: Content
    /// Precise (sub-pixel) bounds. Aseprite writes these for reference layers; when their size is non-zero,
    /// Aseprite draws the cel (of any layer) at their origin instead; see ``drawPosition``.
    public var extra: Extra?
    /// User data. A linked cel shares its source's user data; see ``Aseprite/cel(layer:frame:)``.
    public var userData: UserData

    /// Creates a cel.
    public init(
      layer: Int,
      position: Point,
      opacity: UInt8 = 255,
      zIndex: Int = 0,
      content: Content,
      extra: Extra? = nil,
      userData: UserData = UserData()
    ) {
      self.layer = layer
      self.position = position
      self.opacity = opacity
      self.zIndex = zIndex
      self.content = content
      self.extra = extra
      self.userData = userData
    }

    /// What a cel holds.
    public enum Content: Sendable, Hashable {
      /// Pixels in the sprite's color mode.
      case image(PixelBuffer)
      /// The content of the same layer's cel in `frame`, which holds it (links never chain); see
      /// ``Aseprite/cel(layer:frame:)``.
      case linked(frame: Int)
      /// A grid of tiles.
      case tilemap(Tilemap)
    }

    /// Precise cel bounds (Cel Extra chunk).
    public struct Extra: Sendable, Hashable {
      /// Precise left edge.
      public var x: Fixed
      /// Precise top edge.
      public var y: Fixed
      /// Width of the cel in the sprite.
      public var width: Fixed
      /// Height of the cel in the sprite.
      public var height: Fixed

      /// Creates precise bounds.
      public init(x: Fixed, y: Fixed, width: Fixed, height: Fixed) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
      }
    }
  }

  /// A grid of tiles in a tilemap cel.
  public struct Tilemap: Sendable, Hashable {
    /// Width in tiles.
    public var width: Int
    /// Height in tiles.
    public var height: Int
    /// Tiles, row-major, top row first.
    public var tiles: [Tile]

    /// Creates a tilemap.
    public init(width: Int, height: Int, tiles: [Tile]) {
      self.width = width
      self.height = height
      self.tiles = tiles
    }
  }

  /// One tilemap entry: a tile index plus flip flags.
  public struct Tile: Sendable, Hashable {
    /// Index into the tileset; 0 is the empty tile.
    public var index: Int
    /// Mirrored horizontally.
    public var flipX: Bool
    /// Mirrored vertically.
    public var flipY: Bool
    /// Transposed (x and y swapped). The tile is transposed first, then mirrored by the other flags.
    public var flipDiagonal: Bool

    /// Creates a tile.
    public init(index: Int, flipX: Bool = false, flipY: Bool = false, flipDiagonal: Bool = false) {
      self.index = index
      self.flipX = flipX
      self.flipY = flipY
      self.flipDiagonal = flipDiagonal
    }

    /// The empty tile.
    public static let empty = Tile(index: 0)
  }

  /// A set of equally sized tiles.
  public struct Tileset: Sendable, Hashable {
    /// The ID tilemap layers use to reference this tileset.
    public var id: Int
    /// Tileset flags as stored in the file.
    public var flags: Flags
    /// Tile size in pixels.
    public var tileSize: Size
    /// Number of tiles, including the empty tile 0.
    public var tileCount: Int
    /// The number shown for tile 1 in Aseprite's UI (display only).
    public var baseIndex: Int
    /// The tileset name.
    public var name: String
    /// The external file this tileset comes from, if any.
    public var external: ExternalReference?
    /// All tiles stacked vertically (`tileSize.width × tileSize.height·tileCount`), when embedded.
    public var image: PixelBuffer?
    /// User data of the tileset itself.
    public var userData: UserData
    /// User data of each tile, by tile index.
    public var tileUserData: [UserData]

    /// Creates a tileset.
    public init(
      id: Int,
      flags: Flags,
      tileSize: Size,
      tileCount: Int,
      baseIndex: Int = 1,
      name: String,
      external: ExternalReference? = nil,
      image: PixelBuffer? = nil,
      userData: UserData = UserData(),
      tileUserData: [UserData] = []
    ) {
      self.id = id
      self.flags = flags
      self.tileSize = tileSize
      self.tileCount = tileCount
      self.baseIndex = baseIndex
      self.name = name
      self.external = external
      self.image = image
      self.userData = userData
      self.tileUserData = tileUserData
    }

    /// Tileset flags.
    public struct Flags: OptionSet, Sendable, Hashable {
      /// The raw flag bits.
      public var rawValue: UInt32

      /// Creates flags from raw bits.
      public init(rawValue: UInt32) {
        self.rawValue = rawValue
      }

      /// Links to an external file.
      public static let externalFile = Flags(rawValue: 1)
      /// Tiles are embedded in this file.
      public static let embedded = Flags(rawValue: 2)
      /// Tile 0 is the empty tile (every file written by Aseprite 1.3 or later).
      public static let zeroIsEmpty = Flags(rawValue: 4)
      /// Match horizontally flipped tiles in Auto mode.
      public static let matchFlipX = Flags(rawValue: 8)
      /// Match vertically flipped tiles in Auto mode.
      public static let matchFlipY = Flags(rawValue: 16)
      /// Match diagonally flipped tiles in Auto mode.
      public static let matchFlipDiagonal = Flags(rawValue: 32)
    }

    /// Where an external tileset lives.
    public struct ExternalReference: Sendable, Hashable {
      /// ID of the entry in ``Aseprite/externalFiles``.
      public var fileID: Int
      /// ID of the tileset inside that file.
      public var tilesetID: Int

      /// Creates a reference.
      public init(fileID: Int, tilesetID: Int) {
        self.fileID = fileID
        self.tilesetID = tilesetID
      }
    }
  }

  /// Animation direction of a tag.
  public enum LoopDirection: UInt8, Sendable, Hashable, CaseIterable {
    /// First to last.
    case forward = 0
    /// Last to first.
    case reverse = 1
    /// First to last, then back.
    case pingPong = 2
    /// Last to first, then back.
    case pingPongReverse = 3
  }

  /// A named range of frames.
  public struct Tag: Sendable, Hashable {
    /// The tag name.
    public var name: String
    /// First frame (inclusive).
    public var from: Int
    /// Last frame (inclusive).
    public var to: Int
    /// Playback direction.
    public var direction: LoopDirection
    /// How many times to play; 0 means unspecified (loop forever in the editor, once on export).
    public var repeatCount: Int
    /// The tag color: the user-data color, or the deprecated RGB field for files without tag user data.
    public var color: Color
    /// User data.
    public var userData: UserData

    /// The tag's frames as a range, whichever way round `from` and `to` are stored.
    public var frames: ClosedRange<Int> { min(from, to)...max(from, to) }

    /// Creates a tag.
    public init(
      name: String,
      from: Int,
      to: Int,
      direction: LoopDirection = .forward,
      repeatCount: Int = 0,
      color: Color = .clear,
      userData: UserData = UserData()
    ) {
      self.name = name
      self.from = from
      self.to = to
      self.direction = direction
      self.repeatCount = repeatCount
      self.color = color
      self.userData = userData
    }
  }

  /// A named, animatable region of the canvas.
  public struct Slice: Sendable, Hashable {
    /// The slice name.
    public var name: String
    /// Keys, in file order; each applies from its frame until the next key.
    public var keys: [Key]
    /// User data.
    public var userData: UserData

    /// Creates a slice.
    public init(name: String, keys: [Key], userData: UserData = UserData()) {
      self.name = name
      self.keys = keys
      self.userData = userData
    }

    /// The slice's shape from a given frame on.
    public struct Key: Sendable, Hashable {
      /// The first frame this key applies to.
      public var frame: Int
      /// Bounds on the canvas; zero-sized when the slice is hidden from this frame on.
      public var bounds: Rect
      /// 9-slice center, relative to `bounds`.
      public var center: Rect?
      /// Pivot, relative to `bounds`' origin.
      public var pivot: Point?

      /// Creates a key.
      public init(frame: Int, bounds: Rect, center: Rect? = nil, pivot: Point? = nil) {
        self.frame = frame
        self.bounds = bounds
        self.center = center
        self.pivot = pivot
      }
    }

    /// Returns the key in effect at `frame`: the one with the latest start frame not after `frame`. When
    /// several keys start at the same frame, the last one in the file wins, as in Aseprite.
    public func key(forFrame frame: Int) -> Key? {
      var result: Key?
      for key in keys where key.frame <= frame && key.frame >= (result?.frame ?? Int.min) {
        result = key
      }
      return result
    }
  }

  /// The palette in effect from a given frame on.
  public struct Palette: Sendable, Hashable {
    /// The first frame this palette applies to.
    public var frame: Int
    /// The colors.
    public var entries: [Entry]

    /// Creates a palette.
    public init(frame: Int, entries: [Entry]) {
      self.frame = frame
      self.entries = entries
    }

    /// A palette color.
    public struct Entry: Sendable, Hashable {
      /// The color.
      public var color: Color
      /// The color's name, if any.
      public var name: String?

      /// Creates an entry.
      public init(color: Color, name: String? = nil) {
        self.color = color
        self.name = name
      }
    }
  }

  /// An external file referenced by this one.
  public struct ExternalFile: Sendable, Hashable {
    /// The ID other chunks use to reference this entry.
    public var id: Int
    /// What the entry is.
    public var kind: Kind
    /// A file name or, for extensions, an extension ID such as `publisher/ExtensionName`.
    public var name: String

    /// Creates an entry.
    public init(id: Int, kind: Kind, name: String) {
      self.id = id
      self.kind = kind
      self.name = name
    }

    /// What an external file entry refers to.
    public enum Kind: UInt8, Sendable, Hashable {
      /// An external palette.
      case palette = 0
      /// An external tileset.
      case tileset = 1
      /// An extension whose properties appear in user data.
      case extensionProperties = 2
      /// The extension that manages tiles.
      case extensionTileManagement = 3
    }
  }

  /// The color profile.
  public struct ColorProfile: Sendable, Hashable {
    /// The kind of profile.
    public var kind: Kind
    /// A fixed gamma, when the profile uses one (1.0 = linear).
    public var gamma: Fixed?

    /// Creates a color profile.
    public init(kind: Kind, gamma: Fixed? = nil) {
      self.kind = kind
      self.gamma = gamma
    }

    /// The kind of color profile.
    public enum Kind: Sendable, Hashable {
      /// No color profile (old files).
      case none
      /// sRGB.
      case sRGB
      /// An embedded ICC profile.
      case icc([UInt8])
    }
  }

  /// Text, color, and typed properties attached to an object.
  public struct UserData: Sendable, Hashable {
    /// Text, if set.
    public var text: String?
    /// Color, if set.
    public var color: Color?
    /// Property maps by key: 0 holds the user's properties, other keys are ``ExternalFile`` IDs of
    /// the extensions that own them.
    public var properties: [UInt32: [String: PropertyValue]]

    /// Creates user data.
    public init(text: String? = nil, color: Color? = nil, properties: [UInt32: [String: PropertyValue]] = [:]) {
      self.text = text
      self.color = color
      self.properties = properties
    }

    /// The user's own properties (key 0).
    public var userProperties: [String: PropertyValue] { properties[0] ?? [:] }
  }

  /// A typed user-data property value.
  public indirect enum PropertyValue: Sendable, Hashable {
    /// A boolean.
    case bool(Bool)
    /// A signed 8-bit integer.
    case int8(Int8)
    /// An unsigned 8-bit integer.
    case uint8(UInt8)
    /// A signed 16-bit integer.
    case int16(Int16)
    /// An unsigned 16-bit integer.
    case uint16(UInt16)
    /// A signed 32-bit integer.
    case int32(Int32)
    /// An unsigned 32-bit integer.
    case uint32(UInt32)
    /// A signed 64-bit integer.
    case int64(Int64)
    /// An unsigned 64-bit integer.
    case uint64(UInt64)
    /// A 16.16 fixed-point number.
    case fixed(Fixed)
    /// A 32-bit float.
    case float(Float)
    /// A 64-bit float.
    case double(Double)
    /// A string.
    case string(String)
    /// A point.
    case point(Point)
    /// A size.
    case size(Size)
    /// A rectangle.
    case rect(Rect)
    /// A list of values.
    case vector([PropertyValue])
    /// A nested property map.
    case properties([String: PropertyValue])
    /// A UUID.
    case uuid(UUID)
  }

  /// A recoverable problem found while decoding.
  public struct Warning: Sendable, Hashable, CustomStringConvertible {
    /// Byte offset of the chunk or field involved.
    public var offset: Int
    /// What was skipped and why.
    public var message: String

    /// Creates a warning.
    public init(offset: Int, message: String) {
      self.offset = offset
      self.message = message
    }

    /// `message (at offset N)`.
    public var description: String { "\(message) (at offset \(offset))" }
  }

  /// Options for rendering frames.
  public struct RenderOptions: Sendable {
    /// Decides which layers are drawn. A layer is drawn only if it and every group containing it pass.
    /// When `nil`, layers are drawn like Aseprite draws them: visible, non-reference layers. Reference layers
    /// drawn through a filter are drawn at their integer position, without Aseprite's sub-pixel scaling.
    public var layerFilter: (@Sendable (Layer) -> Bool)?
    /// Whether groups are composited separately before being blended into what's below them.
    /// When `nil`, the file's ``HeaderFlags/compositeGroups`` flag decides.
    public var compositeGroups: Bool?

    /// Creates render options.
    public init(layerFilter: (@Sendable (Layer) -> Bool)? = nil, compositeGroups: Bool? = nil) {
      self.layerFilter = layerFilter
      self.compositeGroups = compositeGroups
    }
  }
}
