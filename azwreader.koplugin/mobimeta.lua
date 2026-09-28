local DataStorage = require("datastorage")
local util = require("util")

local M = {}

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

local function image_ext(data)
    if data:sub(1, 3) == "\255\216\255" then return "jpg" end
    if data:sub(1, 8) == "\137PNG\13\10\26\10" then return "png" end
    if data:sub(1, 4) == "GIF8" then return "gif" end
    if data:sub(1, 2) == "BM" then return "bmp" end
end

local function html_escape(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

function M.inspect(path)
    local raw = read_all(path)
    if #raw < 78 or raw:sub(61, 68):upper() ~= "BOOKMOBI" then
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

    local header = sections[1]
    if not header or header:sub(17, 20) ~= "MOBI" then
        error("BOOKMOBI has no MOBI header")
    end

    local mobi_len = u32(header, 20)
    local version = u32(header, 36)
    local unique_id = u32(header, 32)
    local encryption = u16(header, 12)
    local first_image = u32(header, 108)
    local meta = { authors = {} }

    local exth_pos = 16 + mobi_len
    if header:sub(exth_pos + 1, exth_pos + 4) == "EXTH" then
        local total = u32(header, exth_pos + 4)
        local exth_count = u32(header, exth_pos + 8)
        local p = exth_pos + 12
        local finish = math.min(#header, exth_pos + total)
        for _ = 1, exth_count do
            if p + 8 > finish then break end
            local typ = u32(header, p)
            local len = u32(header, p + 4)
            if len < 8 or p + len > #header then break end
            local value = header:sub(p + 9, p + len)
            if typ == 100 then
                meta.authors[#meta.authors + 1] = value
            elseif typ == 101 then meta.publisher = value
            elseif typ == 103 then meta.description = value
            elseif typ == 105 and not meta.subject then meta.subject = value
            elseif typ == 106 then meta.date = value
            elseif typ == 201 and #value >= 4 then meta.cover_offset = u32(value, 0)
            elseif typ == 202 and #value >= 4 then meta.thumb_offset = u32(value, 0)
            elseif typ == 503 then meta.title = value
            elseif typ == 504 then meta.asin = value
            elseif typ == 524 then meta.language = value
            end
            p = p + len
        end
    end

    if #meta.authors > 0 then
        meta.author = table.concat(meta.authors, "\n")
    end

    -- EXTH 503 is preferred, but old MOBI files may only carry the legacy
    -- Full Name field in the MOBI header.
    if not meta.title or meta.title == "" then
        local name_off = u32(header, 84)
        local name_len = u32(header, 88)
        if name_len > 0 and name_off + name_len <= #header then
            meta.title = header:sub(name_off + 1, name_off + name_len)
        end
    end

    local cache_root = DataStorage:getDataDir() .. "/cache/azwreader"
    util.makePath(cache_root)
    local cache_dir = string.format("%s/v09mobi_%08x_%d", cache_root, unique_id, #raw)
    util.makePath(cache_dir)

    local cover_path
    if first_image < count and meta.cover_offset ~= nil then
        local cover_sec0 = first_image + meta.cover_offset
        local cover = sections[cover_sec0 + 1]
        local ext = cover and image_ext(cover)
        if ext then
            cover_path = string.format("%s/cover.%s", cache_dir, ext)
            write_all(cover_path, cover)
        end
    end

    local notice_path
    if encryption ~= 0 then
        notice_path = cache_dir .. "/drm.html"
        local title = meta.title and html_escape(meta.title) or "Encrypted AZW"
        local author = meta.author and html_escape(meta.author):gsub("\n", ", ") or ""
        local html = table.concat({
            '<!DOCTYPE html><html><head><meta charset="utf-8" />',
            '<title>' .. title .. '</title>',
            author ~= "" and ('<meta name="author" content="' .. author .. '" />') or "",
            '<style>body{margin:2em;font-family:serif;line-height:1.45}h1{font-size:1.4em}p{margin:1em 0}</style>',
            '</head><body><h1>' .. title .. '</h1>',
            author ~= "" and ('<p>' .. author .. '</p>') or "",
            '<p>This AZW is DRM-encrypted (MOBI encryption type ' .. tostring(encryption) .. ').</p>',
            '<p>AZW/KF8 Reader can display its embedded metadata and cover, but cannot decrypt the book text.</p>',
            '</body></html>'
        }, "\n")
        write_all(notice_path, html)
    end

    return {
        metadata = meta,
        cover_path = cover_path,
        encryption = encryption,
        mobi_version = version,
        notice_path = notice_path,
    }
end

return M
