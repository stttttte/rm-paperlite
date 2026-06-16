#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
rmimport —— 一键把书导入 reMarkable 原生书库。
  txt  → 自动转 EPUB(中文章节切分)→ 入库
  epub → 直接入库
  pdf  → 直接入库(原生最强)
  mobi/azw3 → 若装了 Calibre(ebook-convert)则转 EPUB 入库,否则跳过提示

入库 = 生成 <uuid>.epub/.pdf + <uuid>.metadata + <uuid>.content 三件套 scp 到设备,
最后 restart xochitl 一次(其余 .epubindex/缩略图/页数由 xochitl 打开时自动生成)。

用法:
  python3 rmimport.py 书.txt [更多文件/目录...] [--author 作者] [--no-restart]
  python3 rmimport.py ~/某目录/        # 批量导入目录下所有支持的书
"""
import argparse, json, os, shutil, subprocess, sys, tempfile, time, uuid

KEY = os.path.expanduser("~/.ssh/id_ed25519_remarkable")
IP = "10.11.99.1"   # USB 默认;连 WiFi 后用 --ip <设备WiFi地址> 即可不插线传书
XDIR = "/home/root/.local/share/remarkable/xochitl"
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

SUPPORTED = {".txt", ".epub", ".pdf", ".mobi", ".azw3", ".azw"}

def find_ebook_convert():
    p = shutil.which("ebook-convert")
    if p: return p
    for c in ("/Applications/calibre.app/Contents/MacOS/ebook-convert",
              os.path.expanduser("~/Applications/calibre.app/Contents/MacOS/ebook-convert")):
        if os.path.isfile(c) and os.access(c, os.X_OK): return c
    return None

def ssh(cmd):
    return subprocess.run(["ssh", "-i", KEY, "-o", "ConnectTimeout=8",
                           f"root@{IP}", cmd], capture_output=True, text=True)

def scp(local, remote):
    r = subprocess.run(["scp", "-i", KEY, "-q", local, f"root@{IP}:{remote}"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("scp 失败: " + r.stderr.strip())

def make_sidecars(title, author, filetype, size, tmpdir):
    ms = str(int(time.time() * 1000))
    meta = {"createdTime": ms, "lastModified": ms, "lastOpened": "0", "lastOpenedPage": 0,
            "new": True, "parent": "", "pinned": False, "source": "com.paperlite.import",
            "type": "DocumentType", "visibleName": title}
    content = {"coverPageNumber": 0,
               "documentMetadata": {"authors": [author], "title": title},
               "extraMetadata": {}, "fileType": filetype, "fontName": "",
               "formatVersion": 1, "lineHeight": -1, "margins": 125,
               "orientation": "portrait", "pageCount": 0, "pageTags": [], "pages": [],
               "sizeInBytes": str(size), "tags": [], "textAlignment": "justify",
               "textScale": 1, "zoomMode": "bestFit"}
    mp = os.path.join(tmpdir, "x.metadata"); cp = os.path.join(tmpdir, "x.content")
    open(mp, "w").write(json.dumps(meta, ensure_ascii=False, indent=4))
    open(cp, "w").write(json.dumps(content, ensure_ascii=False, indent=4))
    return mp, cp

def prepare(path, author, tmpdir, ebook_convert):
    """返回 (要上传的书文件路径, fileType, 书名) 或 None(跳过)"""
    ext = os.path.splitext(path)[1].lower()
    title = os.path.splitext(os.path.basename(path))[0]
    if ext == ".txt":
        import txt2epub
        out = os.path.join(tmpdir, title + ".epub")
        txt2epub.convert(path, out_path=out, title=title, author=author)
        return out, "epub", title
    if ext == ".epub":
        return path, "epub", title
    if ext == ".pdf":
        return path, "pdf", title
    if ext in (".mobi", ".azw3", ".azw"):
        if not ebook_convert:
            print(f"⚠ 跳过 {os.path.basename(path)}:需要 Calibre(ebook-convert)才能转 {ext}")
            return None
        out = os.path.join(tmpdir, title + ".epub")
        print(f"  Calibre 转换 {ext} → epub ...")
        r = subprocess.run([ebook_convert, path, out], capture_output=True, text=True)
        if r.returncode != 0 or not os.path.isfile(out):
            print(f"⚠ 跳过 {os.path.basename(path)}:转换失败")
            return None
        return out, "epub", title
    return None

def import_one(path, author, ebook_convert):
    with tempfile.TemporaryDirectory() as tmp:
        prep = prepare(path, author, tmp, ebook_convert)
        if not prep: return False
        bookfile, ftype, title = prep
        size = os.path.getsize(bookfile)
        u = str(uuid.uuid4())
        mp, cp = make_sidecars(title, author, ftype, size, tmp)
        ext = ".epub" if ftype == "epub" else ".pdf"
        scp(bookfile, f"{XDIR}/{u}{ext}")
        scp(mp, f"{XDIR}/{u}.metadata")
        scp(cp, f"{XDIR}/{u}.content")
        print(f"✓ 入库: {title}  [{ftype}]  uuid={u[:8]}")
        return True

def collect(inputs):
    files = []
    for inp in inputs:
        if os.path.isdir(inp):
            for f in sorted(os.listdir(inp)):
                if os.path.splitext(f)[1].lower() in SUPPORTED:
                    files.append(os.path.join(inp, f))
        elif os.path.isfile(inp):
            files.append(inp)
        else:
            print(f"⚠ 找不到: {inp}")
    return files

def main():
    global IP
    ap = argparse.ArgumentParser(description="一键导入书到 reMarkable 原生书库")
    ap.add_argument("inputs", nargs="+", help="书文件或目录(txt/epub/pdf/mobi/azw3)")
    ap.add_argument("--author", default="未知")
    ap.add_argument("--ip", default=IP, help="设备地址(USB 默认 10.11.99.1;WiFi 填设备无线 IP 即可不插线)")
    ap.add_argument("--no-restart", action="store_true", help="导入后不重启 xochitl(攒一批后手动刷)")
    a = ap.parse_args()
    IP = a.ip

    # 设备可达?
    if ssh("echo ok").stdout.strip() != "ok":
        print("✗ 设备连不上(检查数据线/SSH)。"); sys.exit(1)

    ebc = find_ebook_convert()
    files = collect(a.inputs)
    if not files:
        print("没有可导入的文件。"); sys.exit(1)
    print(f"待导入 {len(files)} 本" + ("" if ebc else "(无 Calibre,mobi/azw3 将跳过)"))
    ok = 0
    for f in files:
        try:
            if import_one(f, a.author, ebc): ok += 1
        except Exception as e:
            print(f"✗ {os.path.basename(f)} 出错: {e}")
    print(f"\n成功 {ok}/{len(files)} 本。")
    if ok and not a.no_restart:
        print("重启 xochitl 刷新书库...")
        ssh("systemctl restart xochitl")
        print("✓ 完成。稍等几秒书库即可看到新书。")
    elif ok:
        print("(--no-restart:稍后手动 `ssh root@设备 systemctl restart xochitl` 刷新)")

if __name__ == "__main__":
    main()
