import QtQuick 2.5

// 墨阅 · 传书(AppLoad frontend）—— 满屏显示上传二维码,手机扫码即可打开上传页。
// 写法尽量贴近已验证可行的 claude.qml:FontLoader + Text + 声明式 Image,无 onCompleted thrash。
Rectangle {
    id: app
    anchors.fill: parent
    color: "white"
    signal close
    function unloading() {}

    FontLoader { id: cjk; source: "file:///home/root/xovi/exthome/appload/koreader/fonts/NotoSansSC-Regular.ttf" }

    Text {
        id: title
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: 110
        text: "传书 · 手机扫码上传"
        font.family: cjk.name
        font.pointSize: 30
        color: "#1a1a1a"
    }
    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: title.bottom
        anchors.topMargin: 20
        width: parent.width - 160
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        text: "手机连同一 WiFi,用微信/相机扫码,或在浏览器打开 设备IP:8866"
        font.family: cjk.name
        font.pointSize: 15
        color: "#777"
    }
    Image {
        id: qr
        anchors.centerIn: parent
        width: 600
        height: 600
        fillMode: Image.PreserveAspectFit
        cache: false
        source: "file:///home/root/paperlite/upload-qr.png"
    }
    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: qr.bottom
        anchors.topMargin: 26
        text: "上传 txt 自动转 EPUB · epub/pdf 直接入库"
        font.family: cjk.name
        font.pointSize: 13
        color: "#999"
    }
    Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 100
        width: 240
        height: 64
        radius: 8
        color: "#1a1a1a"
        Text { anchors.centerIn: parent; text: "刷新二维码"; color: "white"; font.family: cjk.name; font.pointSize: 16 }
        MouseArea {
            anchors.fill: parent
            onClicked: { qr.source = ""; qr.source = "file:///home/root/paperlite/upload-qr.png"; }
        }
    }
}
