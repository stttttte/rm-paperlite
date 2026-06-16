package main

// EPUB 中文阅读字体切换器(自助):
// reMarkable 原生字体选择器是写死的固定列表(改不了),但所有 EPUB 中文都回退到
// /home/root/ttf-noto/NotoSerifSC-VariableFont_wght.ttf(noto 目录 bind-mount 自此)。
// 替换这个文件 = 全局换 EPUB 中文字体。本模块让用户在网页上选/传字体并应用。
//   - 内置候选:霞鹜文楷 / 朱雀仿宋 / 思源宋体(原版,备份) 等
//   - 上传自定义 TTF
//   - 应用 = 覆盖回退目标 + fc-cache + 重启 xochitl(屏幕刷新约10s)

import (
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

const (
	ttfNotoDir    = "/home/root/ttf-noto"
	cjkTarget     = "/home/root/ttf-noto/NotoSerifSC-VariableFont_wght.ttf"      // 字体源文件(写这里)
	cjkSysFile    = "/usr/share/fonts/ttf/noto/NotoSerifSC-VariableFont_wght.ttf" // 系统 CJK 回退文件(bind 目标)
	fontSrcDir    = "/home/root/paperlite/fontsrc"                              // 改名版候选(family 已统一为 Noto Serif SC)
	fontOrigBak   = "/home/root/paperlite/font-backup/NotoSerifSC-VariableFont_wght.ttf.orig"
	customFontTTF = "/home/root/paperlite/custom-cjk.ttf" // 用户上传的自定义字体存这
)

// 确保字体源文件已单文件 bind-mount 到系统 CJK 回退路径。
// 只挂这一个文件,不动同目录其它原版 Noto 字体(整目录挂载会遮住拉丁/等宽/emoji)。
// 开机由 xovi pre-start 钩子重挂;此处供 bookbridge 启动 + 网页换字体时自愈补挂。
func ensureFontMount() {
	if mounts, _ := os.ReadFile("/proc/mounts"); strings.Contains(string(mounts), cjkSysFile) {
		return // 已挂载
	}
	if _, err := os.Stat(cjkSysFile); err != nil {
		return // 系统目标文件不存在(固件改名?),不强挂
	}
	// 源不存在 → 从系统原版播种一份(全新设备/未播种时自愈,避免后续写入落空)
	if _, err := os.Stat(cjkTarget); err != nil {
		b, rerr := os.ReadFile(cjkSysFile)
		if rerr != nil {
			return
		}
		os.MkdirAll(ttfNotoDir, 0755)
		if werr := os.WriteFile(cjkTarget, b, 0644); werr != nil {
			log.Printf("字体源播种失败: %v", werr)
			return
		}
	}
	if err := exec.Command("mount", "--bind", cjkTarget, cjkSysFile).Run(); err != nil {
		log.Printf("字体 bind-mount 失败: %v", err)
	} else {
		log.Printf("字体已挂载: %s -> %s", cjkTarget, cjkSysFile)
	}
}

// 内置候选字体:显示名 -> 源 ttf 路径(均已把内部 family 改成 "Noto Serif SC",
// 这样覆盖回退目标后 EPUB 一定匹配到,且不与扫描目录里其它 family 冲突)
func builtinFonts() []struct{ Name, Path string } {
	list := []struct{ Name, Path string }{
		{"霞鹜文楷(楷体)", fontSrcDir + "/lxgw-as-noto.ttf"},
		{"霞鹜文楷 Screen", fontSrcDir + "/lxgwscreen-as-noto.ttf"},
		{"朱雀仿宋", fontSrcDir + "/zhuque-as-noto.ttf"},
		{"思源宋体(原版)", fontOrigBak},
	}
	var out []struct{ Name, Path string }
	for _, f := range list {
		if _, err := os.Stat(f.Path); err == nil {
			out = append(out, f)
		}
	}
	if _, err := os.Stat(customFontTTF); err == nil {
		out = append(out, struct{ Name, Path string }{"我上传的字体", customFontTTF})
	}
	return out
}

// 应用某字体为 EPUB 中文渲染字体:复制到回退目标 + 刷新缓存 + 重启 xochitl。
func applyCJKFont(srcPath string) error {
	data, err := os.ReadFile(srcPath)
	if err != nil {
		return fmt.Errorf("读取字体失败: %v", err)
	}
	if len(data) < 1000 {
		return fmt.Errorf("字体文件无效(过小)")
	}
	ensureFontMount() // 写入前先确保单文件 bind 已建立,否则写进的字节系统读不到
	// 原版备份(还原用)由 install.sh 从纯净系统字体播种到 fontOrigBak,此处不再处理
	if err := os.WriteFile(cjkTarget, data, 0644); err != nil {
		return fmt.Errorf("写入失败: %v", err)
	}
	exec.Command("fc-cache", "-f").Run()
	exec.Command("systemctl", "restart", "xochitl").Run()
	return nil
}

// GET /font  → 返回可选字体列表(纯文本,每行一个名称)
// POST /font (body=名称) → 应用内置字体
func handleFont(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodPost {
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1<<10))
		if err != nil {
			http.Error(w, "读取失败", 400)
			return
		}
		name := strings.TrimSpace(string(body))
		for _, f := range builtinFonts() {
			if f.Name == name {
				if err := applyCJKFont(f.Path); err != nil {
					http.Error(w, err.Error(), 500)
					return
				}
				w.WriteHeader(200)
				io.WriteString(w, "ok")
				return
			}
		}
		http.Error(w, "未知字体: "+name, 400)
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	names := []string{}
	for _, f := range builtinFonts() {
		names = append(names, f.Name) // 保持 builtinFonts() 的策划顺序,不重排
	}
	io.WriteString(w, strings.Join(names, "\n"))
}

// POST /fontupload (multipart field=font) → 上传自定义 TTF 并立即应用
func handleFontUpload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", 405)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 80<<20)
	f, hdr, err := r.FormFile("font")
	if err != nil {
		http.Error(w, "读取字体失败", 400)
		return
	}
	defer f.Close()
	ext := strings.ToLower(filepath.Ext(hdr.Filename))
	if ext != ".ttf" {
		http.Error(w, "只支持 TTF 字体(reMarkable 不认 OTF)", 400)
		return
	}
	data, err := io.ReadAll(f)
	if err != nil {
		http.Error(w, "读取中断", 500)
		return
	}
	// 把上传字体的 family 改名为 "Noto Serif SC"(EPUB 中文回退命中),失败则用原样
	if retagged, rerr := retagFontFamily(data); rerr == nil {
		data = retagged
	} else {
		log.Printf("字体改名失败,按原样使用(可能匹配不到): %v", rerr)
	}
	os.MkdirAll(filepath.Dir(customFontTTF), 0755)
	if err := os.WriteFile(customFontTTF, data, 0644); err != nil {
		http.Error(w, "保存失败: "+err.Error(), 500)
		return
	}
	if err := applyCJKFont(customFontTTF); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	w.WriteHeader(200)
	io.WriteString(w, "ok")
}
