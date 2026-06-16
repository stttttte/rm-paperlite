// 墨阅 · 传书服务 (bookbridge)
// 跑在 reMarkable 上的局域网传书服务器：
//   - http://<设备IP>:8866 提供手机友好的上传页（微信扫码可直接打开）
//   - 上传的 epub/txt/pdf/mobi 等落到 /home/root/books（KOReader 书库）
//   - 启动及 IP 变化时，把含上传地址的二维码渲染成 PNG 放进书库，
//     在 KOReader 里打开这张图即可用微信扫码传书
package main

import (
	"fmt"
	"html"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	qrcode "github.com/skip2/go-qrcode"
)

const (
	port   = 8866
	qrName = "0-传书二维码-扫我传书.png"
)

var booksDir = func() string {
	if d := os.Getenv("BOOKBRIDGE_DIR"); d != "" {
		return d
	}
	return "/home/root/books"
}()

// 与设备上 KOReader v2026.03 documentregistry 注册的格式对齐
var allowedExt = map[string]bool{
	".epub": true, ".epub3": true, ".txt": true, ".pdf": true,
	".mobi": true, ".azw": true, ".azw3": true, ".prc": true, ".pdb": true, ".tcr": true,
	".fb2": true, ".fb3": true, ".djvu": true, ".djv": true,
	".cbz": true, ".cbr": true, ".cbt": true,
	".doc": true, ".docx": true, ".rtf": true, ".odt": true, ".chm": true,
	".html": true, ".htm": true, ".xhtml": true, ".htmlz": true, ".md": true,
	".pptx": true, ".xlsx": true, ".xps": true,
	".zip": true, ".png": true, ".jpg": true, ".jpeg": true,
	".gif": true, ".webp": true, ".svg": true, ".tif": true, ".tiff": true,
}

func deviceIP() string {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return ""
	}
	var usb, wifi string
	for _, a := range addrs {
		ipnet, ok := a.(*net.IPNet)
		if !ok || ipnet.IP.To4() == nil || ipnet.IP.IsLoopback() {
			continue
		}
		ip := ipnet.IP.String()
		if strings.HasPrefix(ip, "10.11.99.") {
			usb = ip
		} else {
			wifi = ip
		}
	}
	if wifi != "" {
		return wifi // 优先 WiFi 地址，手机才能扫
	}
	return usb
}

// 把上传地址渲染成二维码 PNG 放进书库；IP 变了就重新生成
func qrUpdater() {
	last := ""
	for {
		ip := deviceIP()
		if ip != "" && ip != last {
			url := fmt.Sprintf("http://%s:%d", ip, port)
			png, err := qrcode.Encode(url, qrcode.Medium, 600)
			if err == nil {
				os.WriteFile(filepath.Join(booksDir, qrName), png, 0644)
				// 稳定路径,供侧边栏"传书"应用显示
				os.MkdirAll("/home/root/paperlite", 0755)
				if werr := os.WriteFile("/home/root/paperlite/upload-qr.png", png, 0644); werr == nil {
					os.WriteFile("/home/root/paperlite/upload-url.txt", []byte(url), 0644)
					log.Printf("二维码已更新: %s", url)
					last = ip
				}
			}
		}
		time.Sleep(20 * time.Second)
	}
}

const pageTpl = `<!DOCTYPE html>
<html lang="zh-CN"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
<title>墨阅 · 传书</title>
<style>
  body{font-family:-apple-system,"PingFang SC","Microsoft YaHei",sans-serif;background:#f5f3ee;margin:0;padding:24px 16px;color:#333}
  .card{max-width:480px;margin:0 auto;background:#fff;border-radius:16px;padding:24px;box-shadow:0 2px 12px rgba(0,0,0,.06)}
  h1{font-size:22px;margin:0 0 4px}
  .sub{color:#888;font-size:13px;margin-bottom:20px}
  .drop{border:2px dashed #bbb;border-radius:12px;padding:36px 16px;text-align:center;color:#666;font-size:15px}
  .drop.on{border-color:#333;background:#fafaf8}
  input[type=file]{display:none}
  .btn{display:block;width:100%;margin-top:16px;padding:14px;background:#1a1a1a;color:#fff;border:0;border-radius:10px;font-size:16px;text-align:center}
  .msg{margin-top:14px;font-size:14px;text-align:center;min-height:20px}
  .ok{color:#2a7d2a}.err{color:#b33}
  ul{padding:0;margin:20px 0 0;list-style:none;font-size:14px;color:#555}
  li{padding:8px 4px;border-bottom:1px solid #eee;display:flex;justify-content:space-between}
  li span:last-child{color:#aaa;font-size:12px;white-space:nowrap;margin-left:8px}
  .hint{font-size:12px;color:#aaa;margin-top:16px;text-align:center}
  .gtitle{font-size:13px;color:#888;margin:16px 0 8px}
  .gallery{display:grid;grid-template-columns:repeat(3,1fr);gap:8px}
  .gallery img{width:100%;aspect-ratio:3/4;object-fit:cover;border:1px solid #ddd;border-radius:8px;cursor:pointer;background:#fafaf8}
  .gallery img.on{border-color:#1a1a1a;border-width:2px}
</style></head><body>
<div class="card">
  <h1>📚 墨阅 · 传书</h1>
  <div class="sub">选择文件，自动转换并传入 reMarkable 原生书库</div>
  <label class="drop" id="drop">点这里选书，或把文件拖进来<br><small>支持 EPUB / TXT / PDF / MOBI 等</small>
    <input type="file" id="file" multiple>
  </label>
  <button class="btn" id="send">上传</button>
  <div class="msg" id="msg"></div>
  <div class="hint">支持 EPUB / TXT / PDF(TXT 自动转 EPUB)· 上传后几秒书会出现在原生书库</div>
</div>
<div class="card">
  <h1>🌙 设休眠屏</h1>
  <div class="sub">上传图片作为 reMarkable 休眠/锁屏画面(自动转灰阶、填满竖屏)</div>
  <label class="drop" id="sdrop">点这里选图片，或拖进来<br><small>JPG / PNG · 建议竖图</small>
    <input type="file" id="sfile" accept="image/*">
  </label>
  <button class="btn" id="ssend">设为休眠屏</button>
  <div class="msg" id="smsg"></div>
  <div class="gtitle">或从图库选一张(点一下即应用):</div>
  <div class="gallery" id="gallery"></div>
  <div class="hint">设置后按一下电源键休眠即可看到效果</div>
</div>
<div class="card">
  <h1>🔤 阅读字体(中文)</h1>
  <div class="sub">切换 EPUB 里的中文字体(全局生效;原生那4个西文选项不变)。切换会重启刷新一下屏</div>
  <select id="fontsel" style="width:100%;box-sizing:border-box;padding:12px;font-size:15px;border:1px solid #ccc;border-radius:10px"></select>
  <button class="btn" id="fontapply">应用所选字体</button>
  <label class="drop" id="fontdrop" style="margin-top:10px;padding:20px">或上传自己的 TTF 字体<br><small>仅支持 .ttf(reMarkable 不认 .otf)</small>
    <input type="file" id="fontfile" accept=".ttf">
  </label>
  <button class="btn" id="fontup" style="background:#777">上传并应用</button>
  <div class="msg" id="fontmsg"></div>
  <div class="hint">应用后等十几秒(重启刷新)再看 EPUB</div>
</div>
<div class="card">
  <h1>📖 词典(KOReader 查词)</h1>
  <div class="sub">上传 StarDict 词典包(.zip/.tar.gz)装进 KOReader;之后在 KOReader 读书时长按词即可查释义</div>
  <label class="drop" id="dictdrop">点这里选词典包，或拖进来<br><small>StarDict 格式 · 含 .ifo/.idx/.dict</small>
    <input type="file" id="dictfile" accept=".zip,.tar.gz,.tgz">
  </label>
  <button class="btn" id="dictup">上传并安装</button>
  <div class="msg" id="dictmsg"></div>
  <div id="dictlist" style="font-size:13px;color:#666;margin-top:8px"></div>
  <div class="hint">免费中文词典搜「StarDict CC-CEDICT / 现代汉语词典」下载;查词只在 KOReader 阅读时生效(原生阅读器加不了)</div>
</div>
<div class="card">
  <h1>📰 新闻(RSS)</h1>
  <div class="sub">每行一个 RSS 地址(可写「网址 | 名称 | 分类」)。点"拉取最新"生成一份新闻进书库</div>
  <textarea id="feeds" rows="6" style="width:100%;box-sizing:border-box;border:1px solid #ccc;border-radius:10px;padding:12px;font-size:14px;font-family:monospace"></textarea>
  <button class="btn" id="fpull">拉取最新新闻</button>
  <button class="btn" id="fsave" style="background:#777;margin-top:8px">保存源列表</button>
  <div style="margin-top:14px;font-size:14px;color:#555">⏰ 自动抓取(逗号分隔时间，留空关闭):
    <input id="sched" type="text" placeholder="07:00,19:00" style="width:150px;border:1px solid #ccc;border-radius:6px;padding:6px;font-size:14px">
    <button id="schedsave" style="border:0;background:#777;color:#fff;border-radius:6px;padding:6px 12px;margin-left:4px">保存</button>
  </div>
  <div class="msg" id="fmsg"></div>
  <div class="hint">默认早晚各一份;睡眠时抓不到,会在你唤醒设备后补抓。需插着 USB(即时通道)</div>
</div>
<script>
const drop=document.getElementById('drop'),inp=document.getElementById('file'),
      msg=document.getElementById('msg'),btn=document.getElementById('send');
let files=[];
inp.onchange=()=>{files=[...inp.files];show()};
drop.ondragover=e=>{e.preventDefault();drop.classList.add('on')};
drop.ondragleave=()=>drop.classList.remove('on');
drop.ondrop=e=>{e.preventDefault();drop.classList.remove('on');files=[...e.dataTransfer.files];show()};
function show(){msg.className='msg';msg.textContent=files.length?('已选 '+files.map(f=>f.name).join(', ')):''}
btn.onclick=async()=>{
  if(!files.length){msg.className='msg err';msg.textContent='请先选择文件';return}
  btn.disabled=true;
  for(const f of files){
    msg.className='msg';msg.textContent='正在上传 '+f.name+' …';
    const fd=new FormData();fd.append('book',f);
    try{
      const r=await fetch('/upload',{method:'POST',body:fd});
      if(!r.ok){throw new Error(await r.text())}
    }catch(e){msg.className='msg err';msg.textContent=f.name+' 上传失败: '+e.message;btn.disabled=false;return}
  }
  msg.className='msg ok';msg.textContent='✓ 上传完成，几秒后在 reMarkable 书库打开';
  btn.disabled=false;files=[];inp.value='';
  setTimeout(()=>location.reload(),1500);
};
const sdrop=document.getElementById('sdrop'),sinp=document.getElementById('sfile'),
      smsg=document.getElementById('smsg'),ssend=document.getElementById('ssend');
let simg=null;
sinp.onchange=()=>{simg=sinp.files[0]||null;smsg.className='msg';smsg.textContent=simg?('已选 '+simg.name):''};
sdrop.ondragover=e=>{e.preventDefault();sdrop.classList.add('on')};
sdrop.ondragleave=()=>sdrop.classList.remove('on');
sdrop.ondrop=e=>{e.preventDefault();sdrop.classList.remove('on');simg=e.dataTransfer.files[0]||null;smsg.className='msg';smsg.textContent=simg?('已选 '+simg.name):''};
ssend.onclick=async()=>{
  if(!simg){smsg.className='msg err';smsg.textContent='请先选择图片';return}
  ssend.disabled=true;smsg.className='msg';smsg.textContent='正在设置…';
  const fd=new FormData();fd.append('image',simg);
  try{
    const r=await fetch('/sleepscreen',{method:'POST',body:fd});
    if(!r.ok){throw new Error(await r.text())}
    smsg.className='msg ok';smsg.textContent='✓ 休眠屏已设置，按电源键休眠看看';
  }catch(e){smsg.className='msg err';smsg.textContent='设置失败: '+e.message}
  ssend.disabled=false;
};
const gallery=document.getElementById('gallery');
fetch('/gallery').then(r=>r.text()).then(t=>{
  const names=t.trim()?t.trim().split('\n'):[];
  if(!names.length){gallery.previousElementSibling.style.display='none';return}
  gallery.innerHTML=names.map(n=>'<img loading="lazy" data-n="'+encodeURIComponent(n)+'" src="/galleryimg?name='+encodeURIComponent(n)+'">').join('');
  gallery.querySelectorAll('img').forEach(im=>{
    im.onclick=async()=>{
      gallery.querySelectorAll('img').forEach(x=>x.classList.remove('on'));
      im.classList.add('on');
      smsg.className='msg';smsg.textContent='正在应用图库屏保…';
      try{
        const r=await fetch('/gallery',{method:'POST',body:decodeURIComponent(im.dataset.n)});
        if(!r.ok)throw new Error(await r.text());
        smsg.className='msg ok';smsg.textContent='✓ 已设为休眠屏,按电源键休眠看看';
      }catch(e){smsg.className='msg err';smsg.textContent='设置失败: '+e.message}
    };
  });
}).catch(()=>{gallery.previousElementSibling.style.display='none'});
const feedsEl=document.getElementById('feeds'),fsave=document.getElementById('fsave'),
      fpull=document.getElementById('fpull'),fmsg=document.getElementById('fmsg');
fetch('/feeds').then(r=>r.text()).then(t=>{feedsEl.value=t}).catch(()=>{});
fsave.onclick=async()=>{
  fmsg.className='msg';fmsg.textContent='保存中…';
  try{const r=await fetch('/feeds',{method:'POST',body:feedsEl.value});if(!r.ok)throw new Error(await r.text());fmsg.className='msg ok';fmsg.textContent='✓ 源已保存'}
  catch(e){fmsg.className='msg err';fmsg.textContent='保存失败: '+e.message}
};
fpull.onclick=async()=>{
  fpull.disabled=true;fmsg.className='msg';fmsg.textContent='正在抓取新闻…(十几秒,别关页面)';
  try{const r=await fetch('/news');const t=await r.text();if(!r.ok)throw new Error(t);fmsg.className='msg ok';fmsg.textContent='✓ '+t+'，等十几秒(设备处理完)再去书库打开'}
  catch(e){fmsg.className='msg err';fmsg.textContent='抓取失败: '+e.message}
  fpull.disabled=false;
};
const fontsel=document.getElementById('fontsel'),fontapply=document.getElementById('fontapply'),
      fontfile=document.getElementById('fontfile'),fontup=document.getElementById('fontup'),
      fontdrop=document.getElementById('fontdrop'),fontmsg=document.getElementById('fontmsg');
fetch('/font').then(r=>r.text()).then(t=>{fontsel.innerHTML=t.trim().split('\n').map(n=>'<option>'+n+'</option>').join('')}).catch(()=>{});
fontapply.onclick=async()=>{
  fontapply.disabled=true;fontmsg.className='msg';fontmsg.textContent='应用中…(重启刷新约10秒)';
  try{const r=await fetch('/font',{method:'POST',body:fontsel.value});if(!r.ok)throw new Error(await r.text());fontmsg.className='msg ok';fontmsg.textContent='✓ 已应用 '+fontsel.value+'，等十几秒看 EPUB'}
  catch(e){fontmsg.className='msg err';fontmsg.textContent='失败: '+e.message}
  fontapply.disabled=false;
};
let fontF=null;
fontfile.onchange=()=>{fontF=fontfile.files[0]||null;fontmsg.className='msg';fontmsg.textContent=fontF?('已选 '+fontF.name):''};
fontup.onclick=async()=>{
  if(!fontF){fontmsg.className='msg err';fontmsg.textContent='请先选一个 TTF';return}
  fontup.disabled=true;fontmsg.className='msg';fontmsg.textContent='上传并应用中…';
  const fd=new FormData();fd.append('font',fontF);
  try{const r=await fetch('/fontupload',{method:'POST',body:fd});if(!r.ok)throw new Error(await r.text());fontmsg.className='msg ok';fontmsg.textContent='✓ 已应用上传的字体，等十几秒看 EPUB'}
  catch(e){fontmsg.className='msg err';fontmsg.textContent='失败: '+e.message}
  fontup.disabled=false;
};
const dictdrop=document.getElementById('dictdrop'),dictfile=document.getElementById('dictfile'),
      dictup=document.getElementById('dictup'),dictmsg=document.getElementById('dictmsg'),
      dictlist=document.getElementById('dictlist');
function loadDicts(){fetch('/dict').then(r=>r.text()).then(t=>{const ds=t.trim()?t.trim().split('\n'):[];dictlist.textContent=ds.length?('已装词典: '+ds.join('、')):'还没装词典'}).catch(()=>{})}
loadDicts();
let dictF=null;
dictfile.onchange=()=>{dictF=dictfile.files[0]||null;dictmsg.className='msg';dictmsg.textContent=dictF?('已选 '+dictF.name):''};
dictdrop.ondragover=e=>{e.preventDefault();dictdrop.classList.add('on')};
dictdrop.ondragleave=()=>dictdrop.classList.remove('on');
dictdrop.ondrop=e=>{e.preventDefault();dictdrop.classList.remove('on');dictF=e.dataTransfer.files[0]||null;dictmsg.className='msg';dictmsg.textContent=dictF?('已选 '+dictF.name):''};
dictup.onclick=async()=>{
  if(!dictF){dictmsg.className='msg err';dictmsg.textContent='请先选词典包';return}
  dictup.disabled=true;dictmsg.className='msg';dictmsg.textContent='上传解压中…';
  const fd=new FormData();fd.append('dict',dictF);
  try{const r=await fetch('/dict',{method:'POST',body:fd});const t=await r.text();if(!r.ok)throw new Error(t);dictmsg.className='msg ok';dictmsg.textContent='✓ '+t;loadDicts()}
  catch(e){dictmsg.className='msg err';dictmsg.textContent='失败: '+e.message}
  dictup.disabled=false;
};
const schedEl=document.getElementById('sched'),schedsave=document.getElementById('schedsave');
fetch('/schedule').then(r=>r.text()).then(t=>{schedEl.value=t.trim()}).catch(()=>{});
schedsave.onclick=async()=>{
  try{const r=await fetch('/schedule',{method:'POST',body:schedEl.value});if(!r.ok)throw 0;fmsg.className='msg ok';fmsg.textContent='✓ 定时已保存'}
  catch(e){fmsg.className='msg err';fmsg.textContent='定时保存失败'}
};
</script>
</body></html>`

func listBooks() (string, int) {
	entries, _ := os.ReadDir(booksDir)
	type item struct {
		name string
		mod  time.Time
		size int64
	}
	var items []item
	for _, e := range entries {
		if e.IsDir() || e.Name() == qrName || strings.HasPrefix(e.Name(), ".") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		items = append(items, item{e.Name(), info.ModTime(), info.Size()})
	}
	sort.Slice(items, func(i, j int) bool { return items[i].mod.After(items[j].mod) })
	var b strings.Builder
	for i, it := range items {
		if i >= 10 {
			break
		}
		fmt.Fprintf(&b, "<li><span>%s</span><span>%.1f MB</span></li>",
			html.EscapeString(it.name), float64(it.size)/1024/1024)
	}
	return b.String(), len(items)
}

func handleIndex(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	io.WriteString(w, pageTpl)
}

func handleUpload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", 405)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 800<<20)
	f, hdr, err := r.FormFile("book")
	if err != nil {
		http.Error(w, "读取文件失败", 400)
		return
	}
	defer f.Close()

	name := filepath.Base(hdr.Filename)
	ext := strings.ToLower(filepath.Ext(name))
	if !allowedExt[ext] {
		http.Error(w, "不支持的文件类型 "+ext, 400)
		return
	}
	// 先落临时文件,再导入原生书库(xochitl)
	tmp := filepath.Join(booksDir, name+".part")
	out, err := os.Create(tmp)
	if err != nil {
		http.Error(w, "设备存储写入失败", 500)
		return
	}
	if _, err := io.Copy(out, f); err != nil {
		out.Close()
		os.Remove(tmp)
		http.Error(w, "传输中断", 500)
		return
	}
	out.Close()
	title, err := importBook(tmp, name)
	os.Remove(tmp)
	if err != nil {
		http.Error(w, "导入失败: "+err.Error(), 500)
		return
	}
	log.Printf("已导入原生书库: %s (%.1f MB)", title, float64(hdr.Size)/1024/1024)
	w.WriteHeader(200)
	io.WriteString(w, "ok:"+title)
}

func main() {
	if err := os.MkdirAll(booksDir, 0755); err != nil {
		log.Fatal(err)
	}
	go qrUpdater()
	ensureFontMount() // 开机重挂自定义中文字体(主力是 xovi pre-start 钩子,此处兜底)
	ensureSleepMount() // 开机重挂自定义休眠图(若有)
	go newsScheduler() // 定时自动抓新闻(默认早晚各一份)
	http.HandleFunc("/", handleIndex)
	http.HandleFunc("/upload", handleUpload)
	http.HandleFunc("/sleepscreen", handleSleepScreen)
	http.HandleFunc("/gallery", handleGallery)
	http.HandleFunc("/galleryimg", handleGalleryImg)
	http.HandleFunc("/news", handleNews)
	http.HandleFunc("/feeds", handleFeeds)
	http.HandleFunc("/schedule", handleSchedule)
	http.HandleFunc("/font", handleFont)
	http.HandleFunc("/fontupload", handleFontUpload)
	http.HandleFunc("/dict", handleDict)
	log.Printf("墨阅传书服务启动 :%d，书库 %s", port, booksDir)
	log.Fatal(http.ListenAndServe(fmt.Sprintf(":%d", port), nil))
}
