-- DRM-free Amazon KFX (CONT) extractor for KOReader.
-- Parses the KFX container and Amazon Ion data directly and emits cached HTML.
-- Initial scope: reflowable KFX books (text, images, metadata, TOC and links).

local DataStorage = require("datastorage")
local logger = require("logger")
local util = require("util")

local M = {}

local function read_all(path)
    local f, err = io.open(path, "rb")
    if not f then error(err or "cannot open file") end
    local d = f:read("*a")
    f:close()
    return d
end

local function write_all(path, data)
    local f, err = io.open(path, "wb")
    if not f then error(err or ("cannot write " .. path)) end
    f:write(data)
    f:close()
end

local function le16(s, p)
    local a, b = s:byte(p, p + 1)
    if not b then error("truncated little-endian u16") end
    return a + b * 256
end

local function le32(s, p)
    local a, b, c, d = s:byte(p, p + 3)
    if not d then error("truncated little-endian u32") end
    return a + b * 256 + c * 65536 + d * 16777216
end

-- KFX entity offsets/lengths are 64-bit little-endian. Kindle KFX files are
-- small enough that the upper word must be zero for our in-memory Lua strings.
local function le64_small(s, p)
    local lo = le32(s, p)
    local hi = le32(s, p + 4)
    if hi ~= 0 then error("KFX entity offset/length exceeds Lua addressable range") end
    return lo
end

local function be_uint(s)
    local n = 0
    for i = 1, #s do n = n * 256 + s:byte(i) end
    return n
end

local function html_escape(s)
    s = tostring(s or "")
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local function attr_escape(s)
    return html_escape(s):gsub("'", "&#39;")
end

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local SYS_SYMBOLS = {
    [1] = "$ion", [2] = "$ion_1_0", [3] = "$ion_symbol_table",
    [4] = "name", [5] = "version", [6] = "imports", [7] = "symbols",
    [8] = "max_id", [9] = "$ion_shared_symbol_table",
}

local function new_symbols()
    local t = {}
    for k, v in pairs(SYS_SYMBOLS) do t[k] = v end
    -- YJ_symbols uses numeric names that correspond to their Ion symbol IDs.
    -- The per-document symbol table may import a shorter prefix, but resolving
    -- the known shared range here is harmless and lets us parse that table.
    for i = 10, 834 do t[i] = "$" .. tostring(i) end
    return t
end

local function reader(data, pos, limit)
    return { data = data, pos = pos or 1, limit = limit or #data }
end

local function rleft(r) return r.limit - r.pos + 1 end
local function rbyte(r)
    if r.pos > r.limit then error("truncated Ion data") end
    local b = r.data:byte(r.pos)
    r.pos = r.pos + 1
    return b
end
local function rtake(r, n)
    if n < 0 or r.pos + n - 1 > r.limit then error("truncated Ion value") end
    local s = r.data:sub(r.pos, r.pos + n - 1)
    r.pos = r.pos + n
    return s
end

local function vluint(r)
    local v = 0
    for _ = 1, 10 do
        local b = rbyte(r)
        v = v * 128 + (b % 128)
        if b >= 128 then return v end
    end
    error("invalid Ion VLUInt")
end

local parse_ion_value

local function parse_ion_stream(data, symbols)
    local r = reader(data)
    if data:sub(1, 4) == "\224\001\000\234" then r.pos = 5 end
    local result
    while rleft(r) > 0 do
        if r.data:byte(r.pos) == 0xE0 then
            if rtake(r, 4) ~= "\224\001\000\234" then error("invalid embedded Ion marker") end
        else
            result = parse_ion_value(r, symbols)
        end
    end
    return result
end

parse_ion_value = function(r, symbols)
    local desc = rbyte(r)
    if desc == 0xE0 then error("unexpected Ion version marker") end
    local typ = math.floor(desc / 16)
    local flag = desc % 16

    if typ == 0 then
        if flag == 15 then return nil end
        local n = flag == 14 and vluint(r) or flag
        rtake(r, n)
        return { __nop = true }
    elseif typ == 1 then
        if flag == 15 then return nil end
        if flag == 0 then return false end
        if flag == 1 then return true end
        error("invalid Ion boolean")
    elseif typ == 13 then
        if flag == 1 then flag = 14 end
        local n = flag == 14 and vluint(r) or flag
        local stop = r.pos + n - 1
        if stop > r.limit then error("truncated Ion struct") end
        local sr = reader(r.data, r.pos, stop)
        r.pos = stop + 1
        local out = {}
        while rleft(sr) > 0 do
            local sid = vluint(sr)
            local key = symbols[sid] or ("$" .. tostring(sid))
            local value = parse_ion_value(sr, symbols)
            if not (type(value) == "table" and value.__nop) then out[key] = value end
        end
        return out
    end

    local n = flag == 14 and vluint(r) or flag
    if flag == 15 then return nil end
    local data = rtake(r, n)

    if typ == 2 then
        return be_uint(data)
    elseif typ == 3 then
        return -be_uint(data)
    elseif typ == 4 then
        -- KFX layout values encountered by this extractor do not require
        -- floating point decoding; preserve uncommon floats as zero rather
        -- than depending on Lua 5.3 string.unpack on older Kindles.
        return 0
    elseif typ == 5 or typ == 6 then
        return 0
    elseif typ == 7 then
        local sid = be_uint(data)
        return symbols[sid] or ("$" .. tostring(sid))
    elseif typ == 8 then
        return data
    elseif typ == 9 then
        return data
    elseif typ == 10 then
        return { __blob = data }
    elseif typ == 11 or typ == 12 then
        local lr = reader(data)
        local out = {}
        while rleft(lr) > 0 do
            local value = parse_ion_value(lr, symbols)
            if not (type(value) == "table" and value.__nop) then out[#out + 1] = value end
        end
        return out
    elseif typ == 14 then
        local ar = reader(data)
        local ann_len = vluint(ar)
        local ann_stop = ar.pos + ann_len - 1
        local anns = {}
        while ar.pos <= ann_stop do
            local sid = vluint(ar)
            anns[#anns + 1] = symbols[sid] or ("$" .. tostring(sid))
        end
        local value = parse_ion_value(ar, symbols)
        return { __ann = anns, __val = value }
    end
    error("unsupported Ion type " .. tostring(typ))
end

local function unwrap(v)
    if type(v) == "table" and v.__ann then return v.__val end
    return v
end

local function first_import_max_id(doc_symbols)
    local v = unwrap(doc_symbols)
    local imports = type(v) == "table" and v.imports
    if type(imports) == "table" then
        for _, imp in ipairs(imports) do
            imp = unwrap(imp)
            if type(imp) == "table" and imp.name == "YJ_symbols" and tonumber(imp.max_id) then
                return tonumber(imp.max_id)
            end
        end
    end
end

local function load_document_symbols(raw, offset0, length, symbols)
    if not offset0 or not length or length <= 0 then return end
    local doc = parse_ion_stream(raw:sub(offset0 + 1, offset0 + length), symbols)
    local v = unwrap(doc)
    if type(v) ~= "table" then return end
    local local_symbols = v.symbols
    if type(local_symbols) ~= "table" then return end

    -- In KFX container symbol tables max_id includes the nine Ion system SIDs.
    -- Therefore local symbols begin at max_id + 1, not 10 + max_id.
    local max_id = first_import_max_id(doc) or 834
    local base = max_id + 1
    for i, name in ipairs(local_symbols) do
        if type(name) == "string" and name ~= "" then symbols[base + i - 1] = name end
    end
end

local function add_entity(by_type, by_key, ftype, fid, value)
    by_type[ftype] = by_type[ftype] or {}
    by_type[ftype][fid] = value
    by_key[ftype .. "\0" .. fid] = value
end

local function parse_container(path)
    local raw = read_all(path)
    if #raw < 18 or raw:sub(1, 4) ~= "CONT" then error("not a KFX CONT container") end
    local version = le16(raw, 5)
    if version ~= 1 and version ~= 2 then error("unsupported KFX container version " .. tostring(version)) end
    local header_len = le32(raw, 7)
    local ci_offset = le32(raw, 11)
    local ci_length = le32(raw, 15)
    if header_len < 18 or header_len > #raw then error("invalid KFX header length") end

    local symbols = new_symbols()
    local ci = unwrap(parse_ion_stream(raw:sub(ci_offset + 1, ci_offset + ci_length), symbols))
    if type(ci) ~= "table" then error("invalid KFX container info") end
    local compression = tonumber(ci["$410"] or 0) or 0
    local drm = tonumber(ci["$411"] or 0) or 0
    if compression ~= 0 then error("compressed KFX containers are not supported") end
    if drm ~= 0 then error("DRM-encrypted KFX is not supported") end

    load_document_symbols(raw, ci["$415"], ci["$416"], symbols)

    local table_offset = tonumber(ci["$413"])
    local table_length = tonumber(ci["$414"])
    if not table_offset or not table_length or table_length % 24 ~= 0 then error("invalid KFX entity table") end

    local by_type, by_key = {}, {}
    local entity_count = 0
    for p0 = table_offset, table_offset + table_length - 24, 24 do
        local p = p0 + 1
        local iid = le32(raw, p)
        local tid = le32(raw, p + 4)
        local off = le64_small(raw, p + 8)
        local len = le64_small(raw, p + 16)
        local start = header_len + off + 1
        local finish = start + len - 1
        if start < 1 or finish > #raw then error("KFX entity outside container") end
        local ent = raw:sub(start, finish)
        if ent:sub(1, 4) ~= "ENTY" or #ent < 10 then error("invalid KFX ENTY record") end
        local eversion = le16(ent, 5)
        local ehlen = le32(ent, 7)
        if eversion ~= 1 or ehlen < 10 or ehlen > #ent then error("invalid KFX entity header") end
        local ftype = symbols[tid] or ("$" .. tostring(tid))
        local fid = symbols[iid] or ("$" .. tostring(iid))
        local payload = ent:sub(ehlen + 1)
        local value
        if ftype == "$417" or ftype == "$418" then
            value = { __blob = payload }
        else
            value = parse_ion_stream(payload, symbols)
            if type(value) == "table" and value.__ann then
                local anns = value.__ann
                if #anns == 1 and anns[1] == ftype and fid == "$348" then
                    fid = ftype
                    value = value.__val
                end
            end
        end
        add_entity(by_type, by_key, ftype, fid, value)
        entity_count = entity_count + 1
    end

    return {
        raw = raw, version = version, container_id = ci["$409"],
        symbols = symbols, by_type = by_type, by_key = by_key,
        entity_count = entity_count,
    }
end

local function entity(book, ftype, fid)
    local t = book.by_type[ftype]
    if not t then return nil end
    if fid ~= nil then return unwrap(t[tostring(fid)]) end
    local _, v = next(t)
    return unwrap(v)
end

local function metadata_from_book(book)
    local meta = { authors = {} }
    local m = entity(book, "$490", "$490") or entity(book, "$490")
    if type(m) == "table" then
        for _, category0 in ipairs(m["$491"] or {}) do
            local category = unwrap(category0)
            if type(category) == "table" and category["$495"] == "kindle_title_metadata" then
                for _, kv0 in ipairs(category["$258"] or {}) do
                    local kv = unwrap(kv0)
                    if type(kv) == "table" then
                        local key, value = kv["$492"], kv["$307"]
                        if key == "author" and type(value) == "string" and value ~= "" then
                            meta.authors[#meta.authors + 1] = value
                        elseif key == "title" then meta.title = value
                        elseif key == "publisher" then meta.publisher = value
                        elseif key == "language" then meta.language = value
                        elseif key == "description" then meta.description = value
                        elseif key == "ASIN" then meta.asin = value
                        elseif key == "issue_date" then meta.date = value
                        elseif key == "cover_image" then meta.cover_image = value
                        end
                    end
                end
            end
        end
    end
    if #meta.authors > 0 then meta.author = table.concat(meta.authors, "\n") end
    return meta
end

local function image_ext(data, mime)
    if data:sub(1, 3) == "\255\216\255" then return "jpg" end
    if data:sub(1, 8) == "\137PNG\13\10\26\10" then return "png" end
    if data:sub(1, 4) == "GIF8" then return "gif" end
    if data:sub(1, 2) == "BM" then return "bmp" end
    mime = tostring(mime or ""):lower()
    if mime:find("png", 1, true) then return "png" end
    if mime:find("gif", 1, true) then return "gif" end
    return "jpg"
end

local function extract_resources(book, cache_dir)
    local resources = {}
    local raw_media = book.by_type["$417"] or {}
    for rid, res0 in pairs(book.by_type["$164"] or {}) do
        local res = unwrap(res0)
        if type(res) == "table" then
            local raw_name = res["$165"]
            local blob = raw_name and raw_media[tostring(raw_name)]
            local data = type(blob) == "table" and blob.__blob
            if type(data) == "string" then
                local ext = image_ext(data, res["$162"])
                local safe = tostring(rid):gsub("[^%w_.%-]", "_")
                local name = "kfx_" .. safe .. "." .. ext
                write_all(cache_dir .. "/" .. name, data)
                resources[tostring(rid)] = name
            end
        end
    end
    return resources
end

local function reading_order(book)
    local result = {}
    local m = entity(book, "$258", "$258") or entity(book, "$258")
    if type(m) == "table" then
        for _, ro0 in ipairs(m["$169"] or {}) do
            local ro = unwrap(ro0)
            if type(ro) == "table" then
                for _, s in ipairs(ro["$170"] or {}) do
                    if type(s) == "string" then result[#result + 1] = s end
                end
            end
        end
    end
    if #result == 0 then
        for name in pairs(book.by_type["$260"] or {}) do result[#result + 1] = name end
        table.sort(result)
    end
    return result
end

local function position_of(v)
    v = unwrap(v)
    if type(v) ~= "table" then return nil end
    local eid = tonumber(v["$155"] or v["$598"])
    if not eid then return nil end
    return eid, tonumber(v["$143"] or 0) or 0
end

local function anchor_id(eid, offset)
    if (offset or 0) == 0 then return "kfx-eid-" .. tostring(eid) end
    return "kfx-pos-" .. tostring(eid) .. "-" .. tostring(offset)
end

local function resolve_inline_or_fragment(book, v, ftype)
    v = unwrap(v)
    if type(v) == "string" then return entity(book, ftype, v) end
    return v
end

local function toc_from_book(book)
    local toc = {}
    local nav = entity(book, "$389", "$389") or entity(book, "$389")
    if type(nav) ~= "table" then return toc end

    local function add_unit(unit0, depth)
        local unit = resolve_inline_or_fragment(book, unit0, "$393")
        if type(unit) ~= "table" then return end
        local rep = unwrap(unit["$241"])
        local label = type(rep) == "table" and rep["$244"] or nil
        local eid, off = position_of(unit["$246"])
        if type(label) == "string" and trim(label) ~= "" and eid then
            toc[#toc + 1] = {
                title = trim(label), depth = depth, eid = eid, offset = off,
                anchor = "#" .. anchor_id(eid, off),
            }
        end
        for _, child in ipairs(unit["$247"] or {}) do add_unit(child, depth + 1) end
        for _, set0 in ipairs(unit["$248"] or {}) do
            local set = unwrap(set0)
            if type(set) == "table" then
                for _, child in ipairs(set["$247"] or {}) do add_unit(child, depth + 1) end
            end
        end
    end

    for _, booknav0 in ipairs(nav) do
        local booknav = unwrap(booknav0)
        if type(booknav) == "table" then
            for _, container0 in ipairs(booknav["$392"] or {}) do
                local container = resolve_inline_or_fragment(book, container0, "$391")
                if type(container) == "table" and container["$235"] == "$212" then
                    for _, unit in ipairs(container["$247"] or {}) do add_unit(unit, 1) end
                end
            end
        end
    end
    return toc
end

local function collect_positions(book, toc)
    local positions = {}
    local function add(eid, off)
        if not eid then return end
        positions[eid] = positions[eid] or {}
        positions[eid][off or 0] = anchor_id(eid, off or 0)
    end
    for _, item in ipairs(toc) do add(item.eid, item.offset) end
    for _, a0 in pairs(book.by_type["$266"] or {}) do
        local a = unwrap(a0)
        if type(a) == "table" and a["$183"] then
            local eid, off = position_of(a["$183"])
            add(eid, off)
        end
    end
    return positions
end

local function utf8_char_starts(s)
    local starts = { 1 }
    local i = 1
    while i <= #s do
        local b = s:byte(i)
        local n = 1
        if b >= 0xF0 then n = 4 elseif b >= 0xE0 then n = 3 elseif b >= 0xC0 then n = 2 end
        i = i + n
        starts[#starts + 1] = i
    end
    return starts
end

local function utf8_slice(s, starts, a, b)
    -- Character interval [a,b), zero-based.
    local p1 = starts[a + 1] or (#s + 1)
    local p2 = starts[b + 1] or (#s + 1)
    return s:sub(p1, p2 - 1)
end

local function link_href(book, ref)
    local a = entity(book, "$266", ref)
    if type(a) ~= "table" then return nil end
    if type(a["$186"]) == "string" and a["$186"] ~= "" then return a["$186"] end
    local eid, off = position_of(a["$183"])
    if eid then return "#" .. anchor_id(eid, off) end
end

local function resolve_text(book, value)
    if type(value) == "string" then return value end
    value = unwrap(value)
    if type(value) ~= "table" then return "" end
    local name, index = value.name, tonumber(value["$403"])
    if not name or index == nil then return "" end
    local block = entity(book, "$145", name)
    if type(block) ~= "table" then return "" end
    local list = block["$146"] or {}
    -- KFX uses zero-based content indexes.
    return type(list[index + 1]) == "string" and list[index + 1] or ""
end

local function render_text(book, text, events, eid, positions)
    text = tostring(text or "")
    local starts = utf8_char_starts(text)
    local char_count = #starts - 1
    local boundaries = { [0] = true, [char_count] = true }
    local links = {}
    local posmap = positions[eid] or {}
    for off in pairs(posmap) do
        if off >= 0 and off <= char_count then boundaries[off] = true end
    end
    for _, ev0 in ipairs(events or {}) do
        local ev = unwrap(ev0)
        if type(ev) == "table" and ev["$179"] then
            local a = tonumber(ev["$143"] or 0) or 0
            local z = a + (tonumber(ev["$144"] or 0) or 0)
            if a < 0 then a = 0 end
            if z > char_count then z = char_count end
            if z > a then
                boundaries[a], boundaries[z] = true, true
                links[#links + 1] = { a = a, z = z, href = link_href(book, ev["$179"]) }
            end
        end
    end
    local cuts = {}
    for n in pairs(boundaries) do cuts[#cuts + 1] = n end
    table.sort(cuts)
    local out = {}
    for i = 1, #cuts - 1 do
        local a, z = cuts[i], cuts[i + 1]
        local aid = posmap[a]
        -- Offset zero is represented by the containing content element's id.
        if aid and a ~= 0 then out[#out + 1] = '<a id="' .. attr_escape(aid) .. '"></a>' end
        local seg = html_escape(utf8_slice(text, starts, a, z))
        local href
        for _, l in ipairs(links) do if a >= l.a and z <= l.z then href = l.href break end end
        if href and href ~= "" then
            out[#out + 1] = '<a href="' .. attr_escape(href) .. '">' .. seg .. '</a>'
        else
            out[#out + 1] = seg
        end
    end
    local final_id = posmap[char_count]
    if final_id then out[#out + 1] = '<a id="' .. attr_escape(final_id) .. '"></a>' end
    return table.concat(out)
end

local function renderer(book, resources, toc, positions)
    local heading_by_eid = {}
    for _, item in ipairs(toc) do
        if item.offset == 0 and not heading_by_eid[item.eid] then heading_by_eid[item.eid] = item end
    end

    local render_content
    local function render_list(list)
        local out = {}
        for _, v in ipairs(list or {}) do out[#out + 1] = render_content(v) end
        return table.concat(out)
    end

    local function render_story(name)
        local story = entity(book, "$259", name)
        if type(story) ~= "table" then return "" end
        return render_list(story["$146"])
    end

    render_content = function(content0)
        local content = unwrap(content0)
        if type(content) == "string" then return html_escape(content) end
        if type(content) ~= "table" then return "" end

        local ctype = content["$159"]
        local eid = tonumber(content["$155"] or content["$598"])
        local idattr = ""
        if eid and positions[eid] and positions[eid][0] then
            idattr = ' id="' .. attr_escape(positions[eid][0]) .. '"'
        elseif eid then
            idattr = ' id="kfx-eid-' .. tostring(eid) .. '"'
        end

        if ctype == "$271" then
            local rid = content["$175"]
            local src = rid and resources[tostring(rid)]
            if src then return '<img' .. idattr .. ' src="' .. attr_escape(src) .. '" alt="' .. attr_escape(content["$584"] or "") .. '" />' end
            return ""
        end

        local inner = ""
        if content["$145"] ~= nil then
            inner = render_text(book, resolve_text(book, content["$145"]), content["$142"], eid, positions)
        elseif type(content["$146"]) == "table" then
            inner = render_list(content["$146"])
        elseif type(content["$176"]) == "string" then
            inner = render_story(content["$176"])
        end

        if inner == "" and type(content["$176"]) == "string" then inner = render_story(content["$176"]) end

        local heading = eid and heading_by_eid[eid]
        if heading and heading.offset == 0 and ctype == "$269" then
            local level = math.max(1, math.min(6, heading.depth or 1))
            return string.format('<h%d%s class="kfx-heading">%s</h%d>', level, idattr, inner, level)
        end

        if ctype == "$269" then return '<p' .. idattr .. '>' .. inner .. '</p>' end
        return '<div' .. idattr .. '>' .. inner .. '</div>'
    end

    local sections = {}
    for _, name in ipairs(reading_order(book)) do
        local section = entity(book, "$260", name)
        if type(section) == "table" then
            sections[#sections + 1] = '<section class="kfx-section" data-kfx-section="' .. attr_escape(name) .. '">'
                .. render_list(section["$141"]) .. '</section>'
        end
    end
    return table.concat(sections, '\n<div class="kfx-pagebreak"></div>\n')
end

function M.is_kfx(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local sig = f:read(4)
    f:close()
    return sig == "CONT"
end

function M.extract(path)
    local book = parse_container(path)
    local meta = metadata_from_book(book)

    local cache_root = DataStorage:getDataDir() .. "/cache/azwreader"
    util.makePath(cache_root)
    local fingerprint = (#book.raw * 131 + (book.raw:byte(19) or 0) * 65537) % 0x7fffffff
    local cache_dir = string.format("%s/v010_kfx_%08x_%d", cache_root, fingerprint, #book.raw)
    util.makePath(cache_dir)

    local resources = extract_resources(book, cache_dir)
    local toc = toc_from_book(book)
    local positions = collect_positions(book, toc)
    local body = renderer(book, resources, toc, positions)

    local cover_path
    if meta.cover_image and resources[tostring(meta.cover_image)] then
        cover_path = cache_dir .. "/" .. resources[tostring(meta.cover_image)]
    end
    if not cover_path then
        -- Conservative fallback: the first image used by the first section is
        -- commonly the cover; failing that use the largest extracted resource.
        local best_name, best_size
        for _, name in pairs(resources) do
            local f = io.open(cache_dir .. "/" .. name, "rb")
            if f then
                local size = f:seek("end") or 0
                f:close()
                if not best_size or size > best_size then best_name, best_size = name, size end
            end
        end
        if best_name then cover_path = cache_dir .. "/" .. best_name end
    end

    local html_path = cache_dir .. "/book.html"
    local html = table.concat({
        '<!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml"><head>',
        '<meta charset="utf-8" />',
        meta.title and ('<title>' .. html_escape(meta.title) .. '</title>') or '',
        meta.author and ('<meta name="author" content="' .. attr_escape(meta.author) .. '" />') or '',
        '<style>body{line-height:1.35}p{margin-top:0;margin-bottom:.7em;text-align:justify}img{max-width:100%;height:auto}.kfx-pagebreak{page-break-before:always;height:0}.kfx-section{display:block}.kfx-heading{page-break-after:avoid}</style>',
        '</head><body>', body, '</body></html>'
    }, "\n")
    write_all(html_path, html)

    logger.info("AZW/KFX Reader: extracted", path, "entities", book.entity_count,
        "toc", #toc, "resources", (function() local n=0 for _ in pairs(resources) do n=n+1 end return n end)())

    return {
        html_path = html_path,
        cover_path = cover_path,
        metadata = meta,
        toc = toc,
        format = "kfx",
    }
end

return M
