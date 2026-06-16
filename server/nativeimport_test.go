package main

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"encoding/xml"
	"io"
	"strings"
	"testing"

	"golang.org/x/text/encoding/simplifiedchinese"
	"golang.org/x/text/transform"
)

func heads(chs []chapter) []string {
	var h []string
	for _, c := range chs {
		h = append(h, c.head)
	}
	return h
}

func xmlOK(b []byte) bool {
	dec := xml.NewDecoder(bytes.NewReader(b))
	for {
		_, err := dec.Token()
		if err == io.EOF {
			return true
		}
		if err != nil {
			return false
		}
	}
}

func TestDecodeGBKAndBOM(t *testing.T) {
	s := "测试中文 第一章 风起"
	gbk, _, err := transform.Bytes(simplifiedchinese.GB18030.NewEncoder(), []byte(s))
	if err != nil {
		t.Fatal(err)
	}
	if got := decodeText(gbk); got != s {
		t.Fatalf("GBK 解码不符: got %q want %q", got, s)
	}
	if got := decodeText([]byte("你好")); got != "你好" { // 带 BOM 的 UTF-8
		t.Fatalf("BOM 没去掉: %q", got)
	}
	if got := decodeText([]byte("纯utf8")); got != "纯utf8" {
		t.Fatalf("UTF-8 直通失败: %q", got)
	}
}

func TestSplitChapters(t *testing.T) {
	txt := "书名\n\n序章\n正文a\n\n第一章 风起\n正文b\n\n第二章 云涌\n正文c\n"
	chs := splitChapters(txt, "书名")
	if len(chs) != 4 {
		t.Fatalf("章节数应为4(书名前言+序章+两章),实得%d: %v", len(chs), heads(chs))
	}
	if chs[1].head != "序章" || chs[2].head != "第一章 风起" || chs[3].head != "第二章 云涌" {
		t.Fatalf("章节标题不对: %v", heads(chs))
	}
	// 误判防护:正文里以"第"开头的长句不应被当成章节
	if isChapterHeading("第一次见到她的时候，天还没亮，街上空无一人，他独自走着") {
		t.Fatal("把长正文误判成章节了")
	}
	if !isChapterHeading("第十章 大结局") {
		t.Fatal("漏判真章节")
	}
}

func TestBuildEPUBValid(t *testing.T) {
	chs := []chapter{{"序章", []string{"你好<世界>&测试"}}, {"第一章 风起", []string{"内容一", "内容二"}}}
	data, err := buildEPUB("测试书", "作者", chs)
	if err != nil {
		t.Fatal(err)
	}
	zr, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		t.Fatal(err)
	}
	if zr.File[0].Name != "mimetype" {
		t.Fatalf("mimetype 必须第一个,实为 %s", zr.File[0].Name)
	}
	if zr.File[0].Method != zip.Store {
		t.Fatal("mimetype 必须 STORED(不压缩)")
	}
	names := map[string]bool{}
	for _, f := range zr.File {
		names[f.Name] = true
		if strings.HasSuffix(f.Name, ".opf") || strings.HasSuffix(f.Name, ".ncx") ||
			strings.HasSuffix(f.Name, ".xhtml") || strings.HasSuffix(f.Name, ".xml") {
			rc, _ := f.Open()
			var buf bytes.Buffer
			buf.ReadFrom(rc)
			rc.Close()
			if !xmlOK(buf.Bytes()) {
				t.Fatalf("XML 不良构: %s", f.Name)
			}
		}
	}
	for _, must := range []string{"META-INF/container.xml", "OEBPS/content.opf", "OEBPS/toc.ncx", "OEBPS/chap0001.xhtml", "OEBPS/chap0002.xhtml"} {
		if !names[must] {
			t.Fatalf("缺文件: %s", must)
		}
	}
}

func TestMetadataContentJSON(t *testing.T) {
	if !json.Valid(metadataJSON("书名")) {
		t.Fatal("metadata 不是合法 JSON")
	}
	if !json.Valid(contentJSON("书名", "epub", 12345)) {
		t.Fatal("content 不是合法 JSON")
	}
	if !strings.Contains(string(contentJSON("书名", "pdf", 1)), `"fileType": "pdf"`) {
		t.Fatal("pdf fileType 没写对")
	}
}
