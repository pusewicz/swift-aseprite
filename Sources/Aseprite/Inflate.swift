/// A zlib (RFC 1950) / DEFLATE (RFC 1951) decompressor.
///
/// Aseprite stores every cel image, tilemap, and tileset as a zlib stream. The output size is always
/// known up front (width × height × bytes per pixel), so the decompressor writes into a buffer of exactly
/// that size and treats both overflow and a short stream as errors. Huffman codes are validated the way
/// zlib validates them, and the Adler-32 trailer is checked.
enum Inflate {
  /// Why a zlib stream could not be decompressed.
  enum Failure: Error, Hashable {
    /// The two-byte zlib header is invalid or uses a preset dictionary.
    case invalidHeader
    /// A block uses the reserved block type 3.
    case invalidBlockType
    /// A stored block's length doesn't match its one's complement.
    case invalidStoredLength
    /// A Huffman code description is over-subscribed, incomplete, or otherwise invalid.
    case invalidCodeLengths
    /// A decoded symbol is not valid in its position.
    case invalidSymbol
    /// A back-reference points before the start of the output.
    case invalidDistance
    /// The stream produces more bytes than requested.
    case outputOverflow
    /// The stream ends before producing all the requested bytes.
    case outputTooShort
    /// The compressed data ends in the middle of the stream.
    case truncated
    /// The Adler-32 checksum doesn't match the decompressed data.
    case checksumMismatch
  }

  /// The largest possible DEFLATE expansion: a 258-byte match can cost as little as 2 bits.
  static let maximumRatio = 1032

  /// Decompresses the zlib stream in `input` into exactly `count` bytes.
  ///
  /// Bytes after the Adler-32 trailer are ignored, as zlib does. With `ignoringExcess`, a stream that
  /// produces more than `count` bytes is cut off after `count` bytes instead of failing; its checksum
  /// can't be verified then. Nothing is allocated until the header has been checked, and output pages
  /// are only touched as bytes are produced.
  static func zlib(
    _ input: ArraySlice<UInt8>,
    count: Int,
    ignoringExcess: Bool = false
  ) throws(Failure) -> [UInt8] {
    let (bound, overflow) = input.count.multipliedReportingOverflow(by: maximumRatio)
    guard count >= 0, overflow || count <= bound else { throw .outputTooShort }
    guard input.count >= 2 else { throw .truncated }
    let cmf = Int(input[input.startIndex])
    let flg = Int(input[input.startIndex + 1])
    guard cmf & 0x0F == 8, cmf >> 4 <= 7, (cmf << 8 | flg) % 31 == 0, flg & 0x20 == 0 else {
      throw .invalidHeader
    }

    var outcome = Outcome.failed(.truncated)
    let output = [UInt8](unsafeUninitializedCapacity: count) { destination, initialized in
      outcome = input.withUnsafeBufferPointer { source in
        var inflater = Inflater(source: source, destination: destination, fillsOnOverflow: ignoringExcess)
        do throws(Failure) {
          return .complete(checksum: try inflater.run())
        } catch {
          if error == .outputOverflow, ignoringExcess, inflater.position == count {
            return .cutShort
          }
          return .failed(error)
        }
      }
      if case .failed = outcome {
        initialized = 0
      } else {
        initialized = count
      }
    }
    switch outcome {
    case .complete(let checksum):
      guard adler32(output) == checksum else { throw .checksumMismatch }
      return output
    case .cutShort:
      return output
    case .failed(let failure):
      throw failure
    }
  }

  /// How a decompression run ended.
  private enum Outcome {
    case complete(checksum: UInt32)
    case cutShort
    case failed(Failure)
  }

  /// Computes the Adler-32 checksum of `bytes`.
  static func adler32(_ bytes: [UInt8]) -> UInt32 {
    bytes.withUnsafeBufferPointer { buffer in
      var a: UInt32 = 1
      var b: UInt32 = 0
      var index = 0
      while index < buffer.count {
        // 5552 is the largest run for which the sums cannot overflow 32 bits before reduction.
        let runEnd = min(index + 5552, buffer.count)
        // Sixteen bytes at a time: b gains 16·a plus the position-weighted byte sum.
        while runEnd - index >= 16 {
          var sum: UInt32 = 0
          var weighted: UInt32 = 0
          for offset in 0..<16 {
            let byte = UInt32(buffer[index + offset])
            sum &+= byte
            weighted &+= UInt32(16 - offset) &* byte
          }
          b &+= 16 &* a &+ weighted
          a &+= sum
          index += 16
        }
        while index < runEnd {
          a &+= UInt32(buffer[index])
          b &+= a
          index += 1
        }
        a %= 65521
        b %= 65521
      }
      return b << 16 | a
    }
  }
}

/// Decodes one zlib stream from `source` into exactly `destination.count` bytes.
///
/// Every write and every read is checked against the buffers' bounds before it happens, so the unsafe
/// buffers never see an out-of-range index, whatever the input.
private struct Inflater {
  let source: UnsafeBufferPointer<UInt8>
  let destination: UnsafeMutableBufferPointer<UInt8>
  /// Whether to fill the output completely before reporting an overflow.
  let fillsOnOverflow: Bool
  /// Next input byte not yet counted in `bits`.
  var index = 0
  /// Bit buffer, least significant bit first. Bits above `count` hold the upcoming input bytes (or zero),
  /// so refilling can OR whole words in without masking.
  var bits: UInt64 = 0
  /// Number of valid bits in `bits`.
  var count = 0
  /// Next output byte.
  var position = 0

  /// Decodes the stream and returns the Adler-32 checksum stored in its trailer.
  mutating func run() throws(Inflate.Failure) -> UInt32 {
    _ = try read(16)  // The zlib header, already validated by the caller.

    var isFinal = false
    while !isFinal {
      isFinal = try read(1) == 1
      switch try read(2) {
      case 0: try stored()
      case 1: try block(literals: Huffman.fixedLiterals, distances: Huffman.fixedDistances)
      case 2:
        let (literals, distances) = try dynamicTables()
        try block(literals: literals, distances: distances)
      default: throw .invalidBlockType
      }
    }

    alignToByte()
    var checksum: UInt32 = 0
    for _ in 0..<4 {
      let byte = try read(8)
      checksum = checksum << 8 | byte
    }
    guard position == destination.count else { throw .outputTooShort }
    return checksum
  }

  // MARK: - Blocks

  private mutating func stored() throws(Inflate.Failure) {
    alignToByte()
    let length = Int(try read(16))
    let complement = Int(try read(16))
    guard length == ~complement & 0xFFFF else { throw .invalidStoredLength }
    let fitting = min(length, destination.count - position)
    guard fitting == length || fillsOnOverflow else { throw .outputOverflow }

    // Whole bytes still in the bit buffer come first, then the rest straight from the input.
    var remaining = fitting
    while remaining > 0, count > 0 {
      destination[position] = UInt8(try read(8))
      position += 1
      remaining -= 1
    }
    if remaining > 0 {
      guard remaining <= source.count - index else { throw .truncated }
      for offset in 0..<remaining {
        destination[position + offset] = source[index + offset]
      }
      position += remaining
      index += remaining
      bits = 0  // The look-ahead bits described the bytes just copied.
    }
    guard fitting == length else { throw .outputOverflow }
  }

  private mutating func block(literals: Huffman, distances: Huffman) throws(Inflate.Failure) {
    try literals.fast.withUnsafeBufferPointer { (literalTable) throws(Inflate.Failure) in
      try distances.fast.withUnsafeBufferPointer { (distanceTable) throws(Inflate.Failure) in
        while true {
          let symbol = try decode(literals, table: literalTable)
          if symbol < 256 {
            guard position < destination.count else { throw .outputOverflow }
            destination[position] = UInt8(truncatingIfNeeded: symbol)
            position += 1
            continue
          }
          if symbol == 256 {
            return
          }
          let lengthIndex = symbol - 257
          guard lengthIndex < Self.lengthBase.count else { throw .invalidSymbol }
          let length = try Self.lengthBase[lengthIndex] + Int(read(Self.lengthExtra[lengthIndex]))
          let distanceSymbol = try decode(distances, table: distanceTable)
          guard distanceSymbol < Self.distanceBase.count else { throw .invalidSymbol }
          let distance = try Self.distanceBase[distanceSymbol] + Int(read(Self.distanceExtra[distanceSymbol]))
          guard distance <= position else { throw .invalidDistance }
          guard length <= destination.count - position else {
            if fillsOnOverflow {
              copyMatch(distance: distance, length: destination.count - position)
            }
            throw .outputOverflow
          }
          copyMatch(distance: distance, length: length)
        }
      }
    }
  }

  /// Appends `length` bytes copied from `distance` bytes back; the ranges may overlap.
  private mutating func copyMatch(distance: Int, length: Int) {
    // Callers checked that `distance <= position` and `length` fits, so every access is in bounds.
    guard let base = destination.baseAddress else { return }
    let source = base + position - distance
    var target = base + position
    if distance == 1 {
      target.update(repeating: source.pointee, count: length)
    } else {
      // Copy the repeating pattern in non-overlapping pieces that double in size each time.
      var remaining = length
      while remaining > 0 {
        let piece = min(remaining, target - source)
        target.update(from: source, count: piece)
        target += piece
        remaining -= piece
      }
    }
    position += length
  }

  private mutating func dynamicTables() throws(Inflate.Failure) -> (Huffman, Huffman) {
    let literalCount = Int(try read(5)) + 257
    let distanceCount = Int(try read(5)) + 1
    let codeLengthCount = Int(try read(4)) + 4
    guard literalCount <= 286, distanceCount <= 30 else { throw .invalidCodeLengths }

    var codeLengthLengths = [UInt8](repeating: 0, count: 19)
    for index in 0..<codeLengthCount {
      codeLengthLengths[Self.codeLengthOrder[index]] = UInt8(try read(3))
    }
    let codeLengths = try Huffman(lengths: codeLengthLengths, isCodeLengthCode: true, fastBits: 7)

    var lengths = [UInt8](repeating: 0, count: literalCount + distanceCount)
    var index = 0
    while index < lengths.count {
      let symbol = try codeLengths.fast.withUnsafeBufferPointer { (table) throws(Inflate.Failure) in
        try decode(codeLengths, table: table)
      }
      if symbol < 16 {
        lengths[index] = UInt8(symbol)
        index += 1
        continue
      }
      let value: UInt8
      let repeatCount: Int
      switch symbol {
      case 16:
        guard index > 0 else { throw .invalidCodeLengths }
        value = lengths[index - 1]
        repeatCount = try 3 + Int(read(2))
      case 17:
        value = 0
        repeatCount = try 3 + Int(read(3))
      default:
        value = 0
        repeatCount = try 11 + Int(read(7))
      }
      guard repeatCount <= lengths.count - index else { throw .invalidCodeLengths }
      for _ in 0..<repeatCount {
        lengths[index] = value
        index += 1
      }
    }
    guard lengths[256] != 0 else { throw .invalidCodeLengths }
    let literals = try Huffman(lengths: Array(lengths[0..<literalCount]), isCodeLengthCode: false, fastBits: 9)
    let distances = try Huffman(lengths: Array(lengths[literalCount...]), isCodeLengthCode: false, fastBits: 7)
    return (literals, distances)
  }

  // MARK: - Bits

  /// Tops the bit buffer up to at least 57 bits, or to whatever input is left.
  private mutating func refill() {
    if source.count - index >= 8, let base = source.baseAddress {
      let word = UInt64(littleEndian: UnsafeRawPointer(base + index).loadUnaligned(as: UInt64.self))
      bits |= word << UInt64(count)
      let taken = (63 - count) >> 3
      index += taken
      count += taken << 3
    } else {
      while count <= 56, index < source.count {
        bits |= UInt64(source[index]) << UInt64(count)
        index += 1
        count += 8
      }
    }
  }

  /// Reads `width` bits (at most 16) as an unsigned value.
  private mutating func read(_ width: Int) throws(Inflate.Failure) -> UInt32 {
    if count < width {
      refill()
      guard count >= width else { throw .truncated }
    }
    let value = UInt32(truncatingIfNeeded: bits & (UInt64(1) << UInt64(width) - 1))
    bits >>= UInt64(width)
    count -= width
    return value
  }

  /// Drops the bits up to the next byte boundary.
  private mutating func alignToByte() {
    let drop = count & 7
    bits >>= UInt64(drop)
    count -= drop
  }

  /// Decodes one symbol: a lookup in `table` (the code's fast table) for short codes, canonical bit-by-bit
  /// decoding for long ones.
  @inline(__always)
  private mutating func decode(
    _ code: Huffman,
    table: UnsafeBufferPointer<UInt16>
  ) throws(Inflate.Failure) -> Int {
    if count < 15 {
      refill()
    }
    let entry = table[Int(truncatingIfNeeded: bits) & (table.count - 1)]
    if entry != 0 {
      let length = Int(entry & 0xF)
      guard length <= count else { throw .truncated }
      bits >>= UInt64(length)
      count -= length
      return Int(entry >> 4)
    }

    var value = 0
    var first = 0
    var index = 0
    for length in 1...15 {
      guard count > 0 else { throw .truncated }
      value |= Int(bits & 1)
      bits >>= 1
      count -= 1
      let symbols = code.counts[length]
      if value - first < symbols {
        return Int(code.symbols[index + value - first])
      }
      index += symbols
      first = (first + symbols) << 1
      value <<= 1
    }
    throw .invalidSymbol
  }

  private static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
  private static let lengthBase = [
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227,
    258,
  ]
  private static let lengthExtra = [
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
  ]
  private static let distanceBase = [
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097,
    6145, 8193, 12289, 16385, 24577,
  ]
  private static let distanceExtra = [
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
  ]
}

/// A canonical Huffman code.
private struct Huffman: Sendable {
  /// Number of codes of each length (index 0 unused).
  var counts = [Int](repeating: 0, count: 16)
  /// Symbols ordered by code length, then by value.
  var symbols: [UInt16]
  /// Lookup table indexed by the next few input bits (its size is a power of two): `symbol << 4 | length`,
  /// or 0 for codes longer than the table covers.
  var fast: [UInt16]

  static let fixedLiterals = Huffman(
    validLengths: [UInt8](repeating: 8, count: 144) + [UInt8](repeating: 9, count: 112)
      + [UInt8](repeating: 7, count: 24) + [UInt8](repeating: 8, count: 8),
    fastBits: 9
  )
  static let fixedDistances = Huffman(validLengths: [UInt8](repeating: 5, count: 30), fastBits: 5)

  /// Builds a code from per-symbol lengths, rejecting over-subscribed codes and incomplete ones the way
  /// zlib does: an incomplete code is only allowed for literals/distances with at most one code.
  /// `fastBits` sizes the lookup table; longer codes are decoded bit by bit.
  init(lengths: [UInt8], isCodeLengthCode: Bool, fastBits: Int) throws(Inflate.Failure) {
    var counts = [Int](repeating: 0, count: 16)
    for length in lengths {
      counts[Int(length)] += 1
    }
    var left = 1
    var longest = 0
    for length in 1...15 {
      left <<= 1
      left -= counts[length]
      guard left >= 0 else { throw .invalidCodeLengths }
      if counts[length] > 0 {
        longest = length
      }
    }
    if left > 0, isCodeLengthCode || longest > 1 {
      throw .invalidCodeLengths
    }
    self.init(validLengths: lengths, fastBits: fastBits)
  }

  private init(validLengths lengths: [UInt8], fastBits: Int) {
    fast = [UInt16](repeating: 0, count: 1 << fastBits)
    for length in lengths {
      counts[Int(length)] += 1
    }
    counts[0] = 0

    var offsets = [Int](repeating: 0, count: 16)
    for length in 1..<15 {
      offsets[length + 1] = offsets[length] + counts[length]
    }
    symbols = [UInt16](repeating: 0, count: lengths.count)
    for (symbol, length) in lengths.enumerated() where length != 0 {
      symbols[offsets[Int(length)]] = UInt16(symbol)
      offsets[Int(length)] += 1
    }

    var code = 0
    var index = 0
    for length in 1...fastBits {
      for _ in 0..<counts[length] {
        let entry = symbols[index] << 4 | UInt16(length)
        var reversed = 0
        for bit in 0..<length where code & (1 << bit) != 0 {
          reversed |= 1 << (length - 1 - bit)
        }
        var slot = reversed
        while slot < fast.count {
          fast[slot] = entry
          slot += 1 << length
        }
        code += 1
        index += 1
      }
      code <<= 1
    }
  }
}
