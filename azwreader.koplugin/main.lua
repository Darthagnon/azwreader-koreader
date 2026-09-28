local DocumentRegistry = require("document/documentregistry")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local CreDocument = require("document/credocument")
local AZW3Document = require("azw3document")

local AZWReader = WidgetContainer:extend{
    name = "azwreader",
    fullname = "AZW/KF8 Reader",
}

function AZWReader:init()
    -- Legacy .azw files are often ordinary MOBI6/PalmDOC containers.
    -- KOReader's CREngine has native MOBI support and handles these better
    -- than MuPDF.  v0.8.1 accidentally overrode KOReader's normal CREngine
    -- provider with PdfDocument, which broke otherwise valid legacy AZWs.
    -- Register CREngine explicitly at plugin priority for the common Amazon
    -- and Mobipocket MIME types while leaving the file untouched.
    DocumentRegistry:addProvider("azw", "application/vnd.amazon.ebook", CreDocument, 110)
    DocumentRegistry:addProvider("azw", "application/x-mobipocket-ebook", CreDocument, 110)
    DocumentRegistry:addProvider("azw", "application/vnd.amazon.mobi8-ebook", CreDocument, 110)
    DocumentRegistry:addProvider("azw", "application/x-mobi8-ebook", CreDocument, 110)

    -- AZW3/KF8 still uses our Calibre-style reconstruction path.
    DocumentRegistry:addProvider("azw3", "application/vnd.amazon.mobi8-ebook", AZW3Document, 110)
end

return AZWReader
