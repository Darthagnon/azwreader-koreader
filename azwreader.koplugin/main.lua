local DocumentRegistry = require("document/documentregistry")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local LegacyAZWDocument = require("legacyazwdocument")
local AZW3Document = require("azw3document")

local AZWReader = WidgetContainer:extend{
    name = "azwreader",
    fullname = "AZW/KF8/KFX Reader",
}

function AZWReader:init()
    -- .azw may be legacy MOBI6 rather than KF8. Handle the container ourselves
    -- so EXTH metadata/covers are available even when the payload is encrypted.
    DocumentRegistry:addProvider("azw", "application/vnd.amazon.ebook", LegacyAZWDocument, 120)
    DocumentRegistry:addProvider("azw", "application/x-mobipocket-ebook", LegacyAZWDocument, 120)
    DocumentRegistry:addProvider("azw", "application/vnd.amazon.mobi8-ebook", LegacyAZWDocument, 120)
    DocumentRegistry:addProvider("azw", "application/x-mobi8-ebook", LegacyAZWDocument, 120)

    -- Standalone AZW3/KF8 uses the Calibre-style reconstruction path.
    DocumentRegistry:addProvider("azw3", "application/vnd.amazon.mobi8-ebook", AZW3Document, 120)
    DocumentRegistry:addProvider("kfx", "application/vnd.amazon.kfx", LegacyAZWDocument, 120)
    DocumentRegistry:addProvider("kfx", "application/octet-stream", LegacyAZWDocument, 120)
    DocumentRegistry:addProvider("azw8", "application/vnd.amazon.kfx", LegacyAZWDocument, 120)
end

return AZWReader
