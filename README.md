# Aseprite

Pure Swift decoder and renderer for Aseprite `.ase` / `.aseprite` files. No dependencies.

Renders frames the way Aseprite does: blend modes, groups, z-index, tilemaps, indexed and grayscale sprites.

Runs on macOS 14+, Linux, Windows, and WebAssembly. Requires Swift 6.4.

## Install

```swift
.package(url: "https://github.com/pusewicz/swift-aseprite.git", branch: "main")
```

## Usage

```swift
import Aseprite

let sprite = try Aseprite(contentsOf: "player.aseprite")

for tag in sprite.tags {
  let images = sprite.renderFrames(tag.frames)  // Straight-alpha RGBA8
}
```

## License

MIT. Portions derived from Aseprite's MIT-licensed doc, dio, and render libraries. See [LICENSE](LICENSE).
