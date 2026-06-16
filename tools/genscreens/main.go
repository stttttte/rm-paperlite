package main

// 生成内置休眠屏图库:纯 Go 标准库,无字体依赖,极简墨水屏风格。
// 输出 1404x1872 灰阶 PNG 到 device/payload/paperlite/screensavers/。
// 运行: go run ./tools/genscreens

import (
	"fmt"
	"image"
	"image/color"
	"image/png"
	"math"
	"os"
	"path/filepath"
)

const (
	W = 1404
	H = 1872
)

// 输出目录:默认仓库内 payload 路径,可用 os.Args[1] 覆盖
var out = "/Users/liusidi/Desktop/rm-paperlite/device/payload/paperlite/screensavers"

func newCanvas(bg uint8) *image.Gray {
	img := image.NewGray(image.Rect(0, 0, W, H))
	for i := range img.Pix {
		img.Pix[i] = bg
	}
	return img
}

func set(img *image.Gray, x, y int, v uint8) {
	if x >= 0 && x < W && y >= 0 && y < H {
		img.SetGray(x, y, color.Gray{Y: v})
	}
}

// 实心圆点
func dot(img *image.Gray, cx, cy, r int, v uint8) {
	for y := -r; y <= r; y++ {
		for x := -r; x <= r; x++ {
			if x*x+y*y <= r*r {
				set(img, cx+x, cy+y, v)
			}
		}
	}
}

// 圆环(描边)
func ring(img *image.Gray, cx, cy, r, thick int, v uint8) {
	for a := 0.0; a < 2*math.Pi; a += 0.0008 {
		for t := 0; t < thick; t++ {
			rr := float64(r + t)
			set(img, cx+int(rr*math.Cos(a)), cy+int(rr*math.Sin(a)), v)
		}
	}
}

func hline(img *image.Gray, y, x0, x1 int, thick int, v uint8) {
	for t := 0; t < thick; t++ {
		for x := x0; x <= x1; x++ {
			set(img, x, y+t, v)
		}
	}
}

func vline(img *image.Gray, x, y0, y1 int, thick int, v uint8) {
	for t := 0; t < thick; t++ {
		for y := y0; y <= y1; y++ {
			set(img, x+t, y, v)
		}
	}
}

func save(img *image.Gray, name string) error {
	f, err := os.Create(filepath.Join(out, name))
	if err != nil {
		return err
	}
	defer f.Close()
	enc := png.Encoder{CompressionLevel: png.BestCompression}
	return enc.Encode(f, img)
}

func main() {
	if len(os.Args) > 1 {
		out = os.Args[1]
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		panic(err)
	}

	// 1) 点阵网格(reMarkable 招牌)
	g1 := newCanvas(255)
	for y := 96; y < H-48; y += 48 {
		for x := 96; x < W-48; x += 48 {
			dot(g1, x, y, 3, 200)
		}
	}

	// 2) 横线笔记纸
	g2 := newCanvas(255)
	for y := 240; y < H-160; y += 72 {
		hline(g2, y, 120, W-120, 1, 198)
	}
	hline(g2, 160, 120, 360, 4, 120) // 顶部一道粗短线点缀

	// 3) 单个大圆环居中(留白禅意)
	g3 := newCanvas(255)
	ring(g3, W/2, H/2, 360, 3, 110)

	// 4) 同心圆
	g4 := newCanvas(255)
	for _, r := range []int{160, 320, 480, 640} {
		ring(g4, W/2, H/2, r, 2, 165)
	}
	dot(g4, W/2, H/2, 6, 110)

	// 5) 斜向细网纹
	g5 := newCanvas(255)
	for s := -H; s < W+H; s += 44 {
		for y := 0; y < H; y++ {
			set(g5, s+y, y, 222) // 斜线 x = s + y
		}
	}

	// 6) 内嵌细边框 + 四角标记
	g6 := newCanvas(255)
	m := 90
	hline(g6, m, m, W-m, 2, 130)
	hline(g6, H-m, m, W-m, 2, 130)
	vline(g6, m, m, H-m, 2, 130)
	vline(g6, W-m, m, H-m, 2, 130)
	// 四角加粗
	for _, c := range [][2]int{{m, m}, {W - m, m}, {m, H - m}, {W - m, H - m}} {
		hline(g6, c[1], c[0]-40, c[0]+40, 5, 60)
		vline(g6, c[0], c[1]-40, c[1]+40, 5, 60)
	}

	imgs := []struct {
		img  *image.Gray
		name string
	}{
		{g1, "01-点阵.png"},
		{g2, "02-横线.png"},
		{g3, "03-圆环.png"},
		{g4, "04-同心圆.png"},
		{g5, "05-斜纹.png"},
		{g6, "06-边框.png"},
	}
	for _, it := range imgs {
		if err := save(it.img, it.name); err != nil {
			panic(err)
		}
		fmt.Println("✓", it.name)
	}
	fmt.Println("done →", out)
}
