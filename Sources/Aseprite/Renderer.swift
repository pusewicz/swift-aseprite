/// Composites frames the way Aseprite does (src/doc/render_plan.cpp, src/render/render.cpp).
///
/// Layers are ordered into a render plan (with per-cel z-index applied), background layers are drawn in
/// a first pass and everything else in a second, and, when groups are composited, each group is rendered
/// into its own buffer and blended into its parent with the group's opacity and blend mode.
struct Renderer {
  private let sprite: Aseprite
  private let compositeGroups: Bool
  /// Children of each layer, bottom to top.
  private let children: [[Int]]
  /// Top-level layers, bottom to top.
  private let topLevel: [Int]
  /// Whether each layer and all of its ancestors pass the layer filter.
  private let drawn: [Bool]

  /// An entry of a render plan: a layer (or the root group, `nil`) and its stacking order.
  private struct Item {
    var layer: Int?
    var order: Int
    var zIndex: Int
  }

  init(sprite: Aseprite, options: Aseprite.RenderOptions) {
    self.sprite = sprite
    self.compositeGroups = options.compositeGroups ?? sprite.flags.contains(.compositeGroups)

    var children = [[Int]](repeating: [], count: sprite.layers.count)
    var topLevel: [Int] = []
    for (index, layer) in sprite.layers.enumerated() {
      if let parent = layer.parent, children.indices.contains(parent) {
        children[parent].append(index)
      } else {
        topLevel.append(index)
      }
    }
    self.children = children
    self.topLevel = topLevel

    let filter = options.layerFilter ?? { $0.isVisible && !$0.isReference }
    var drawn = [Bool](repeating: false, count: sprite.layers.count)
    for (index, layer) in sprite.layers.enumerated() {
      // Parents always precede their children, so the parent's value is already final.
      let parentDrawn = layer.parent.map { $0 < index ? drawn[$0] : false } ?? true
      drawn[index] = parentDrawn && filter(layer)
    }
    self.drawn = drawn
  }

  /// Renders `frame`; frames outside the sprite render fully transparent.
  func render(frame: Int) -> Aseprite.Image {
    var canvas = [UInt32](repeating: 0, count: sprite.width * sprite.height)
    if sprite.frames.indices.contains(frame) {
      let palette = sprite.palette(forFrame: frame).entries.map { packed($0.color) }

      // Indexed sprites with a visible background start from the transparent color's palette entry.
      if sprite.colorMode == .indexed, let first = topLevel.first, sprite.layers[first].isBackground,
        drawn[first]
      {
        let index = Int(sprite.transparentIndex)
        let fill = palette.indices.contains(index) ? palette[index] : 0
        canvas = [UInt32](repeating: fill, count: canvas.count)
      }

      // Each layer's cel in this frame, links resolved; the first cel of a layer wins, as when decoding.
      var cels = [Aseprite.Cel?](repeating: nil, count: sprite.layers.count)
      for cel in sprite.frames[frame].cels where cels.indices.contains(cel.layer) && cels[cel.layer] == nil {
        cels[cel.layer] = sprite.resolved(cel)
      }

      let plan = rootPlan(cels)
      draw(plan, into: &canvas, cels: cels, palette: palette, backgroundPass: true)
      draw(plan, into: &canvas, cels: cels, palette: palette, backgroundPass: false)
    }

    var image = Aseprite.Image(width: sprite.width, height: sprite.height)
    for (index, color) in canvas.enumerated() {
      image.pixels[index] = Aseprite.Color(
        r: UInt8(truncatingIfNeeded: color),
        g: UInt8(truncatingIfNeeded: color >> 8),
        b: UInt8(truncatingIfNeeded: color >> 16),
        a: UInt8(truncatingIfNeeded: color >> 24)
      )
    }
    return image
  }

  // MARK: - Render plan

  /// The plan for the whole sprite: `RenderPlan::addLayer(sprite->root())`.
  private func rootPlan(_ cels: [Aseprite.Cel?]) -> [Item] {
    var items: [Item] = []
    var order = 1  // The root group takes the first order number.
    if compositeGroups {
      items.append(Item(layer: nil, order: order, zIndex: 0))
    } else {
      for layer in topLevel {
        add(layer, cels, order: &order, to: &items)
      }
    }
    return finish(items)
  }

  /// The plan for a composited group's children.
  private func groupPlan(_ layers: [Int], _ cels: [Aseprite.Cel?]) -> [Item] {
    var items: [Item] = []
    var order = 0
    for layer in layers {
      add(layer, cels, order: &order, to: &items)
    }
    return finish(items)
  }

  private func add(_ layer: Int, _ cels: [Aseprite.Cel?], order: inout Int, to items: inout [Item]) {
    order += 1
    if sprite.layers[layer].isGroup && !compositeGroups {
      for child in children[layer] {
        add(child, cels, order: &order, to: &items)
      }
    } else {
      let zIndex = cels[layer]?.zIndex ?? 0
      items.append(Item(layer: layer, order: order, zIndex: zIndex))
    }
  }

  /// `RenderPlan::processZIndexes`: apply z-indexes, then drop layers that aren't drawn.
  private func finish(_ plan: [Item]) -> [Item] {
    var items = plan
    if items.contains(where: { $0.zIndex != 0 }) {
      for index in items.indices {
        items[index].order += items[index].zIndex
      }
      items.sort { ($0.order, $0.zIndex) < ($1.order, $1.zIndex) }
    }
    return items.filter { item in item.layer.map { drawn[$0] } ?? true }
  }

  // MARK: - Drawing

  private func draw(
    _ plan: [Item],
    into buffer: inout [UInt32],
    cels: [Aseprite.Cel?],
    palette: [UInt32],
    backgroundPass: Bool
  ) {
    for item in plan {
      guard let index = item.layer else {
        drawGroup(topLevel, opacity: 255, mode: .normal, into: &buffer, cels, palette, backgroundPass)
        continue
      }
      let layer = sprite.layers[index]
      if layer.isGroup {
        drawGroup(
          children[index],
          opacity: Int(layer.opacity),
          mode: layer.blendMode,
          into: &buffer,
          cels,
          palette,
          backgroundPass
        )
        continue
      }
      guard layer.isBackground == backgroundPass, let cel = cels[index] else {
        continue
      }
      let opacity = Blend.mul(Int(cel.opacity), Int(layer.opacity))
      switch cel.content {
      case .image(let pixels):
        drawPixels(pixels, cel: cel, into: &buffer, palette: palette, opacity: opacity, mode: layer.blendMode)
      case .tilemap(let tilemap):
        if case .tilemap(let id) = layer.kind, let tileset = sprite.tileset(id: id) {
          drawTilemap(
            tilemap,
            tileset: tileset,
            at: cel.drawPosition,
            into: &buffer,
            palette,
            opacity,
            layer.blendMode
          )
        }
      case .linked:
        break  // A link that doesn't resolve draws nothing.
      }
    }
  }

  /// Renders a composited group into its own buffer, then blends that into `buffer`.
  private func drawGroup(
    _ layers: [Int],
    opacity: Int,
    mode: Aseprite.BlendMode,
    into buffer: inout [UInt32],
    _ cels: [Aseprite.Cel?],
    _ palette: [UInt32],
    _ backgroundPass: Bool
  ) {
    var group = [UInt32](repeating: 0, count: buffer.count)
    draw(
      groupPlan(layers, cels),
      into: &group,
      cels: cels,
      palette: palette,
      backgroundPass: backgroundPass
    )
    for index in buffer.indices where group[index] != 0 {
      buffer[index] = Blend.blend(mode, buffer[index], group[index], opacity: opacity)
    }
  }

  /// Draws a cel's pixels at its bounds origin, clipped to the canvas.
  private func drawPixels(
    _ pixels: Aseprite.PixelBuffer,
    cel: Aseprite.Cel,
    into buffer: inout [UInt32],
    palette: [UInt32],
    opacity: Int,
    mode: Aseprite.BlendMode
  ) {
    let origin = cel.drawPosition
    let left = max(origin.x, 0)
    let right = min(origin.x + pixels.width, sprite.width)
    let top = max(origin.y, 0)
    let bottom = min(origin.y + pixels.height, sprite.height)
    guard left < right, top < bottom else { return }
    for y in top..<bottom {
      for x in left..<right {
        guard let color = color(pixels, x: x - origin.x, y: y - origin.y, palette: palette) else { continue }
        let index = y * sprite.width + x
        buffer[index] = Blend.blend(mode, buffer[index], color, opacity: opacity)
      }
    }
  }
  private func drawTilemap(
    _ tilemap: Aseprite.Tilemap,
    tileset: Aseprite.Tileset,
    at origin: Aseprite.Point,
    into buffer: inout [UInt32],
    _ palette: [UInt32],
    _ opacity: Int,
    _ mode: Aseprite.BlendMode
  ) {
    guard let image = tileset.image else { return }
    let size = tileset.tileSize
    for row in 0..<tilemap.height {
      for column in 0..<tilemap.width {
        let tile = tilemap.tiles[row * tilemap.width + column]
        // Only the exact empty value is skipped; tile 0 with flip flags is still drawn.
        guard tile != .empty, tile.index < tileset.tileCount else { continue }
        let tileOrigin = Aseprite.Point(x: origin.x + column * size.width, y: origin.y + row * size.height)
        drawTile(tile, image, size: size, at: tileOrigin, into: &buffer, palette, opacity, mode)
      }
    }
  }

  /// Draws one tile. Flipped tiles follow `composite_image_general_with_tile_flags`, including its quirk
  /// of clearing destination pixels that fall outside a diagonally flipped non-square tile.
  private func drawTile(
    _ tile: Aseprite.Tile,
    _ image: Aseprite.PixelBuffer,
    size: Aseprite.Size,
    at origin: Aseprite.Point,
    into buffer: inout [UInt32],
    _ palette: [UInt32],
    _ opacity: Int,
    _ mode: Aseprite.BlendMode
  ) {
    let firstRow = tile.index * size.height
    let side = min(size.width, size.height)
    let left = max(origin.x, 0)
    let right = min(origin.x + size.width, sprite.width)
    let top = max(origin.y, 0)
    let bottom = min(origin.y + size.height, sprite.height)
    guard left < right, top < bottom else { return }
    for y in top..<bottom {
      for x in left..<right {
        let u = x - origin.x
        let v = y - origin.y
        var sourceX = tile.flipX ? size.width - 1 - u : u
        var sourceY = tile.flipY ? size.height - 1 - v : v
        let index = y * sprite.width + x
        if tile.flipDiagonal {
          swap(&sourceX, &sourceY)
          guard sourceX < side, sourceY < side else {
            buffer[index] = 0
            continue
          }
        }
        guard let color = color(image, x: sourceX, y: firstRow + sourceY, palette: palette) else { continue }
        buffer[index] = Blend.blend(mode, buffer[index], color, opacity: opacity)
      }
    }
  }

  /// The RGBA color of a pixel, or `nil` if it is the image's transparent ("mask") color or lies
  /// outside the buffer.
  private func color(_ pixels: Aseprite.PixelBuffer, x: Int, y: Int, palette: [UInt32]) -> UInt32? {
    let index = y * pixels.width + x
    let size = pixels.colorMode.bytesPerPixel
    guard x >= 0, x < pixels.width, y >= 0, (index + 1) * size <= pixels.bytes.count else { return nil }
    switch pixels.colorMode {
    case .rgba:
      let base = index * 4
      let value =
        UInt32(pixels.bytes[base]) | UInt32(pixels.bytes[base + 1]) << 8 | UInt32(pixels.bytes[base + 2]) << 16
        | UInt32(pixels.bytes[base + 3]) << 24
      return value == 0 ? nil : value
    case .grayscale:
      let value = Int(pixels.bytes[index * 2])
      let alpha = Int(pixels.bytes[index * 2 + 1])
      return value == 0 && alpha == 0 ? nil : Blend.pack(value, value, value, alpha)
    case .indexed:
      let entry = pixels.bytes[index]
      guard entry != sprite.transparentIndex else { return nil }
      return palette.indices.contains(Int(entry)) ? palette[Int(entry)] : 0
    }
  }

  private func packed(_ color: Aseprite.Color) -> UInt32 {
    Blend.pack(Int(color.r), Int(color.g), Int(color.b), Int(color.a))
  }
}
