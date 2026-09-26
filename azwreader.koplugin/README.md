# AZW/KF8 Reader for KOReader — v0.4

Adds DRM-free standalone KF8/AZW3 reading to KOReader by reconstructing the
KF8 PalmDB/MOBI container into cached HTML/CSS/images and rendering it with
CREngine.

## v0.4

- Fixes text being cut off when a KF8 fragment boundary occurs inside a
  paragraph or word.
- Removes the synthetic hidden heading injection used by v0.3.
- Exposes the extracted KF8/inline TOC directly through KOReader's document
  API instead, retaining chapter navigation and chapter divisions without
  modifying the visible book text.
- Fixes duplicated chapter headings caused by the v0.3 TOC markers.
- Uses a new v04 cache namespace so stale v0.3 HTML is not reused.

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
