-- Exports Aseprite's own view of each fixture: every frame rendered to raw RGBA8
-- (frame-<n>.rgba, 0-based) plus meta.json with the decoded document model.
-- Run through regenerate.rb, or directly:
--   aseprite -b --script-param list=<file with one path per line> --script-param out=<dir> --script export_goldens.lua
-- Each input path must look like <...>/<Category>/<name>.<ext>; output goes to <out>/<Category>/<name>/.

local listPath = assert(app.params.list, "missing --script-param list=<file>")
local outRoot = assert(app.params.out, "missing --script-param out=<dir>")

-- JSON --------------------------------------------------------------------

local ARRAY = {}
local function array(t)
	return setmetatable(t or {}, ARRAY)
end

local encode

local function encodeString(s)
	return '"' .. s:gsub('[%c"\\]', function(c)
		local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
		return map[c] or string.format("\\u%04x", c:byte())
	end) .. '"'
end

encode = function(v)
	local t = type(v)
	if v == nil then
		return "null"
	elseif t == "boolean" then
		return tostring(v)
	elseif t == "number" then
		if math.type(v) == "integer" then
			return string.format("%d", v)
		end
		return string.format("%.17g", v)
	elseif t == "string" then
		return encodeString(v)
	elseif t == "table" then
		local isArray = getmetatable(v) == ARRAY or (#v > 0)
		local parts = {}
		if isArray then
			for i = 1, #v do
				parts[#parts + 1] = encode(v[i])
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local keys = {}
		for k in pairs(v) do
			keys[#keys + 1] = tostring(k)
		end
		table.sort(keys)
		for _, k in ipairs(keys) do
			parts[#parts + 1] = encodeString(k) .. ":" .. encode(v[k])
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	error("cannot encode " .. t)
end

-- Aseprite objects -> plain tables ----------------------------------------

local function field(v, name)
	local ok, result = pcall(function() return v[name] end)
	if ok then
		return result
	end
	return nil
end

local function color(c)
	if c == nil then
		return nil
	end
	return array { c.red, c.green, c.blue, c.alpha }
end

local function rect(r)
	if r == nil then
		return nil
	end
	return array { r.x, r.y, r.width, r.height }
end

local function point(p)
	if p == nil then
		return nil
	end
	return array { p.x, p.y }
end

local value

local function properties(props)
	local result = {}
	for k, v in pairs(props) do
		result[k] = value(v)
	end
	return result
end

value = function(v)
	local t = type(v)
	if t == "table" then
		if #v > 0 then
			local list = array()
			for i = 1, #v do
				list[i] = value(v[i])
			end
			return list
		end
		return properties(v)
	elseif t == "userdata" then
		local w, x = field(v, "width"), field(v, "x")
		if w ~= nil and x ~= nil then
			return { rect = rect(v) }
		elseif w ~= nil then
			return { size = array { v.width, v.height } }
		elseif x ~= nil then
			return { point = point(v) }
		end
		return { uuid = tostring(v) }
	end
	return v
end

local function userData(obj)
	return {
		text = obj.data,
		color = color(obj.color),
		properties = properties(obj.properties),
	}
end

-- Lua's BlendMode values are not the file's; map them to the file's 0...18 numbering.
local fileBlendMode = {}
for index, mode in ipairs {
	BlendMode.NORMAL, BlendMode.MULTIPLY, BlendMode.SCREEN, BlendMode.OVERLAY, BlendMode.DARKEN,
	BlendMode.LIGHTEN, BlendMode.COLOR_DODGE, BlendMode.COLOR_BURN, BlendMode.HARD_LIGHT,
	BlendMode.SOFT_LIGHT, BlendMode.DIFFERENCE, BlendMode.EXCLUSION, BlendMode.HSL_HUE,
	BlendMode.HSL_SATURATION, BlendMode.HSL_COLOR, BlendMode.HSL_LUMINOSITY, BlendMode.ADDITION,
	BlendMode.SUBTRACT, BlendMode.DIVIDE,
} do
	fileBlendMode[mode] = index - 1
end

local function readHeaderFlags(path)
	local f = assert(io.open(path, "rb"))
	local header = f:read(18)
	f:close()
	return string.unpack("<I4", header, 15)
end

local function layerList(container, list, parentIndex, level)
	for li = 1, #container.layers do
		local layer = container.layers[li]
		list[#list + 1] = { layer = layer, parent = parentIndex, level = level }
		if layer.isGroup then
			layerList(layer, list, #list - 1, level + 1)
		end
	end
	return list
end

local function writeFile(path, bytes)
	local f = assert(io.open(path, "wb"))
	f:write(bytes)
	f:close()
end

local function export(path)
	local category, name = path:match("([^/]+)/([^/]+)%.[^.]+$")
	local dir = outRoot .. "/" .. category .. "/" .. name
	app.fs.makeAllDirectories(dir)

	local flags = readHeaderFlags(path)
	app.preferences.experimental.compose_groups = (flags & 2) ~= 0

	local spr = assert(app.open(path), "cannot open " .. path)

	for i = 1, #spr.frames do
		local img = Image(spr.width, spr.height, ColorMode.RGB)
		img:drawSprite(spr, i)
		writeFile(string.format("%s/frame-%d.rgba", dir, i - 1), img.bytes)
	end

	local meta = {
		width = spr.width,
		height = spr.height,
		colorMode = spr.colorMode,
		transparentColor = spr.transparentColor,
		pixelRatio = array { spr.pixelRatio.width, spr.pixelRatio.height },
		gridBounds = rect(spr.gridBounds),
		headerFlags = flags,
		userData = userData(spr),
		frames = array(),
		layers = array(),
		tags = array(),
		slices = array(),
		palettes = array(),
		tilesets = array(),
	}

	for i = 1, #spr.frames do
		local frame = spr.frames[i]
		meta.frames[i] = { duration = math.floor(frame.duration * 1000 + 0.5) }
	end

	for i, entry in ipairs(layerList(spr, {}, nil, 0)) do
		local layer = entry.layer
		local cels = array()
		if not layer.isGroup then
			for f = 1, #spr.frames do
				local cel = layer:cel(f)
				if cel then
					cels[#cels + 1] = {
						frame = f - 1,
						position = point(cel.position),
						opacity = cel.opacity,
						zIndex = cel.zIndex,
						size = array { cel.image.width, cel.image.height },
						userData = userData(cel),
					}
				end
			end
		end
		meta.layers[i] = {
			name = layer.name,
			parent = entry.parent,
			childLevel = entry.level,
			kind = layer.isGroup and "group" or (layer.isTilemap and "tilemap" or "image"),
			visible = layer.isVisible,
			editable = layer.isEditable,
			background = layer.isBackground,
			reference = layer.isReference,
			blendMode = fileBlendMode[layer.blendMode],
			opacity = layer.opacity,
			uuid = spr.useLayerUuids and tostring(layer.uuid) or nil,
			userData = userData(layer),
			cels = cels,
		}
	end

	for i = 1, #spr.tags do
		local tag = spr.tags[i]
		meta.tags[i] = {
			name = tag.name,
			from = tag.fromFrame.frameNumber - 1,
			to = tag.toFrame.frameNumber - 1,
			direction = tag.aniDir,
			repeatCount = tag.repeats,
			color = color(tag.color),
			userData = userData(tag),
		}
	end

	for i = 1, #spr.slices do
		local slice = spr.slices[i]
		meta.slices[i] = {
			name = slice.name,
			bounds = rect(slice.bounds),
			center = rect(slice.center),
			pivot = point(slice.pivot),
			userData = userData(slice),
		}
	end

	for i = 1, #spr.palettes do
		local pal = spr.palettes[i]
		local colors = array()
		for c = 0, #pal - 1 do
			colors[c + 1] = color(pal:getColor(c))
		end
		meta.palettes[i] = { frame = pal.frame.frameNumber - 1, colors = colors }
	end

	for i = 1, #spr.tilesets do
		local ts = spr.tilesets[i]
		local tiles = array()
		for t = 0, #ts - 1 do
			tiles[t + 1] = userData(ts:tile(t))
		end
		meta.tilesets[i] = {
			name = ts.name,
			tileSize = array { ts.grid.tileSize.width, ts.grid.tileSize.height },
			tileCount = #ts,
			baseIndex = ts.baseIndex,
			userData = userData(ts),
			tiles = tiles,
		}
	end

	writeFile(dir .. "/meta.json", encode(meta) .. "\n")
	spr:close()
end

local originalCompose = app.preferences.experimental.compose_groups
local ok, err = xpcall(function()
	for line in io.lines(listPath) do
		if #line > 0 then
			export(line)
		end
	end
end, debug.traceback)
app.preferences.experimental.compose_groups = originalCompose
if not ok then
	error(err)
end
