local DocumentRegistry = require("document/documentregistry")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local PdfDocument = require("document/pdfdocument")
local AZW3Document = require("azw3document")

local AZWReader = WidgetContainer:extend{
    name = "azwreader",
    fullname = "AZW/KF8 Reader",
}

function AZWReader:init()
    -- Legacy AZW is MOBI-family and MuPDF already knows how to render MOBI.
    DocumentRegistry:addProvider("azw", "application/vnd.amazon.ebook", PdfDocument, 95)

    -- AZW3/KF8 needs reconstruction before CREngine can render it correctly.
    DocumentRegistry:addProvider("azw3", "application/vnd.amazon.mobi8-ebook", AZW3Document, 110)
end

return AZWReader
