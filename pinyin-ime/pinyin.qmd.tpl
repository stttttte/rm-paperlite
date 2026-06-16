; 纸镇 · 中文拼音输入法(增强版:长句连打 + 简拼 + 词频记忆 + 大词库)
; 基于已验证的 spike 结构:AFFECT KeyboardPanel.qml / TRAVERSE 根 Item 类型 / LOCATE BEFORE ALL / INSERT
AFFECT [[7182484153792115919]]
    TRAVERSE [[6502786168]]
        LOCATE BEFORE ALL
        INSERT {
            Item {
                id: pinyinIme
                parent: virtualKeyboard
                anchors.fill: parent
                z: 999

                QtObject {
                    id: imeState
                    property bool active: false
                    property string buffer: ""
                    property var cands: []           // [{text, consume}]
                    property int page: 0
                }
                readonly property int pageSize: 9
                readonly property bool clawPerLetter: true
                property var visibleCands: []        // 当前页候选(纯 property,确保 UI 刷新)

                // ===== 字典:PY 单字 / PYW 全拼词组 / SP 简拼词组 =====
                property var dict: (function() {
__DICT__
                    return { PY:  (typeof PY  !== "undefined" ? PY  : {}),
                             PYW: (typeof PYW !== "undefined" ? PYW : {}),
                             SP:  (typeof SP  !== "undefined" ? SP  : {}) };
                })()

                // ===== 词频记忆(持久化,XHR file:// 读写)=====
                property var userFreq: ({})
                readonly property string freqPath: "file:///home/root/paperlite/pinyin-freq.json"
                Component.onCompleted: pinyinIme.loadFreq()
                function loadFreq() {
                    try {
                        var xhr = new XMLHttpRequest();
                        xhr.open("GET", pinyinIme.freqPath, false);
                        xhr.send();
                        if (xhr.responseText && xhr.responseText.length > 0)
                            pinyinIme.userFreq = JSON.parse(xhr.responseText);
                    } catch (e) { pinyinIme.userFreq = ({}); }
                }
                Timer { id: saveTimer; interval: 1500; onTriggered: pinyinIme.saveFreq() }
                function saveFreq() {
                    try {
                        var xhr = new XMLHttpRequest();
                        xhr.open("PUT", pinyinIme.freqPath);
                        xhr.send(JSON.stringify(pinyinIme.userFreq));
                    } catch (e) {}
                }
                function bumpFreq(text) {
                    var f = pinyinIme.userFreq || ({});
                    f[text] = (f[text] || 0) + 1;
                    pinyinIme.userFreq = f;
                    saveTimer.restart();
                }

                // ===== 字典查询 =====
                function lookupPY(syl) {
                    var d = pinyinIme.dict.PY; var v = d && d[syl];
                    return (typeof v === "string") ? v : "";
                }
                function lookupList(map, k) {
                    var v = map && map[k];
                    if (typeof v !== "string" || v.length === 0) return [];
                    return v.split(",");
                }
                function longestSyllableAt(s, start) {
                    for (var L = 6; L >= 1; L--) {
                        if (start + L > s.length) continue;
                        var seg = s.substring(start, start + L);
                        if (lookupPY(seg).length > 0) return seg;
                    }
                    return s.length > start ? s.substring(start, start + 1) : "";
                }
                // 整句贪心分词:从左到右每次取最长词/单字,拼成整句(长句一次上屏用)
                function fullSentence(buf) {
                    var res = "", i = 0, guard = 0, words = 0;
                    while (i < buf.length && guard++ < 40) {
                        var best = null, bestLen = 0;
                        var kmax = Math.min(buf.length - i, 12);
                        for (var k = kmax; k >= 2; k--) {
                            var seg = buf.substring(i, i + k);
                            var w = lookupList(pinyinIme.dict.PYW, seg);
                            if (w.length > 0) { best = w[0]; bestLen = k; break; }
                        }
                        if (best === null) {
                            var syl = longestSyllableAt(buf, i);
                            var ch = lookupPY(syl);
                            if (ch.length > 0) { best = ch.charAt(0); bestLen = syl.length; }
                            else { best = ""; bestLen = (syl.length > 0 ? syl.length : 1); }
                        }
                        res += best; i += bestLen; if (best.length > 0) words++;
                    }
                    return { text: res, words: words };
                }

                // ===== 候选生成。候选 = {text, consume(消耗的拼音字母数)} =====
                function recomputeCandidates() {
                    var buf = imeState.buffer;
                    if (!buf || buf.length === 0) { imeState.cands = []; imeState.page = 0; refreshVisible(); return; }
                    var out = []; var seen = {};
                    function add(text, consume, isFull) {
                        if (!text || seen[text]) return;
                        seen[text] = 1; out.push({ text: text, consume: consume, isFull: !!isFull });
                    }
                    try {
                        // 0) 整句候选:buf 较长且能分成多词时,把整句放最前(选一次全上屏)
                        if (buf.length >= 5) {
                            var fsent = fullSentence(buf);
                            if (fsent.words >= 2 && fsent.text.length >= 2) add(fsent.text, buf.length, true);
                        }
                        if (buf.length >= 3) {
                            var ws = lookupList(pinyinIme.dict.PYW, buf);
                            for (var i = 0; i < ws.length; i++) add(ws[i], buf.length);
                        }
                        if (buf.length >= 2) {
                            var ss = lookupList(pinyinIme.dict.SP, buf);
                            for (var j = 0; j < ss.length; j++) add(ss[j], buf.length);
                        }
                        var maxk = Math.min(buf.length, 12);
                        for (var k = maxk; k >= 2; k--) {
                            var pre = buf.substring(0, k);
                            var pw = lookupList(pinyinIme.dict.PYW, pre);
                            for (var p = 0; p < pw.length; p++)
                                if (pw[p].length >= 2) add(pw[p], k);
                        }
                        var fs = longestSyllableAt(buf, 0);
                        var chars = lookupPY(fs);
                        for (var c = 0; c < chars.length; c++) add(chars.charAt(c), fs.length);
                    } catch (e) { out = []; }
                    // 排序:整句候选永远最前;其余按词频记忆(用过的提前)
                    var f = pinyinIme.userFreq || {};
                    var full = [], hot = [], cold = [];
                    for (var x = 0; x < out.length; x++) {
                        if (out[x].isFull) full.push(out[x]);
                        else if ((f[out[x].text] || 0) > 0) hot.push(out[x]);
                        else cold.push(out[x]);
                    }
                    hot.sort(function(a, b) { return (f[b.text] || 0) - (f[a.text] || 0); });
                    imeState.cands = full.concat(hot).concat(cold);
                    imeState.page = 0;
                    refreshVisible();
                }

                function pageCands() {
                    var all = imeState.cands || [];
                    var s = imeState.page * pinyinIme.pageSize;
                    return all.slice(s, s + pinyinIme.pageSize);
                }
                function hasMorePages() { return (imeState.cands || []).length > pinyinIme.pageSize; }
                // 刷新可见候选(每次 cands/page/active 变化后调,确保 UI 更新)
                function refreshVisible() {
                    pinyinIme.visibleCands = imeState.active ? pageCands() : [];
                }

                // ===== 动作 =====
                // 点候选用全局 index 从 imeState.cands 取原始对象(含 consume,不经 modelData 包装)
                function commitByIndex(i) {
                    var g = imeState.page * pinyinIme.pageSize + i;
                    var arr = imeState.cands || [];
                    if (g >= 0 && g < arr.length) commitCandidate(arr[g]);
                }
                function commitCandidate(cand) {
                    if (!cand || !cand.text) return;
                    try {
                        if (pinyinIme.clawPerLetter)
                            virtualKeyboard.insertText(cand.text, 0, 0);
                        else
                            virtualKeyboard.insertText(cand.text, imeState.buffer.length, 0);
                    } catch (e) {}
                    pinyinIme.bumpFreq(cand.text);
                    // 长句连打:只消耗该候选对应的拼音,剩余继续出候选
                    var cons = cand.consume || imeState.buffer.length;
                    var rest = imeState.buffer.substring(cons);
                    imeState.buffer = rest;
                    if (rest.length > 0) recomputeCandidates();
                    else { imeState.cands = []; imeState.page = 0; refreshVisible(); }
                }
                function clearBuffer() { imeState.buffer = ""; imeState.cands = []; imeState.page = 0; refreshVisible(); }
                function toggleActive() { imeState.active = !imeState.active; if (!imeState.active) clearBuffer(); else refreshVisible(); }
                function handleLetter(letter) {
                    try {
                        if (pinyinIme.clawPerLetter) virtualKeyboard.insertText("", -1, 0);
                        imeState.buffer = imeState.buffer + letter;
                        recomputeCandidates();
                    } catch (e) {}
                }
                function handleBackspace() {
                    try {
                        if (imeState.buffer.length > 0) {
                            imeState.buffer = imeState.buffer.substring(0, imeState.buffer.length - 1);
                            recomputeCandidates();
                        }
                    } catch (e) {}
                }
                function handleSpace() {
                    var all = imeState.cands || [];
                    if (all.length > 0) commitCandidate(all[0]);
                }
                function nextPage() {
                    var all = imeState.cands || [];
                    var pages = Math.ceil(all.length / pinyinIme.pageSize);
                    if (pages < 1) pages = 1;
                    imeState.page = (imeState.page + 1) % pages;
                    refreshVisible();
                }

                // ===== 候选行 UI(黑底白字 / 细竖线分隔 / 选中反色)=====
                Rectangle {
                    id: candidateBar
                    parent: virtualKeyboard
                    z: 999
                    height: 72
                    anchors { top: parent.top; left: parent.left; right: parent.right }
                    color: "black"
                    antialiasing: false

                    Rectangle {
                        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                        height: 1; color: "#444444"; antialiasing: false
                    }

                    Row {
                        id: candidateRow
                        anchors { left: parent.left; leftMargin: 8; verticalCenter: parent.verticalCenter }
                        spacing: 0

                        Rectangle {
                            id: imeToggle
                            width: 78; height: 56; radius: 6; antialiasing: false
                            color: imeToggleMa.pressed ? "#555555" : (imeState.active ? "#ffffff" : "#000000")
                            border.color: "#888888"; border.width: 1
                            Text {
                                anchors.centerIn: parent
                                text: imeState.active ? "中" : "EN"
                                color: imeState.active ? "#000000" : "#ffffff"
                                font.pixelSize: 30; antialiasing: false
                            }
                            MouseArea { id: imeToggleMa; anchors.fill: parent; onClicked: pinyinIme.toggleActive() }
                        }

                        Item {
                            width: imeState.active && imeState.buffer.length > 0 ? (bufText.implicitWidth + 28) : 0
                            height: 56; visible: width > 0
                            Text {
                                id: bufText
                                anchors { verticalCenter: parent.verticalCenter; left: parent.left; leftMargin: 14 }
                                text: imeState.buffer; color: "#aaaaaa"; font.pixelSize: 28; antialiasing: false
                            }
                        }

                        Repeater {
                            model: pinyinIme.visibleCands
                            delegate: Row {
                                spacing: 0
                                property int candIndex: index
                                Rectangle {
                                    width: 1; height: 36; anchors.verticalCenter: parent.verticalCenter
                                    color: "#555555"; antialiasing: false
                                }
                                Rectangle {
                                    width: Math.max(64, candText.implicitWidth + 32)
                                    height: 56; radius: 6; antialiasing: false
                                    color: candMa.pressed ? "#ffffff" : "#000000"
                                    Text {
                                        id: candText
                                        anchors.centerIn: parent
                                        text: modelData.text
                                        color: candMa.pressed ? "#000000" : "#ffffff"
                                        font.pixelSize: 38; antialiasing: false
                                    }
                                    MouseArea {
                                        id: candMa; anchors.fill: parent
                                        onClicked: pinyinIme.commitByIndex(candIndex)
                                    }
                                }
                            }
                        }

                        Rectangle {
                            width: imeState.active && pinyinIme.hasMorePages() ? 64 : 0
                            height: 56; visible: width > 0; radius: 6; antialiasing: false
                            color: moreMa.pressed ? "#555555" : "#000000"
                            Text { anchors.centerIn: parent; text: "›"; color: "#ffffff"; font.pixelSize: 40; antialiasing: false }
                            MouseArea { id: moreMa; anchors.fill: parent; onClicked: pinyinIme.nextPage() }
                        }
                    }
                }

                // ===== 按键拦截(第二个 Connections,与原生并存)=====
                Connections {
                    target: virtualKeyboard
                    function onKeyPressed(key) {
                        if (!imeState.active) return;
                        try {
                            var syms = (virtualKeyboard.shiftSelected && key.shiftedSymbols) ? key.shiftedSymbols : key.symbols;
                            var ch = (syms && syms.length > 0) ? syms[0] : "";
                            if (key.type === VirtualKeyboardKey.Backspace) {
                                if (imeState.buffer.length > 0) pinyinIme.handleBackspace();
                                return;
                            }
                            if (ch === " " || key.type === VirtualKeyboardKey.Space) {
                                if ((imeState.cands || []).length > 0) pinyinIme.handleSpace();
                                return;
                            }
                            if (ch && ch.length === 1 && ch >= "a" && ch <= "z") {
                                pinyinIme.handleLetter(ch);
                                return;
                            }
                        } catch (e) {}
                    }
                    function onKeyReleased(key) {}
                }
            }
        }
    END TRAVERSE
END AFFECT
