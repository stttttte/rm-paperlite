package main

// 把上传的书导入 reMarkable 原生书库(xochitl)。
// txt → 转 EPUB(编码识别+中文章节切分);epub/pdf → 直接入库。
// 生成 <uuid>.epub/.pdf + .metadata + .content 三件套,放进 xochitl 数据目录,
// 防抖重启 xochitl 刷新书库(其余 .epubindex/缩略图/页数由 xochitl 打开时生成)。

import (
	"archive/zip"
	"bytes"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"html"
	"log"
	"mime/multipart"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"golang.org/x/text/encoding/simplifiedchinese"
	"golang.org/x/text/transform"
)

// 转发给 reMarkable 自带的 USB 网页上传接口(10.11.99.1:80/upload):
// 即时入库、不重启 xochitl、不白屏,且由 xochitl 自己生成全部 sidecar。
// 仅在 USB 接口在线时可达;不可达则由 importBook 回退到写库+刷新。
func forwardToNative(data []byte, filename string) error {
	// 文件名带空格/冒号会让 xochitl 丢掉扩展名、误判成 PDF(无法打开)。
	// 清理:扩展名保留,主名里的空格/冒号换成 -。(书名实际取自 EPUB 内部 OPF 标题,不受影响)
	ext := filepath.Ext(filename)
	base := strings.TrimSuffix(filename, ext)
	base = strings.NewReplacer(" ", "-", ":", "-", "：", "-", "　", "-").Replace(base)
	if base == "" {
		base = "book"
	}
	filename = base + ext

	var buf bytes.Buffer
	w := multipart.NewWriter(&buf)
	fw, err := w.CreateFormFile("file", filename)
	if err != nil {
		return err
	}
	if _, err = fw.Write(data); err != nil {
		return err
	}
	w.Close()
	req, err := http.NewRequest("POST", "http://10.11.99.1/upload", &buf)
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", w.FormDataContentType())
	resp, err := (&http.Client{Timeout: 60 * time.Second}).Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 && resp.StatusCode != 201 {
		return fmt.Errorf("native upload status %d", resp.StatusCode)
	}
	return nil
}

const xochitlDir = "/home/root/.local/share/remarkable/xochitl"

func newUUID() string {
	b := make([]byte, 16)
	rand.Read(b)
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

func nowMs() string { return fmt.Sprintf("%d", time.Now().UnixMilli()) }

// ---------- 编码识别 ----------
func decodeText(raw []byte) string {
	if utf8.Valid(raw) {
		return strings.TrimPrefix(string(raw), "\ufeff")
	}
	if out, _, err := transform.Bytes(simplifiedchinese.GB18030.NewDecoder(), raw); err == nil {
		return string(out)
	}
	return string(raw)
}

// ---------- 章节切分 ----------
var chapterRe = regexp.MustCompile(`^\s*(第[0-9零一二三四五六七八九十百千两壹贰叁肆伍陆柒捌玖拾佰仟]+[章回卷节節部篇集話话幕折]|序章|序言|序幕|序|楔子|引子|前言|后记|後記|尾声|尾聲|终章|終章|番外|外传|外傳|大结局|大結局|结局|結局|Chapter\s+\d+|CHAPTER\s+\d+|Prologue|Epilogue)([\s　:：、.\-—].{0,40})?\s*$`)

func isChapterHeading(line string) bool {
	s := strings.TrimSpace(line)
	if s == "" || utf8.RuneCountInString(s) > 45 {
		return false
	}
	return chapterRe.MatchString(s)
}

type chapter struct {
	head  string
	lines []string
}

func anyNonEmpty(ls []string) bool {
	for _, l := range ls {
		if strings.TrimSpace(l) != "" {
			return true
		}
	}
	return false
}

func splitChapters(text, title string) []chapter {
	text = strings.ReplaceAll(strings.ReplaceAll(text, "\r\n", "\n"), "\r", "\n")
	lines := strings.Split(text, "\n")
	var chs []chapter
	curHead := ""
	headSet := false
	var curBody []string
	flush := func() {
		if headSet || anyNonEmpty(curBody) {
			h := curHead
			if !headSet {
				h = title
			}
			chs = append(chs, chapter{h, curBody})
		}
	}
	for _, ln := range lines {
		if isChapterHeading(ln) {
			flush()
			curHead = strings.TrimSpace(ln)
			headSet = true
			curBody = nil
		} else {
			curBody = append(curBody, ln)
		}
	}
	flush()
	// 无章节 → 按字数切块(每块约 12000 字),保证目录可用
	if len(chs) <= 1 {
		body := strings.Join(lines, "\n")
		runes := []rune(body)
		const size = 12000
		if len(runes) > size*3/2 {
			chs = nil
			for i := 0; i < len(runes); i += size {
				end := i + size
				if end > len(runes) {
					end = len(runes)
				}
				chs = append(chs, chapter{fmt.Sprintf("第%d部分", i/size+1), strings.Split(string(runes[i:end]), "\n")})
			}
		} else {
			chs = []chapter{{title, lines}}
		}
	}
	return chs
}

// ---------- EPUB 生成 ----------
const containerXML = `<?xml version="1.0" encoding="utf-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
`

const cssContent = `body { margin: 0 1em; line-height: 1.6; }
h2 { font-weight: bold; margin: 1.2em 0 0.8em; text-align: center; }
p { margin: 0; text-indent: 2em; }
`

func chapterXHTML(title string, lines []string) string {
	var b strings.Builder
	for _, ln := range lines {
		t := strings.TrimSpace(ln)
		if t != "" {
			b.WriteString("    <p>" + html.EscapeString(t) + "</p>\n")
		}
	}
	body := b.String()
	if body == "" {
		body = "    <p></p>\n"
	}
	return `<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="zh-CN">
<head>
  <meta charset="utf-8"/>
  <title>` + html.EscapeString(title) + `</title>
  <link rel="stylesheet" type="text/css" href="style.css"/>
</head>
<body>
  <h2>` + html.EscapeString(title) + `</h2>
` + body + `</body>
</html>
`
}

func buildOPF(title, author, bookID string, chapFiles []string) string {
	var man, spine strings.Builder
	man.WriteString(`    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>` + "\n")
	man.WriteString(`    <item id="css" href="style.css" media-type="text/css"/>` + "\n")
	for i, fn := range chapFiles {
		man.WriteString(fmt.Sprintf(`    <item id="chap%d" href="%s" media-type="application/xhtml+xml"/>`+"\n", i+1, fn))
		spine.WriteString(fmt.Sprintf(`    <itemref idref="chap%d"/>`+"\n", i+1))
	}
	return `<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:title>` + html.EscapeString(title) + `</dc:title>
    <dc:creator opf:role="aut">` + html.EscapeString(author) + `</dc:creator>
    <dc:language>zh-CN</dc:language>
    <dc:identifier id="bookid">urn:uuid:` + bookID + `</dc:identifier>
  </metadata>
  <manifest>
` + man.String() + `  </manifest>
  <spine toc="ncx">
` + spine.String() + `  </spine>
</package>
`
}

func buildNCX(title, bookID string, chs []chapter, chapFiles []string) string {
	var nav strings.Builder
	for i, ch := range chs {
		nav.WriteString(fmt.Sprintf(`    <navPoint id="np%d" playOrder="%d">
      <navLabel><text>%s</text></navLabel>
      <content src="%s"/>
    </navPoint>
`, i+1, i+1, html.EscapeString(ch.head), chapFiles[i]))
	}
	return `<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="urn:uuid:` + bookID + `"/>
    <meta name="dtb:depth" content="1"/>
  </head>
  <docTitle><text>` + html.EscapeString(title) + `</text></docTitle>
  <navMap>
` + nav.String() + `  </navMap>
</ncx>
`
}

func buildEPUB(title, author string, chs []chapter) ([]byte, error) {
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	// mimetype 必须第一个且 STORED(不压缩)
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
	chapFiles := make([]string, len(chs))
	for i := range chs {
		chapFiles[i] = fmt.Sprintf("chap%04d.xhtml", i+1)
	}
	if err = add("META-INF/container.xml", containerXML); err != nil {
		return nil, err
	}
	add("OEBPS/style.css", cssContent)
	add("OEBPS/content.opf", buildOPF(title, author, bookID, chapFiles))
	add("OEBPS/toc.ncx", buildNCX(title, bookID, chs, chapFiles))
	for i, ch := range chs {
		add("OEBPS/"+chapFiles[i], chapterXHTML(ch.head, ch.lines))
	}
	if err = zw.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// ---------- 元数据三件套 ----------
func metadataJSON(title string) []byte {
	ms := nowMs()
	m := map[string]interface{}{
		"createdTime": ms, "lastModified": ms, "lastOpened": "0", "lastOpenedPage": 0,
		"new": true, "parent": "", "pinned": false, "source": "com.paperlite.wifi",
		"type": "DocumentType", "visibleName": title,
	}
	b, _ := json.MarshalIndent(m, "", "    ")
	return b
}

func contentJSON(title, fileType string, size int) []byte {
	m := map[string]interface{}{
		"coverPageNumber":  0,
		"documentMetadata": map[string]interface{}{"authors": []string{"未知"}, "title": title},
		"extraMetadata":    map[string]interface{}{},
		"fileType":         fileType,
		"fontName":         "",
		"formatVersion":    1,
		"lineHeight":       -1,
		"margins":          125,
		"orientation":      "portrait",
		"pageCount":        0,
		"pageTags":         []interface{}{},
		"pages":            []interface{}{},
		"sizeInBytes":      fmt.Sprintf("%d", size),
		"tags":             []interface{}{},
		"textAlignment":    "justify",
		"textScale":        1,
		"zoomMode":         "bestFit",
	}
	b, _ := json.MarshalIndent(m, "", "    ")
	return b
}

// ---------- 防抖刷新 ----------
var (
	reindexMu    sync.Mutex
	reindexTimer *time.Timer
)

func scheduleReindex() {
	reindexMu.Lock()
	defer reindexMu.Unlock()
	if reindexTimer != nil {
		reindexTimer.Stop()
	}
	reindexTimer = time.AfterFunc(4*time.Second, func() {
		exec.Command("systemctl", "restart", "xochitl").Run()
	})
}

// ---------- 入口:导入一本书 ----------
// 返回书名;srcPath 是已落盘的上传文件,origName 用于取扩展名/书名。
func importBook(srcPath, origName string) (string, error) {
	ext := strings.ToLower(filepath.Ext(origName))
	title := strings.TrimSuffix(filepath.Base(origName), filepath.Ext(origName))
	var fileType, sendName string
	var bookBytes []byte
	var err error

	switch ext {
	case ".txt":
		raw, e := os.ReadFile(srcPath)
		if e != nil {
			return "", e
		}
		bookBytes, err = buildEPUB(title, "未知", splitChapters(decodeText(raw), title))
		if err != nil {
			return "", err
		}
		fileType, sendName = "epub", title+".epub"
	case ".epub":
		bookBytes, err = os.ReadFile(srcPath)
		fileType, sendName = "epub", filepath.Base(origName)
	case ".pdf":
		bookBytes, err = os.ReadFile(srcPath)
		fileType, sendName = "pdf", filepath.Base(origName)
	default:
		return "", fmt.Errorf("不支持的格式 %s", ext)
	}
	if err != nil {
		return "", err
	}

	// 优先:转发给 xochitl 原生 /upload → 即时入库、不重启、不白屏
	if ferr := forwardToNative(bookBytes, sendName); ferr == nil {
		return title, nil
	} else {
		log.Printf("原生 /upload 不可用(%v),回退写库+刷新", ferr)
	}

	// 回退(纯 WiFi 无 USB,10.11.99.1 不可达):直接写 sidecar + 防抖重启刷新
	u := newUUID()
	bookExt := ".epub"
	if fileType == "pdf" {
		bookExt = ".pdf"
	}
	if err = os.WriteFile(filepath.Join(xochitlDir, u+bookExt), bookBytes, 0644); err != nil {
		return "", err
	}
	os.WriteFile(filepath.Join(xochitlDir, u+".metadata"), metadataJSON(title), 0644)
	os.WriteFile(filepath.Join(xochitlDir, u+".content"), contentJSON(title, fileType, len(bookBytes)), 0644)
	scheduleReindex()
	return title, nil
}
