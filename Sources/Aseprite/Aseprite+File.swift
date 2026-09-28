#if canImport(FoundationEssentials)
internal import FoundationEssentials
#elseif canImport(Foundation)
internal import Foundation
#endif

#if canImport(FoundationEssentials) || canImport(Foundation)
extension Aseprite {
  /// Reads and decodes the Aseprite file at `path`.
  ///
  /// - Throws: ``AsepriteError/unreadableFile(path:reason:)`` if the file can't be read, or another
  ///   ``AsepriteError`` if it is not a valid Aseprite file.
  public init(contentsOf path: String) throws(AsepriteError) {
    let data: Data
    do {
      data = try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
      throw .unreadableFile(path: path, reason: "\(error)")
    }
    try self.init(bytes: data)
  }
}
#endif
