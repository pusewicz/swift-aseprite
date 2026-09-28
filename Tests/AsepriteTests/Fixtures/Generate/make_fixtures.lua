-- Builds the feature fixtures in Fixtures/Features/ using Aseprite's own encoder.
-- Run through regenerate.rb, or directly:
--   aseprite -b --script-param out=<dir> --script make_fixtures.lua

local out = assert(app.params.out, "missing --script-param out=<dir>")

local rgba = app.pixelColor.rgba
local graya = app.pixelColor.graya

local function fill(img, fn)
	for y = 0, img.height - 1 do
		for x = 0, img.width - 1 do
			img:putPixel(x, y, fn(x, y))
		end
	end
	return img
end

local function image(w, h, mode, fn)
	return fill(Image(w, h, mode), fn)
end

local function setDurations(spr, ms)
	for i, d in ipairs(ms) do
		spr.frames[i].duration = d / 1000
	end
end

local function ensureFrames(spr, n)
	while #spr.frames < n do
		spr:newEmptyFrame()
	end
end

local function clearCels(spr)
	for _, cel in ipairs(spr.cels) do
		spr:deleteCel(cel)
	end
end

local function save(spr, name)
	spr:saveAs(out .. "/" .. name .. ".aseprite")
	spr:close()
end

local function link(spr, layer, frames)
	app.sprite = spr
	app.range:clear()
	app.range.layers = { layer }
	app.range.frames = frames
	app.command.LinkCels()
	app.range:clear()
end

local blendModes = {
	BlendMode.NORMAL, BlendMode.MULTIPLY, BlendMode.SCREEN, BlendMode.OVERLAY, BlendMode.DARKEN,
	BlendMode.LIGHTEN, BlendMode.COLOR_DODGE, BlendMode.COLOR_BURN, BlendMode.HARD_LIGHT,
	BlendMode.SOFT_LIGHT, BlendMode.DIFFERENCE, BlendMode.EXCLUSION, BlendMode.HSL_HUE,
	BlendMode.HSL_SATURATION, BlendMode.HSL_COLOR, BlendMode.HSL_LUMINOSITY, BlendMode.ADDITION,
	BlendMode.SUBTRACT, BlendMode.DIVIDE,
}

-- RGB sprite: opacity, off-canvas cels, hidden layer, linked cels, tags, slices, user data.
do
	local spr = Sprite(16, 12, ColorMode.RGB)
	clearCels(spr)
	ensureFrames(spr, 4)
	setDurations(spr, { 100, 150, 200, 250 })
	spr.data = "sprite text"
	spr.color = Color { r = 10, g = 20, b = 30, a = 40 }
	spr.properties.title = "hero"
	spr.properties.count = 3

	local base = spr.layers[1]
	base.name = "base"
	for f = 1, 4 do
		spr:newCel(base, f, image(16, 12, ColorMode.RGB, function(x, y)
			local a = ((x + y) % 5 == 0) and 0 or 255
			return rgba(x * 16, y * 20, f * 60, a)
		end), Point(0, 0))
	end
	base:cel(1).data = "base cel"
	base:cel(1).color = Color { r = 1, g = 2, b = 3, a = 4 }
	base:cel(1).properties.z = 1

	local overlay = spr:newLayer()
	overlay.name = "overlay"
	overlay.opacity = 180
	overlay.data = "overlay layer"
	overlay.color = Color { r = 200, g = 100, b = 50, a = 255 }
	overlay.properties.speed = 2.5
	local ov = function(x, y) return rgba(255 - x * 20, 100, y * 40, 60 + x * 19) end
	spr:newCel(overlay, 1, image(10, 6, ColorMode.RGB, ov), Point(-3, 2)).opacity = 200
	spr:newCel(overlay, 2, image(10, 6, ColorMode.RGB, ov), Point(10, 8)).opacity = 128
	link(spr, overlay, { 2, 3, 4 })

	local hidden = spr:newLayer()
	hidden.name = "hidden"
	spr:newCel(hidden, 1, image(16, 12, ColorMode.RGB, function() return rgba(255, 0, 0, 255) end), Point(0, 0))
	hidden.isVisible = false

	local t1 = spr:newTag(1, 1)
	t1.name = "idle"
	local t2 = spr:newTag(1, 4)
	t2.name = "walk"
	t2.aniDir = AniDir.REVERSE
	t2.repeats = 2
	t2.color = Color { r = 255, g = 0, b = 0, a = 255 }
	t2.data = "walk data"
	t2.properties.loop = true
	local t3 = spr:newTag(2, 3)
	t3.name = "pp"
	t3.aniDir = AniDir.PING_PONG
	local t4 = spr:newTag(1, 2)
	t4.name = "ppr"
	t4.aniDir = AniDir.PING_PONG_REVERSE
	t4.repeats = 3

	local plain = spr:newSlice(Rectangle(1, 1, 5, 4))
	plain.name = "plain"
	plain.data = "plain slice"
	local nine = spr:newSlice(Rectangle(2, 2, 10, 8))
	nine.name = "nine"
	nine.center = Rectangle(2, 2, 6, 4)
	nine.pivot = Point(5, 4)
	nine.color = Color { r = 0, g = 0, b = 255, a = 255 }
	nine.properties.kind = "button"

	save(spr, "rgba_basic")
end

-- Grayscale sprite with alpha.
do
	local spr = Sprite(12, 10, ColorMode.GRAY)
	clearCels(spr)
	ensureFrames(spr, 2)
	local a = spr.layers[1]
	a.name = "a"
	local b = spr:newLayer()
	b.name = "b"
	b.opacity = 128
	for f = 1, 2 do
		spr:newCel(a, f, image(12, 10, ColorMode.GRAY, function(x, y)
			return graya((x * 20 + f * 30) % 256, (y == 0) and 0 or 255)
		end), Point(0, 0))
		spr:newCel(b, f, image(8, 7, ColorMode.GRAY, function(x, y)
			return graya(255 - y * 20, 40 + x * 18)
		end), Point(f, 1)).opacity = 220
	end
	save(spr, "grayscale")
end

-- Indexed sprites: transparent index, background layer, alpha palette entries.
local function indexedPalette(n)
	local p = Palette(n)
	for i = 0, n - 1 do
		p:setColor(i, Color { r = (i * 37) % 256, g = (i * 91) % 256, b = (i * 53) % 256, a = (i % 3 == 2) and 128 or 255 })
	end
	return p
end

do
	local spr = Sprite(12, 10, ColorMode.INDEXED)
	clearCels(spr)
	ensureFrames(spr, 2)
	spr:setPalette(indexedPalette(8))
	spr.transparentColor = 3
	local bg = spr.layers[1]
	bg.name = "bg"
	for f = 1, 2 do
		spr:newCel(bg, f, image(12, 10, ColorMode.INDEXED, function(x, y) return (x + y + f) % 8 end), Point(0, 0))
	end
	app.sprite = spr
	app.layer = bg
	app.command.BackgroundFromLayer()
	local fg = spr:newLayer()
	fg.name = "fg"
	fg.opacity = 200
	for f = 1, 2 do
		spr:newCel(fg, f, image(7, 6, ColorMode.INDEXED, function(x, y) return (x * y + f) % 8 end), Point(3, 2))
	end
	save(spr, "indexed_background")
end

do
	local spr = Sprite(10, 8, ColorMode.INDEXED)
	clearCels(spr)
	spr:setPalette(indexedPalette(6))
	spr.transparentColor = 0
	local a = spr.layers[1]
	a.name = "a"
	spr:newCel(a, 1, image(10, 8, ColorMode.INDEXED, function(x, y) return (x + 2 * y) % 6 end), Point(0, 0))
	local b = spr:newLayer()
	b.name = "b"
	b.blendMode = BlendMode.SCREEN
	spr:newCel(b, 1, image(6, 5, ColorMode.INDEXED, function(x, y) return (x * 3 + y) % 6 end), Point(-2, 4))
	save(spr, "indexed")
end

-- One frame per blend mode, over a backdrop whose alpha spans 255 / 128 / 40 / 0.
do
	local spr = Sprite(16, 16, ColorMode.RGB)
	clearCels(spr)
	ensureFrames(spr, #blendModes)
	local backdrop = spr.layers[1]
	backdrop.name = "backdrop"
	local alphas = { 255, 128, 40, 0 }
	for f = 1, #blendModes do
		spr:newCel(backdrop, f, image(16, 16, ColorMode.RGB, function(x, y)
			return rgba(x * 16, y * 16, (x * y * 3) % 256, alphas[y // 4 + 1])
		end), Point(0, 0))
	end
	for f, mode in ipairs(blendModes) do
		local layer = spr:newLayer()
		layer.name = "mode_" .. (f - 1)
		layer.blendMode = mode
		layer.opacity = 220
		spr:newCel(layer, f, image(16, 16, ColorMode.RGB, function(x, y)
			return rgba(255 - x * 16, (x * 7 + y * 13) % 256, y * 16, 255 - x * 12)
		end), Point(0, 0))
	end
	save(spr, "blend_modes")
end

-- Nested groups. Saved flat; regenerate.rb derives groups_composed.aseprite from it.
local function buildGroups(spr, zIndexes)
	clearCels(spr)
	ensureFrames(spr, 2)
	local back = spr.layers[1]
	back.name = "back"
	local g1 = spr:newGroup()
	g1.name = "G1"
	local g1a = spr:newLayer()
	g1a.name = "g1a"
	g1a.parent = g1
	g1a.blendMode = BlendMode.SCREEN
	g1a.opacity = 200
	local g2 = spr:newGroup()
	g2.name = "G2"
	g2.parent = g1
	local g2a = spr:newLayer()
	g2a.name = "g2a"
	g2a.parent = g2
	local g2b = spr:newLayer()
	g2b.name = "g2b"
	g2b.parent = g2
	g2b.blendMode = BlendMode.DIFFERENCE
	local g1b = spr:newLayer()
	g1b.name = "g1b"
	g1b.parent = g1
	local hiddenGroup = spr:newGroup()
	hiddenGroup.name = "Hidden"
	local h1 = spr:newLayer()
	h1.name = "h1"
	h1.parent = hiddenGroup
	local front = spr:newLayer()
	front.name = "front"
	front.opacity = 100

	for f = 1, 2 do
		spr:newCel(back, f, image(12, 12, ColorMode.RGB, function(x, y) return rgba(x * 20, y * 20, 90 * f, 255) end), Point(0, 0))
		spr:newCel(g1a, f, image(8, 8, ColorMode.RGB, function(x, y) return rgba(200, x * 30, y * 30, 180) end), Point(f, 0))
		spr:newCel(g2a, f, image(9, 6, ColorMode.RGB, function(x, y) return rgba(x * 25, 255, 0, 150 + x * 10) end), Point(2, 3))
		spr:newCel(g2b, f, image(6, 9, ColorMode.RGB, function(x, y) return rgba(0, y * 25, 255, 255) end), Point(4, 1 + f))
		spr:newCel(g1b, f, image(5, 5, ColorMode.RGB, function(x, y) return rgba(255, 255, 0, 255) end), Point(0, 7))
		spr:newCel(h1, f, image(12, 12, ColorMode.RGB, function() return rgba(255, 0, 255, 255) end), Point(0, 0))
		spr:newCel(front, f, image(4, 12, ColorMode.RGB, function(x, y) return rgba(0, 0, 0, 200) end), Point(8, 0))
	end
	g1b.isVisible = false
	hiddenGroup.isVisible = false
	if zIndexes then
		g1a:cel(2).zIndex = 3
		g2b:cel(1).zIndex = -2
		front:cel(2).zIndex = -6
		back:cel(2).zIndex = 1
	end
end

do
	local spr = Sprite(12, 12, ColorMode.RGB)
	buildGroups(spr, false)
	save(spr, "groups_flat")
end

do
	local spr = Sprite(12, 12, ColorMode.RGB)
	buildGroups(spr, true)
	save(spr, "zindex_groups_flat")
end

-- Z-index on a flat stack.
do
	local spr = Sprite(10, 10, ColorMode.RGB)
	clearCels(spr)
	ensureFrames(spr, 4)
	local colors = { rgba(255, 0, 0, 255), rgba(0, 255, 0, 200), rgba(0, 0, 255, 150) }
	local layers = { spr.layers[1], spr:newLayer(), spr:newLayer() }
	for i, layer in ipairs(layers) do
		layer.name = string.char(64 + i)
		for f = 1, 4 do
			spr:newCel(layer, f, image(6, 6, ColorMode.RGB, function() return colors[i] end), Point((i - 1) * 2, (i - 1) * 2))
		end
	end
	layers[1]:cel(2).zIndex = 2
	layers[3]:cel(3).zIndex = -2
	layers[2]:cel(3).zIndex = -1
	layers[1]:cel(4).zIndex = 1
	layers[2]:cel(4).zIndex = -1
	save(spr, "zindex")
end

-- Tilemaps: flips, off-canvas cel, tileset and tile user data.
local function buildTilemap(spr, px)
	clearCels(spr)
	ensureFrames(spr, 2)
	spr.gridBounds = Rectangle(0, 0, 4, 4)
	app.sprite = spr
	app.layer = spr.layers[1]
	app.command.NewLayer { tilemap = true }
	local tl = app.layer
	tl.name = "tiles"
	tl.opacity = 200
	local ts = tl.tileset
	ts.name = "TS"
	ts.data = "tileset data"
	ts.properties.biome = "forest"
	for i = 1, 4 do
		local tile = spr:newTile(ts)
		local img = tile.image
		for y = 0, 3 do
			for x = 0, 3 do
				img:putPixel(x, y, px(i, x, y))
			end
		end
		tile.data = "tile " .. i
		tile.properties.solid = (i % 2 == 0)
	end
	local X, Y, D = app.pixelColor.TILE_XFLIP, app.pixelColor.TILE_YFLIP, app.pixelColor.TILE_DFLIP
	local flags = { 0, X, Y, D, X | Y, X | D, Y | D, X | Y | D, 0 }
	local map = Image(3, 3, ColorMode.TILEMAP)
	for k = 0, 8 do
		map:putPixel(k % 3, k // 3, app.pixelColor.tile((k % 4) + 1, flags[k + 1]))
	end
	map:putPixel(1, 1, app.pixelColor.tile(0, 0))
	spr:newCel(tl, 1, map, Point(0, 0))
	spr:newCel(tl, 2, map, Point(-4, 4))
	local under = spr.layers[1]
	under.name = "under"
	for f = 1, 2 do
		spr:newCel(under, f, image(12, 12, spr.colorMode, function(x, y) return px(4, x % 4, y % 4) end), Point(0, 0))
	end
end

do
	local spr = Sprite(12, 12, ColorMode.RGB)
	buildTilemap(spr, function(i, x, y)
		if x + y == 6 then return rgba(0, 0, 0, 0) end
		return rgba(60 * i, x * 60, y * 60, (x == 0) and 128 or 255)
	end)
	save(spr, "tilemap")
end

do
	local spr = Sprite(12, 12, ColorMode.INDEXED)
	spr:setPalette(indexedPalette(8))
	spr.transparentColor = 2
	buildTilemap(spr, function(i, x, y) return (i + x * 2 + y) % 8 end)
	save(spr, "tilemap_indexed")
end

-- User data with every property type Lua can express, plus extension properties.
do
	local spr = Sprite(4, 4, ColorMode.RGB)
	local layer = spr.layers[1]
	layer.name = "props"
	local p = layer.properties
	p.str = "text"
	p.yes = true
	p.no = false
	p.small = 7
	p.negative = -5
	p.medium = 1000
	p.big = 100000
	p.huge = 5000000000
	p.real = 0.25
	p.point = Point(3, -4)
	p.size = Size(5, 6)
	p.rect = Rectangle(1, 2, 3, 4)
	p.list = { 1, 2, 3 }
	p.mixed = { 1, "two", true, 4.5 }
	p.map = { a = 1, b = { c = "deep" } }
	layer.properties("pusewicz/test").ext = "extension value"
	spr:newCel(layer, 1, image(4, 4, ColorMode.RGB, function(x, y) return rgba(x * 60, y * 60, 0, 255) end), Point(0, 0))
	save(spr, "user_data")
end

-- Layer UUIDs (header flag 4).
do
	local spr = Sprite(4, 4, ColorMode.RGB)
	spr.useLayerUuids = true
	spr.layers[1].name = "first"
	spr:newLayer().name = "second"
	save(spr, "layer_uuids")
end

-- No cels at all.
do
	local spr = Sprite(5, 3, ColorMode.RGB)
	clearCels(spr)
	ensureFrames(spr, 2)
	save(spr, "empty")
end
