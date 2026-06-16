# 墨阅 (PaperLite)

免费复刻「镇纸」核心功能的 reMarkable 2 增强工具包，适配固件 3.20+（已按 3.22 路线构建）。

## 功能

| 功能 | 说明 |
|---|---|
| 📖 KOReader | Kindle 级阅读器：EPUB/TXT/PDF/MOBI，已内置思源宋体/黑体中文字体 |
| 📲 微信扫码传书 | 书库里有「传书二维码」图，KOReader 打开 → 微信扫码 → 传文件，落地即可读 |
| 🖼 自定义屏保 | `./screensaver.sh 图片.jpg` 一键更换待机画面 |
| 🔒 防升级保护 | 安装时自动关闭 OTA，防止固件升级抹掉一切 |

| 🤖 Claude 终端 | KOReader 菜单 → 工具 → Claude：完成提醒、虚拟键盘问 Claude、墨水屏浏览 Mac 上所有 Claude Code agents 会话 | ✅ |

不包含：系统界面汉化、中文输入法（KOReader 自身界面就是中文的，阅读场景够用）。

## Claude 终端（clawd.koplugin）

依赖 **Mac 上的 M5 中转在线**（`m5-stopwatch` worktree 的 server，`uvicorn app.main:app --host 0.0.0.0 --port 8000`），rM2 和 Mac 同一 WiFi。

- **完成提醒**：读书时每 30 秒轮询中转 `/events`，Claude 任务完成弹消息框（和 M5 手表同一事件源）
- **问 Claude…**：弹输入框+虚拟键盘（中文拼音：键盘设置里切换布局），发给中转的常驻 claude 会话；长任务等待期间界面会卡住，正常
- **Agents 会话**：列出 Mac `~/.claude/projects/` 里最近 20 个会话（含各 agent），点开全文阅读，太长自动只显示最近部分
- **中转地址**：默认 `http://172.20.10.2:8000`（构建时的 Mac IP），**IP 变了在菜单里改**

中转侧新增接口（已加进 m5 server）：`POST /ask_text`、`GET /last`、`GET /sessions`、`GET /session/{id}`。

## 安装（3 步）

1. rM2 用 **USB 线**连 Mac（或确保和 Mac 同一 WiFi）
2. 在设备上查 SSH 密码：`Settings → Help → About → Copyrights and licenses` 页面拉到底
3. 终端运行：

```bash
cd ~/Desktop/rm-paperlite
./install.sh              # USB 连接
./install.sh 192.168.x.x  # 或用设备 WiFi IP
```

中途会要求输一次设备密码（配免密），以及在「重建哈希表」步骤盯一下设备屏幕。

## 日常使用

- **读书**：设备侧边栏 → `AppLoad` → KOReader
- **传书**：KOReader 书库打开「0-传书二维码」→ 微信扫一扫 → 网页里选文件上传（微信聊天里收到的书：先存到手机文件/用「其他应用打开」也可以走浏览器上传页）
- **传书地址**：手机浏览器直接访问 `http://<设备IP>:8866` 也行
- **换屏保**：`./screensaver.sh ~/Pictures/xxx.jpg`，恢复 `./screensaver.sh --restore`

## 恢复 / 卸载

- 界面异常临时恢复原生：`ssh root@10.11.99.1 '/home/root/xovi/stock'`
- 完整卸载：`./uninstall.sh`（书保留）
- 设备重启后 xovi 会自动拉起（xovi-autostart.service）；若想禁用自启：删除设备上 `/home/root/xovi/auto-start-enabled`

## 风险须知

- 全部改动在用户层（LD_PRELOAD 注入 + systemd 服务），**不刷固件不动 bootloader**，最坏情况恢复出厂即可
- 系统升级会清掉本安装且可能堵死重装路线——所以安装时已禁用自动更新，**不要手动点系统更新**
- 传书服务只监听局域网，数据不出内网

## 组件来源

- [xovi](https://github.com/asivery/xovi) v0.3.3 / [rm-appload](https://github.com/asivery/rm-appload) **v0.4.1**（⚠️ v0.5.x 在固件 3.22.0.64 上 panic "Couldn't resolve the hashed identifier"，appload 版本必须与固件年代匹配）/ [扩展包](https://github.com/asivery/rm-xovi-extensions) v19
- [KOReader](https://github.com/koreader/koreader) v2026.03 (reMarkable arm32)
- 思源宋体/黑体 (Noto CJK SC, OFL 协议)
- bookbridge 传书服务：本项目自研（`server/main.go`，Go 交叉编译 ARMv7）

## 从零 clone 后如何补齐（本仓库只含原创源码）

为保持仓库轻量，**第三方运行时与字体、以及编译产物未提交**（见 `.gitignore`）。本仓库收录的是原创部分：bookbridge 传书服务（`server/`）、qmldiff 补丁（`*.qmd`）、拼音输入法（`pinyin-ime/`）、安装/部署脚本、各类工具（`tools/`）。新机器 clone 后需补三样：

1. **字体** — `./fetch-fonts.sh`（拉霞鹜文楷/朱雀仿宋等到 `fonts/`；Noto 按提示自取）。设备端 Noto 安装时会从设备自带字体播种，可不依赖此步。
2. **bookbridge 二进制** — 从源码交叉编译 ARMv7：
   ```bash
   cd server && GOOS=linux GOARCH=arm GOARM=7 go build -o bookbridge-arm .
   ```
3. **xovi / AppLoad / KOReader 运行时** — 按上方「组件来源」从各上游 releases 下载对应版本，解压组装进 `device/payload/xovi/`（扩展 `.so`、KOReader 整包）。版本务必与固件年代匹配（见上方 ⚠️）。

补齐后即可 `./install.sh [设备IP]` 安装。

> ⚠️ 本工具在用户层注入（LD_PRELOAD + systemd），不刷固件、不动 bootloader，不破解 DRM；仅供个人在自有设备上折腾使用，风险自负。
