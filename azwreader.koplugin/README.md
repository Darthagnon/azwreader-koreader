# AZW/KF8 Reader for KOReader - v0.2

This version no longer sends AZW3 directly to MuPDF.

For DRM-free standalone KF8/AZW3 it follows the same structural path used by
Calibre's MOBI8 reader:

1. Read the PalmDB/MOBI records.
2. Remove MOBI trailing record data.
3. Decompress uncompressed or PalmDOC text records.
4. Read `FDST` flow boundaries.
5. Parse `SKEL` and `DIV` INDX tables.
6. Reconstruct the original XHTML parts.
7. Extract raster resources.
8. Rewrite `kindle:flow`, `kindle:embed`, and `kindle:pos` references.
9. Cache the reconstructed book under KOReader's data/cache directory and load
   it with CREngine while keeping the original AZW3 as KOReader's document key.

## Tested input

Developed against the supplied `The Lost World (AmazonClassics - Sir Arthur Conan-Doyle.azw3`.
It is standalone KF8 (MOBI v8), UTF-8, unencrypted, compression type 1, with
24 SKEL parts and 77 DIV fragments.

## Current support

- DRM-free standalone AZW3/KF8
- compression type 1 (none)
- compression type 2 (PalmDOC)
- raster JPEG/PNG/GIF/BMP resources
- KF8 CSS/SVG flows
- approximate internal `kindle:pos` links (fragment target; offset ignored)
- legacy `.azw` remains routed to KOReader's existing MuPDF MOBI backend

## Not yet supported

- Amazon DRM
- KFX
- Topaz
- HUFF/CDIC-compressed KF8
- embedded KF8 fonts (font references fall back to KOReader fonts)
- joint MOBI6+KF8 containers
- exact `kindle:pos` offset placement / NCX reconstruction

## Install

Copy the complete folder as:

    koreader/plugins/azwreader.koplugin/

The folder name must end in `.koplugin`. Restart KOReader afterwards.
