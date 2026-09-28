# frozen_string_literal: true

require "zlib"

# Byte-level .aseprite writer for synthetic fixtures that Aseprite's Lua API
# cannot produce (raw cels, old palette chunks, deprecated chunks, odd flags...).
# Field layouts follow docs/ase-file-specs.md in the aseprite repository.
module AseWriter
  module_function

  def byte(v) = [v].pack("C")
  def word(v) = [v].pack("v")
  def short(v) = [v].pack("s<")
  def dword(v) = [v].pack("V")
  def long(v) = [v].pack("l<")
  def qword(v) = [v].pack("Q<")
  def long64(v) = [v].pack("q<")
  def float(v) = [v].pack("e")
  def double(v) = [v].pack("E")
  def string(s) = word(s.bytesize) + s.b
  def zeros(n) = "\0".b * n

  # A complete file: header + frames. Each frame is a hash with :chunks (array of
  # [type, payload]) and optional :duration, :old_count, :new_count overrides.
  def file(width:, height:, depth: 32, flags: 1, speed: 100, transparent: 0, ncolors: 256, frames:)
    body = frames.map { |f| frame(f) }.join
    header = word(0xA5E0) + word(frames.size) + word(width) + word(height) + word(depth) +
      dword(flags) + word(speed) + dword(0) + dword(0) + byte(transparent) + zeros(3) +
      word(ncolors) + byte(1) + byte(1) + short(0) + short(0) + word(16) + word(16) + zeros(84)
    raise "bad header size" unless header.bytesize == 124

    dword(128 + body.bytesize) + header + body
  end

  def frame(f)
    chunks = f.fetch(:chunks).map { |type, payload| dword(payload.bytesize + 6) + word(type) + payload }.join
    count = f.fetch(:chunks).size
    old_count = f.fetch(:old_count, [count, 0xFFFF].min)
    new_count = f.fetch(:new_count, count)
    dword(16 + chunks.bytesize) + word(0xF1FA) + word(old_count) + word(f.fetch(:duration, 100)) +
      zeros(2) + dword(new_count) + chunks
  end

  def layer(name:, flags: 3, type: 0, level: 0, blend: 0, opacity: 255, tileset: nil, uuid: nil, extra: "".b)
    payload = word(flags) + word(type) + word(level) + word(0) + word(0) + word(blend) + byte(opacity) +
      zeros(3) + string(name)
    payload += dword(tileset) if tileset
    payload += uuid if uuid
    [0x2004, payload + extra]
  end

  def cel_header(layer:, x:, y:, opacity:, type:, z: 0)
    word(layer) + short(x) + short(y) + byte(opacity) + word(type) + short(z) + zeros(5)
  end

  def cel_raw(layer:, x: 0, y: 0, opacity: 255, z: 0, w:, h:, pixels:)
    [0x2005, cel_header(layer:, x:, y:, opacity:, type: 0, z:) + word(w) + word(h) + pixels.b]
  end

  def cel_image(layer:, x: 0, y: 0, opacity: 255, z: 0, w:, h:, pixels:)
    [0x2005, cel_header(layer:, x:, y:, opacity:, type: 2, z:) + word(w) + word(h) + Zlib::Deflate.deflate(pixels.b)]
  end

  def cel_linked(layer:, frame:, x: 0, y: 0, opacity: 255, z: 0)
    [0x2005, cel_header(layer:, x:, y:, opacity:, type: 1, z:) + word(frame)]
  end

  def cel_tilemap(layer:, w:, h:, tiles:, x: 0, y: 0, opacity: 255, z: 0, bits: 32,
                  id_mask: 0x1fffffff, x_mask: 0x80000000, y_mask: 0x40000000, d_mask: 0x20000000)
    format = { 8 => "C*", 16 => "v*", 32 => "V*" }.fetch(bits)
    data = Zlib::Deflate.deflate(tiles.pack(format))
    [0x2005, cel_header(layer:, x:, y:, opacity:, type: 3, z:) + word(w) + word(h) + word(bits) +
      dword(id_mask) + dword(x_mask) + dword(y_mask) + dword(d_mask) + zeros(10) + data]
  end

  def cel_extra(flags: 1, x:, y:, w:, h:)
    [0x2006, dword(flags) + long(x) + long(y) + long(w) + long(h) + zeros(16)]
  end

  # entries: [[r, g, b, a], ...] or [[r, g, b, a, "name"], ...]
  def palette(size:, first: 0, entries:)
    payload = dword(size) + dword(first) + dword(first + entries.size - 1) + zeros(8)
    entries.each do |r, g, b, a, name|
      payload += word(name ? 1 : 0) + byte(r) + byte(g) + byte(b) + byte(a)
      payload += string(name) if name
    end
    [0x2019, payload]
  end

  # packets: [[skip, [[r, g, b], ...]], ...]; type 4 = 8-bit components, type 11 = 6-bit components.
  def old_palette(type:, packets:)
    payload = word(packets.size)
    packets.each do |skip, colors|
      payload += byte(skip) + byte(colors.size == 256 ? 0 : colors.size)
      colors.each { |r, g, b| payload += byte(r) + byte(g) + byte(b) }
    end
    [type, payload]
  end

  # tags: [{from:, to:, dir:, repeat:, rgb: [r, g, b], name:}, ...]
  def tags(list)
    payload = word(list.size) + zeros(8)
    list.each do |t|
      payload += word(t[:from]) + word(t[:to]) + byte(t.fetch(:dir, 0)) + word(t.fetch(:repeat, 0)) + zeros(6) +
        t.fetch(:rgb, [0, 0, 0]).map { byte(it) }.join + byte(0) + string(t[:name])
    end
    [0x2018, payload]
  end

  # props: { key => { "name" => [type, value] } }, see property_value for value shapes.
  def user_data(text: nil, color: nil, props: nil)
    flags = (text ? 1 : 0) | (color ? 2 : 0) | (props ? 4 : 0)
    payload = dword(flags)
    payload += string(text) if text
    payload += color.map { byte(it) }.join if color
    if props
      maps = props.map { |key, map| dword(key) + properties(map) }.join
      payload += dword(8 + maps.bytesize) + dword(props.size) + maps
    end
    [0x2020, payload]
  end

  def properties(map)
    dword(map.size) + map.map { |name, (type, value)| string(name) + word(type) + property_value(type, value) }.join
  end

  def property_value(type, value)
    case type
    when 0x01 then byte(value ? 1 : 0)
    when 0x02 then [value].pack("c")
    when 0x03 then byte(value)
    when 0x04 then short(value)
    when 0x05 then word(value)
    when 0x06 then long(value)
    when 0x07 then dword(value)
    when 0x08 then long64(value)
    when 0x09 then qword(value)
    when 0x0A then long(value)
    when 0x0B then float(value)
    when 0x0C then double(value)
    when 0x0D then string(value)
    when 0x0E, 0x0F then long(value[0]) + long(value[1])
    when 0x10 then value.map { long(it) }.join
    when 0x11
      element_type, elements = value
      head = dword(elements.size) + word(element_type)
      if element_type.zero?
        head + elements.map { |t, v| word(t) + property_value(t, v) }.join
      else
        head + elements.map { property_value(element_type, it) }.join
      end
    when 0x12 then properties(value)
    when 0x13 then value.b
    else raise "unknown property type #{type}"
    end
  end

  # keys: [{frame:, bounds: [x, y, w, h], center: [...] | nil, pivot: [x, y] | nil}, ...]
  def slice_payload(name:, keys:)
    nine = keys.any? { it[:center] }
    pivot = keys.any? { it[:pivot] }
    payload = dword(keys.size) + dword((nine ? 1 : 0) | (pivot ? 2 : 0)) + dword(0) + string(name)
    keys.each do |k|
      x, y, w, h = k[:bounds]
      payload += dword(k[:frame]) + long(x) + long(y) + dword(w) + dword(h)
      if nine
        cx, cy, cw, ch = k.fetch(:center)
        payload += long(cx) + long(cy) + dword(cw) + dword(ch)
      end
      payload += long(k[:pivot][0]) + long(k[:pivot][1]) if pivot
    end
    payload
  end

  def slice(name:, keys:) = [0x2022, slice_payload(name:, keys:)]

  # Deprecated 0x2021 chunk: several slices at once.
  def slices_old(list)
    [0x2021, dword(list.size) + zeros(8) + list.map { slice_payload(**it) }.join]
  end

  def tileset(id:, flags:, tile_w:, tile_h:, count:, name:, pixels: nil, base: 1, external: nil)
    payload = dword(id) + dword(flags) + dword(count) + word(tile_w) + word(tile_h) + short(base) + zeros(14) +
      string(name)
    payload += dword(external[0]) + dword(external[1]) if external
    if pixels
      data = Zlib::Deflate.deflate(pixels.b)
      payload += dword(data.bytesize) + data
    end
    [0x2023, payload]
  end

  # entries: [[id, type, name], ...]
  def external_files(entries)
    [0x2008, dword(entries.size) + zeros(8) + entries.map { |id, type, name| dword(id) + byte(type) + zeros(7) + string(name) }.join]
  end

  def color_profile(type:, flags: 0, gamma: 0, icc: nil)
    payload = word(type) + word(flags) + long(gamma) + zeros(8)
    payload += dword(icc.bytesize) + icc.b if icc
    [0x2007, payload]
  end

  def mask(x:, y:, w:, h:, name:)
    [0x2016, short(x) + short(y) + word(w) + word(h) + zeros(8) + string(name) + zeros(h * ((w + 7) / 8))]
  end

  # Rewrites an existing file: sets header flag bits and patches group layers'
  # blend mode / opacity (Aseprite's Lua saveAs never writes composed groups).
  def compose_groups(bytes, groups)
    data = bytes.b.dup
    flags = data[14, 4].unpack1("V") | 2
    data[14, 4] = dword(flags)
    frame_pos = 128
    frame_size = data[frame_pos, 4].unpack1("V")
    old_count, = data[frame_pos + 6, 2].unpack("v")
    new_count = data[frame_pos + 12, 4].unpack1("V")
    count = old_count == 0xFFFF && old_count < new_count ? new_count : old_count
    pos = frame_pos + 16
    count.times do
      size = data[pos, 4].unpack1("V")
      type = data[pos + 4, 2].unpack1("v")
      if type == 0x2004 && data[pos + 8, 2].unpack1("v") == 1
        name_len = data[pos + 22, 2].unpack1("v")
        name = data[pos + 24, name_len]
        if (blend, opacity = groups[name])
          data[pos + 16, 2] = word(blend)
          data[pos + 18, 1] = byte(opacity)
        end
      end
      pos += size
    end
    raise "walked past first frame" if pos > frame_pos + frame_size

    data
  end
end
