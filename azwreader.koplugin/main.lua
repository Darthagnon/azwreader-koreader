local DocumentRegistry = require("document/documentregistry")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local AZWDocument = require("azwdocument")

local AZWReader = WidgetContainer:extend{
    name = "azwreader",
    fullname = "AZW Reader",
}

function AZWReader:init()
    -- Amazon's legacy AZW is MOBI-family content. AZW3 is KF8 in a MOBI
    -- container. MuPDF currently has a MOBI backend, but KOReader does not
    -- register these extensions itself.
    DocumentRegistry:addProvider(
        "azw",
        "application/vnd.amazon.ebook",
        AZWDocument,
        95
    )

    DocumentRegistry:addProvider(
        "azw3",
        "application/vnd.amazon.mobi8-ebook",
        AZWDocument,
        95
    )
end

return AZWReader
