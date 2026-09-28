local CreDocument = require("document/credocument")
local Document = require("document/document")
local MobiMeta = require("mobimeta")
local KFXExtractor = require("kfxextractor")
local RenderImage = require("ui/renderimage")
local logger = require("logger")

local LegacyAZWDocument = CreDocument:extend{
    provider = "azwreader",
    provider_name = "AZW/KF8 Reader",
}

function LegacyAZWDocument:init()
    local original = self.file
    local ok, info
    if KFXExtractor.is_kfx(original) then
        ok, info = pcall(KFXExtractor.extract, original)
        if not ok then error("KFX extraction failed: " .. tostring(info)) end
    else
        ok, info = pcall(MobiMeta.inspect, original)
        if not ok then error("AZW metadata inspection failed: " .. tostring(info)) end
        if info.encryption ~= 0 then
            logger.warn("AZW/KF8 Reader: DRM-encrypted legacy AZW detected", original,
                "MOBI version", info.mobi_version, "encryption", info.encryption)
        end
    end
    self._azw_info = info
    self._azw_render_file = info.html_path or info.notice_path or original
    CreDocument.init(self)
end

function LegacyAZWDocument:loadDocument(full_document)
    if not self._loaded then
        local only_metadata = full_document == false
        if self._document:loadDocument(self._azw_render_file, only_metadata) then
            self._loaded = true
        end
    end
    return self._loaded
end


function LegacyAZWDocument:getToc()
    local source_toc = self._azw_info and self._azw_info.toc
    if not source_toc or #source_toc == 0 then return CreDocument.getToc(self) end
    self:loadDocument()
    local toc, last_page = {}, 1
    for _, item in ipairs(source_toc) do
        local xp = item.anchor
        local page
        if xp and self:isXPointerInDocument(xp) then
            local ok, resolved = pcall(self.getPageFromXPointer, self, xp)
            if ok and type(resolved) == "number" and resolved > 0 then page = resolved end
        end
        page = page or last_page
        if page < last_page then page = last_page end
        last_page = page
        toc[#toc + 1] = {
            title = item.title, depth = item.depth or 1, page = page, xpointer = xp,
        }
    end
    return toc
end

function LegacyAZWDocument:getDocumentProps()
    local props = {}
    if self._loaded then
        props = CreDocument.getDocumentProps(self) or {}
    end
    local meta = self._azw_info and self._azw_info.metadata or {}
    if meta.title and meta.title ~= "" then props.title = meta.title end
    if meta.author and meta.author ~= "" then
        props.authors = meta.author
        props.author = meta.author
    end
    if meta.language and meta.language ~= "" then props.language = meta.language end
    if meta.publisher and meta.publisher ~= "" then props.publisher = meta.publisher end
    if meta.description and meta.description ~= "" then props.description = meta.description end
    return props
end

function LegacyAZWDocument:getProps(cached_doc_metadata)
    local props = Document.getProps(self, cached_doc_metadata) or {}
    local meta = self._azw_info and self._azw_info.metadata or {}
    if meta.title and meta.title ~= "" then props.title = meta.title end
    if meta.author and meta.author ~= "" then
        props.authors = meta.author
        props.author = meta.author
    end
    if meta.language and meta.language ~= "" then props.language = meta.language end
    if meta.publisher and meta.publisher ~= "" then props.publisher = meta.publisher end
    if meta.description and meta.description ~= "" then props.description = meta.description end
    return props
end

function LegacyAZWDocument:getCoverPageImage()
    local cover = self._azw_info and self._azw_info.cover_path
    if cover then
        local ok, image = pcall(function()
            return RenderImage:renderImageFile(cover, false, nil, nil)
        end)
        if ok and image then return image end
        logger.warn("AZW/KF8 Reader: failed to render legacy AZW cover", cover)
    end
    return CreDocument.getCoverPageImage(self)
end

return LegacyAZWDocument
