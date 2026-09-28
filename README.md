# AZW/AZW3 plugin for KOReader

[KOReader] is a fantastic ebook reader application that supports all formats of ebook on Amazon Kindles and similar ereader devices. With this plugin, you can read Amazon's AZW3 and KFX format books, which normally cannot open in KOReader. 

## Features 
- Read the books you bought from Amazon, without converting them\*: ..azw3 (KF8)/.azw(KFX) support (\*= remove DRM first)
- working table of contents (TOC), images, hyperlinks in all formats. 

## Background

I asked my work's ChatGPT subscription to create a KOReader plugin that can read AZW/AZW3/KFX ebooks, based off [Calibre 4] and [Readest], both of which can read AZW/AZW3 ebooks, and threw a few of my owned AZW3 ebooks at it. Surprisingly, it worked. 

Normally in KOReader [Amazon's own AZW/AZW3 formats are unreadable](https://github.com/koreader/koreader/issues/5845). And [MOBI support is 2nd-class](https://github.com/koreader/koreader/issues/15478) (but they do read, albeit without a TOC and metadata/covers; deDRMed AZW is just plain MOBI). This always seemed a little bit incongruous to me - hack your Amazon Kindle to read "all" ebooks, and you can no longer read the device's native formats properly (unless you use the vanilla Kindle reader, which means dumping all your books in `/mnt/us/documents/`, which makes KUAL or KOReader launch scriptlets difficult to find, making it difficult to read all your other books). 

The AZW3 implementation is based off Calibre: 
- `calibre/ebooks/mobi/reader/mobi8.py`
- `calibre/ebooks/mobi/reader/index.py`
- `calibre/ebooks/mobi/reader/headers.py`
- `calibre/ebooks/mobi/reader/ncx.py`
- `calibre/ebooks/mobi/huffcdic.py`
- Calibre’s MOBI format documentation 

The KFX implementation is based off [jhowell's KFX Conversion Input Plugin](https://www.mobileread.com/forums/showthread.php?t=291290): 
- `kfxlib/kfx_container.py`
- `kfxlib/ion_binary.py`
- `kfxlib/ion_symbol_table.py`
- `kfxlib/yj_container.py`
- `kfxlib/yj_metadata.py`
- `kfxlib/yj_to_epub_content.py`
- `kfxlib/yj_to_epub_navigation.py`
- `kfxlib/yj_to_epub_resources.py`

## Usage
1. Download this repo
2. Copy `azwreader.koplugin` to `/mnt/us/KOReader/plugins/`
3. DeDRM your ebooks using something like [DeDRM_tools] ([updated fork]) or [Epubor] (what I used). **Note:** Downloaded Amazon books come with DRM to prevent unauthorised reading of books that you ~~bought~~ leased from them. Books downloaded more recently may also be in KFX format, which should work from v0.10+. eBooks with DRM **will not work**. 
4. Copy over your deDRMed ebooks and read them with KOReader, the way God intended.

Tested with my owned deDRMed AZW3/KFX books from Amazon Classics, etc. on Kindle Basic 3.

## Limitations
- AZW is not properly supported, because: 
  - (a) DeDRMed .azw is just MOBI, which already works in KOReader. 
  - (b) DRMed .azw should display metadata, but cannot be read (custom message displays saying as much). 
  - (c) Epubor outputs some deDRMed KFX books with the .azw file extension. Is that their proper extension? No clue, but KFX works. 
  - (d) As a result of the aforementioned, I cannot find a single actual .azw file on my PC that I should be able to read; they're all either DRMed .azw (cannot read), converted to MOBI as soon as I deDRM them, or deDRMed KFX masquerading as .azw (and these read just fine). 
- Don't use it to try and read jailbreak AZW files like SpiderCat, Véra, or other known-malformed AZW/AZW3 books. It could crash KOReader or other unpredictable results.
- Currently untested or doesn't work with:
  - large (100MB) AZW3 comics (use CBZ/CBR/PDF instead, keep file sizes small on low-power Kindles)
  - AZW (see above)
  - DRMed AZW/AZW3 (yarr)
- **How it works:** Renders KF8 from AZW3 to HTML/CSS/images in the KOReader cache (`/mnt/us/koreader/cache/azwreader/[version][book-id]/`. I don't know when/if KOReader empties this cache, so if you're running low on space on your Kindle or concerned about flash writes, this could be an issue. Manually empty this folder as needed. 
- The cache is versioned, so you will probably lose reading progress between plugin updates.
- Calibre and Readest both read AZW3, but their TOC for some reason does not hyperlink correctly to chapters in my testing. **This plugin fixes that.** It does hyperlink correctly from the TOC to chapter headings. (See v0.9.2 and v0.10.1)

## License

[Covfefe](SLOP.md) and AGPLv3. README, Git log, testing and idea are human. The code was written by ChatGPT.

[KOReader]: https://github.com/koreader/koreader
[Calibre 4]: https://calibre-ebook.com/
[Readest]: https://github.com/readest/readest/
[DeDRM_tools]: https://github.com/apprenticeharper/DeDRM_tools
[updated fork]: https://github.com/noDRM/DeDRM_tools
[Epubor]: https://www.epubor.com/
[DRM]: https://en.wikipedia.org/wiki/Digital_rights_management?useskin=vector
