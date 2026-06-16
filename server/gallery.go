package main

// 内置休眠屏图库:预置几张极简墨水屏壁纸,网页点一下即设为休眠屏(复用 setSleepScreen 管线)。
// 图片放 /home/root/paperlite/screensavers/*.png(随 install.sh 一并下发)。

import (
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

var galleryDir = func() string {
	if d := os.Getenv("BOOKBRIDGE_GALLERY"); d != "" {
		return d
	}
	return "/home/root/paperlite/screensavers"
}()

// 列出图库里的图片文件名(不含扩展名作显示名)
func galleryItems() []string {
	entries, _ := os.ReadDir(galleryDir)
	var names []string
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		ext := strings.ToLower(filepath.Ext(e.Name()))
		if ext == ".png" || ext == ".jpg" || ext == ".jpeg" {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	return names
}

// 安全地把请求的文件名解析为图库内的真实路径(防目录穿越)
func galleryPath(name string) (string, bool) {
	clean := filepath.Base(name) // 去掉任何路径成分
	if clean == "" || clean == "." || clean == ".." {
		return "", false
	}
	full := filepath.Join(galleryDir, clean)
	if _, err := os.Stat(full); err != nil {
		return "", false
	}
	return full, true
}

// GET /gallery        → 每行一个图片文件名
// POST /gallery (body=文件名) → 把该内置图设为休眠屏
func handleGallery(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodPost {
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1<<10))
		if err != nil {
			http.Error(w, "读取失败", 400)
			return
		}
		name := strings.TrimSpace(string(body))
		path, ok := galleryPath(name)
		if !ok {
			http.Error(w, "未知图片: "+name, 400)
			return
		}
		data, err := os.ReadFile(path)
		if err != nil {
			http.Error(w, "读取图片失败", 500)
			return
		}
		if err := setSleepScreen(data); err != nil {
			http.Error(w, "设置失败: "+err.Error(), 500)
			return
		}
		w.WriteHeader(200)
		io.WriteString(w, "ok")
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	io.WriteString(w, strings.Join(galleryItems(), "\n"))
}

// GET /galleryimg?name=X → 返回该内置图(供网页显示缩略图)
func handleGalleryImg(w http.ResponseWriter, r *http.Request) {
	name := r.URL.Query().Get("name")
	path, ok := galleryPath(name)
	if !ok {
		http.NotFound(w, r)
		return
	}
	data, err := os.ReadFile(path)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	ct := "image/png"
	if e := strings.ToLower(filepath.Ext(path)); e == ".jpg" || e == ".jpeg" {
		ct = "image/jpeg"
	}
	w.Header().Set("Content-Type", ct)
	w.Header().Set("Cache-Control", "max-age=86400")
	w.Write(data)
}
