--[[
    Minimal MOBI/AZW header reader for KOReader.

    The structure and validation strategy follow the same PalmDB/PalmDOC/MOBI
    container model used by calibre's MOBI reader, but this is a clean Lua
    implementation intended for KOReader.

    Only header inspection is done here. Rendering is delegated to KOReader's
    existing MuPDF MOBI backend.
]]

local M = {}

local function be16(s, p)
    local a, b = s:byte(p, p + 1)
    if not b then return nil end
    return a * 256 + b
end

local function be32(s, p)
    local a, b, c, d = s:byte(p, p + 3)
    if not d then return nil end
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local function read_at(f, offset, count)
    assert(f:seek("set", offset))
    return f:read(count)
end

function M.inspect(path)
    local f, err = io.open(path, "rb")
    if not f then
        return nil, "Cannot open file: " .. tostring(err)
    end

    local hdr = f:read(78)
    if not hdr or #hdr < 78 then
        f:close()
        return nil, "File is too small to be a PalmDB/MOBI book"
    end

    -- Palm Database header: record count is a big-endian uint16 at offset 76.
    local record_count = be16(hdr, 77)
    if not record_count or record_count < 1 then
        f:close()
        return nil, "PalmDB has no records"
    end

    local rec0_entry = f:read(8)
    if not rec0_entry or #rec0_entry < 8 then
        f:close()
        return nil, "Truncated PalmDB record table"
    end

    local rec0_offset = be32(rec0_entry, 1)
    if not rec0_offset then
        f:close()
        return nil, "Invalid first record offset"
    end

    local rec0 = read_at(f, rec0_offset, 256)
    f:close()

    if not rec0 or #rec0 < 24 then
        return nil, "Truncated PalmDOC/MOBI header"
    end

    -- PalmDOC header occupies the first 16 bytes of record zero.
    local compression = be16(rec0, 1)
    local text_length = be32(rec0, 5)
    local text_records = be16(rec0, 9)
    local record_size = be16(rec0, 11)
    local encryption = be16(rec0, 13)

    if rec0:sub(17, 20) ~= "MOBI" then
        return nil, "Record 0 does not contain a MOBI header"
    end

    local mobi_header_length = be32(rec0, 21)
    local mobi_type = be32(rec0, 25)
    local encoding = be32(rec0, 29)
    local unique_id = be32(rec0, 33)
    local file_version = be32(rec0, 37)

    -- First image record is at MOBI header offset 76, i.e. record0 offset 92.
    local first_image_index = (#rec0 >= 96) and be32(rec0, 93) or nil

    -- EXTH flags live at MOBI header offset 112 in sufficiently long headers.
    local exth_flags = (#rec0 >= 132) and be32(rec0, 129) or nil

    local format
    if file_version and file_version >= 8 then
        format = "KF8/AZW3"
    else
        format = "MOBI/AZW"
    end

    return {
        record_count = record_count,
        record0_offset = rec0_offset,
        compression = compression,
        text_length = text_length,
        text_records = text_records,
        record_size = record_size,
        encryption = encryption,
        mobi_header_length = mobi_header_length,
        mobi_type = mobi_type,
        encoding = encoding,
        unique_id = unique_id,
        file_version = file_version,
        first_image_index = first_image_index,
        exth_flags = exth_flags,
        format = format,
        drm = encryption ~= 0,
    }
end

return M
