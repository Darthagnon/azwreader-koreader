# AZW/KF8 Reader for KOReader v0.3

Experimental KOReader plugin for DRM-free Amazon AZW/AZW3 (KF8) books.

## v0.3

- Reads EXTH title, author, language, publisher and cover metadata.
- Extracts and exposes the actual cover to KOReader.
- Reads KF8 NCX navigation where useful.
- Falls back like Calibre to the inline contents page when the KF8 NCX is sparse.
- Injects semantic, zero-height chapter markers at reconstructed Kindle positions so CREngine supplies KOReader's native table of contents, chapter ticks/divisions and chapter navigation.
- Uses a versioned extraction cache so v0.2 cached HTML is not reused.

## Existing support

- Standalone KF8/AZW3 (MOBI version 8)
- Uncompressed KF8
- PalmDOC-compressed KF8
- SKEL/DIV reconstruction
- FDST flows
- Images and CSS
- `kindle:embed`, `kindle:flow`, `kindle:pos` links

## Not supported yet

- DRM
- KFX
- HUFF/CDIC compressed KF8
- Joint MOBI6+KF8 files
