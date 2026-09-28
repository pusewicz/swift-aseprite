/// A bounds-checked little-endian reader over a byte array.
///
/// Every read checks against `end`, so a reader created for a single chunk can never read into the
/// next one: an over-read throws ``AsepriteError/truncated(offset:)`` instead.
struct ByteReader {
  /// The whole file; readers for frames and chunks share it and only narrow `end`.
  let bytes: [UInt8]
  /// Offset of the next byte to read.
  var position: Int
  /// Offset one past the last byte this reader may read.
  let end: Int

  /// Creates a reader over all of `bytes`.
  init(_ bytes: [UInt8]) {
    self.bytes = bytes
    self.position = 0
    self.end = bytes.count
  }

  private init(bytes: [UInt8], position: Int, end: Int) {
    self.bytes = bytes
    self.position = position
    self.end = end
  }

  /// The number of bytes left before `end`.
  var remaining: Int { end - position }

  /// Returns a reader over the next `count` bytes and advances past them.
  mutating func take(_ count: Int) throws(AsepriteError) -> ByteReader {
    try require(count)
    let sub = ByteReader(bytes: bytes, position: position, end: position + count)
    position += count
    return sub
  }

  /// Returns a reader starting at the current position with its end at absolute offset `end`.
  func bounded(to end: Int) throws(AsepriteError) -> ByteReader {
    guard end >= position, end <= self.end else { throw .truncated(offset: min(max(end, position), self.end)) }
    return ByteReader(bytes: bytes, position: position, end: end)
  }

  /// Moves to absolute offset `offset`, which must lie within this reader's range.
  mutating func seek(to offset: Int) throws(AsepriteError) {
    guard offset >= 0, offset <= end else { throw .truncated(offset: min(max(offset, 0), end)) }
    position = offset
  }

  /// Skips `count` bytes.
  mutating func skip(_ count: Int) throws(AsepriteError) {
    try require(count)
    position += count
  }

  /// Reads a `BYTE`.
  mutating func u8() throws(AsepriteError) -> UInt8 {
    try require(1)
    defer { position += 1 }
    return bytes[position]
  }

  /// Reads a `WORD`.
  mutating func u16() throws(AsepriteError) -> UInt16 {
    try require(2)
    defer { position += 2 }
    return UInt16(bytes[position]) | UInt16(bytes[position + 1]) << 8
  }

  /// Reads a `SHORT`.
  mutating func i16() throws(AsepriteError) -> Int16 {
    Int16(bitPattern: try u16())
  }

  /// Reads a `DWORD`.
  mutating func u32() throws(AsepriteError) -> UInt32 {
    try require(4)
    defer { position += 4 }
    return UInt32(bytes[position]) | UInt32(bytes[position + 1]) << 8 | UInt32(bytes[position + 2]) << 16
      | UInt32(bytes[position + 3]) << 24
  }

  /// Reads a `LONG`.
  mutating func i32() throws(AsepriteError) -> Int32 {
    Int32(bitPattern: try u32())
  }

  /// Reads a `QWORD`.
  mutating func u64() throws(AsepriteError) -> UInt64 {
    let low = UInt64(try u32())
    let high = UInt64(try u32())
    return low | high << 32
  }

  /// Reads a `LONG64`.
  mutating func i64() throws(AsepriteError) -> Int64 {
    Int64(bitPattern: try u64())
  }

  /// Reads a `FLOAT`.
  mutating func f32() throws(AsepriteError) -> Float {
    Float(bitPattern: try u32())
  }

  /// Reads a `DOUBLE`.
  mutating func f64() throws(AsepriteError) -> Double {
    Double(bitPattern: try u64())
  }

  /// Reads a `FIXED` (signed 16.16).
  mutating func fixed() throws(AsepriteError) -> Aseprite.Fixed {
    Aseprite.Fixed(rawValue: try i32())
  }

  /// Reads a `STRING`: a `WORD` length followed by that many UTF-8 bytes.
  ///
  /// Invalid UTF-8 is repaired with replacement characters rather than rejected.
  mutating func string() throws(AsepriteError) -> String {
    let count = Int(try u16())
    try require(count)
    defer { position += count }
    return String(decoding: bytes[position..<position + count], as: UTF8.self)
  }

  /// Reads a `UUID`.
  mutating func uuid() throws(AsepriteError) -> Aseprite.UUID {
    Aseprite.UUID(bytes: try array(16))
  }

  /// Reads `count` raw bytes.
  mutating func array(_ count: Int) throws(AsepriteError) -> [UInt8] {
    try require(count)
    defer { position += count }
    return Array(bytes[position..<position + count])
  }

  /// Returns the remaining bytes of this reader as a slice, without copying, and consumes them.
  mutating func rest() -> ArraySlice<UInt8> {
    defer { position = end }
    return bytes[position..<end]
  }

  private func require(_ count: Int) throws(AsepriteError) {
    guard count >= 0, count <= end - position else { throw .truncated(offset: position) }
  }
}
