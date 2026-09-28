/// Pixel blending, an exact integer port of Aseprite's RGBA blenders (src/doc/blend_funcs.cpp).
///
/// Colors are packed like Aseprite's `color_t`: red in the low byte, alpha in the high byte, which is also
/// the in-memory layout of ``Aseprite/Color`` on little-endian machines. Blend modes use Aseprite's
/// "new blending method" (the `_n` blenders), which Aseprite uses by default and for all exports.
enum Blend {
  static let alphaMask: UInt32 = 0xFF00_0000
  static let rgbMask: UInt32 = 0x00FF_FFFF

  /// Blends `source` over `backdrop` with `mode`, scaling the source alpha by `opacity` (0...255).
  static func blend(_ mode: Aseprite.BlendMode, _ backdrop: UInt32, _ source: UInt32, opacity: Int) -> UInt32 {
    guard mode != .normal, backdrop & alphaMask != 0 else {
      return normal(backdrop, source, opacity: opacity)
    }
    // RGBA_BLENDER_N: fade from normal to the blended color as the backdrop becomes opaque.
    let normalResult = normal(backdrop, source, opacity: opacity)
    let blended = legacy(mode, backdrop, source, opacity: opacity)
    let backdropAlpha = alpha(backdrop)
    let normalToBlend = merge(normalResult, blended, opacity: backdropAlpha)
    let sourceAlpha = mul(alpha(source), opacity)
    return merge(normalToBlend, blended, opacity: mul(backdropAlpha, sourceAlpha))
  }

  /// `rgba_blender_normal`: Porter-Duff source-over with straight alpha.
  static func normal(_ backdrop: UInt32, _ source: UInt32, opacity: Int) -> UInt32 {
    if backdrop & alphaMask == 0 {
      return source & rgbMask | UInt32(truncatingIfNeeded: mul(alpha(source), opacity)) << 24
    }
    if source & alphaMask == 0 {
      return backdrop
    }
    let sourceAlpha = mul(alpha(source), opacity)
    let backdropAlpha = alpha(backdrop)
    let resultAlpha = sourceAlpha + backdropAlpha - mul(backdropAlpha, sourceAlpha)
    return pack(
      red(backdrop) + (red(source) - red(backdrop)) * sourceAlpha / resultAlpha,
      green(backdrop) + (green(source) - green(backdrop)) * sourceAlpha / resultAlpha,
      blue(backdrop) + (blue(source) - blue(backdrop)) * sourceAlpha / resultAlpha,
      resultAlpha
    )
  }

  /// `rgba_blender_merge`: linear interpolation from `backdrop` to `source` by `opacity`.
  static func merge(_ backdrop: UInt32, _ source: UInt32, opacity: Int) -> UInt32 {
    let backdropAlpha = alpha(backdrop)
    let sourceAlpha = alpha(source)
    var r: Int
    var g: Int
    var b: Int
    if backdropAlpha == 0 {
      (r, g, b) = (red(source), green(source), blue(source))
    } else if sourceAlpha == 0 {
      (r, g, b) = (red(backdrop), green(backdrop), blue(backdrop))
    } else {
      r = red(backdrop) + mul(red(source) - red(backdrop), opacity)
      g = green(backdrop) + mul(green(source) - green(backdrop), opacity)
      b = blue(backdrop) + mul(blue(source) - blue(backdrop), opacity)
    }
    let a = backdropAlpha + mul(sourceAlpha - backdropAlpha, opacity)
    if a == 0 {
      (r, g, b) = (0, 0, 0)
    }
    return pack(r, g, b, a)
  }

  /// The per-mode blenders (`rgba_blender_multiply` and friends): blend the color channels, keep the
  /// source alpha, then composite normally.
  private static func legacy(_ mode: Aseprite.BlendMode, _ backdrop: UInt32, _ source: UInt32, opacity: Int) -> UInt32 {
    let (br, bg, bb) = (red(backdrop), green(backdrop), blue(backdrop))
    let (sr, sg, sb) = (red(source), green(source), blue(source))
    let channels: (Int, Int, Int)
    switch mode {
    case .normal: channels = (sr, sg, sb)
    case .multiply: channels = (mul(br, sr), mul(bg, sg), mul(bb, sb))
    case .screen: channels = (screen(br, sr), screen(bg, sg), screen(bb, sb))
    case .overlay: channels = (hardLight(sr, br), hardLight(sg, bg), hardLight(sb, bb))
    case .darken: channels = (min(br, sr), min(bg, sg), min(bb, sb))
    case .lighten: channels = (max(br, sr), max(bg, sg), max(bb, sb))
    case .colorDodge: channels = (colorDodge(br, sr), colorDodge(bg, sg), colorDodge(bb, sb))
    case .colorBurn: channels = (colorBurn(br, sr), colorBurn(bg, sg), colorBurn(bb, sb))
    case .hardLight: channels = (hardLight(br, sr), hardLight(bg, sg), hardLight(bb, sb))
    case .softLight: channels = (softLight(br, sr), softLight(bg, sg), softLight(bb, sb))
    case .difference: channels = (abs(br - sr), abs(bg - sg), abs(bb - sb))
    case .exclusion: channels = (exclusion(br, sr), exclusion(bg, sg), exclusion(bb, sb))
    case .addition: channels = (min(br + sr, 255), min(bg + sg, 255), min(bb + sb, 255))
    case .subtract: channels = (max(br - sr, 0), max(bg - sg, 0), max(bb - sb, 0))
    case .divide: channels = (divide(br, sr), divide(bg, sg), divide(bb, sb))
    case .hue, .saturation, .color, .luminosity: channels = hsl(mode, backdrop: (br, bg, bb), source: (sr, sg, sb))
    }
    let composed = pack(channels.0, channels.1, channels.2, 0) | source & alphaMask
    return normal(backdrop, composed, opacity: opacity)
  }

  // MARK: - Channel math

  /// Pixman's `MUL_UN8`: `a * b / 255`, rounded. `a` may be negative (arithmetic shifts, as in C).
  @inline(__always)
  static func mul(_ a: Int, _ b: Int) -> Int {
    let t = a * b + 0x80
    return ((t >> 8) + t) >> 8
  }

  /// Pixman's `DIV_UN8`: `a * 255 / b`, rounded.
  @inline(__always)
  private static func div(_ a: Int, _ b: Int) -> Int {
    (a * 255 + b / 2) / b
  }

  private static func screen(_ b: Int, _ s: Int) -> Int {
    b + s - mul(b, s)
  }

  private static func hardLight(_ b: Int, _ s: Int) -> Int {
    s < 128 ? mul(b, s << 1) : screen(b, (s << 1) - 255)
  }

  private static func exclusion(_ b: Int, _ s: Int) -> Int {
    b + s - 2 * mul(b, s)
  }

  private static func divide(_ b: Int, _ s: Int) -> Int {
    if b == 0 { return 0 }
    if b >= s { return 255 }
    return div(b, s)
  }

  private static func colorDodge(_ b: Int, _ s: Int) -> Int {
    if b == 0 { return 0 }
    let inverse = 255 - s
    if b >= inverse { return 255 }
    return div(b, inverse)
  }

  private static func colorBurn(_ b: Int, _ s: Int) -> Int {
    if b == 255 { return 255 }
    let inverse = 255 - b
    if inverse >= s { return 0 }
    return 255 - div(inverse, s)
  }

  private static func softLight(_ backdrop: Int, _ source: Int) -> Int {
    let b = Double(backdrop) / 255
    let s = Double(source) / 255
    let d = b <= 0.25 ? ((16 * b - 12) * b + 4) * b : b.squareRoot()
    let r = s <= 0.5 ? b - (1 - 2 * s) * b * (1 - b) : b + (2 * s - 1) * (d - b)
    return truncate(r * 255 + 0.5)
  }

  private static func hsl(
    _ mode: Aseprite.BlendMode,
    backdrop: (Int, Int, Int),
    source: (Int, Int, Int)
  ) -> (Int, Int, Int) {
    let b = (Double(backdrop.0) / 255, Double(backdrop.1) / 255, Double(backdrop.2) / 255)
    let s = (Double(source.0) / 255, Double(source.1) / 255, Double(source.2) / 255)
    var c: (Double, Double, Double)
    switch mode {
    case .hue:
      c = setSaturation(s, saturation(b))
      c = setLuminosity(c, luminosity(b))
    case .saturation:
      c = setSaturation(b, saturation(s))
      c = setLuminosity(c, luminosity(b))
    case .color:
      c = setLuminosity(s, luminosity(b))
    default:
      c = setLuminosity(b, luminosity(s))
    }
    return (truncate(255 * c.0), truncate(255 * c.1), truncate(255 * c.2))
  }

  private static func luminosity(_ c: (Double, Double, Double)) -> Double {
    0.3 * c.0 + 0.59 * c.1 + 0.11 * c.2
  }

  private static func saturation(_ c: (Double, Double, Double)) -> Double {
    max(c.0, max(c.1, c.2)) - min(c.0, min(c.1, c.2))
  }

  private static func setLuminosity(_ c: (Double, Double, Double), _ l: Double) -> (Double, Double, Double) {
    let d = l - luminosity(c)
    var (r, g, b) = (c.0 + d, c.1 + d, c.2 + d)
    let lum = luminosity((r, g, b))
    let n = min(r, min(g, b))
    let x = max(r, max(g, b))
    if n < 0 {
      r = lum + (r - lum) * lum / (lum - n)
      g = lum + (g - lum) * lum / (lum - n)
      b = lum + (b - lum) * lum / (lum - n)
    }
    if x > 1 {
      r = lum + (r - lum) * (1 - lum) / (x - lum)
      g = lum + (g - lum) * (1 - lum) / (x - lum)
      b = lum + (b - lum) * (1 - lum) / (x - lum)
    }
    return (r, g, b)
  }

  private static func setSaturation(_ c: (Double, Double, Double), _ s: Double) -> (Double, Double, Double) {
    let low = min(min(c.0, c.1), c.2)
    let high = max(max(c.0, c.1), c.2)
    let range = high - low
    guard range > 0 else { return (0, 0, 0) }
    return ((c.0 - low) * s / range, (c.1 - low) * s / range, (c.2 - low) * s / range)
  }

  /// C's `int(value)`: truncation toward zero. Non-finite values (undefined behavior in C) become 0.
  private static func truncate(_ value: Double) -> Int {
    value.isFinite ? Int(value.rounded(.towardZero)) : 0
  }

  // MARK: - Packing

  @inline(__always)
  static func red(_ c: UInt32) -> Int { Int(c & 0xFF) }
  @inline(__always)
  static func green(_ c: UInt32) -> Int { Int(c >> 8 & 0xFF) }
  @inline(__always)
  static func blue(_ c: UInt32) -> Int { Int(c >> 16 & 0xFF) }
  @inline(__always)
  static func alpha(_ c: UInt32) -> Int { Int(c >> 24) }

  /// Aseprite's `rgba()`: each component is truncated to 8 bits.
  @inline(__always)
  static func pack(_ r: Int, _ g: Int, _ b: Int, _ a: Int) -> UInt32 {
    UInt32(UInt8(truncatingIfNeeded: r)) | UInt32(UInt8(truncatingIfNeeded: g)) << 8
      | UInt32(UInt8(truncatingIfNeeded: b)) << 16 | UInt32(UInt8(truncatingIfNeeded: a)) << 24
  }
}
