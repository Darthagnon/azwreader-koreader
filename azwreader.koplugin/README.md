# AZW/KF8/KFX Reader for KOReader — v0.10.1

Adds DRM-free Amazon AZW/AZW3/KFX reading to KOReader. KF8/AZW3 is
reconstructed from PalmDB/MOBI records; DRM-free reflowable KFX `CONT`
containers are decoded from Amazon Ion into cached HTML/images and rendered
with CREngine.

## v0.6

- Fixes misplaced/cut-off text caused by synthetic fragment anchors changing
  Calibre/KF8 byte offsets during SKEL/DIV reconstruction.
- Reconstructs each XHTML part first, then adds fragment anchors in a second
  right-to-left pass so the original KF8 offsets are never disturbed.
- Implements Calibre's bad-DIV-offset repair path using the DIV CnCx `aid`
  target and `start_pos` when an insert position lands inside a tag.
- Restores semantic headings without duplication: existing source title blocks
  that match a ToC entry are promoted/replaced with a single `<h1>`.
- Keeps KOReader ToC/chapter navigation through the document API.
- Uses versioned extraction caches so older generated HTML is ignored.

## Tested against the supplied books

- *The Lost World (AmazonClassics Edition)*: standalone KF8, 24 XHTML parts,
  77 DIV fragments. The previously broken phrases around `from the fire.`,
  `was very slow.`, and `general view.` reconstruct contiguously.
- *The Jungle Book (AmazonClassics Edition)*: standalone KF8, 34 XHTML parts,
  69 DIV fragments; the extractor accepts and reconstructs it.

## Supported

- Standalone MOBI 8 / KF8 / AZW3
- No DRM
- Uncompressed, PalmDOC-compressed, or HUFF/CDIC-compressed KF8 text
- Images, CSS/SVG flows, internal hyperlinks
- EXTH metadata and cover
- NCX with inline-contents fallback
- DRM-free reflowable KFX (`CONT`) stored as `.azw`, `.kfx`, or `.azw8`
- KFX title/author/publisher/language metadata and cover
- KFX reading order, images, TOC/chapter headings, and internal/external hyperlinks

## Not yet supported

- Joint MOBI6+KF8 containers
- DRM
- KFX fixed-layout/comic/print-replica features beyond the reflowable path

## Calibre wireless transfer note

KOReader's built-in Calibre wireless plugin does not currently advertise
`azw3` in its default accepted-formats list. This is separate from the local
AZW reader registration. If you use Calibre Wireless Device Connection,
KOReader supports a `calibre-extensions.lua` override in its data directory;
add `azw3` to that list if you want Calibre to send the original AZW3 instead
of converting/selecting another format.


## v0.6 rendering fixes

- Preserves two-line publisher chapter headings as separate semantic H1/H2 elements.
- Removes empty Kindle page-marker spans that can create visible spacing before punctuation in CREngine.
- Converts percentage horizontal padding to equivalent margins for CREngine while retaining text-indent and the rest of the publisher CSS.
- Uses a v06 cache namespace.

## v0.7 changes

- Fix KOReader cover rendering call (`RenderImage:renderImageFile`).
- Fix TOC labels with inline small-caps spans (e.g. `H<span>UNTING</span>` no longer becomes `H UNTING`).
- Convert Kindle horizontal percentage layout values to CREngine-friendly `em` values.
- Mirror publisher paragraph indentation/margins as inline `!important` styles on block elements so KOReader's reader stylesheet does not silently flatten them.
- Cache namespace bumped to `v07_...`.


## v0.8.1 changes

- Rebased on the stable v0.7 renderer/cover path.
- Fixes the v0.8 low-memory crash: paragraph conversion is now a single linear pass instead of repeatedly rebuilding the complete HTML string.
- Converts publisher-styled leaf KF8 prose DIVs to semantic `<p>` elements while leaving structural DIVs intact.
- Adds a `getProps()` metadata fallback so cached ZenOS/KOReader metadata can still receive the embedded EXTH author.
- Uses a new `v081_...` extraction cache namespace.


## v0.9 changes

- Fix legacy `.azw` / MOBI6 books failing to open.
- Stops routing `.azw` through MuPDF/PdfDocument; legacy AZW is now explicitly handled by KOReader's native CREngine MOBI backend.
- Keeps `.azw3` / KF8 on the existing Calibre-style reconstruction path.
- Verified the supplied Fifth and Sixth Science Fiction Megapack files are DRM-free MOBI6/PalmDOC containers with valid EXTH metadata, covers and NCX records.

## v0.9.1 changes

- Adds a dedicated legacy `.azw` / MOBI6 document path instead of blindly handing `.azw` to another renderer.
- Parses legacy MOBI/EXTH title, authors, publisher, language, description and cover directly from the container.
- Supports unencrypted legacy `.azw` rendering through CREngine with the extracted metadata/cover overlaid into KOReader/ZenOS.
- Detects MOBI encryption before rendering. Encrypted text is never sent to CREngine as plaintext, preventing the previous gobbledygook display.
- For DRM-encrypted `.azw`, embedded metadata and cover remain available, while opening the book displays a clear unsupported-DRM notice.
- The supplied Fifth and Sixth Science Fiction Megapack files are MOBI 6 with encryption type 2; their EXTH metadata and cover records are readable, but their text payload is encrypted.


## v0.9.2 changes

- Adds native HUFF/CDIC decompression for DRM-free standalone KF8/AZW3 books.
- Loads the MOBI HUFF record and all associated CDIC dictionary records, with recursive phrase expansion and memoization.
- Uses a 32-bit sliding Huffman code window implemented with exact Lua-number arithmetic, avoiding 64-bit bit-operation dependencies on older Kindle/KOReader builds.
- Keeps the existing KF8 SKEL/DIV reconstruction path unchanged after decompression.
- Uses a new `v092_...` extraction cache namespace.
- Validated against the supplied *The Second Science Fiction Megapack*: decompressed output matches the reference Calibre algorithm byte-for-byte (1,676,379 bytes; FDST flows 1,672,014 + 4,365 bytes).


## v0.9.3 changes

- Fix the KF8 NCX index pointer: MOBI header offset `0xF4` is NCX; `0x104` is the KF8 other-index pointer.
- Preserve NCX `fid + off` targets instead of discarding the offset.
- Create exact synthetic anchors for all NCX and `kindle:pos` targets after DIV reconstruction.
- Rewrite internal `kindle:pos:fid:...:off:...` hyperlinks to those exact anchors.
- Promote NCX-matched `<p>` chapter titles to semantic `<h1>` headings as well as the existing `<div>` title forms.
- Use a fresh `v093_...` cache namespace.


## v0.10 changes

- Adds native DRM-free reflowable KFX `CONT` parsing with Amazon Ion decoding.
- Detects KFX by container signature, so KFX books mislabeled with `.azw` work alongside normal MOBI/AZW files.
- Registers `.kfx` and `.azw8` in addition to `.azw`.
- Extracts KFX metadata and embedded cover/resources directly from `$490`, `$164`, and `$417` entities.
- Rebuilds KFX reading order from `$258`/`$260`/`$259` content entities, including externalized `$145` text.
- Builds KOReader TOC/chapter navigation from KFX `$389` / `$212` navigation trees and promotes matching text blocks to semantic headings.
- Rewrites KFX `$266` internal/external link events into HTML hyperlinks and exact EID anchors.
- Uses a separate `v010_kfx_...` cache namespace.
- The v0.9.3 KF8/AZW3 extractor is unchanged.

Validated with the supplied DRM-free KFX samples: *Egyptian Mythology* (24 sections / 14 TOC entries), *Self Discipline* (36 / 16), and *Ishtar's Odyssey* (47 / 34).

## v0.10.1 changes

- Fix normal AZW3/KF8 TOC regression introduced by v0.9.3 exact-offset navigation.
- Prefer a substantial inline Kindle contents page (4+ unique targets) when present and use the proven fragment/FID navigation model for its TOC, chapter headings and `kindle:pos` links.
- Keep native NCX exact `fid+offset` navigation for books without a useful inline ToC, including HUFF/CDIC KF8 books such as the Silverberg test file.
- Use a fresh `v0101_...` KF8 cache namespace. KFX extraction remains unchanged.
