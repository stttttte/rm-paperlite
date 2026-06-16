package main

// 自定义休眠屏:用户上传图片 → 等比填充裁切到 1404×1872 → 灰阶 → PNG
// → 写入 /home/root/paperlite/suspended.png(bind-mount 到系统 suspended.png)。
// 不占根分区(图在 /home),开机由 ensureSleepMount 重挂,可 umount 还原。

import (
	"bytes"
	"fmt"
	"image"
	"image/png"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"strings"

	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"

	xdraw "golang.org/x/image/draw"
)

const (
	rmW         = 1404
	rmH         = 1872
	sleepPath   = "/home/root/paperlite/suspended.png"
	sysSuspend  = "/usr/share/remarkable/suspended.png"
)

// 把任意图片转成 1404×1872 灰阶 PNG(cover:等比放大填满,居中裁切),写入 sleepPath。
func setSleepScreen(data []byte) error {
	// 先只读图片头校验尺寸,挡住超大图(避免巨幅图解码占爆内存);图库/上传两条路都经此
	if cfg, _, derr := image.DecodeConfig(bytes.NewReader(data)); derr == nil {
		if cfg.Width > 20000 || cfg.Height > 20000 {
			return fmt.Errorf("图片尺寸过大(%dx%d)", cfg.Width, cfg.Height)
		}
	}
	src, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return fmt.Errorf("无法识别图片: %v", err)
	}
	sb := src.Bounds()
	sw, sh := sb.Dx(), sb.Dy()
	if sw == 0 || sh == 0 {
		return fmt.Errorf("图片尺寸为 0")
	}
	// 计算居中裁切区域,使其宽高比 = 屏幕(cover)
	srcAspect := float64(sw) / float64(sh)
	dstAspect := float64(rmW) / float64(rmH)
	var cw, ch, ox, oy int
	if srcAspect > dstAspect {
		ch = sh
		cw = int(float64(sh) * dstAspect)
		ox = (sw - cw) / 2
	} else {
		cw = sw
		ch = int(float64(sw) / dstAspect)
		oy = (sh - ch) / 2
	}
	cropRect := image.Rect(sb.Min.X+ox, sb.Min.Y+oy, sb.Min.X+ox+cw, sb.Min.Y+oy+ch)

	// 直接缩放裁切区到灰阶目标图(dst 是 Gray → 输出即灰阶)
	dst := image.NewGray(image.Rect(0, 0, rmW, rmH))
	xdraw.CatmullRom.Scale(dst, dst.Bounds(), src, cropRect, xdraw.Over, nil)

	var buf bytes.Buffer
	enc := png.Encoder{CompressionLevel: png.BestCompression}
	if err := enc.Encode(&buf, dst); err != nil {
		return err
	}
	if err := os.MkdirAll("/home/root/paperlite", 0755); err != nil {
		return err
	}
	// 就地覆写(保持同 inode,bind-mount 视图即时更新)
	if err := os.WriteFile(sleepPath, buf.Bytes(), 0644); err != nil {
		return err
	}
	ensureSleepMount()
	return nil
}

// 确保 sleepPath 已 bind-mount 到系统 suspended.png(开机调一次;首次设置后调一次)。
func ensureSleepMount() {
	if _, err := os.Stat(sleepPath); err != nil {
		return // 还没有自定义休眠图
	}
	if mounts, _ := os.ReadFile("/proc/mounts"); strings.Contains(string(mounts), sysSuspend) {
		return // 已挂载
	}
	if err := exec.Command("mount", "--bind", sleepPath, sysSuspend).Run(); err != nil {
		log.Printf("休眠图 bind-mount 失败: %v", err)
	} else {
		log.Printf("休眠图已挂载: %s -> %s", sleepPath, sysSuspend)
	}
}

func handleSleepScreen(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", 405)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 60<<20)
	f, _, err := r.FormFile("image")
	if err != nil {
		http.Error(w, "读取图片失败", 400)
		return
	}
	defer f.Close()
	data, err := io.ReadAll(f)
	if err != nil {
		http.Error(w, "读取中断", 500)
		return
	}
	if err := setSleepScreen(data); err != nil {
		http.Error(w, "设置失败: "+err.Error(), 500)
		return
	}
	log.Printf("休眠屏已更新 (%.1f MB 源图)", float64(len(data))/1024/1024)
	w.WriteHeader(200)
	io.WriteString(w, "ok")
}
