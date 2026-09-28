/// Builds Aseprite files byte by byte, for inputs too large or too odd to check in as fixtures.
/// Layouts follow the spec; see Fixtures/Generate/ase_writer.rb for the fixture-side equivalent.
struct TestFile {
  /// A chunk: type and payload (the size header is added when writing).
  typealias Chunk = (type: UInt16, payload: [UInt8])

  var width = 1
  var height = 1
  var depth: UInt16 = 32
  var flags: UInt32 = 1
  var colorCount: UInt16 = 256
  var frames: [[Chunk]] = [[]]

  /// The complete file.
  var bytes: [UInt8] {
    var body: [UInt8] = []
    for chunks in frames {
      var frame: [UInt8] = []
      for chunk in chunks {
        frame += Self.dword(chunk.payload.count + 6) + Self.word(Int(chunk.type)) + chunk.payload
      }
      let count = min(chunks.count, 0xFFFF)
      body += Self.dword(frame.count + 16) + Self.word(0xF1FA) + Self.word(count) + Self.word(100) + [0, 0]
      body += Self.dword(chunks.count) + frame
    }
    var header = Self.word(0xA5E0) + Self.word(frames.count) + Self.word(width) + Self.word(height)
    header += Self.word(Int(depth)) + Self.dword(Int(flags)) + Self.word(100) + [UInt8](repeating: 0, count: 8)
    header += [0, 0, 0, 0] + Self.word(Int(colorCount)) + [1, 1] + [UInt8](repeating: 0, count: 8)
    header += [UInt8](repeating: 0, count: 84)
    return Self.dword(128 + body.count) + header + body
  }

  static func layer(_ name: String = "l", type: Int = 0, level: Int = 0) -> Chunk {
    (0x2004, word(3) + word(type) + word(level) + word(0) + word(0) + word(0) + [255, 0, 0, 0] + string(name))
  }

  static func rawCel(layer: Int, x: Int = 0, y: Int = 0, width: Int = 1, height: Int = 1, pixels: [UInt8]) -> Chunk {
    (0x2005, celHeader(layer: layer, x: x, y: y, type: 0) + word(width) + word(height) + pixels)
  }

  static func compressedCel(layer: Int, width: Int, height: Int, data: [UInt8]) -> Chunk {
    (0x2005, celHeader(layer: layer, x: 0, y: 0, type: 2) + word(width) + word(height) + data)
  }

  static func linkedCel(layer: Int, frame: Int) -> Chunk {
    (0x2005, celHeader(layer: layer, x: 0, y: 0, type: 1) + word(frame))
  }

  static func celHeader(layer: Int, x: Int, y: Int, type: Int) -> [UInt8] {
    word(layer) + word(x & 0xFFFF) + word(y & 0xFFFF) + [255] + word(type) + word(0) + [0, 0, 0, 0, 0]
  }

  static func word(_ value: Int) -> [UInt8] {
    [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
  }

  static func dword(_ value: Int) -> [UInt8] {
    (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
  }

  static func string(_ value: String) -> [UInt8] {
    word(value.utf8.count) + Array(value.utf8)
  }
}
