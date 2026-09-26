local CreDocument = require("document/credocument")
local Extractor = require("kf8extractor")
local logger = require("logger")

local AZW3Document = CreDocument:extend{
    provider = "azwreader",
    provider_name = "AZW/KF8 Reader",
}

function AZW3Document:init()
    local original = self.file
    local ok, generated = pcall(Extractor.extract, original)
    if not ok then
        error("AZW3 extraction failed: " .. tostring(generated))
    end
    self._azw_render_file = generated
    logger.info("AZW/KF8 Reader: rendering", original, "from", generated)
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

return AZW3Document
