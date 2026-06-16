#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
txt2epub —— 把 .txt(中文小说为主)转成原生 reMarkable 可读的 EPUB2。
- 自动探测编码(chardet,回退 utf-8-sig / gb18030 / big5)
- 中文章节自动切分(第X章/第X回/卷/序章/楔子/番外/Chapter N…)
- 无章节时按字数切块,保证目录可用
- 纯标准库 + chardet,输出标准 EPUB2(mimetype 头存储不压缩)

用法:
  python3 txt2epub.py 输入.txt [-o 输出.epub] [--title 书名] [--author 作者]
  python3 txt2epub.py 某目录/            # 批量转目录下所有 .txt
"""
import argparse, os, re, sys, uuid, zipfile, html

# ---------- 编码探测 ----------
def read_text(path):
    raw = open(path, "rb").read()
    # 1) 试 BOM / chardet
    try:
        import chardet
        guess = chardet.detect(raw)
        enc = (guess.get("encoding") or "").lower()
        conf = guess.get("confidence") or 0
    except Exception:
        enc, conf = "", 0
    candidates = []
    if enc and conf >= 0.7:
        candidates.append(enc)
    candidates += ["utf-8-sig", "utf-8", "gb18030", "big5", "utf-16"]
    for c in candidates:
        try:
            return raw.decode(c)
        except Exception:
            continue
    return raw.decode("gb18030", errors="replace")  # 兜底,gb18030 几乎不报错

# ---------- 章节切分 ----------
CH_NUM = r"[0-9零一二三四五六七八九十百千两壹贰叁肆伍陆柒捌玖拾佰仟]+"
CHAPTER_RE = re.compile(
    r"^\s*(?:"
    r"第" + CH_NUM + r"[章回卷节節部篇集卷話话幕折]"          # 第X章/回/卷…
    r"|" + r"(?:序章|序言|序幕|序|楔子|引子|前言|后记|後記|尾声|尾聲|终章|終章|"
    r"番外|外传|外傳|大结局|大結局|结局|結局|完本感言|作品相关|后序)"
    r"|Chapter\s+\d+|CHAPTER\s+\d+|Prologue|Epilogue"
    r")"
    r"(?:[\s　::、.\-—].{0,40})?\s*$"
)

def is_chapter_heading(line):
    s = line.strip()
    if not s or len(s) > 45:
        return False
    return bool(CHAPTER_RE.match(s))

def split_chapters(text, title):
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    chapters = []           # [(heading, [lines])]
    cur_head, cur_body = None, []
    for ln in lines:
        if is_chapter_heading(ln):
            if cur_head is not None or any(x.strip() for x in cur_body):
                chapters.append((cur_head or title, cur_body))
            cur_head, cur_body = ln.strip(), []
        else:
            cur_body.append(ln)
    if cur_head is not None or any(x.strip() for x in cur_body):
        chapters.append((cur_head or title, cur_body))

    # 无章节 → 按字数切块(每块约 12000 字),保证目录可用
    if len(chapters) <= 1:
        body = "\n".join(lines)
        size = 12000
        if len(body) > size * 1.5:
            chapters = []
            for i in range(0, len(body), size):
                chunk = body[i:i+size]
                chapters.append(("第%d部分" % (i // size + 1), chunk.split("\n")))
        else:
            chapters = [(title, lines)]
    return chapters

# ---------- XHTML 生成 ----------
def body_to_xhtml(title, lines):
    paras = []
    for ln in lines:
        t = ln.strip()
        if t:
            paras.append("    <p>%s</p>" % html.escape(t))
    body = "\n".join(paras) if paras else "    <p></p>"
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<!DOCTYPE html>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="zh-CN">\n'
        '<head>\n'
        '  <meta charset="utf-8"/>\n'
        '  <title>%s</title>\n'
        '  <link rel="stylesheet" type="text/css" href="style.css"/>\n'
        '</head>\n'
        '<body>\n'
        '  <h2>%s</h2>\n'
        '%s\n'
        '</body>\n'
        '</html>\n'
    ) % (html.escape(title), html.escape(title), body)

CSS = """body { margin: 0 1em; line-height: 1.6; }
h2 { font-weight: bold; margin: 1.2em 0 0.8em; text-align: center; }
p { margin: 0; text-indent: 2em; }
"""

CONTAINER = """<?xml version="1.0" encoding="utf-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
"""

def build_opf(title, author, book_id, chap_files):
    manifest, spine = [], []
    manifest.append('    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>')
    manifest.append('    <item id="css" href="style.css" media-type="text/css"/>')
    for i, fn in enumerate(chap_files, 1):
        manifest.append('    <item id="chap%d" href="%s" media-type="application/xhtml+xml"/>' % (i, fn))
        spine.append('    <itemref idref="chap%d"/>' % i)
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="bookid">\n'
        '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:opf="http://www.idpf.org/2007/opf">\n'
        '    <dc:title>%s</dc:title>\n'
        '    <dc:creator opf:role="aut">%s</dc:creator>\n'
        '    <dc:language>zh-CN</dc:language>\n'
        '    <dc:identifier id="bookid">urn:uuid:%s</dc:identifier>\n'
        '  </metadata>\n'
        '  <manifest>\n%s\n  </manifest>\n'
        '  <spine toc="ncx">\n%s\n  </spine>\n'
        '</package>\n'
    ) % (html.escape(title), html.escape(author), book_id,
         "\n".join(manifest), "\n".join(spine))

def build_ncx(title, book_id, chapters, chap_files):
    pts = []
    for i, ((head, _), fn) in enumerate(zip(chapters, chap_files), 1):
        pts.append(
            '    <navPoint id="np%d" playOrder="%d">\n'
            '      <navLabel><text>%s</text></navLabel>\n'
            '      <content src="%s"/>\n'
            '    </navPoint>' % (i, i, html.escape(head), fn))
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">\n'
        '  <head>\n'
        '    <meta name="dtb:uid" content="urn:uuid:%s"/>\n'
        '    <meta name="dtb:depth" content="1"/>\n'
        '  </head>\n'
        '  <docTitle><text>%s</text></docTitle>\n'
        '  <navMap>\n%s\n  </navMap>\n'
        '</ncx>\n'
    ) % (book_id, html.escape(title), "\n".join(pts))

# ---------- 打包 ----------
def write_epub(out_path, title, author, chapters):
    book_id = str(uuid.uuid4())
    chap_files = ["chap%04d.xhtml" % i for i in range(1, len(chapters) + 1)]
    with zipfile.ZipFile(out_path, "w") as z:
        # mimetype 必须第一个且存储(不压缩)
        zi = zipfile.ZipInfo("mimetype")
        zi.compress_type = zipfile.ZIP_STORED
        z.writestr(zi, "application/epub+zip")
        z.writestr("META-INF/container.xml", CONTAINER, zipfile.ZIP_DEFLATED)
        z.writestr("OEBPS/style.css", CSS, zipfile.ZIP_DEFLATED)
        z.writestr("OEBPS/content.opf", build_opf(title, author, book_id, chap_files), zipfile.ZIP_DEFLATED)
        z.writestr("OEBPS/toc.ncx", build_ncx(title, book_id, chapters, chap_files), zipfile.ZIP_DEFLATED)
        for (head, lines), fn in zip(chapters, chap_files):
            z.writestr("OEBPS/" + fn, body_to_xhtml(head, lines), zipfile.ZIP_DEFLATED)
    return book_id, len(chapters)

def convert(in_path, out_path=None, title=None, author="未知"):
    title = title or os.path.splitext(os.path.basename(in_path))[0]
    out_path = out_path or os.path.splitext(in_path)[0] + ".epub"
    text = read_text(in_path)
    chapters = split_chapters(text, title)
    book_id, n = write_epub(out_path, title, author, chapters)
    print("✓ %s  →  %s  (%d 章/块, %d 字)" % (
        os.path.basename(in_path), os.path.basename(out_path), n, len(text)))
    return out_path

def main():
    ap = argparse.ArgumentParser(description="TXT → EPUB(原生 reMarkable 可读)")
    ap.add_argument("input", help=".txt 文件或包含 txt 的目录")
    ap.add_argument("-o", "--output", help="输出 .epub(单文件时有效)")
    ap.add_argument("--title", help="书名(默认取文件名)")
    ap.add_argument("--author", default="未知", help="作者")
    a = ap.parse_args()
    if os.path.isdir(a.input):
        txts = [os.path.join(a.input, f) for f in sorted(os.listdir(a.input))
                if f.lower().endswith(".txt")]
        if not txts:
            print("目录下没有 .txt"); sys.exit(1)
        for t in txts:
            convert(t, author=a.author)
    else:
        convert(a.input, a.output, a.title, a.author)

if __name__ == "__main__":
    main()
