#!/usr/bin/env ruby
# frozen_string_literal: true

# Regenerates every checked-in fixture and golden:
#   Features/   files built by Aseprite's own encoder (make_fixtures.lua), plus
#               composed-group variants patched from them
#   Synthetic/  byte-level files for what the Lua API cannot express
#   Inflate/    zlib vectors for the inflater (stored, fixed, dynamic, multi-block...)
#   Goldens/    Aseprite's rendering (raw RGBA per frame) + meta.json for every file
#
# Requires Aseprite (ASEPRITE env var, or the default macOS install path).
#   ruby Tests/AsepriteTests/Fixtures/Generate/regenerate.rb

require "fileutils"
require "tmpdir"
require_relative "ase_writer"

ASEPRITE = ENV.fetch("ASEPRITE", "/Applications/Aseprite.app/Contents/MacOS/aseprite")
GENERATE = __dir__
FIXTURES = File.expand_path("..", GENERATE)
FEATURES = File.join(FIXTURES, "Features")
SYNTHETIC = File.join(FIXTURES, "Synthetic")
INFLATE = File.join(FIXTURES, "Inflate")
REAL = File.join(FIXTURES, "Real")
GOLDENS = File.join(FIXTURES, "Goldens")

include AseWriter

def aseprite(script, **params)
  args = [ASEPRITE, "-b"]
  params.each { |k, v| args += ["--script-param", "#{k}=#{v}"] }
  args += ["--script", File.join(GENERATE, script)]
  output = IO.popen(args, err: %i[child out], &:read)
  raise "#{script} failed:\n#{output}" unless $?.success? && !output.include?("stack traceback")

  puts output unless output.empty?
end

def rgba_pixels(w, h) = (0...h).flat_map { |y| (0...w).map { |x| yield(x, y) } }.flatten.pack("C*")
def index_pixels(w, h) = (0...h).flat_map { |y| (0...w).map { |x| yield(x, y) } }.pack("C*")

def write(dir, name, bytes)
  FileUtils.mkdir_p(dir)
  File.binwrite(File.join(dir, name), bytes)
end

# Features ------------------------------------------------------------------

def features
  FileUtils.rm_rf(FEATURES)
  FileUtils.mkdir_p(FEATURES)
  aseprite("make_fixtures.lua", out: FEATURES)
  groups = { "G1" => [1, 160], "G2" => [3, 128], "Hidden" => [0, 255] }
  %w[groups zindex_groups].each do |name|
    flat = File.binread(File.join(FEATURES, "#{name}_flat.aseprite"))
    write(FEATURES, "#{name}_composed.aseprite", compose_groups(flat, groups))
  end
end

# Synthetic -----------------------------------------------------------------

def gradient(w, h, seed = 0) = rgba_pixels(w, h) { |x, y| [(x * 40 + seed) % 256, (y * 50) % 256, (x * y * 20 + seed) % 256, 255 - x * 10] }

def synthetic
  FileUtils.rm_rf(SYNTHETIC)
  s = {}

  s["raw_cel"] = file(width: 6, height: 5, frames: [{ chunks: [
    layer(name: "raw"),
    cel_raw(layer: 0, x: 1, y: 1, w: 4, h: 3, pixels: gradient(4, 3)),
    layer(name: "compressed"),
    cel_image(layer: 1, x: -1, y: 2, opacity: 180, w: 5, h: 2, pixels: gradient(5, 2, 99)),
  ] }])

  pal8 = [[10, 20, 30], [200, 0, 0], [0, 200, 0], [0, 0, 200], [255, 255, 0], [0, 255, 255], [255, 0, 255], [128, 128, 128]]
  indexed_cel = cel_image(layer: 0, w: 4, h: 4, pixels: index_pixels(4, 4) { |x, y| (x + y * 4) % 8 })
  s["old_palette_4"] = file(width: 4, height: 4, depth: 8, ncolors: 8, transparent: 7, frames: [{ chunks: [
    old_palette(type: 4, packets: [[0, pal8[0, 3]], [4, pal8[3, 2]]]),
    layer(name: "l"), indexed_cel,
  ] }])
  s["old_palette_11"] = file(width: 4, height: 4, depth: 8, ncolors: 8, transparent: 7, frames: [{ chunks: [
    old_palette(type: 11, packets: [[0, pal8.map { |c| c.map { it / 4 } }]]),
    layer(name: "l"), indexed_cel,
  ] }])

  new_pal = ->(shift) { pal8.map { |r, g, b| [(r + shift) % 256, g, b, 255] } }
  s["palette_per_frame"] = file(width: 4, height: 4, depth: 8, ncolors: 8, transparent: 0, frames: [
    { chunks: [old_palette(type: 4, packets: [[0, pal8.reverse]]), palette(size: 8, entries: new_pal.(0)),
               layer(name: "l"), indexed_cel] },
    { chunks: [old_palette(type: 4, packets: [[0, pal8]]), palette(size: 8, first: 2, entries: new_pal.(77)[2, 3]),
               cel_linked(layer: 0, frame: 0)] },
    { chunks: [palette(size: 8, first: 2, entries: new_pal.(77)[2, 3]), cel_linked(layer: 0, frame: 0)] },
    { chunks: [palette(size: 10, first: 8, entries: [[1, 2, 3, 4], [5, 6, 7, 8, "named"]]), cel_linked(layer: 0, frame: 0)] },
  ])

  s["skipped_chunks"] = file(width: 4, height: 3, frames: [{ chunks: [
    color_profile(type: 2, icc: "not really an icc profile"),
    external_files([[1, 0, "palette.gpl"], [2, 1, "tiles.aseprite"], [3, 2, "pusewicz/test"]]),
    [0x2017, "".b],
    mask(x: 1, y: 1, w: 9, h: 2, name: "mask"),
    [0x7777, "future chunk".b],
    layer(name: "l", extra: "future!".b),
    cel_image(layer: 0, w: 4, h: 3, pixels: gradient(4, 3)),
    cel_extra(x: 0x18000, y: -0x8000, w: 0x40000, h: 0x30000),
    user_data(text: "cel text", props: { 3 => { "ext" => [0x0D, "extension"] } }),
  ] }])

  s["chunk_counts"] = file(width: 3, height: 3, speed: 77, frames: [
    { new_count: 0, duration: 0, chunks: [layer(name: "l"), cel_image(layer: 0, w: 3, h: 3, pixels: gradient(3, 3))] },
    { old_count: 1, new_count: 5, duration: 0, chunks: [cel_image(layer: 0, w: 2, h: 2, pixels: gradient(2, 2, 50))] },
    { duration: 33, chunks: [] },
  ])

  s["no_opacity_flag"] = file(width: 4, height: 4, flags: 0, frames: [{ chunks: [
    layer(name: "base"), cel_image(layer: 0, w: 4, h: 4, pixels: gradient(4, 4)),
    layer(name: "half", opacity: 100, blend: 2), cel_image(layer: 1, w: 3, h: 3, pixels: gradient(3, 3, 128)),
  ] }])

  s["reference_layer"] = file(width: 4, height: 4, frames: [{ chunks: [
    layer(name: "normal"), cel_image(layer: 0, w: 4, h: 4, pixels: gradient(4, 4)),
    layer(name: "reference", flags: 1 | 64), cel_image(layer: 1, w: 4, h: 4, pixels: rgba_pixels(4, 4) { [255, 0, 0, 255] }),
  ] }])

  s["background_blend"] = file(width: 4, height: 4, frames: [{ chunks: [
    layer(name: "bg", flags: 1 | 2 | 8, blend: 1, opacity: 50),
    cel_image(layer: 0, x: 1, y: 0, w: 3, h: 4, pixels: gradient(3, 4)),
    layer(name: "top", blend: 10, opacity: 200), cel_image(layer: 1, w: 4, h: 2, pixels: gradient(4, 2, 77)),
  ] }])

  s["linked_cels"] = file(width: 5, height: 5, frames: [
    { chunks: [layer(name: "l"), layer(name: "group", type: 1), layer(name: "child", level: 1),
               cel_image(layer: 0, x: 1, y: 1, w: 3, h: 3, pixels: gradient(3, 3)),
               cel_image(layer: 1, w: 2, h: 2, pixels: gradient(2, 2)),
               user_data(text: "dropped cel on a group"),
               cel_image(layer: 9, w: 2, h: 2, pixels: gradient(2, 2)),
               cel_image(layer: 2, w: 0, h: 3, pixels: "".b)] },
    { chunks: [cel_linked(layer: 0, frame: 0, x: 1, y: 1), user_data(text: "linked")] },
    { chunks: [cel_linked(layer: 0, frame: 1, x: 2, y: 0, opacity: 128, z: 1)] },
    { chunks: [cel_linked(layer: 0, frame: 5), cel_linked(layer: 2, frame: 0)] },
  ])

  # Precise bounds (Cel Extra) move and clip any cel; true links share them, copies don't.
  s["precise_bounds"] = file(width: 6, height: 5, frames: [
    { chunks: [layer(name: "l"), cel_image(layer: 0, w: 4, h: 3, pixels: gradient(4, 3)),
               cel_extra(x: 0x10000, y: 0x18000, w: 0x20000, h: 0x28000), user_data(text: "shared")] },
    { chunks: [cel_linked(layer: 0, frame: 0, x: 1, y: 1)] },
    { chunks: [cel_linked(layer: 0, frame: 0, x: 2, y: 2)] },
    { chunks: [cel_image(layer: 0, x: 1, y: 1, w: 4, h: 3, pixels: gradient(4, 3, 60)),
               cel_extra(flags: 0, x: 0x30000, y: 0, w: 0x10000, h: 0x10000),
               cel_extra(x: -0x28000, y: 0, w: 0x70000, h: 0), user_data(text: "zero height ignored")] },
  ])

  # What Aseprite tolerates. Corrupt cels are tiny so Aseprite's zlib chunking leaves them all-zero.
  red = [255, 0, 0, 255].pack("C*")
  blue = [0, 0, 255, 255].pack("C*")
  bad_checksum = Zlib::Deflate.deflate(red).b.tap { it[-1] = (it[-1].ord ^ 0xFF).chr }
  bad_code = Zlib::Deflate.deflate(red).b.tap { it[2] = (it[2].ord | 0x06).chr }  # Reserved block type.
  compressed_cel = ->(layer, x, data) { [0x2005, cel_header(layer:, x:, y: 0, opacity: 255, type: 2) + word(1) + word(1) + data] }
  s["corrupt_cels"] = file(width: 4, height: 1, frames: [{ chunks: [
    layer(name: "l0"), layer(name: "l1"), layer(name: "l2"), layer(name: "l3"),
    compressed_cel.(0, 0, bad_checksum),
    compressed_cel.(1, 1, bad_code),
    compressed_cel.(2, 2, Zlib::Deflate.deflate(red + blue).b),  # Longer than the 1x1 cel.
    compressed_cel.(3, 3, Zlib::Deflate.deflate(red).b[0...-6]),  # Cut off mid-stream.
  ] }])
  s["corrupt_indexed_cel"] = file(width: 2, height: 1, depth: 8, ncolors: 4, transparent: 3, frames: [{ chunks: [
    palette(size: 4, entries: [[10, 20, 30, 255], [200, 0, 0, 255], [0, 200, 0, 255], [0, 0, 200, 255]]),
    layer(name: "l"), [0x2005, cel_header(layer: 0, x: 0, y: 0, opacity: 255, type: 2) + word(2) + word(1) + Zlib::Deflate.deflate("\x01\x02").b.tap { it[-1] = (it[-1].ord ^ 1).chr }],
  ] }])

  s["dropped_layers"] = file(width: 3, height: 1, frames: [{ chunks: [
    layer(name: "a"), layer(name: "missing tileset", type: 2, tileset: 9), layer(name: "future", type: 7), layer(name: "b"),
    cel_image(layer: 0, w: 1, h: 1, pixels: red), user_data(text: "a cel"),
    cel_image(layer: 1, x: 1, w: 1, h: 1, pixels: blue), user_data(text: "dropped with its layer"),
    cel_image(layer: 3, x: 2, w: 1, h: 1, pixels: blue),
  ] }])

  s["duplicate_cels"] = file(width: 2, height: 1, frames: [{ chunks: [
    layer(name: "a"), layer(name: "b"),
    cel_image(layer: 0, w: 1, h: 1, pixels: red), cel_image(layer: 0, w: 1, h: 1, pixels: blue), user_data(text: "second"),
    cel_image(layer: 1, x: 1, w: 1, h: 1, pixels: red), cel_linked(layer: 1, frame: 0),
  ] }])

  s["old_palette_bounds"] = file(width: 2, height: 1, depth: 8, ncolors: 4, frames: [{ chunks: [
    old_palette(type: 4, packets: [[1, [[9, 9, 9]]], [2, [[1, 2, 3], [4, 5, 6], [7, 8, 9]]], [255, [[100, 100, 100]]]]),
    layer(name: "l"), cel_image(layer: 0, w: 2, h: 1, pixels: "\x01\x03".b),
  ] }])

  s["slice_sizes"] = file(width: 4, height: 4, frames: [{ chunks: [
    layer(name: "l"), cel_image(layer: 0, w: 4, h: 4, pixels: gradient(4, 4)),
    slice(name: "negative", keys: [{ frame: 0, bounds: [1, 1, 0xFFFF_FFFF, 0xFFFF_FFFF] }]),
    slice(name: "huge", keys: [{ frame: 0, bounds: [0, 0, 0x8000_0000, 0x7FFF_FFFF] }]),
    slice(name: "same frame twice", keys: [{ frame: 0, bounds: [0, 0, 1, 1] }, { frame: 0, bounds: [1, 1, 2, 2] }]),
  ] }])

  uuid = (0...16).map { it * 7 }.pack("C*")
  s["properties_all"] = file(width: 2, height: 2, frames: [{ chunks: [
    external_files([[5, 2, "pusewicz/ext"]]),
    user_data(text: "sprite", color: [1, 2, 3, 4], props: {
      0 => {
        "bool" => [0x01, true], "int8" => [0x02, -8], "uint8" => [0x03, 200], "int16" => [0x04, -1600],
        "uint16" => [0x05, 60000], "int32" => [0x06, -2_000_000], "uint32" => [0x07, 4_000_000_000],
        "int64" => [0x08, -9_000_000_000], "uint64" => [0x09, 18_000_000_000_000_000_000],
        "fixed" => [0x0A, 0x18000], "float" => [0x0B, 1.5], "double" => [0x0C, -2.25], "string" => [0x0D, "hi"],
        "point" => [0x0E, [-1, 2]], "size" => [0x0F, [3, 4]], "rect" => [0x10, [5, 6, 7, 8]],
        "vector" => [0x11, [0x06, [1, -2, 3]]], "mixed" => [0x11, [0, [[0x0D, "a"], [0x01, false], [0x0B, 0.5]]]],
        "map" => [0x12, { "inner" => [0x12, { "deep" => [0x03, 1] }] }], "uuid" => [0x13, uuid],
      },
      5 => { "from_extension" => [0x05, 42] },
    }),
    layer(name: "l"), cel_image(layer: 0, w: 2, h: 2, pixels: gradient(2, 2)),
  ] }])

  s["slices_old"] = file(width: 8, height: 8, frames: [{ chunks: [
    layer(name: "l"), cel_image(layer: 0, w: 8, h: 8, pixels: gradient(8, 8)),
    slices_old([{ name: "a", keys: [{ frame: 0, bounds: [1, 1, 3, 3] }] },
                { name: "b", keys: [{ frame: 0, bounds: [0, 0, 8, 8], center: [2, 2, 4, 4], pivot: [4, 4] }] }]),
    slice(name: "keys", keys: [{ frame: 0, bounds: [0, 0, 2, 2], pivot: [1, 1] }, { frame: 1, bounds: [-2, 3, 5, 0], pivot: [0, 0] }]),
    user_data(text: "keys slice"),
  ] }])

  tile_px = ->(count, empty_first) { rgba_pixels(2, 2 * count) { |x, y| empty_first && y < 2 ? [0, 0, 0, 0] : [y * 30, x * 200, 90, 255] } }
  s["tileset_old"] = file(width: 6, height: 4, frames: [{ chunks: [
    tileset(id: 0, flags: 2, tile_w: 2, tile_h: 2, count: 3, name: "old", base: 1, pixels: tile_px.(3, false)),
    tileset(id: 7, flags: 2, tile_w: 2, tile_h: 2, count: 3, name: "old_empty0", base: 1, pixels: tile_px.(3, true)),
    layer(name: "map_a", type: 2, tileset: 0),
    cel_tilemap(layer: 0, w: 3, h: 1, tiles: [0, 0xffffffff, 0x80000002]),
    layer(name: "map_b", type: 2, tileset: 7),
    cel_tilemap(layer: 1, y: 2, w: 3, h: 1, tiles: [1, 0xffffffff, 2]),
  ] }])

  s["tilemap_bits"] = file(width: 4, height: 2, frames: [{ chunks: [
    tileset(id: 0, flags: 2 | 4, tile_w: 2, tile_h: 2, count: 2, name: "t", pixels: tile_px.(2, true)),
    layer(name: "map16", type: 2, tileset: 0),
    cel_tilemap(layer: 0, w: 2, h: 1, bits: 16, tiles: [1, 1]),
    layer(name: "map32", type: 2, tileset: 0),
    cel_tilemap(layer: 1, x: 2, w: 1, h: 1, tiles: [1]),
  ] }])

  s["tags_user_data"] = file(width: 2, height: 2, frames: [{ chunks: [
    layer(name: "l"), cel_image(layer: 0, w: 2, h: 2, pixels: gradient(2, 2)),
    tags([{ from: 0, to: 0, name: "a", rgb: [1, 2, 3] }, { from: 0, to: 0, dir: 7, name: "b", rgb: [4, 5, 6] },
          { from: 0, to: 0, dir: 2, repeat: 4, name: "c", rgb: [7, 8, 9] }]),
    user_data(text: "tag a", color: [10, 20, 30, 40]),
    user_data(text: "tag b"),
  ] }])

  s["group_levels"] = file(width: 3, height: 3, frames: [{ chunks: [
    layer(name: "g0", type: 1), layer(name: "g1", type: 1, level: 1), layer(name: "a", level: 2),
    layer(name: "b", level: 1), layer(name: "c", level: 0),
    cel_image(layer: 2, w: 3, h: 3, pixels: gradient(3, 3)),
    cel_image(layer: 3, w: 2, h: 2, pixels: gradient(2, 2, 100)),
    cel_image(layer: 4, x: 1, y: 1, w: 2, h: 2, pixels: gradient(2, 2, 200)),
  ] }])

  s.each { |name, bytes| write(SYNTHETIC, "#{name}.aseprite", bytes) }
end

# Inflate vectors -------------------------------------------------------------

def deflate(data, level: Zlib::DEFAULT_COMPRESSION, strategy: Zlib::DEFAULT_STRATEGY, flush_every: nil)
  z = Zlib::Deflate.new(level, Zlib::MAX_WBITS, Zlib::DEF_MEM_LEVEL, strategy)
  out = +"".b
  if flush_every
    data.bytes.each_slice(flush_every) { out << z.deflate(it.pack("C*"), Zlib::SYNC_FLUSH) }
    out << z.finish
  else
    out << z.deflate(data, Zlib::FINISH)
  end
  z.close
  out
end

def inflate_vectors
  FileUtils.rm_rf(INFLATE)
  rng = Random.new(1234)
  noise = rng.bytes(70_000)
  text = ("Aseprite cels are zlib streams. " * 400).b
  runs = (0...5000).map { |i| (i / 97) % 3 }.pack("C*")
  vectors = {
    "empty_stored" => ["".b, { level: Zlib::NO_COMPRESSION }],
    "empty_default" => ["".b, {}],
    "one_byte" => ["A".b, {}],
    "stored_large" => [noise, { level: Zlib::NO_COMPRESSION }],
    "fixed" => [text, { strategy: Zlib::FIXED }],
    "dynamic" => [text, {}],
    "dynamic_noise" => [noise, { level: Zlib::BEST_COMPRESSION }],
    "huffman_only" => [text, { strategy: Zlib::HUFFMAN_ONLY }],
    "rle" => [runs, { strategy: Zlib::RLE }],
    "multi_block" => [text + noise[0, 3000] + runs, { flush_every: 1000 }],
    "long_distance" => [(noise[0, 30_000] + noise[0, 30_000]).b, {}],
  }
  vectors.each do |name, (data, opts)|
    write(INFLATE, "#{name}.bin", data)
    write(INFLATE, "#{name}.zz", deflate(data, **opts))
  end
end

# Goldens ---------------------------------------------------------------------

def goldens
  FileUtils.rm_rf(GOLDENS)
  files = [REAL, FEATURES, SYNTHETIC].flat_map { |dir| Dir.glob(File.join(dir, "*.{ase,aseprite}")).sort }
  # One Aseprite process per file: 1.3.18 can crash when one batch session opens several odd files.
  Dir.mktmpdir do |tmp|
    list = File.join(tmp, "files.txt")
    files.each do |path|
      File.write(list, path + "\n")
      aseprite("export_goldens.lua", list:, out: GOLDENS)
    end
  end
  files.each do |path|
    dir = File.join(GOLDENS, File.basename(File.dirname(path)), File.basename(path, ".*"))
    raise "no golden for #{path}" unless File.exist?(File.join(dir, "meta.json"))
  end
  puts "#{files.size} fixtures, goldens in #{GOLDENS}"
end

features
synthetic
inflate_vectors
goldens
