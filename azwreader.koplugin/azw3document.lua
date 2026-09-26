local CreDocument = require("document/credocument")
local Extractor = require("kf8extractor")
local RenderImage = require("ui/renderimage")
local logger = require("logger")

local AZW3Document = CreDocument:extend{
    provider = "azwreader",
    provider_name = "AZW/KF8 Reader",
}

function AZW3Document:init()
    local original = self.file
    local ok, info = pcall(Extractor.extract, original)
    if not ok then
        error("AZW3 extraction failed: " .. tostring(info))
    end
    self._azw_info = info
    self._azw_render_file = info.html_path
    logger.info("AZW/KF8 Reader: rendering", original, "from", self._azw_render_file)
    CreDocument.init(self)
end

function AZW3Document:loadDocument(full_document)
    if not self._loaded then
        local only_metadata = full_document == false
        if self._document:loadDocument(self._azw_render_file, only_metadata) then
            self._loaded = true
        end
    end
    return self._loaded
end


function AZW3Document:getToc()
    local source_toc = self._azw_info and self._azw_info.toc
    if not source_toc or #source_toc == 0 then
        return CreDocument.getToc(self)
    end

    -- Resolve the inline KF8 fragment anchors only after CREngine has built its
    -- DOM.  Returning both page and xpointer gives ReaderToc accurate chapter
    -- divisions as well as precise navigation without modifying book content.
    self:loadDocument()
    local toc = {}
    local last_page = 1
    for _, item in ipairs(source_toc) do
        local xp = item.anchor
        local page
        if xp and self:isXPointerInDocument(xp) then
            local ok, resolved = pcall(self.getPageFromXPointer, self, xp)
            if ok and type(resolved) == "number" and resolved > 0 then
                page = resolved
            end
        end

        -- A malformed target should not make KOReader reject the whole ToC.
        -- Keep ordering stable and use the previous valid page as a fallback.
        page = page or last_page
        if page < last_page then page = last_page end
        last_page = page
        toc[#toc + 1] = {
            title = item.title,
            depth = item.depth or 1,
            page = page,
            xpointer = xp,
        }
    end
    return toc
end

function AZW3Document:getDocumentProps()
    local props = CreDocument.getDocumentProps(self) or {}
    local meta = self._azw_info and self._azw_info.metadata or {}
    if meta.title and meta.title ~= "" then props.title = meta.title end
    if meta.author and meta.author ~= "" then props.authors = meta.author end
    if meta.language and meta.language ~= "" then props.language = meta.language end
    if meta.publisher and meta.publisher ~= "" then props.publisher = meta.publisher end
    if meta.description and meta.description ~= "" then props.description = meta.description end
    return props
end

function AZW3Document:getCoverPageImage()
    local cover = self._azw_info and self._azw_info.cover_path
    if cover then
        local ok, image = pcall(function()
            return RenderImage:renderImageFile(cover, false, nil, nil)
        end)
        if ok and image then return image end
        logger.warn("AZW/KF8 Reader: failed to render cover", cover)
    end
    return CreDocument.getCoverPageImage(self)
end

return AZW3Document
