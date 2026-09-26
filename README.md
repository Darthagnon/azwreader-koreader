# AZW/AZW3 plugin for KOReader

[KOReader] is a fantastic ebook reader application that supports all formats of ebook on Amazon Kindles and similar ereader devices. 

Except for [Amazon's own AZW/AZW3 formats, which are unreadable](https://github.com/koreader/koreader/issues/5845). And [MOBI support is 2nd-class](https://github.com/koreader/koreader/issues/15478), but they do read.

This always seemed a little bit incongruous to me - install a program on your hacked Amazon Kindle to read "all" ebooks, and you can no longer read the device's native formats properly (unless you use the vanilla reader, which means dumping all your books in `/mnt/us/documents`, which makes KUAL or KOReader launch scriptlets difficult to find, making it difficult to read all your other books). 

So I apologise for getting AI to spawn this slop into the world, but at least now we will be able to read AZW/AZW3 ebooks in KOReader with working table of contents (TOC), images, hyperlinks. I asked my work's ChatGPT subscription to create a KOReader plugin that can read AZW/AZW3 ebooks, based off [Calibre 4] and [Readest], both of which can read AZW/AZW3 ebooks, and threw one of my owned AZW3 ebooks at it. Surprisingly, it worked.

## Usage
1. Download this repo
2. Copy `azwreader.koplugin` to `/mnt/us/KOReader/plugins/`
3. DeDRM your ebooks using something like [DeDRM_tools] ([updated fork]) or [Epubor] (what I used). **Note:** Downloaded Amazon books come with DRM to prevent unauthorised reading of books that you ~~bought~~ leased from them. Books downloaded more recently may also be in KFX format. eBooks with DRM and KFX **will not work**. 
4. Copy over your deDRMed ebooks and read them with KOReader, the way God intended.

Tested with my owned deDRMed AZW3 books from Amazon Classics on Kindle Basic 3.

## License

[Covfefe](SLOP.md) and AGPLv3

[KOReader]: https://github.com/koreader/koreader
[Calibre 4]: https://calibre-ebook.com/
[Readest]: https://github.com/readest/readest/
[DeDRM_tools]: https://github.com/apprenticeharper/DeDRM_tools
[updated fork]: https://github.com/noDRM/DeDRM_tools
[Epubor]: https://www.epubor.com/
[DRM]: https://en.wikipedia.org/wiki/Digital_rights_management?useskin=vector
