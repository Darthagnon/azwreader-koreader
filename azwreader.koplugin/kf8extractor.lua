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


-- MOBI HUFF/CDIC decompressor. This mirrors Calibre's huffcdic.py logic,
-- but avoids relying on Lua 64-bit integers: each Huffman decision only needs
-- the next 32 bits, which we build exactly from at most five source bytes.
local POW2 = {}
for i = 0, 32 do POW2[i] = 2 ^ i end

local function huff_code32(data, bitpos)
    local bytepos = math.floor(bitpos / 8) + 1
    local shift = bitpos % 8
    local b1 = data:byte(bytepos) or 0
    local b2 = data:byte(bytepos + 1) or 0
    local b3 = data:byte(bytepos + 2) or 0
    local b4 = data:byte(bytepos + 3) or 0
    local b5 = data:byte(bytepos + 4) or 0
    local word = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
    if shift == 0 then return word end
    return (word * POW2[shift] + math.floor(b5 / POW2[8 - shift])) % POW2[32]
end

local function huff_reader_load_huff(huff)
    if huff:sub(1, 8) ~= "HUFF\0\0\0\24" then
        error("invalid HUFF header")
    end
    local off1, off2 = u32(huff, 8), u32(huff, 12)
    local reader = { dict1 = {}, mincode = {}, maxcode = {}, dictionary = {} }

    for i = 0, 255 do
        local v = u32(huff, off1 + i * 4)
        local codelen = v % 32
        if codelen == 0 then error("invalid HUFF code length") end
        local term = (math.floor(v / 128) % 2) == 1
        if codelen <= 8 and not term then error("invalid HUFF terminal table") end
        local maxcode = math.floor(v / 256)
        maxcode = (maxcode + 1) * POW2[32 - codelen] - 1
        reader.dict1[i + 1] = { codelen = codelen, term = term, maxcode = maxcode }
    end

    reader.mincode[1] = 0
    reader.maxcode[1] = 0
    for codelen = 1, 32 do
        local minraw = u32(huff, off2 + (codelen - 1) * 8)
        local maxraw = u32(huff, off2 + (codelen - 1) * 8 + 4)
        reader.mincode[codelen + 1] = minraw * POW2[32 - codelen]
        reader.maxcode[codelen + 1] = (maxraw + 1) * POW2[32 - codelen] - 1
    end
    return reader
end

local function huff_reader_load_cdic(reader, cdic)
    if cdic:sub(1, 8) ~= "CDIC\0\0\0\16" then
        error("invalid CDIC header")
    end
    local phrases, bits = u32(cdic, 8), u32(cdic, 12)
    if bits > 31 then error("invalid CDIC bit width") end
    local remaining = phrases - #reader.dictionary
    local n = math.min(POW2[bits], remaining)
    if n < 0 then error("invalid CDIC phrase count") end

    for i = 0, n - 1 do
        local off = u16(cdic, 16 + i * 2)
        local blen = u16(cdic, 16 + off)
        local length = blen % 0x8000
        local literal = blen >= 0x8000
        local start = 18 + off
        if start + length > #cdic then error("truncated CDIC phrase") end
        reader.dictionary[#reader.dictionary + 1] = {
            data = cdic:sub(start + 1, start + length),
            literal = literal,
        }
    end
end

local function huff_unpack(reader, data, depth)
    depth = depth or 0
    if depth > 64 then error("HUFF/CDIC recursion limit exceeded") end
    local bitsleft = #data * 8
    local bitpos = 0
    local out = {}

    while bitsleft > 0 do
        local code = huff_code32(data, bitpos)
        local d = reader.dict1[math.floor(code / POW2[24]) + 1]
        if not d then error("invalid HUFF prefix") end
        local codelen, maxcode = d.codelen, d.maxcode

        if not d.term then
            while codelen <= 32 and code < (reader.mincode[codelen + 1] or 0) do
                codelen = codelen + 1
            end
            if codelen > 32 then error("invalid HUFF code") end
            maxcode = reader.maxcode[codelen + 1]
        end

        bitpos = bitpos + codelen
        bitsleft = bitsleft - codelen
        if bitsleft < 0 then break end

        local r = math.floor((maxcode - code) / POW2[32 - codelen])
        local phrase = reader.dictionary[r + 1]
        if not phrase then error("HUFF dictionary index out of range: " .. tostring(r)) end
        if not phrase.literal then
            if phrase.expanding then error("recursive HUFF/CDIC dictionary cycle") end
            phrase.expanding = true
            phrase.data = huff_unpack(reader, phrase.data, depth + 1)
            phrase.literal = true
            phrase.expanding = nil
        end
        out[#out + 1] = phrase.data
    end
    return table.concat(out)
end

local function make_huff_reader(sections, huff_offset, huff_count)
    if huff_offset == NULL_INDEX or huff_count < 2 then
        error("HUFF/CDIC compression has no dictionary records")
    end
    local huff = sections[huff_offset + 1]
    if not huff then error("missing HUFF record") end
    local reader = huff_reader_load_huff(huff)
    for sec0 = huff_offset + 1, huff_offset + huff_count - 1 do
        local cdic = sections[sec0 + 1]
        if not cdic then error("missing CDIC record " .. sec0) end
        huff_reader_load_cdic(reader, cdic)
    end
    return reader
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

local function position_anchor_id(fid, off)
    return "azwpos" .. base32_encode(fid, 4) .. "_" .. base32_encode(off or 0, 1)
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
    -- TOC labels are usually made from inline styling spans (small caps,
    -- italics, etc.).  Replacing each tag with a space corrupts words such as
    -- H<span>UNTING</span> into "H UNTING". Strip inline markup instead.
    local s = html:gsub("<[^>]+>", "")
    s = s:gsub("&nbsp;", " "):gsub("&#160;", " ")
    s = s:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
    s = s:gsub("&quot;", '"'):gsub("&apos;", "'")
    s = trim(s:gsub("%s+", " "))
    -- Kindle small-caps spans are often surrounded by source newlines. After
    -- stripping the spans, remove whitespace that was only formatting markup.
    s = s:gsub("%s+([%-%.,:;!?])", "%1")
    s = s:gsub("%s+([’'])", "%1")
    return s
end

local function html_escape(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

-- Return true when a byte insertion offset falls inside an HTML/XML tag.
-- KF8 DIV offsets are byte offsets into the reconstructed source, not DOM
-- positions, so we must preserve them exactly while assembling the book.
local function insertion_inside_tag(s, offset)
    local head = s:sub(1, offset)
    local last_lt = head:match(".*()<") or 0
    local last_gt = head:match(".*()>") or 0
    return last_lt > last_gt
end

local function safe_fragment_offset(fragment, off)
    off = math.max(0, math.min(off or 0, #fragment))
    if insertion_inside_tag(fragment, off) then
        local head = fragment:sub(1, off)
        local lt = head:match(".*()<")
        if lt then return lt - 1 end
    end
    return off
end

local function find_aid_tag_end(s, aid)
    for _, needle in ipairs({ 'aid="' .. aid .. '"', "aid='" .. aid .. "'" }) do
        local apos = s:find(needle, 1, true)
        if apos then
            local gt = s:find(">", apos, true)
            if gt then return gt end
        end
    end
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

local function normalize_heading_text(s)
    return trim(text_label((s or ""):gsub("&nbsp;", " ")):gsub("%s+", " "))
end

local function add_css_class(attrs, class_name)
    local changed = false
    attrs = attrs:gsub('class%s*=%s*"([^"]*)"', function(classes)
        changed = true
        return 'class="' .. classes .. ' ' .. class_name .. '"'
    end, 1)
    if not changed then
        attrs = attrs:gsub("class%s*=%s*'([^']*)'", function(classes)
            changed = true
            return "class='" .. classes .. " " .. class_name .. "'"
        end, 1)
    end
    if not changed then attrs = attrs .. ' class="' .. class_name .. '"' end
    return attrs
end

-- CREngine handles margins more consistently than percentage padding on the
-- Kindle-generated block layouts used by AZW3.  Preserve the same effective
-- horizontal inset by folding percentage padding into percentage margins.
-- Publisher declarations are otherwise left alone.
local function pct_to_em(value)
    -- KF8 percentage indents are relative to the content box. CREngine's HTML
    -- path is inconsistent with percentage horizontal spacing on Kindle DIVs.
    -- Amazon's common 6.719% first-line indent maps closely to ~1.7em, so use
    -- the same proportional conversion for the related inset values.
    return value * 0.25
end

local function convert_horizontal_percentages(decls)
    for _, prop in ipairs({ "margin-left", "margin-right", "padding-left", "padding-right", "text-indent" }) do
        local patt = prop:gsub("%-", "%%-") .. "%s*:%s*([%+%-]?[%d%.]+)%%"
        decls = decls:gsub(patt, function(v)
            return string.format("%s: %.6gem", prop, pct_to_em(tonumber(v)))
        end)
    end
    return decls
end

local function normalize_css_for_cre(css)
    return css:gsub("([^{}]+){([^{}]*)}", function(selector, decls)
        -- First preserve the effective Kindle box-model inset by folding
        -- percentage padding into margins. Then convert horizontal percentages
        -- to em units, which CREngine applies reliably to HTML DIVs.
        local pl = tonumber(decls:match("padding%-left%s*:%s*([%+%-]?[%d%.]+)%%"))
        local pr = tonumber(decls:match("padding%-right%s*:%s*([%+%-]?[%d%.]+)%%"))
        if pl then
            local ml = tonumber(decls:match("margin%-left%s*:%s*([%+%-]?[%d%.]+)%%")) or 0
            decls = decls .. string.format("; margin-left: %.6g%%; padding-left: 0", ml + pl)
        end
        if pr then
            local mr = tonumber(decls:match("margin%-right%s*:%s*([%+%-]?[%d%.]+)%%")) or 0
            decls = decls .. string.format("; margin-right: %.6g%%; padding-right: 0", mr + pr)
        end
        decls = convert_horizontal_percentages(decls)
        return selector .. "{" .. decls .. "}"
    end)
end

-- Parse the publisher stylesheet's layout declarations so we can mirror them
-- as inline styles. CREngine/KOReader may apply its reading stylesheet after
-- linked CSS; inline author declarations keep the KF8 paragraph geometry intact.
local function collect_block_layout_styles(css)
    local map = {}
    local paragraph_classes = {}
    local wanted = {
        ["text-indent"] = true, ["margin-top"] = true, ["margin-bottom"] = true,
        ["margin-left"] = true, ["margin-right"] = true, ["padding-left"] = true,
        ["padding-right"] = true, ["text-align"] = true,
    }
    local order = {
        "text-indent", "margin-top", "margin-bottom", "margin-left",
        "margin-right", "padding-left", "padding-right", "text-align"
    }
    css:gsub("([^{}]+){([^{}]*)}", function(selector, decls)
        decls = convert_horizontal_percentages(decls)
        -- CSS uses the last declaration of equal specificity, so retain the
        -- last value rather than the first one in our normalized rules.
        local values = {}
        for prop, value in decls:gmatch("([%w%-]+)%s*:%s*([^;{}]+)") do
            prop = prop:lower()
            if wanted[prop] then values[prop] = trim(value) end
        end
        local kept = {}
        for _, prop in ipairs(order) do
            if values[prop] then
                kept[#kept + 1] = prop .. ": " .. values[prop] .. " !important"
            end
        end
        if #kept > 0 then
            for cls in selector:gmatch("%.([%w_%-]+)") do
                map[cls] = table.concat(kept, "; ")
                local align = values["text-align"] and values["text-align"]:lower() or nil
                if align ~= "center" and (values["text-indent"] ~= nil
                    or align == "justify"
                    or values["margin-bottom"] ~= nil) then
                    paragraph_classes[cls] = true
                end
            end
        end
        return selector .. "{" .. decls .. "}"
    end)
    return map, paragraph_classes
end

local function add_inline_style(attrs, style)
    local changed = false
    attrs = attrs:gsub('style%s*=%s*"([^"]*)"', function(existing)
        changed = true
        local sep = existing:match(";%s*$") and " " or "; "
        return 'style="' .. existing .. sep .. style .. '"'
    end, 1)
    if not changed then
        attrs = attrs:gsub("style%s*=%s*'([^']*)'", function(existing)
            changed = true
            local sep = existing:match(";%s*$") and " " or "; "
            return "style='" .. existing .. sep .. style .. "'"
        end, 1)
    end
    if not changed then attrs = attrs .. ' style="' .. style .. '"' end
    return attrs
end

local function inline_block_layout(body, style_map)
    return body:gsub("<([%a][%w]*)" .. "([^>]*)>", function(tag, attrs)
        local lower = tag:lower()
        if lower ~= "div" and lower ~= "p" and not lower:match("^h[1-6]$") then
            return "<" .. tag .. attrs .. ">"
        end
        local classes = attrs:match('class%s*=%s*"([^"]*)"') or attrs:match("class%s*=%s*'([^']*)'")
        if not classes then return "<" .. tag .. attrs .. ">" end
        local styles = {}
        for cls in classes:gmatch("[^%s]+") do
            if style_map[cls] then styles[#styles + 1] = style_map[cls] end
        end
        if #styles == 0 then return "<" .. tag .. attrs .. ">" end
        attrs = add_inline_style(attrs, table.concat(styles, "; "))
        return "<" .. tag .. attrs .. ">"
    end)
end
-- Kindle page-position spans carry navigation metadata only.  CREngine may
-- render the formatting whitespace around these empty spans as visible gaps,
-- especially before punctuation. Remove the markers after KF8 reconstruction;
-- our own azwfid anchors already provide navigation targets.

-- Convert publisher-styled leaf DIVs to semantic P elements in one linear pass.
-- This deliberately avoids rebuilding the whole HTML string for every paragraph,
-- which is prohibitively expensive on low-memory Kindle devices.
local function paragraphize_leaf_divs(body, paragraph_classes)
    local out = {}
    local stack = {}
    local pos = 1
    while true do
        local a, b, slash, attrs = body:find("<(%/?)[dD][iI][vV]([^>]*)>", pos)
        if not a then
            out[#out + 1] = body:sub(pos)
            break
        end

        out[#out + 1] = body:sub(pos, a - 1)

        if slash == "" then
            if #stack > 0 then stack[#stack].has_child_div = true end
            local classes = attrs:match('class%s*=%s*"([^"]*)"') or attrs:match("class%s*=%s*'([^']*)'")
            local candidate = false
            if classes then
                for cls in classes:gmatch("[^%s]+") do
                    if paragraph_classes[cls] then candidate = true break end
                end
            end
            out[#out + 1] = "<div" .. attrs .. ">"
            stack[#stack + 1] = { out_index = #out, attrs = attrs, candidate = candidate, has_child_div = false }
        else
            local open = table.remove(stack)
            if open and open.candidate and not open.has_child_div then
                out[open.out_index] = "<p" .. open.attrs .. ">"
                out[#out + 1] = "</p>"
            else
                out[#out + 1] = body:sub(a, b)
            end
        end
        pos = b + 1
    end
    return table.concat(out)
end

local function strip_page_markers(body)
    local marker = '<span[^>]-id=["\']page_[^"\']+["\'][^>]*></span>'
    body = body:gsub(marker .. '%s*([%.,:;!?])', '%1')
    body = body:gsub(marker .. '%s*%)', ')')
    body = body:gsub(marker .. '%s*%]', ']')
    body = body:gsub(marker .. '%s*”', '”')
    body = body:gsub(marker .. '%s*’', '’')
    body = body:gsub(marker .. '%s*—', '—')
    body = body:gsub(marker .. '%s*–', '–')
    body = body:gsub(marker, '')
    return body
end

local function promote_toc_headings(body, toc)
    for _, item in ipairs(toc or {}) do
        local title = item.title or ""
        local anchor_id = item.anchor and item.anchor:gsub("^#", "")
        if title ~= "" and anchor_id and anchor_id ~= "" then
            local anchor = '<a id="' .. anchor_id .. '"></a>'
            local apos = body:find(anchor, 1, true)
            if apos then
                local after = apos + #anchor
                local tail = body:sub(after)
                local wanted = normalize_heading_text(title)
                local replaced = false

                -- Preserve Amazon's two-line chapter design.  Promote the
                -- existing chapter-number and subtitle blocks separately so
                -- publisher CSS still controls their relative size/spacing.
                local ws, attrs1, text1, attrs2, text2, rest = tail:match(
                    "^(%s*)<div([^>]*)>(.-)</div>%s*<div([^>]*)>(.-)</div>(.*)$")
                if ws and not text1:find("<div", 1, true) and not text2:find("<div", 1, true)
                    and normalize_heading_text(text1 .. " " .. text2) == wanted then
                    local h1attrs = add_css_class(attrs1, "azw-chapter-number")
                    local h2attrs = add_css_class(attrs2, "azw-chapter-title")
                    local heading = ws .. '<h1' .. h1attrs .. '>' .. text1 .. '</h1>\n'
                        .. '<h2' .. h2attrs .. '>' .. text2 .. '</h2>'
                    body = body:sub(1, after - 1) .. heading .. rest
                    replaced = true
                end

                if not replaced then
                    -- A large number of Kindlegen books use <p> rather than
                    -- <div> for their visible chapter-title element.  Promote
                    -- either form without changing classes/inline styling.
                    local ws1, attrs1b, text1b, rest1 = tail:match(
                        "^(%s*)<div([^>]*)>(.-)</div>(.*)$")
                    local source_tag = "div"
                    if not ws1 then
                        ws1, attrs1b, text1b, rest1 = tail:match(
                            "^(%s*)<[pP]([^>]*)>(.-)</[pP]>(.*)$")
                        source_tag = "p"
                    end
                    if ws1 and not text1b:find("<div", 1, true)
                        and not text1b:find("<p", 1, true)
                        and normalize_heading_text(text1b) == wanted then
                        attrs1b = add_css_class(attrs1b, "azw-chapter-heading")
                        local heading = ws1 .. '<h1' .. attrs1b .. '>' .. text1b .. '</h1>'
                        body = body:sub(1, after - 1) .. heading .. rest1
                        replaced = true
                    end
                end

                if not replaced then
                    -- A title page may wrap its one title block in a container.
                    local ws2, outer_attrs, inner_ws, inner_attrs, text1c, inner_tail, rest2 = tail:match(
                        "^(%s*)<div([^>]*)>(%s*)<div([^>]*)>(.-)</div>(%s*)</div>(.*)$")
                    if ws2 and not text1c:find("<div", 1, true)
                        and normalize_heading_text(text1c) == wanted then
                        inner_attrs = add_css_class(inner_attrs, "azw-chapter-heading")
                        local rebuilt = ws2 .. '<div' .. outer_attrs .. '>' .. inner_ws
                            .. '<h1' .. inner_attrs .. '>' .. text1c .. '</h1>'
                            .. inner_tail .. '</div>' .. rest2
                        body = body:sub(1, after - 1) .. rebuilt
                    end
                end
            end
        end
    end
    return body
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
    local huff_offset = (#header >= 0x78) and u32(header, 0x70) or NULL_INDEX
    local huff_count = (#header >= 0x78) and u32(header, 0x74) or 0
    local ncxidx = (#header >= 0xF8) and u32(header, 0xF4) or NULL_INDEX
    local metadata = parse_exth(header)
    local huff_reader = compression == 0x4448 and make_huff_reader(sections, huff_offset, huff_count) or nil

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
            chunks[#chunks + 1] = huff_unpack(huff_reader, data)
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
    local divs, div_cncx = read_index(sections, dividx)
    local text = flows[1]

    -- The NCX pointer lives at MOBI header offset 0xF4.  Older versions of
    -- this plugin accidentally read 0x104 (the KF8 "other index" pointer),
    -- so books without a useful inline contents page lost their native ToC.
    local native_toc = {}
    if ncxidx ~= NULL_INDEX then
        local ok_ncx, ncx, cncx = pcall(read_index, sections, ncxidx)
        if ok_ncx and ncx then
            for _, entry in ipairs(ncx) do
                local tags = entry.tags
                local title_offset = tags[3] and tags[3][1]
                local title = title_offset and cncx and cncx[title_offset]
                local posfid = tags[6]
                if title and posfid and posfid[1] ~= nil then
                    native_toc[#native_toc + 1] = {
                        title = title,
                        fid = posfid[1],
                        off = posfid[2] or 0,
                        depth = (tags[4] and tags[4][1] or 0) + 1,
                    }
                end
            end
        end
    end

    -- Gather every exact fid+offset navigation target before reconstruction.
    -- NCX targets may exist even when no corresponding kindle:pos link occurs
    -- in the XHTML.  Conversely, ordinary internal hyperlinks may introduce
    -- targets not present in the NCX.
    local target_offsets = {}
    local function add_target(fid, off)
        if fid == nil then return end
        off = off or 0
        target_offsets[fid] = target_offsets[fid] or {}
        target_offsets[fid][off] = true
    end
    for _, item in ipairs(native_toc) do add_target(item.fid, item.off) end
    for fid_s, off_s in text:gmatch("kindle:pos:fid:([0-9A-Va-v]+):off:([0-9A-Va-v]+)") do
        add_target(base32_decode(fid_s), base32_decode(off_s))
    end

    local parts = {}
    local divptr = 1

    for _, sk in ipairs(skels) do
        local t1, t6 = sk.tags[1], sk.tags[6]
        if not t1 or not t6 then error("malformed SKEL index") end
        local divcount = t1[1]
        local skelpos, skellen = t6[1], t6[2]
        local baseptr = skelpos + skellen
        local skeleton = text:sub(skelpos + 1, baseptr)
        local anchor_points = {}

        for _ = 1, divcount do
            local d = divs[divptr]
            if not d then error("DIV index ended early") end
            local t6d = d.tags[6]
            if not t6d then error("malformed DIV index") end
            local insertpos = tonumber(d.ident)
            local startpos, length = t6d[1], t6d[2]
            local fragment = text:sub(baseptr + 1, baseptr + length)
            local ip = insertpos - skelpos

            -- Match Calibre's KF8 repair path for bad DIV insert offsets.
            -- Some books point a couple of bytes into a tag; tag 2 identifies
            -- the containing aid= element and tag 6 gives the relative offset.
            if insertion_inside_tag(skeleton, ip) then
                local t2 = d.tags[2]
                local idtext = t2 and div_cncx and div_cncx[t2[1]]
                local aid = idtext and idtext:match("aid=['\"]([^'\"]+)['\"]")
                local tag_end = aid and find_aid_tag_end(skeleton, aid)
                if tag_end then
                    local corrected = tag_end + startpos
                    logger.warn("AZW/KF8 Reader: corrected DIV insert position", ip, "to", corrected, "fid", divptr - 1)
                    ip = corrected
                end
            end

            if ip < 0 or ip > #skeleton then
                error("invalid KF8 DIV insert position " .. tostring(ip))
            end

            -- IMPORTANT: do not add navigation anchors yet. KF8 insert positions
            -- are offsets into the unmodified reconstructed XHTML. Adding even
            -- an empty <a> here shifts every later offset and silently reorders
            -- text fragments. Assemble first, then add anchors in a second pass.
            local fid = divptr - 1
            skeleton = skeleton:sub(1, ip) .. fragment .. skeleton:sub(ip + 1)

            -- Preserve the historical fragment-start anchor, then add any
            -- exact fid+offset targets needed by NCX entries or hyperlinks.
            anchor_points[#anchor_points + 1] = {
                id = "azwfid" .. base32_encode(fid, 4),
                pos = ip,
            }
            local offsets = target_offsets[fid]
            if offsets then
                for off in pairs(offsets) do
                    local safe_off = safe_fragment_offset(fragment, off)
                    anchor_points[#anchor_points + 1] = {
                        id = position_anchor_id(fid, off),
                        pos = ip + safe_off,
                    }
                end
            end
            baseptr = baseptr + length
            divptr = divptr + 1
        end

        -- Add the synthetic fragment anchors only after this XHTML part is fully
        -- reconstructed. Insert from right to left so earlier byte positions do
        -- not move. At this stage the DIV offsets are no longer used.
        table.sort(anchor_points, function(a, b) return a.pos > b.pos end)
        for _, ap in ipairs(anchor_points) do
            local anchor = '<a id="' .. ap.id .. '"></a>'
            skeleton = skeleton:sub(1, ap.pos) .. anchor .. skeleton:sub(ap.pos + 1)
        end

        parts[#parts + 1] = skeleton
    end

    local unique_id = u32(header, 32)
    local cache_root = DataStorage:getDataDir() .. "/cache/azwreader"
    util.makePath(cache_root)
    local cache_dir = string.format("%s/v0101_%08x_%d", cache_root, unique_id, #raw)
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
    local block_style_map = {}
    local paragraph_classes = {}
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
            data = normalize_css_for_cre(data)
            local this_map, this_paragraphs = collect_block_layout_styles(data)
            for k, v in pairs(this_map) do block_style_map[k] = v end
            for k in pairs(this_paragraphs) do paragraph_classes[k] = true end
        else
            data = data:gsub("kindle:embed:([0-9A-Va-v]+)[^\"']*", function(id)
                local n = base32_decode(id)
                return (n and resource_map[n]) or ""
            end)
        end
        write_all(cache_dir .. "/" .. name, data)
    end

    -- Some KF8 generators emit native NCX fid+offset positions that bunch up
    -- near the start of the book (the same failure mode seen in Calibre), while
    -- also shipping a perfectly good inline Kindle contents page.  Historically
    -- this plugin used the inline links and navigated to the fragment start,
    -- which is reliable for those books.  Other books (notably the HUFF/CDIC
    -- Silverberg test case) have no useful inline contents page and require the
    -- native NCX's exact fid+offset targets.  Detect a substantial inline ToC
    -- and choose the navigation model per book.
    local inline_toc = {}
    for _, part in ipairs(parts) do
        local links = {}
        local seen = {}
        for href, label_html in part:gmatch('<[aA][^>]-href=["\'](kindle:pos:fid:[0-9A-Va-v]+:off:[0-9A-Va-v]+)["\'][^>]*>(.-)</[aA]>') do
            local fid_s, off_s = href:match('kindle:pos:fid:([0-9A-Va-v]+):off:([0-9A-Va-v]+)')
            local fid = fid_s and base32_decode(fid_s)
            local off = off_s and base32_decode(off_s) or 0
            local label = text_label(label_html)
            local key = fid and (tostring(fid) .. ":" .. tostring(off)) or nil
            if fid and label ~= "" and not seen[key] then
                seen[key] = true
                links[#links + 1] = { title = label, fid = fid, off = off, depth = 1 }
            end
        end
        if #links > #inline_toc then inline_toc = links end
    end

    local use_inline_toc = #inline_toc >= 4
    local toc = use_inline_toc and inline_toc or native_toc

    -- Preserve the old fallback for malformed/minimal NCX books whose inline
    -- contents page contains only two or three entries.
    if #toc < 2 and #inline_toc >= 2 then
        toc = inline_toc
        use_inline_toc = true
    end

    -- Keep the KF8 fragment anchors inline and otherwise untouched.  A fragment
    -- boundary may legally fall in the middle of a text node (or even a word),
    -- so inserting block elements here corrupts the document.  AZW3Document
    -- exposes these anchors to KOReader as a native ToC instead.
    for _, item in ipairs(toc) do
        item.off = item.off or 0
        if use_inline_toc then
            item.anchor = "#azwfid" .. base32_encode(item.fid, 4)
        else
            item.anchor = "#" .. position_anchor_id(item.fid, item.off)
        end
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
    if use_inline_toc then
        -- Legacy Kindlegen navigation: offsets in these books are not reliable
        -- after reconstruction, but the fragment id identifies the correct
        -- chapter/content block. This is the pre-v0.9.3 behaviour.
        body = body:gsub("kindle:pos:fid:([0-9A-Va-v]+):off:[0-9A-Va-v]+", function(fid_s)
            return "#azwfid" .. fid_s:upper()
        end)
        -- Exact-offset anchors were gathered before we knew which navigation
        -- model this book needed. They are unnecessary in FID mode and can sit
        -- between the fragment anchor and visible chapter title, preventing
        -- semantic heading promotion. Remove only our synthetic exact anchors.
        body = body:gsub('<a id="azwpos[0-9A-V_]+"></a>', '')
    else
        body = body:gsub("kindle:pos:fid:([0-9A-Va-v]+):off:([0-9A-Va-v]+)", function(fid_s, off_s)
            local fid = base32_decode(fid_s)
            local off = base32_decode(off_s)
            if fid == nil or off == nil then return "#" end
            return "#" .. position_anchor_id(fid, off)
        end)
    end

    body = strip_page_markers(body)
    body = promote_toc_headings(body, toc)
    body = paragraphize_leaf_divs(body, paragraph_classes)
    body = inline_block_layout(body, block_style_map)

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
        '<style>.azw-part{display:block} .azw-part + div[style]{height:0} h1.azw-chapter-number,h2.azw-chapter-title,h1.azw-chapter-heading{display:block;font-weight:normal;margin:0;text-indent:0;page-break-before:auto;page-break-after:avoid}</style>',
        table.concat(css_links, "\n"),
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
