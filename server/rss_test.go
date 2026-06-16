package main

import (
	"strings"
	"testing"
)

func TestHtmlToText(t *testing.T) {
	in := `<div class="a"><script>bad()</script><style>x{}</style>` +
		`<p>第一段 &amp; 测试 &lt;ok&gt;</p><p>第二段<br>换行</p>` +
		`<a href="http://x">链接</a><img src="http://y/a.png"></div>`
	out := htmlToText(in)
	if strings.Contains(out, "bad()") || strings.Contains(out, "x{}") {
		t.Fatalf("script/style 没去掉: %q", out)
	}
	if !strings.Contains(out, "第一段 & 测试 <ok>") {
		t.Fatalf("实体没解码: %q", out)
	}
	if !strings.Contains(out, "第二段") || !strings.Contains(out, "换行") {
		t.Fatalf("缺正文: %q", out)
	}
	if strings.ContainsAny(out, "<>") && !strings.Contains(out, "<ok>") {
		t.Fatalf("标签没清干净: %q", out)
	}
	if !strings.Contains(out, "链接") {
		t.Fatalf("链接文字丢了: %q", out)
	}
}
