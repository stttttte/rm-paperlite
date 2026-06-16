package main

// 把 screensavers 里的 PNG 拼成一张预览联系表(box 降采样,纯标准库)。
// 运行: go run . <图目录> <输出png>

import (
	"fmt"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

func loadPNG(p string) (*image.Gray, error) {
	f, err := os.Open(p)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	src, err := png.Decode(f)
	if err != nil {
		return nil, err
	}
	b := src.Bounds()
	g := image.NewGray(b)
	for y := b.Min.Y; y < b.Max.Y; y++ {
		for x := b.Min.X; x < b.Max.X; x++ {
			g.Set(x, y, src.At(x, y))
		}
	}
	return g, nil
}

// box 降采样到 dw x dh
func downscale(src *image.Gray, dw, dh int) *image.Gray {
	sb := src.Bounds()
	sw, sh := sb.Dx(), sb.Dy()
	dst := image.NewGray(image.Rect(0, 0, dw, dh))
	for dy := 0; dy < dh; dy++ {
		for dx := 0; dx < dw; dx++ {
			x0 := dx * sw / dw
			x1 := (dx + 1) * sw / dw
			y0 := dy * sh / dh
			y1 := (dy + 1) * sh / dh
			if x1 <= x0 {
				x1 = x0 + 1
			}
			if y1 <= y0 {
				y1 = y0 + 1
			}
			var sum, n int
			for y := y0; y < y1; y++ {
				for x := x0; x < x1; x++ {
					sum += int(src.GrayAt(sb.Min.X+x, sb.Min.Y+y).Y)
					n++
				}
			}
			dst.SetGray(dx, dy, color.Gray{Y: uint8(sum / n)})
		}
	}
	return dst
}

func main() {
	dir, outp := os.Args[1], os.Args[2]
	entries, _ := os.ReadDir(dir)
	var names []string
	for _, e := range entries {
		if strings.HasSuffix(strings.ToLower(e.Name()), ".png") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)

	const cols, tw, th, pad = 3, 240, 320, 24
	rows := (len(names) + cols - 1) / cols
	cw := cols*tw + (cols+1)*pad
	ch := rows*th + (rows+1)*pad
	canvas := image.NewGray(image.Rect(0, 0, cw, ch))
	for i := range canvas.Pix {
		canvas.Pix[i] = 235 // 浅灰底,衬出白图
	}
	for i, n := range names {
		g, err := loadPNG(filepath.Join(dir, n))
		if err != nil {
			continue
		}
		thumb := downscale(g, tw, th)
		c, r := i%cols, i/cols
		ox := pad + c*(tw+pad)
		oy := pad + r*(th+pad)
		for y := 0; y < th; y++ {
			for x := 0; x < tw; x++ {
				canvas.SetGray(ox+x, oy+y, thumb.GrayAt(x, y))
			}
		}
	}
	f, err := os.Create(outp)
	if err != nil {
		panic(err)
	}
	defer f.Close()
	if err := png.Encode(f, canvas); err != nil {
		panic(err)
	}
	fmt.Println("✓", outp, fmt.Sprintf("(%dx%d, %d 张)", cw, ch, len(names)))
}
