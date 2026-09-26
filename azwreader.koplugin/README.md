# AZW Reader for KOReader

Experimental KOReader plugin for DRM-free Amazon AZW/AZW3 ebooks.

## What it does

- Registers `.azw` and `.azw3` as readable document types in KOReader.
- Parses the PalmDB/PalmDOC/MOBI header before opening the book.
- Rejects malformed containers and DRM-encrypted books explicitly.
- Passes valid DRM-free books to KOReader's bundled MuPDF MOBI engine.

The header model is based on the same PalmDB/PalmDOC/MOBI structure used by
Calibre's MOBI input/metadata code, but the Lua code here is a clean
implementation for KOReader.

## Install

Copy the whole folder:

    azwreader.koplugin

to KOReader's `plugins` directory, then restart KOReader.

Typical locations include:

    koreader/plugins/azwreader.koplugin

## Supported

- DRM-free `.azw` MOBI-family books
- DRM-free `.azw3` / KF8, subject to the MOBI support in the MuPDF version
  bundled with your KOReader build

## Not supported

- Amazon DRM
- KFX
- Topaz/AZW1

## Why this is deliberately small

KOReader already ships MuPDF with MOBI support, but its current document
registry only exposes `.mobi`. Reusing that backend avoids carrying a second
complete renderer in Lua.

The separate `mobiheader.lua` module gives us a place to extend this into a
full Calibre-style extractor later if KF8/AZW3 compatibility proves
insufficient in MuPDF.

## Licence

AGPL-3.0-or-later, matching KOReader's licensing model.
