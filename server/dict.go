package main

// 无线推词典:网页上传 StarDict 词典包(.zip / .tar.gz)→ 解压进 KOReader 词典目录,
// 之后在 KOReader 里长按词即可查释义。词典目录运行时自动探测(AppLoad 版 KOReader)。
// StarDict 三件套:<名>.ifo / <名>.idx / <名>.dict 或 .dict.dz(KOReader 直接读 .dz,无需解 gzip)。

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const (
	dictMaxUpload  = 80 << 20  // 上传压缩包上限(真实 StarDict 词典 10~30MB,80MB 足够且不撑爆内存)
	dictMaxPerFile = 256 << 20 // 单个解压文件上限(防解压炸弹)
	dictMaxTotal   = 512 << 20 // 整包解压总量上限(防解压炸弹)
)

// 候选 KOReader 根目录(AppLoad 安装布局),返回其中 data/dict 路径。
func koreaderDictDir() (string, error) {
	if d := os.Getenv("BOOKBRIDGE_DICTDIR"); d != "" {
		if err := os.MkdirAll(d, 0755); err != nil {
			return "", err
		}
		return d, nil
	}
	roots := []string{
		"/home/root/xovi/exthome/appload/koreader",
		"/home/root/xovi/exthome/appload/koreader/koreader",
		"/home/root/.config/koreader",
	}
	for _, root := range roots {
		// 判定像 KOReader 根:有 reader.lua / settings.reader.lua / data 目录之一
		for _, marker := range []string{"reader.lua", "settings.reader.lua", "data"} {
			if _, err := os.Stat(filepath.Join(root, marker)); err == nil {
				d := filepath.Join(root, "data", "dict")
				if err := os.MkdirAll(d, 0755); err != nil {
					return "", err
				}
				return d, nil
			}
		}
	}
	return "", fmt.Errorf("没找到 KOReader 安装目录(确认 KOReader 已装)")
}

// 已安装词典列表(dict 目录下的子文件夹名)
func installedDicts(dictDir string) []string {
	entries, _ := os.ReadDir(dictDir)
	var out []string
	for _, e := range entries {
		if e.IsDir() {
			out = append(out, e.Name())
		}
	}
	sort.Strings(out)
	return out
}

// 是否词典相关文件(只解压这些,跳过 readme 等)
func isDictFile(name string) bool {
	low := strings.ToLower(name)
	for _, ext := range []string{".ifo", ".idx", ".dict", ".dz", ".syn"} {
		if strings.HasSuffix(low, ext) {
			return true
		}
	}
	return false
}

// 把归档里一个文件安全写入 dictDir(防 zip-slip + 防解压炸弹单文件上限)。
// 返回写入字节数;非词典文件返回 (0, nil) 被跳过。
func writeDictEntry(dictDir, name string, r io.Reader) (int64, error) {
	name = strings.ReplaceAll(name, "\\", "/")
	// 防穿越:清理后必须仍在 dictDir 内
	clean := filepath.Clean(filepath.Join(dictDir, name))
	base := filepath.Clean(dictDir)
	if clean != base && !strings.HasPrefix(clean, base+string(os.PathSeparator)) {
		return 0, fmt.Errorf("非法路径: %s", name)
	}
	if !isDictFile(name) {
		return 0, nil // 跳过非词典文件
	}
	if err := os.MkdirAll(filepath.Dir(clean), 0755); err != nil {
		return 0, err
	}
	f, err := os.Create(clean)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	// 防解压炸弹:多读 1 字节探测是否超单文件上限
	n, err := io.Copy(f, io.LimitReader(r, dictMaxPerFile+1))
	if err != nil {
		return n, err
	}
	if n > dictMaxPerFile {
		os.Remove(clean)
		return n, fmt.Errorf("词典文件过大(>%dMB): %s", dictMaxPerFile>>20, name)
	}
	return n, nil
}

// 解压 zip 到 dictDir(zip 需随机访问,故在内存中按 80MB 上限处理)
func extractZipDict(data []byte, dictDir string) (int, error) {
	zr, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return 0, err
	}
	n := 0
	var total int64
	for _, zf := range zr.File {
		if zf.FileInfo().IsDir() {
			continue
		}
		rc, err := zf.Open()
		if err != nil {
			return n, err
		}
		wn, werr := writeDictEntry(dictDir, zf.Name, rc)
		rc.Close()
		if werr != nil {
			return n, werr // 写失败即中止,由 handler 报 500(不静默成功)
		}
		total += wn
		if total > dictMaxTotal {
			return n, fmt.Errorf("解压总量超限(>%dMB),疑似异常词典包", dictMaxTotal>>20)
		}
		if strings.HasSuffix(strings.ToLower(zf.Name), ".ifo") {
			n++
		}
	}
	return n, nil
}

// 解压 tar.gz 到 dictDir(流式,不缓冲整包入内存)
func extractTarGzDict(r io.Reader, dictDir string) (int, error) {
	gz, err := gzip.NewReader(r)
	if err != nil {
		return 0, err
	}
	defer gz.Close()
	tr := tar.NewReader(gz)
	n := 0
	var total int64
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return n, err
		}
		if hdr.FileInfo().IsDir() {
			continue
		}
		wn, werr := writeDictEntry(dictDir, hdr.Name, tr)
		if werr != nil {
			return n, werr // 写失败即中止
		}
		total += wn
		if total > dictMaxTotal {
			return n, fmt.Errorf("解压总量超限(>%dMB),疑似异常词典包", dictMaxTotal>>20)
		}
		if strings.HasSuffix(strings.ToLower(hdr.Name), ".ifo") {
			n++
		}
	}
	return n, nil
}

// GET /dict        → 已安装词典列表(每行一个)
// POST /dict (multipart field=dict, .zip/.tar.gz/.tgz) → 解压安装
func handleDict(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodPost {
		dictDir, err := koreaderDictDir()
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, dictMaxUpload)
		f, hdr, err := r.FormFile("dict")
		if err != nil {
			http.Error(w, "读取文件失败(或超过 80MB 上限)", 400)
			return
		}
		defer f.Close()
		name := strings.ToLower(hdr.Filename)
		var dictCount int
		switch {
		case strings.HasSuffix(name, ".zip"):
			data, rerr := io.ReadAll(f)
			if rerr != nil {
				http.Error(w, "读取中断", 500)
				return
			}
			dictCount, err = extractZipDict(data, dictDir)
		case strings.HasSuffix(name, ".tar.gz"), strings.HasSuffix(name, ".tgz"):
			dictCount, err = extractTarGzDict(f, dictDir) // 流式,不缓冲
		default:
			http.Error(w, "只支持 .zip 或 .tar.gz 的 StarDict 词典包", 400)
			return
		}
		if err != nil {
			http.Error(w, "解压失败: "+err.Error(), 500)
			return
		}
		if dictCount == 0 {
			http.Error(w, "包里没找到 StarDict 词典(应含 .ifo/.idx/.dict 文件)", 400)
			return
		}
		w.WriteHeader(200)
		fmt.Fprintf(w, "ok:装了 %d 部词典", dictCount)
		return
	}
	// GET
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	dictDir, err := koreaderDictDir()
	if err != nil {
		io.WriteString(w, "")
		return
	}
	io.WriteString(w, strings.Join(installedDicts(dictDir), "\n"))
}
