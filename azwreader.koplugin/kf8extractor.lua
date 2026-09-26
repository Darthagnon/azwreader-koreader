-- Minimal Calibre-style KF8 extractor for KOReader.
-- Implements PalmDB records, PalmDOC text decompression, FDST flows,
-- SKEL/DIV INDX reconstruction, and Kindle flow/embed/pos rewriting.

local DataStorage = require("datastorage")
local logger = require("logger")
local util = require("util")

local M = {}
local NULL_INDEX = 0xFFFFFFFF

local function u16(s, o)
    local a, b = s:byte(o + 1, o + 2)
    if not b then error("truncated u16") end
    return a * 256 + b
end

local function u32(s, o)
    local a, b, c, d = s:byte(o + 1, o + 4)
    if not d then error("truncated u32") end
    return ((a * 256 + b) * 256 + c) * 256 + d
end

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

local function section_table(raw)
    if #raw < 78 then error("not a PalmDB/MOBI file") end
    if raw:sub(61, 68):upper() ~= "BOOKMOBI" then
        error("not a BOOKMOBI container")
    end
    local count = u16(raw, 76)
    local offsets = {}
    for i = 0, count - 1 do
        offsets[i + 1] = u32(raw, 78 + i * 8)
    end
    offsets[count + 1] = #raw
    local sections = {}
    for i = 1, count do
        sections[i] = raw:sub(offsets[i] + 1, offsets[i + 1])
    end
    return sections
end

local function trailing_size(data, extra_flags)
    local num = 0
    local flags = math.floor(extra_flags / 2)
    while flags > 0 do
        if flags % 2 == 1 then
            local p = #data - num
            local bitpos, result = 0, 0
            while p > 0 do
                local v = data:byte(p)
                result = result + (v % 128) * (2 ^ bitpos)
                bitpos = bitpos + 7
                p = p - 1
                if v >= 128 or bitpos >= 28 then break end
            end
            num = num + result
        end
        flags = math.floor(flags / 2)
    end
    if extra_flags % 2 == 1 then
        local p = #data - num
        local v = data:byte(p)
        if not v then error("corrupt MOBI trailing data") end
        num = num + (v % 4) + 1
    end
    return num
end

local function palmdoc_decompress(data)
    local out = {}
    local n = 0
    local i = 1
    while i <= #data do
        local c = data:byte(i)
        i = i + 1
        if c >= 1 and c <= 8 then
            for _ = 1, c do
                if i > #data then break end
                n = n + 1
                out[n] = data:byte(i)
                i = i + 1
            end
        elseif c <= 0x7F then
            n = n + 1
            out[n] = c
        elseif c >= 0xC0 then
            n = n + 1; out[n] = 0x20
            n = n + 1; out[n] = c - 0x80
        else
            if i > #data then error("truncated PalmDOC backreference") end
            local c2 = data:byte(i); i = i + 1
            local pair = c * 256 + c2
            local distance = math.floor((pair % 0x4000) / 8)
            local length = (pair % 8) + 3
            if distance == 0 or distance > n then error("invalid PalmDOC backreference") end
            for _ = 1, length do
                local v = out[n - distance + 1]
                n = n + 1
                out[n] = v
            end
        end
    end
    local chunks = {}
    local p = 1
    while p <= n do
        local last = math.min(p + 4095, n)
        local t = {}
        for j = p, last do t[#t + 1] = string.char(out[j]) end
        chunks[#chunks + 1] = table.concat(t)
        p = last + 1
    end
    return table.concat(chunks)
end

local function decint(data, pos)
    local value, consumed = 0, 0
    while pos + consumed <= #data do
        local b = data:byte(pos + consumed)
        consumed = consumed + 1
        value = value * 128 + (b % 128)
        if b >= 128 then break end
    end
    return value, consumed
end

local function count_bits(v)
    local n = 0
    while v > 0 do
        n = n + (v % 2)
        v = math.floor(v / 2)
    end
    return n
end

local function parse_tagx(data, base)
    if data:sub(base + 1, base + 4) ~= "TAGX" then error("invalid TAGX") end
    local first_entry_offset = u32(data, base + 4)
    local control_byte_count = u32(data, base + 8)
    local tags = {}
    local p = base + 12
    while p < base + first_entry_offset do
        tags[#tags + 1] = {
            tag = data:byte(p + 1),
            num_values = data:byte(p + 2),
            bitmask = data:byte(p + 3),
            eof = data:byte(p + 4),
        }
        p = p + 4
    end
    return control_byte_count, tags
end

local function parse_indx_header(data)
    if data:sub(1, 4) ~= "INDX" then error("invalid INDX record") end
    return {
        start = u32(data, 20),
        count = u32(data, 24),
        ncncx = u32(data, 52),
        tagx = u32(data, 180),
    }
end

local function get_tag_map(control_count, tags, data)
    local controls = { data:byte(1, control_count) }
    local pos = control_count + 1
    local ci = 1
    local pending = {}
    for _, x in ipairs(tags) do
        if x.eof == 1 then
            ci = ci + 1
        else
            local control = controls[ci] or 0
            local value = control % (x.bitmask * 2)
            value = value - (value % x.bitmask)
            -- Above is only safe for single-bit masks. Use arithmetic AND below.
            local a, b, bitv = control, x.bitmask, 0
            local place = 1
            while a > 0 or b > 0 do
                if (a % 2 == 1) and (b % 2 == 1) then bitv = bitv + place end
                a = math.floor(a / 2); b = math.floor(b / 2); place = place * 2
            end
            value = bitv
            if value ~= 0 then
                local value_count, value_bytes
                if value == x.bitmask then
                    if count_bits(x.bitmask) > 1 then
                        value_bytes, value_count = decint(data, pos)
                        pos = pos + value_count
                        value_count = nil
                    else
                        value_count = 1
                    end
                else
                    local mask = x.bitmask
                    while mask % 2 == 0 do
                        mask = math.floor(mask / 2)
                        value = math.floor(value / 2)
                    end
                    value_count = value
                end
                pending[#pending + 1] = {
                    tag = x.tag,
                    value_count = value_count,
                    value_bytes = value_bytes,
                    num_values = x.num_values,
                }
            end
        end
    end

    local ans = {}
    for _, x in ipairs(pending) do
        local vals = {}
        if x.value_count then
            for _ = 1, x.value_count * x.num_values do
                local v, used = decint(data, pos)
                pos = pos + used
                vals[#vals + 1] = v
            end
        else
            local used_total = 0
            while used_total < x.value_bytes do
                local v, used = decint(data, pos)
                pos = pos + used
                used_total = used_total + used
                vals[#vals + 1] = v
            end
        end
        ans[x.tag] = vals
    end
    return ans
end

local function read_index(sections, idx0)
    local master = sections[idx0 + 1]
    local mh = parse_indx_header(master)
    local tagx = mh.tagx
    if master:sub(tagx + 1, tagx + 4) ~= "TAGX" then
        local p = master:find("TAGX", 197, true)
        if not p then error("INDX has no TAGX") end
        tagx = p - 1
    end
    local control_count, tags = parse_tagx(master, tagx)
    local table_out = {}
    for sec0 = idx0 + 1, idx0 + mh.count do
        local data = sections[sec0 + 1]
        local h = parse_indx_header(data)
        local idxt = h.start
        if data:sub(idxt + 1, idxt + 4) ~= "IDXT" then error("invalid IDXT") end
        local positions = {}
        for j = 0, h.count - 1 do
            positions[j + 1] = u16(data, idxt + 4 + j * 2)
        end
        positions[h.count + 1] = idxt
        for j = 1, h.count do
            local rec = data:sub(positions[j] + 1, positions[j + 1])
            local len = rec:byte(1) or 0
            local ident = rec:sub(2, 1 + len)
            local payload = rec:sub(2 + len)
            table_out[#table_out + 1] = { ident = ident, tags = get_tag_map(control_count, tags, payload) }
        end
    end
    local cncx = {}
    if mh.ncncx and mh.ncncx > 0 then
        local record_offset = 0
        local first_cncx0 = idx0 + mh.count + 1
        for sec0 = first_cncx0, first_cncx0 + mh.ncncx - 1 do
            local data = sections[sec0 + 1]
            if data then
                local pos = 1
                while pos <= #data do
                    local len, used = decint(data, pos)
                    if not len or len <= 0 then break end
                    cncx[(pos - 1) + record_offset] = data:sub(pos + used, pos + used + len - 1)
                    pos = pos + used + len
                end
            end
            record_offset = record_offset + 0x10000
        end
    end
    return table_out, cncx
end

local B32 = "0123456789ABCDEFGHIJKLMNOPQRSTUV"
local function base32_decode(s)
    local n = 0
    s = s:upper()
    for i = 1, #s do
        local p = B32:find(s:sub(i, i), 1, true)
        if not p then return nil end
        n = n * 32 + (p - 1)
    end
    return n
end

local function base32_encode(n, width)
    local out = ""
    repeat
        local d = n % 32
        out = B32:sub(d + 1, d + 1) .. out
        n = math.floor(n / 32)
    until n == 0
    while #out < (width or 1) do out = "0" .. out end
    return out
end

local function image_ext(data)
    if data:sub(1, 3) == "\255\216\255" then return "jpg" end
    if data:sub(1, 8) == "\137PNG\13\10\26\10" then return "png" end
    if data:sub(1, 4) == "GIF8" then return "gif" end
    if data:sub(1, 2) == "BM" then return "bmp" end
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function text_label(html)
    local s = html:gsub("<[^>]+>", " "):gsub("%s+", " ")
    return trim(s)
end

local function html_escape(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local function parse_exth(header)
    local meta = { authors = {} }
    local mobi_len = u32(header, 20)
    local pos = 16 + mobi_len
    if header:sub(pos + 1, pos + 4) ~= "EXTH" then return meta end
    local total = u32(header, pos + 4)
    local count = u32(header, pos + 8)
    local p = pos + 12
    local finish = math.min(#header, pos + total)
    for _ = 1, count do
        if p + 8 > finish then break end
        local typ = u32(header, p)
        local len = u32(header, p + 4)
        if len < 8 or p + len > #header then break end
        local value = header:sub(p + 9, p + len)
        if typ == 100 then
            meta.authors[#meta.authors + 1] = value
        elseif typ == 101 then meta.publisher = value
        elseif typ == 103 then meta.description = value
        elseif typ == 105 then meta.subject = value
        elseif typ == 106 then meta.date = value
        elseif typ == 201 and #value >= 4 then meta.cover_offset = u32(value, 0)
        elseif typ == 202 and #value >= 4 then meta.thumb_offset = u32(value, 0)
        elseif typ == 503 then meta.title = value
        elseif typ == 504 then meta.asin = value
        elseif typ == 524 then meta.language = value
        end
        p = p + len
    end
    if #meta.authors > 0 then meta.author = table.concat(meta.authors, "\n") end
    return meta
end

local function extract_bodies(parts)
    local out = {}
    for i, part in ipairs(parts) do
        local body = part:match("<[bB][oO][dD][yY][^>]*>(.-)</[bB][oO][dD][yY]>") or part
        out[#out + 1] = '<div class="azw-part" id="azw-part-' .. i .. '">\n' .. body .. "\n</div>"
    end
    return table.concat(out, '\n<div style="page-break-before:always"></div>\n')
end

function M.extract(path)
    local raw = read_all(path)
    local sections = section_table(raw)
    local header = sections[1]
    if header:sub(17, 20) ~= "MOBI" then error("missing MOBI header") end

    local encryption = u16(header, 12)
    if encryption ~= 0 then error("DRM-encrypted AZW3 is not supported") end

    local mobi_version = u32(header, 36)
    if mobi_version ~= 8 then error("not a standalone KF8/AZW3 book (MOBI version " .. mobi_version .. ")") end

    local compression = u16(header, 0)
    local text_records = u16(header, 8)
    local extra_flags = (#header >= 0xF4) and u16(header, 0xF2) or 0
    local skelidx = u32(header, 0xFC)
    local dividx = u32(header, 0xF8)
    local fdstidx = u32(header, 0xC0)
    local first_image = u32(header, 0x6C)
    local ncxidx = (#header >= 0x108) and u32(header, 0x104) or NULL_INDEX
    local metadata = parse_exth(header)

    if skelidx == NULL_INDEX or dividx == NULL_INDEX then
        error("KF8 has no SKEL/DIV reconstruction indexes")
    end

    local chunks = {}
    for sec0 = 1, text_records do
        local data = sections[sec0 + 1]
        if not data then error("missing text record " .. sec0) end
        local ts = trailing_size(data, extra_flags)
        if ts > 0 then data = data:sub(1, #data - ts) end
        if compression == 1 then
            chunks[#chunks + 1] = data
        elseif compression == 2 then
            chunks[#chunks + 1] = palmdoc_decompress(data)
        elseif compression == 0x4448 then
            error("HUFF/CDIC-compressed KF8 is not supported yet")
        else
            error("unknown MOBI compression " .. compression)
        end
    end
    local raw_ml = table.concat(chunks):gsub("%z", "")

    local flows = { raw_ml }
    if fdstidx ~= NULL_INDEX then
        local fd = sections[fdstidx + 1]
        if not fd or fd:sub(1, 4) ~= "FDST" then error("invalid KF8 FDST record") end
        local table_start = u32(fd, 4)
        local count = u32(fd, 8)
        flows = {}
        for i = 0, count - 1 do
            local a = u32(fd, table_start + i * 8)
            local z = u32(fd, table_start + i * 8 + 4)
            flows[#flows + 1] = raw_ml:sub(a + 1, z)
        end
    end

    local skels = read_index(sections, skelidx)
    local divs = read_index(sections, dividx)
    local text = flows[1]
    local parts = {}
    local divptr = 1

    for _, sk in ipairs(skels) do
        local t1, t6 = sk.tags[1], sk.tags[6]
        if not t1 or not t6 then error("malformed SKEL index") end
        local divcount = t1[1]
        local skelpos, skellen = t6[1], t6[2]
        local baseptr = skelpos + skellen
        local skeleton = text:sub(skelpos + 1, baseptr)

        for _ = 1, divcount do
            local d = divs[divptr]
            if not d then error("DIV index ended early") end
            local t6d = d.tags[6]
            if not t6d then error("malformed DIV index") end
            local insertpos = tonumber(d.ident)
            local startpos, length = t6d[1], t6d[2]
            local fragment = text:sub(baseptr + 1, baseptr + length)
            local anchor = '<a id="azwfid' .. base32_encode(divptr - 1, 4) .. '"></a>'
            fragment = anchor .. fragment
            local ip = insertpos - skelpos
            skeleton = skeleton:sub(1, ip) .. fragment .. skeleton:sub(ip + 1)
            baseptr = baseptr + length
            divptr = divptr + 1
        end
        parts[#parts + 1] = skeleton
    end

    local unique_id = u32(header, 32)
    local cache_root = DataStorage:getDataDir() .. "/cache/azwreader"
    util.makePath(cache_root)
    local cache_dir = string.format("%s/v03_%08x_%d", cache_root, unique_id, #raw)
    util.makePath(cache_dir)
    local html_path = cache_dir .. "/book.html"

    local resource_map = {}
    if first_image ~= NULL_INDEX and first_image < #sections then
        local ridx = 1
        for sec0 = first_image, #sections - 1 do
            local data = sections[sec0 + 1]
            local ext = image_ext(data)
            if ext then
                local name = string.format("res%04d.%s", ridx, ext)
                write_all(cache_dir .. "/" .. name, data)
                resource_map[ridx] = name
            end
            ridx = ridx + 1
        end
    end

    local cover_path
    if metadata.cover_offset ~= nil then
        cover_path = resource_map[metadata.cover_offset + 1]
        if cover_path then cover_path = cache_dir .. "/" .. cover_path end
    end

    local flow_map = {}
    for i = 2, #flows do
        local logical = i - 1
        local data = flows[i]
        local ext = data:find("<svg", 1, true) and "svg" or "css"
        local name = string.format("flow%04d.%s", logical, ext)
        flow_map[logical] = name
        if ext == "css" then
            data = data:gsub("kindle:embed:([0-9A-Va-v]+)[^%)%s\"']*", function(id)
                local n = base32_decode(id)
                return (n and resource_map[n]) or ""
            end)
        else
            data = data:gsub("kindle:embed:([0-9A-Va-v]+)[^\"']*", function(id)
                local n = base32_decode(id)
                return (n and resource_map[n]) or ""
            end)
        end
        write_all(cache_dir .. "/" .. name, data)
    end

    -- Build a Calibre-style navigation fallback. Many KF8 books have a tiny NCX
    -- and put the real chapter list in an inline contents page. First try NCX;
    -- if it is not useful, use the densest internal-link page as the inline ToC.
    local toc = {}
    if ncxidx ~= NULL_INDEX then
        local ok_ncx, ncx, cncx = pcall(read_index, sections, ncxidx)
        if ok_ncx and ncx then
            for _, entry in ipairs(ncx) do
                local tags = entry.tags
                local title_offset = tags[3] and tags[3][1]
                local title = title_offset and cncx and cncx[title_offset]
                local posfid = tags[6]
                if title and posfid and posfid[1] ~= nil then
                    toc[#toc + 1] = { title = title, fid = posfid[1], depth = (tags[4] and tags[4][1] or 0) + 1 }
                end
            end
        end
    end

    if #toc < 3 then
        toc = {}
        local best = {}
        for _, part in ipairs(parts) do
            local links = {}
            for href, label_html in part:gmatch('<[aA][^>]-href=["\'](kindle:pos:fid:[0-9A-Va-v]+:off:[0-9A-Va-v]+)["\'][^>]*>(.-)</[aA]>') do
                local fid = href:match('kindle:pos:fid:([0-9A-Va-v]+)')
                local n = fid and base32_decode(fid)
                local label = text_label(label_html)
                if n and label ~= "" then links[#links + 1] = { title = label, fid = n, depth = 1 } end
            end
            if #links > #best then best = links end
        end
        if #best >= 2 then toc = best end
    end

    -- CREngine builds its native ToC from heading elements. Inject zero-height
    -- semantic headings at the Kindle fragment targets so KOReader gets native
    -- chapter navigation, chapter ticks/divisions, and accurate page numbers.
    local toc_by_fid = {}
    for _, item in ipairs(toc) do
        toc_by_fid[item.fid] = item
    end
    for i, part in ipairs(parts) do
        parts[i] = part:gsub('<a id="azwfid([0-9A-V]+)"></a>', function(fid_text)
            local n = base32_decode(fid_text)
            local item = n and toc_by_fid[n]
            if not item then return '<a id="azwfid' .. fid_text .. '"></a>' end
            local level = math.max(1, math.min(6, item.depth or 1))
            return string.format('<a id="azwfid%s"></a><h%d class="azw-toc-marker">%s</h%d>',
                fid_text, level, html_escape(item.title), level)
        end)
    end

    local body = extract_bodies(parts)
    body = body:gsub("kindle:embed:([0-9A-Va-v]+)[^\"']*", function(id)
        local n = base32_decode(id)
        return (n and resource_map[n]) or ""
    end)
    body = body:gsub("kindle:flow:([0-9A-Va-v]+)[^\"']*", function(id)
        local n = base32_decode(id)
        return (n and flow_map[n]) or ""
    end)
    body = body:gsub("kindle:pos:fid:([0-9A-Va-v]+):off:[0-9A-Va-v]+", function(fid)
        return "#azwfid" .. fid:upper()
    end)

    local css_links = {}
    for i = 2, #flows do
        local n = i - 1
        local name = flow_map[n]
        if name and name:sub(-4) == ".css" then
            css_links[#css_links + 1] = '<link rel="stylesheet" type="text/css" href="' .. name .. '" />'
        end
    end

    local html = table.concat({
        '<!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml"><head>',
        '<meta charset="utf-8" />',
        metadata.title and ('<title>' .. html_escape(metadata.title) .. '</title>') or '',
        metadata.author and ('<meta name="author" content="' .. html_escape(metadata.author) .. '" />') or '',
        table.concat(css_links, "\n"),
        '<style>.azw-part{display:block} .azw-part + div[style]{height:0} .azw-toc-marker{font-size:1px!important;line-height:1px!important;height:0!important;overflow:hidden!important;margin:0!important;padding:0!important;color:transparent!important}</style>',
        '</head><body>', body, '</body></html>'
    }, "\n")

    write_all(html_path, html)
    logger.info("AZW/KF8 Reader: extracted", path, "to", html_path,
        "parts", #parts, "flows", #flows, "resources", #sections - first_image)
    return {
        html_path = html_path,
        cover_path = cover_path,
        metadata = metadata,
        toc = toc,
    }
end

return M
