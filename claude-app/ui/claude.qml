import QtQuick 2.5

// 墨阅 · Claude 原生应用（AppLoad frontend）
// 连 Mac 中转：问答 / 浏览 agents 会话 / 快捷指令
// 输入：内置英文/拼音键盘；完整中文输入请用 KOReader 里的 Claude 插件

Rectangle {
    id: app
    anchors.fill: parent
    color: "white"
    property bool chatWantBottom: false

    signal close
    function unloading() {}

    // ---------- 配置 ----------
    property string server: "http://192.168.2.197:8000"
    property string sessionId: ""
    property bool busy: false
    property bool kbVisible: true
    property bool kbShift: false
    property bool kbSym: false
    // 遥控模式：非空 = 已接管某个 Claude Code 会话
    property string remoteSid: ""
    property string remoteTitle: ""
    property var readerTurns: []
    property string readerSid: ""
    property bool readerWantBottom: false

    // 字体：中文用思源黑体（什么都能渲染），等宽用 Droid Sans Mono（仅 ASCII，给终端味的提示符）
    FontLoader { id: cjk;  source: "file:///home/root/xovi/exthome/appload/koreader/fonts/NotoSansSC-Regular.ttf" }
    FontLoader { id: mono; source: "file:///home/root/xovi/exthome/appload/koreader/fonts/droid/DroidSansMono.ttf" }

    Component.onCompleted: {
        // 允许用 /home/root/paperlite/claude.json 覆盖中转地址（不用重新编译）
        var xhr = new XMLHttpRequest();
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE && xhr.responseText) {
                try {
                    var cfg = JSON.parse(xhr.responseText);
                    if (cfg.server) app.server = cfg.server;
                } catch (e) {}
            }
        }
        xhr.open("GET", "file:///home/root/paperlite/claude.json");
        xhr.send();
        chatModel.append({ who: "Claude", text: "Welcome to Claude Code — 墨水屏版\n\n连接 Mac 中转，遥控你的 Claude Code 会话。\n· /sessions 浏览并接管 Mac 上的任意会话\n· /continue /status /test 快捷指令\n· 下方键盘输入英文/拼音，↵ 发送\n· 完整中文输入：KOReader → 工具 → Claude" });
    }

    // ---------- 网络 ----------
    function http(method, path, bodyObj, cb) {
        var xhr = new XMLHttpRequest();
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            if (xhr.status === 200) {
                try { cb(JSON.parse(xhr.responseText), null); }
                catch (e) { cb(null, "解析失败"); }
            } else {
                cb(null, "HTTP " + xhr.status + "（中转开了吗？）");
            }
        }
        xhr.open(method, app.server + path);
        if (bodyObj) {
            xhr.setRequestHeader("Content-Type", "application/json");
            xhr.send(JSON.stringify(bodyObj));
        } else {
            xhr.send();
        }
    }

    function ask(prompt) {
        if (busy || prompt === "") return;
        busy = true;
        chatModel.append({ who: "我", text: prompt });
        chatModel.append({ who: "Claude", text: "…思考中…" });
        chatFlick.scrollToEnd();
        var remote = remoteSid !== "";
        var path = remote ? "/session_ask" : "/ask_text";
        var sess = remote ? remoteSid : sessionId;
        http("POST", path, { prompt: prompt, session: sess }, function(data, err) {
            busy = false;
            chatModel.remove(chatModel.count - 1);
            if (!data) {
                chatModel.append({ who: "Claude", text: "❌ " + err });
            } else {
                if (data.session) {
                    if (remote) remoteSid = data.session;
                    else sessionId = data.session;
                }
                chatModel.append({ who: "Claude", text: data.answer });
            }
            chatFlick.scrollToEnd();
        });
    }

    function enterSession(sid, title, turns) {
        chatModel.clear();
        for (var i = 0; i < turns.length; i++) {
            chatModel.append({ who: turns[i].who === "👤 我" ? "我" : "Claude",
                               text: turns[i].text });
        }
        remoteSid = sid;
        remoteTitle = title || "会话";
        readerOverlay.visible = false;
        sessionsOverlay.visible = false;
        chatModel.append({ who: "Claude", text: "—— 已接管此会话，下面的输入会继续这个对话 ——" });
        chatFlick.scrollToEnd();
    }

    function exitRemote() {
        remoteSid = "";
        remoteTitle = "";
        chatModel.clear();
        chatModel.append({ who: "Claude", text: "已回到普通对话。" });
    }

    function loadSessions() {
        sessionsModel.clear();
        sessionsOverlay.visible = true;
        sessionsTitle.text = "加载中…";
        http("GET", "/sessions?limit=20", null, function(data, err) {
            if (!data) { sessionsTitle.text = "❌ " + err; return; }
            sessionsTitle.text = "Claude Code 会话（点开阅读）";
            for (var i = 0; i < data.sessions.length; i++) {
                var s = data.sessions[i];
                var d = new Date(s.mtime * 1000);
                sessionsModel.append({
                    sid: s.id,
                    label: (d.getMonth()+1) + "-" + d.getDate() + " " +
                           d.getHours() + ":" + (d.getMinutes()<10?"0":"") + d.getMinutes() +
                           "  " + s.title
                });
            }
        });
    }

    function openSession(sid) {
        readerTitle.text = "加载中…";
        readerText.text = "";
        readerSid = sid;
        readerTurns = [];
        readerOverlay.visible = true;
        http("GET", "/session/" + sid, null, function(data, err) {
            if (!data || !data.ok) { readerTitle.text = "❌ " + (err || "加载失败"); return; }
            readerTitle.text = data.title;
            readerText.text = (data.truncated ? "（太长，只显示最近部分）\n\n" : "") + data.text;
            readerTurns = data.turn_list || [];
            app.readerWantBottom = true;   // 加载后滚到最新（底部）
        });
    }

    // ---------- 标题栏（Claude Code 风）----------
    Rectangle {
        id: header
        width: parent.width; height: 88
        color: "white"
        Text {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left; anchors.leftMargin: 28
            text: "✻ Claude Code"
            font.family: mono.name; font.pointSize: 26; font.bold: true
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right; anchors.rightMargin: 28
            text: busy ? "● running" : "○ ready"
            font.family: mono.name; font.pointSize: 16; color: "#777"
        }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: "#d0cdc2" }
    }

    // ---------- 遥控模式提示条 ----------
    Rectangle {
        id: modeBar
        anchors.top: header.bottom
        width: parent.width
        height: app.remoteSid !== "" ? 64 : 0
        visible: app.remoteSid !== ""
        color: "#eeeeee"
        Text {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left; anchors.leftMargin: 24
            anchors.right: exitRemoteBtn.left; anchors.rightMargin: 12
            text: "🎮 遥控中: " + app.remoteTitle
            elide: Text.ElideRight
            font.family: cjk.name; font.pointSize: 17
        }
        Rectangle {
            id: exitRemoteBtn
            anchors.right: parent.right
            width: 120; height: parent.height
            color: "#333"
            Text { anchors.centerIn: parent; text: "退出"; color: "white"; font.family: cjk.name; font.pointSize: 18 }
            MouseArea { anchors.fill: parent; onClicked: exitRemote() }
        }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: "#999" }
    }

    // ---------- 聊天区 ----------
    ListModel { id: chatModel }

    Flickable {
        id: chatFlick
        anchors.top: modeBar.bottom
        anchors.bottom: quickRow.top
        width: parent.width
        contentHeight: chatCol.height + 30
        clip: true
        // 标记“要滚到底”，真正滚动等内容高度算好后在 onContentHeightChanged 里做
        function scrollToEnd() {
            app.chatWantBottom = true;
            if (contentHeight > height) { contentY = contentHeight - height; }
        }
        onContentHeightChanged: {
            if (app.chatWantBottom && contentHeight > height) {
                contentY = contentHeight - height;
            }
        }
        Column {
            id: chatCol
            x: 28; y: 20
            width: chatFlick.width - 56
            spacing: 20
            Repeater {
                model: chatModel
                Row {
                    width: chatCol.width
                    spacing: 12
                    // 终端式行首标记：用户 ">"，Claude 实心点 "⏺"
                    Text {
                        width: 26
                        text: who === "我" ? ">" : "⏺"
                        font.family: mono.name; font.pointSize: 20; font.bold: true
                        color: who === "我" ? "#777" : "#000"
                    }
                    Text {
                        width: parent.width - 38
                        text: model.text
                        wrapMode: Text.Wrap
                        textFormat: Text.PlainText
                        font.family: cjk.name; font.pointSize: 19
                        color: who === "我" ? "#555" : "#111"
                        lineHeight: 1.15
                    }
                }
            }
        }
    }

    // ---------- 斜杠命令条（Claude Code 风）----------
    Row {
        id: quickRow
        anchors.bottom: inputRow.top
        width: parent.width
        height: 76
        Repeater {
            model: [
                { label: "/continue", prompt: "继续" },
                { label: "/status",   prompt: "简要汇报当前任务进展" },
                { label: "/test",     prompt: "运行当前项目的测试并汇报结果" },
                { label: "/sessions", prompt: "" },
                { label: "/clear",    prompt: "" }
            ]
            Rectangle {
                width: quickRow.width / 5; height: quickRow.height
                color: "white"
                Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: "#ccc" }
                Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: "#ccc" }
                Text {
                    anchors.centerIn: parent
                    text: modelData.label
                    font.family: mono.name; font.pointSize: 16
                    color: "#444"
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        if (modelData.label === "/sessions") loadSessions();
                        else if (modelData.label === "/clear") { chatModel.clear(); }
                        else ask(modelData.prompt);
                    }
                }
            }
        }
    }

    // ---------- 输入行（终端提示符 "> _"）----------
    property string buf: ""
    Rectangle {
        id: inputRow
        anchors.bottom: keyboard.visible ? keyboard.top : parent.bottom
        width: parent.width; height: 92
        color: "#ffffff"
        Rectangle { anchors.top: parent.top; width: parent.width; height: 2; color: "#000" }
        Text {
            id: promptMark
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left; anchors.leftMargin: 22
            text: ">"
            font.family: mono.name; font.pointSize: 24; font.bold: true
        }
        Text {
            id: bufText
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: promptMark.right; anchors.leftMargin: 12
            anchors.right: kbToggle.left
            text: app.buf === "" ? "输入英文/拼音，回车发送…" : app.buf + "_"
            color: app.buf === "" ? "#aaa" : "#000"
            font.family: cjk.name; font.pointSize: 21
            elide: Text.ElideLeft
        }
        Rectangle {
            id: kbToggle
            anchors.right: sendBtn.left
            width: 86; height: parent.height
            color: "white"
            Rectangle { anchors.left: parent.left; width: 1; height: parent.height; color: "#ccc" }
            Text { anchors.centerIn: parent; text: "⌨"; font.pointSize: 24 }
            MouseArea { anchors.fill: parent; onClicked: app.kbVisible = !app.kbVisible }
        }
        Rectangle {
            id: sendBtn
            anchors.right: parent.right
            width: 124; height: parent.height
            color: "#000"
            Text {
                anchors.centerIn: parent; text: "↵"
                color: "white"; font.family: mono.name; font.pointSize: 30
            }
            MouseArea {
                anchors.fill: parent
                onClicked: { var p = app.buf; app.buf = ""; ask(p); }
            }
        }
    }

    // ---------- 内置键盘 ----------
    Rectangle {
        id: keyboard
        visible: app.kbVisible
        anchors.bottom: parent.bottom
        width: parent.width
        height: 420
        color: "#fafafa"
        Rectangle { width: parent.width; height: 1; color: "black" }

        property var rowsAbc: ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        property var rowsSym: ["1234567890", "@#$%&*()-+", ".,?!:;'\"/_"]

        Column {
            anchors.fill: parent
            anchors.margins: 8
            spacing: 8

            Repeater {
                model: 3
                Row {
                    property int rowIdx: index
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 6
                    Repeater {
                        model: (app.kbSym ? keyboard.rowsSym : keyboard.rowsAbc)[rowIdx].split("")
                        Rectangle {
                            width: (keyboard.width - 80) / 10; height: 88
                            border.width: 1; border.color: "#777"
                            color: "white"; radius: 6
                            Text {
                                anchors.centerIn: parent
                                text: app.kbShift && !app.kbSym ? modelData.toUpperCase() : modelData
                                font.pointSize: 24
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: {
                                    app.buf += (app.kbShift && !app.kbSym) ? modelData.toUpperCase() : modelData;
                                    if (app.kbShift) app.kbShift = false;
                                }
                            }
                        }
                    }
                }
            }

            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 6
                Rectangle {  // shift / 符号切换
                    width: 140; height: 88
                    border.width: 1; border.color: "#777"; radius: 6
                    color: app.kbShift ? "#ddd" : "white"
                    Text { anchors.centerIn: parent; text: app.kbSym ? "abc" : (app.kbShift ? "⇧●" : "⇧"); font.pointSize: 20 }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: { if (app.kbSym) app.kbSym = false; else app.kbShift = !app.kbShift; }
                    }
                }
                Rectangle {  // 123
                    width: 110; height: 88
                    border.width: 1; border.color: "#777"; radius: 6; color: "white"
                    Text { anchors.centerIn: parent; text: "123"; font.pointSize: 20 }
                    MouseArea { anchors.fill: parent; onClicked: { app.kbSym = true; app.kbShift = false; } }
                }
                Rectangle {  // 空格
                    width: keyboard.width - 700; height: 88
                    border.width: 1; border.color: "#777"; radius: 6; color: "white"
                    Text { anchors.centerIn: parent; text: "空格"; font.family: cjk.name; font.pointSize: 18 }
                    MouseArea { anchors.fill: parent; onClicked: app.buf += " " }
                }
                Rectangle {  // 退格
                    width: 140; height: 88
                    border.width: 1; border.color: "#777"; radius: 6; color: "white"
                    Text { anchors.centerIn: parent; text: "⌫"; font.pointSize: 24 }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: app.buf = app.buf.slice(0, -1)
                        onPressAndHold: app.buf = ""
                    }
                }
                Rectangle {  // 收起
                    width: 110; height: 88
                    border.width: 1; border.color: "#777"; radius: 6; color: "white"
                    Text { anchors.centerIn: parent; text: "▼"; font.pointSize: 20 }
                    MouseArea { anchors.fill: parent; onClicked: app.kbVisible = false }
                }
            }
        }
    }

    // ---------- 会话列表浮层 ----------
    ListModel { id: sessionsModel }
    Rectangle {
        id: sessionsOverlay
        visible: false
        anchors.fill: parent
        color: "white"
        Rectangle {
            id: sessHeader
            width: parent.width; height: 90
            Text {
                id: sessionsTitle
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left; anchors.leftMargin: 30
                font.family: cjk.name; font.pointSize: 24; font.bold: true
            }
            Rectangle {
                anchors.right: parent.right; width: 110; height: parent.height
                color: "black"
                Text { anchors.centerIn: parent; text: "✕"; color: "white"; font.pointSize: 26 }
                MouseArea { anchors.fill: parent; onClicked: sessionsOverlay.visible = false }
            }
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 2; color: "black" }
        }
        Flickable {
            anchors.top: sessHeader.bottom
            anchors.bottom: parent.bottom
            width: parent.width
            contentHeight: sessCol.height
            clip: true
            Column {
                id: sessCol
                width: parent.width
                Repeater {
                    model: sessionsModel
                    Rectangle {
                        width: sessCol.width; height: 100
                        color: "white"
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left; anchors.leftMargin: 30
                            anchors.right: parent.right; anchors.rightMargin: 30
                            text: label
                            elide: Text.ElideRight
                            font.family: cjk.name; font.pointSize: 20
                        }
                        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: "#ccc" }
                        MouseArea { anchors.fill: parent; onClicked: openSession(sid) }
                    }
                }
            }
        }
    }

    // ---------- 会话阅读浮层 ----------
    Rectangle {
        id: readerOverlay
        visible: false
        anchors.fill: parent
        color: "white"
        Rectangle {
            id: readerHeader
            width: parent.width; height: 90
            Text {
                id: readerTitle
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left; anchors.leftMargin: 30
                anchors.right: readerClose.left
                elide: Text.ElideRight
                font.family: cjk.name; font.pointSize: 22; font.bold: true
            }
            Rectangle {
                id: readerClose
                anchors.right: parent.right; width: 110; height: parent.height
                color: "black"
                Text { anchors.centerIn: parent; text: "✕"; color: "white"; font.pointSize: 26 }
                MouseArea { anchors.fill: parent; onClicked: readerOverlay.visible = false }
            }
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 2; color: "black" }
        }
        Flickable {
            id: readerFlick
            anchors.top: readerHeader.bottom
            anchors.bottom: enterSessionBtn.top
            width: parent.width
            contentHeight: readerText.height + 60
            clip: true
            // 内容高度就绪后，若标记了「要看最新」就滚到底部
            onContentHeightChanged: {
                if (app.readerWantBottom && contentHeight > height) {
                    contentY = contentHeight - height;
                    app.readerWantBottom = false;
                }
            }
            Text {
                id: readerText
                x: 30; y: 20
                width: readerFlick.width - 60
                wrapMode: Text.Wrap
                font.family: cjk.name; font.pointSize: 19
            }
        }
        Rectangle {
            id: enterSessionBtn
            anchors.bottom: parent.bottom
            width: parent.width; height: 100
            color: "black"
            Text {
                anchors.centerIn: parent
                text: "🎮 进入此对话，继续和它聊"
                color: "white"; font.family: cjk.name; font.pointSize: 22
            }
            MouseArea {
                anchors.fill: parent
                onClicked: enterSession(app.readerSid, readerTitle.text, app.readerTurns)
            }
        }
    }
}
