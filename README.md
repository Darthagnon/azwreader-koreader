# AZW/AZW3 plugin for KOReader

[KOReader] is a fantastic ebook reader application that supports all formats of ebook on Amazon Kindles and similar ereader devices. With this plugin, you can read Amazon's AZW3-format books, which normally cannot open in KOReader. Features working table of contents (TOC), images, hyperlinks. I asked my work's ChatGPT subscription to create a KOReader plugin that can read AZW/AZW3 ebooks, based off [Calibre 4] and [Readest], both of which can read AZW/AZW3 ebooks, and threw a few of my owned AZW3 ebooks at it. Surprisingly, it worked. 

Normally in KOReader [Amazon's own AZW/AZW3 formats are unreadable](https://github.com/koreader/koreader/issues/5845). And [MOBI support is 2nd-class](https://github.com/koreader/koreader/issues/15478), but they do read, albeit without a TOC; I believe the MOBI format is related to AZW/AZW3. This always seemed a little bit incongruous to me - hack your Amazon Kindle to read "all" ebooks, and you can no longer read the device's native formats properly (unless you use the vanilla Kindle reader, which means dumping all your books in `/mnt/us/documents`, which makes KUAL or KOReader launch scriptlets difficult to find, making it difficult to read all your other books). 

## Usage
1. Download this repo
2. Copy `azwreader.koplugin` to `/mnt/us/KOReader/plugins/`
3. DeDRM your ebooks using something like [DeDRM_tools] ([updated fork]) or [Epubor] (what I used). **Note:** Downloaded Amazon books come with DRM to prevent unauthorised reading of books that you ~~bought~~ leased from them. Books downloaded more recently may also be in KFX format. eBooks with DRM and KFX **will not work**. 
4. Copy over your deDRMed ebooks and read them with KOReader, the way God intended.

Tested with my owned deDRMed AZW3 books from Amazon Classics on Kindle Basic 3.

## Limitations
- Don't use it to try and read jailbreak AZW files like SpiderCat, Véra, or other known-malformed AZW/AZW3 books. It could crash KOReader or other unpredictable results.
- Currently untested (and probably doesn't work with) with AZW3 comics, AZW, DRMed AZW/AZW3, KFX. 
- **How it works:** Renders KF8 from AZW3 to HTML/CSS/images in the KOReader cache (`/mnt/us/koreader/cache/azwreader/[version][book-id]/`. I don't know when/if KOReader empties this cache, so if you're running low on space on your Kindle or concerned about flash writes, this could be an issue. Manually empty this folder as needed. 
- The cache is versioned, so you will probably lose reading progress between plugin updates.
- Calibre and Readest both read AZW3, but their TOC for some reason does not hyperlink correctly to chapters in my testing. **This plugin fixes that.** It does hyperlink correctly from the TOC to chapter headings. 

## License

[Covfefe](SLOP.md) and AGPLv3

[KOReader]: https://github.com/koreader/koreader
[Calibre 4]: https://calibre-ebook.com/
[Readest]: https://github.com/readest/readest/
[DeDRM_tools]: https://github.com/apprenticeharper/DeDRM_tools
[updated fork]: https://github.com/noDRM/DeDRM_tools
[Epubor]: https://www.epubor.com/
[DRM]: https://en.wikipedia.org/wiki/Digital_rights_management?useskin=vector
