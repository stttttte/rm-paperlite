package main

// 报纸版式新闻 EPUB:报头(报名+日期)→ 栏目分版 → 文章标题层次 + 衬线 + 分隔线。
// 单栏可调字号(reMarkable EPUB 渲染稳定),视觉像报纸。不影响通用 buildEPUB(books 用)。

import (
	"archive/zip"
	"bytes"
	"fmt"
	"html"
	"strings"
)

type newsArticle struct {
	title, source, published, link string
	paras                          []string
}

type newsSection struct {
	name     string
	articles []newsArticle
}

// 报纸 CSS(只用 reMarkable EPUB 渲染器支持的基本 CSS:字号/粗细/对齐/边框/缩进)
const newspaperCSS = `body { margin: 0 1.1em; line-height: 1.7; }
.masthead { text-align: center; border-top: 5px solid #000; border-bottom: 2px solid #000; padding: 0.5em 0 0.4em; margin: 0 0 1.2em; }
.masthead .name { font-size: 2.6em; font-weight: bold; letter-spacing: 0.35em; }
.masthead .date { font-size: 0.85em; margin-top: 0.4em; }
.section { font-size: 1.45em; font-weight: bold; border-left: 10px solid #000; padding-left: 0.5em; margin: 1.4em 0 0.7em; }
.headline { font-size: 1.3em; font-weight: bold; line-height: 1.45; margin: 0.9em 0 0.25em; }
.meta { font-size: 0.8em; color: #666; margin: 0 0 0.5em; }
.body p { margin: 0 0 0.35em; text-indent: 2em; text-align: justify; }
.sep { border: 0; border-top: 1px solid #bbb; margin: 1.1em 0; }
.link { font-size: 0.78em; color: #999; margin: 0.3em 0 0; word-break: break-all; }
`

func esc(s string) string { return html.EscapeString(s) }

// 渲染一个版面(栏目)。首版顶部加报头。
func newspaperPageXHTML(sec newsSection, paper, dateStr string, isFirst bool) string {
	var b strings.Builder
	if isFirst {
		b.WriteString(`  <div class="masthead"><div class="name">` + esc(paper) +
			`</div><div class="date">` + esc(dateStr) + `</div></div>` + "\n")
	}
	b.WriteString(`  <div class="section">` + esc(sec.name) + `</div>` + "\n")
	for ai, art := range sec.articles {
		if ai > 0 {
			b.WriteString(`  <hr class="sep"/>` + "\n")
		}
		b.WriteString(`  <div class="headline">` + esc(art.title) + `</div>` + "\n")
		meta := art.source
		if art.published != "" {
			meta += " · " + art.published
		}
		if meta != "" {
			b.WriteString(`  <div class="meta">` + esc(meta) + `</div>` + "\n")
		}
		b.WriteString(`  <div class="body">` + "\n")
		hasP := false
		for _, p := range art.paras {
			pp := strings.TrimSpace(p)
			if pp != "" {
				b.WriteString(`    <p>` + esc(pp) + `</p>` + "\n")
				hasP = true
			}
		}
		if !hasP {
			b.WriteString(`    <p></p>` + "\n")
		}
		b.WriteString(`  </div>` + "\n")
		if art.link != "" {
			b.WriteString(`  <div class="link">原文 ` + esc(art.link) + `</div>` + "\n")
		}
	}
	title := sec.name
	return `<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="zh-CN">
<head>
  <meta charset="utf-8"/>
  <title>` + esc(title) + `</title>
  <link rel="stylesheet" type="text/css" href="style.css"/>
</head>
<body>
` + b.String() + `</body>
</html>
`
}

// 生成报纸版 EPUB:每栏目一版面章,首版含报头。
func buildNewspaperEPUB(paper, dateStr string, sections []newsSection) ([]byte, error) {
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	mw, err := zw.CreateHeader(&zip.FileHeader{Name: "mimetype", Method: zip.Store})
	if err != nil {
		return nil, err
	}
	mw.Write([]byte("application/epub+zip"))
	add := func(name, content string) error {
		fw, e := zw.CreateHeader(&zip.FileHeader{Name: name, Method: zip.Deflate})
		if e != nil {
			return e
		}
		_, e = fw.Write([]byte(content))
		return e
	}
	bookID := newUUID()
	chapFiles := make([]string, len(sections))
	chs := make([]chapter, len(sections)) // 仅供 OPF/NCX 用版面名做目录
	for i, s := range sections {
		chapFiles[i] = fmt.Sprintf("page%02d.xhtml", i+1)
		chs[i] = chapter{head: s.name}
	}
	if err = add("META-INF/container.xml", containerXML); err != nil {
		return nil, err
	}
	add("OEBPS/style.css", newspaperCSS)
	add("OEBPS/content.opf", buildOPF(paper+" "+dateStr, "墨阅日报", bookID, chapFiles))
	add("OEBPS/toc.ncx", buildNCX(paper+" "+dateStr, bookID, chs, chapFiles))
	for i, sec := range sections {
		add("OEBPS/"+chapFiles[i], newspaperPageXHTML(sec, paper, dateStr, i == 0))
	}
	if err = zw.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
