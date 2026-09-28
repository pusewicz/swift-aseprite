/// An error thrown while decoding an Aseprite file.
///
/// Decoding never traps on malformed input: every structural problem surfaces as one of these cases,
/// with the byte offset where it was detected. Problems that Aseprite itself tolerates (a cel pointing
/// at a missing layer, corrupt compressed pixels, an unknown chunk type, ...) are not errors; they are
/// handled the way Aseprite handles them and reported in ``Aseprite/warnings`` instead.
public enum AsepriteError: Error, Sendable, Hashable {
  /// The data ended, or a chunk or frame ended, before a value could be read.
  case truncated(offset: Int)
  /// A header or frame magic number is wrong.
  case invalidMagic(offset: Int, found: UInt16)
  /// A field holds a value the format doesn't allow (unknown color depth, unknown blend mode, layers
  /// nested deeper than ``Aseprite/maximumLayerDepth``, ...).
  case invalidValue(field: String, value: Int, offset: Int)
  /// A file could not be read (``Aseprite/init(contentsOf:)`` only); `reason` describes the I/O error.
  case unreadableFile(path: String, reason: String)
}
