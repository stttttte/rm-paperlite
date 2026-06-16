package main

// 定时自动抓新闻:默认每天 07:00 / 19:00 各一份。
// reMarkable 睡眠时进程暂停,故用轮询:"过了某个设定点、当天该点还没抓过 → 唤醒后补抓"。
// 自动抓只走原生即时通道(不重启/不白屏);通道不可达(无 USB)则跳过,下次轮询再试。

import (
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	schedulePath    = "/home/root/paperlite/schedule.txt"
	lastSlotPath    = "/home/root/paperlite/news_last.txt"
	defaultSchedule = "07:00,19:00"
)

func loadSchedule() []string {
	s := defaultSchedule
	if data, err := os.ReadFile(schedulePath); err == nil {
		s = strings.TrimSpace(string(data))
	}
	if s == "" || s == "off" || s == "关闭" {
		return nil
	}
	var out []string
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

func parseHM(s string) (int, int, bool) {
	parts := strings.Split(s, ":")
	if len(parts) != 2 {
		return 0, 0, false
	}
	h, e1 := strconv.Atoi(strings.TrimSpace(parts[0]))
	m, e2 := strconv.Atoi(strings.TrimSpace(parts[1]))
	if e1 != nil || e2 != nil || h < 0 || h > 23 || m < 0 || m > 59 {
		return 0, 0, false
	}
	return h, m, true
}

// 原生上传通道是否可达(自动抓只在可达时进行,避免回退重启白屏)
func nativeReachable() bool {
	c := &http.Client{Timeout: 3 * time.Second}
	resp, err := c.Get("http://10.11.99.1/")
	if err != nil {
		return false
	}
	resp.Body.Close()
	return true
}

var schedLastSlot string

func newsScheduler() {
	if data, err := os.ReadFile(lastSlotPath); err == nil {
		schedLastSlot = strings.TrimSpace(string(data))
	}
	time.Sleep(30 * time.Second) // 启动后稍等(让网络就绪)
	for {
		checkSchedule()
		time.Sleep(5 * time.Minute)
	}
}

func checkSchedule() {
	times := loadSchedule()
	if len(times) == 0 {
		return
	}
	now := time.Now()
	today := now.Format("2006-01-02")
	var best time.Time
	applicable := ""
	for _, ts := range times {
		h, m, ok := parseHM(ts)
		if !ok {
			continue
		}
		sched := time.Date(now.Year(), now.Month(), now.Day(), h, m, 0, 0, now.Location())
		if !now.Before(sched) && sched.After(best) { // 取 <= now 中最晚的一个
			best = sched
			applicable = today + " " + ts
		}
	}
	if applicable == "" || applicable == schedLastSlot {
		return
	}
	if nativeReachable() {
		log.Printf("定时抓取新闻(即时通道,无缝): %s", applicable)
	} else {
		log.Printf("定时抓取新闻(纯WiFi,将短暂刷新): %s", applicable)
	}
	title, n, err := fetchAndBuildNews(true)
	if err != nil {
		log.Printf("定时抓取失败: %v", err)
		return
	}
	log.Printf("定时新闻已生成: %s (%d 篇)", title, n)
	schedLastSlot = applicable
	os.WriteFile(lastSlotPath, []byte(applicable), 0644)
}

func handleSchedule(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodPost {
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1<<10))
		if err != nil {
			http.Error(w, "读取失败", 400)
			return
		}
		if err := os.WriteFile(schedulePath, []byte(strings.TrimSpace(string(body))), 0644); err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		w.WriteHeader(200)
		io.WriteString(w, "ok")
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	if data, err := os.ReadFile(schedulePath); err == nil {
		w.Write(data)
	} else {
		io.WriteString(w, defaultSchedule)
	}
}
