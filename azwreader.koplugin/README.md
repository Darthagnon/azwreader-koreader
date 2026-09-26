# AZW/KF8 Reader for KOReader — v0.8

Adds DRM-free standalone KF8/AZW3 reading to KOReader by reconstructing the
KF8 PalmDB/MOBI container into cached HTML/CSS/images and rendering it with
CREngine.

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
- Uncompressed or PalmDOC-compressed text
- Images, CSS/SVG flows, internal hyperlinks
- EXTH metadata and cover
- NCX with inline-contents fallback

## Not yet supported

- HUFF/CDIC-compressed KF8
- Joint MOBI6+KF8 containers
- DRM
- KFX

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

## v0.8 changes

- Fix KOReader cover rendering call (`RenderImage:renderImageFile`).
- Fix TOC labels with inline small-caps spans (e.g. `H<span>UNTING</span>` no longer becomes `H UNTING`).
- Convert Kindle horizontal percentage layout values to CREngine-friendly `em` values.
- Mirror publisher paragraph indentation/margins as inline `!important` styles on block elements so KOReader's reader stylesheet does not silently flatten them.
- Cache namespace bumped to `v07_...`.


## v0.8
- Convert publisher-styled leaf KF8 prose DIVs to semantic `<p>` elements for KOReader/CREngine paragraph layout.
- Preserve publisher classes and inline layout declarations on converted paragraphs.
- Fill missing `authors` in `getProps()` directly from EXTH metadata, even when KOReader/ZenOS passes cached metadata.
- Uses a new `v08_...` extraction cache namespace.
