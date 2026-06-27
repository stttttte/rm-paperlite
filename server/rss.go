package main

// RSS 新闻:抓取用户配置的 RSS/Atom 源 → 每篇文章转干净文本 → 打包成一份
// "新闻 日期" EPUB → 导入原生书库(优先原生 /upload,失败回退)。
// 源配置在 /home/root/paperlite/feeds.txt:每行 "url" 或 "url | 名称 | 分类";# 开头为注释。

import (
	"encoding/json"
	"fmt"
	"html"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/mmcdole/gofeed"
)

// 找(或建)"新闻"文件夹(CollectionType),返回其 UUID。新闻都放进这个文件夹,不占书库主界面。
func newsFolderUUID() string {
	files, _ := filepath.Glob(filepath.Join(xochitlDir, "*.metadata"))
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		s := string(b)
		if strings.Contains(s, `"CollectionType"`) && strings.Contains(s, `"visibleName": "新闻"`) {
			return strings.TrimSuffix(filepath.Base(f), ".metadata")
		}
	}
	// 不存在 → 创建
	u := newUUID()
	ms := nowMs()
	meta := map[string]interface{}{
		"createdTime": ms, "lastModified": ms, "parent": "", "pinned": false,
		"type": "CollectionType", "visibleName": "新闻",
	}
	mb, _ := json.MarshalIndent(meta, "", "    ")
	os.WriteFile(filepath.Join(xochitlDir, u+".metadata"), mb, 0644)
	os.WriteFile(filepath.Join(xochitlDir, u+".content"), []byte("{}"), 0644)
	return u
}

// 把新闻 EPUB 写进"新闻"文件夹(sidecar 指定 parent + 刷新)。
func importNewsToFolder(epubBytes []byte, title string) error {
	folder := newsFolderUUID()
	u := newUUID()
	ms := nowMs()
	meta := map[string]interface{}{
		"createdTime": ms, "lastModified": ms, "lastOpened": "0", "lastOpenedPage": 0,
		"new": true, "parent": folder, "pinned": false, "source": "com.paperlite.news",
		"type": "DocumentType", "visibleName": title,
	}
	mb, _ := json.MarshalIndent(meta, "", "    ")
	if err := os.WriteFile(filepath.Join(xochitlDir, u+".epub"), epubBytes, 0644); err != nil {
		return err
	}
	os.WriteFile(filepath.Join(xochitlDir, u+".metadata"), mb, 0644)
	os.WriteFile(filepath.Join(xochitlDir, u+".content"), contentJSON(title, "epub", len(epubBytes)), 0644)
	scheduleReindex()
	return nil
}

const feedsPath = "/home/root/paperlite/feeds.txt"

type feedDef struct {
	url, name, category string
}

func loadFeeds() []feedDef {
	data, err := os.ReadFile(feedsPath)
	if err != nil {
		return nil
	}
	var out []feedDef
	for _, ln := range strings.Split(string(data), "\n") {
		ln = strings.TrimSpace(ln)
		if ln == "" || strings.HasPrefix(ln, "#") {
			continue
		}
		parts := strings.Split(ln, "|")
		f := feedDef{url: strings.TrimSpace(parts[0])}
		if len(parts) > 1 {
			f.name = strings.TrimSpace(parts[1])
		}
		if len(parts) > 2 {
			f.category = strings.TrimSpace(parts[2])
		}
		if f.url != "" {
			out = append(out, f)
		}
	}
	return out
}

func saveFeeds(text string) error {
	if err := os.MkdirAll("/home/root/paperlite", 0755); err != nil {
		return err
	}
	return os.WriteFile(feedsPath, []byte(text), 0644)
}

// ---------- HTML → 干净文本(保留段落)----------
var (
	reScript = regexp.MustCompile(`(?is)<script\b[^>]*>.*?</script>`)
	reStyle  = regexp.MustCompile(`(?is)<style\b[^>]*>.*?</style>`)
	reBlock  = regexp.MustCompile(`(?i)</(p|div|li|h[1-6]|tr|blockquote|section|article|header|footer)>|<br\s*/?>`)
	reTag    = regexp.MustCompile(`<[^>]+>`)
	reWS     = regexp.MustCompile(`[ \t\x{00a0}]+`)
	reNL     = regexp.MustCompile(`\n{3,}`)
)

func htmlToText(s string) string {
	s = reScript.ReplaceAllString(s, "")
	s = reStyle.ReplaceAllString(s, "")
	s = reBlock.ReplaceAllString(s, "\n")
	s = reTag.ReplaceAllString(s, "")
	s = html.UnescapeString(s)
	s = reWS.ReplaceAllString(s, " ")
	s = reNL.ReplaceAllString(s, "\n\n")
	return strings.TrimSpace(s)
}

// ---------- 抓取 + 打包 + 入库 ----------
const (
	maxPerFeed = 5 // 每源取最新 5 篇(篇数太多 xochitl 处理慢、打开前要等久)
	fetchConc  = 6 // 并发抓取上限
)

// auto=true 表示定时自动抓:只走原生即时通道,不回退重启(避免白屏)。
func fetchAndBuildNews(auto bool) (string, int, error) {
	feeds := loadFeeds()
	if len(feeds) == 0 {
		return "", 0, fmt.Errorf("还没配置 RSS 源(先在「新闻」区填几个地址)")
	}
	// 并发抓取,结果按 feeds 顺序回填
	parsed := make([]*gofeed.Feed, len(feeds))
	var wg sync.WaitGroup
	sem := make(chan struct{}, fetchConc)
	for i, fd := range feeds {
		wg.Add(1)
		go func(i int, url string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			fp := gofeed.NewParser()
			fp.Client = &http.Client{Timeout: 25 * time.Second}
			f, err := fp.ParseURL(url)
			if err != nil {
				log.Printf("RSS 抓取失败 %s: %v", url, err)
				return
			}
			parsed[i] = f
		}(i, fd.url)
	}
	wg.Wait()

	// 按分类聚合成报纸版面(科技版/财经版/体育版…)
	secMap := map[string]*newsSection{}
	var secOrder []string
	arts := 0
	for i, fd := range feeds {
		feed := parsed[i]
		if feed == nil {
			continue
		}
		cat := fd.category
		if cat == "" {
			cat = "综合"
		}
		sec, ok := secMap[cat]
		if !ok {
			sec = &newsSection{name: cat}
			secMap[cat] = sec
			secOrder = append(secOrder, cat)
		}
		name := fd.name
		if name == "" {
			name = feed.Title
		}
		for j, it := range feed.Items {
			if j >= maxPerFeed {
				break
			}
			content := it.Content
			if strings.TrimSpace(content) == "" {
				content = it.Description
			}
			body := htmlToText(content)
			var paras []string
			for _, ln := range strings.Split(body, "\n") {
				if strings.TrimSpace(ln) != "" {
					paras = append(paras, ln)
				}
			}
			head := it.Title
			if head == "" {
				head = name
			}
			sec.articles = append(sec.articles, newsArticle{
				title:     head,
				source:    name,
				published: it.Published,
				link:      it.Link,
				paras:     paras,
			})
			arts++
		}
	}
	if arts == 0 {
		return "", 0, fmt.Errorf("没抓到任何文章(检查 RSS 地址或设备联网)")
	}
	var sections []newsSection
	for _, c := range secOrder {
		sections = append(sections, *secMap[c])
	}
	// 报头:墨阅日报 + 日期 + 早/晚版
	now := time.Now()
	edition := "早间版"
	if now.Hour() >= 14 {
		edition = "晚间版"
	}
	dateStr := now.Format("2006年01月02日") + " · " + edition
	const paper = "墨阅日报"
	title := paper + " " + now.Format("2006-01-02 15:04") // 书库里的文件名(visibleName)
	epub, err := buildNewspaperEPUB(paper, dateStr, sections)
	if err != nil {
		return "", 0, err
	}
	// 入库:优先经原生 :80 即时入库(零重启,落书库根目录);不可达再回退写库+刷新。
	// (原生 /upload 忽略 parent,无法放进"新闻"文件夹——用户已选"零重启进根目录"。)
	_ = auto
	if err := importBytes(epub, title, "epub", title+".epub", true); err != nil {
		return "", 0, err
	}
	return title, arts, nil
}

// 复用:转发原生 /upload,失败回退写库+刷新(books 与 news 共用)。
func importBytes(bookBytes []byte, title, fileType, sendName string, allowFallback bool) error {
	if err := forwardToNative(bookBytes, sendName); err == nil {
		return nil
	} else if !allowFallback {
		return fmt.Errorf("原生上传通道不可达(无 USB?),已跳过: %v", err)
	} else {
		log.Printf("原生 /upload 不可用(%v),回退写库+刷新", err)
	}
	u := newUUID()
	ext := ".epub"
	if fileType == "pdf" {
		ext = ".pdf"
	}
	if err := os.WriteFile(filepath.Join(xochitlDir, u+ext), bookBytes, 0644); err != nil {
		return err
	}
	os.WriteFile(filepath.Join(xochitlDir, u+".metadata"), metadataJSON(title), 0644)
	os.WriteFile(filepath.Join(xochitlDir, u+".content"), contentJSON(title, fileType, len(bookBytes)), 0644)
	scheduleReindex()
	return nil
}

// ---------- HTTP 处理 ----------
func handleNews(w http.ResponseWriter, r *http.Request) {
	title, n, err := fetchAndBuildNews(false)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	log.Printf("已生成新闻: %s (%d 篇)", title, n)
	w.WriteHeader(200)
	fmt.Fprintf(w, "ok:%s（%d 篇）", title, n)
}

func handleFeeds(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodPost {
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1<<20))
		if err != nil {
			http.Error(w, "读取失败", 400)
			return
		}
		if err := saveFeeds(string(body)); err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		w.WriteHeader(200)
		io.WriteString(w, "ok")
		return
	}
	// GET: 返回当前 feeds.txt 原文
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	data, _ := os.ReadFile(feedsPath)
	w.Write(data)
}
