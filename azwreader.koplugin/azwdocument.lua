local PdfDocument = require("document/pdfdocument")
local Header = require("mobiheader")

local AZWDocument = PdfDocument:extend{
    provider = "azwreader",
    provider_name = "AZW Reader (MuPDF)",
    is_pdf = false,
}

function AZWDocument:init()
    local info, err = Header.inspect(self.file)
    if not info then
        error("Invalid AZW/MOBI container: " .. tostring(err))
    end

    if info.drm then
        error("DRM-protected AZW books are not supported")
    end

    self.azw_info = info

    -- MuPDF already contains a MOBI parser in current KOReader builds.
    -- Registering .azw/.azw3 with this provider allows MuPDF to receive the
    -- original file without renaming or copying it.
    PdfDocument.init(self)
end

return AZWDocument
