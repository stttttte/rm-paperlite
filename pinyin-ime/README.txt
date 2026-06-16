reMarkable 原生拼音输入法 (qmldiff)
- pinyin.qmd = 最终补丁(已含内联字典),部署到 xovi/exthome/qt-resource-rebuilder/
- gen_pinyin_dict.py = 字典生成器(需 pinyin.txt+dict_small.txt,见脚本注释)
- pinyin-dict.js = 生成的字典(PY单字+PYW词组)
- pinyin.qmd.tpl = 引擎模板(__DICT__ 占位)
机制: AFFECT KeyboardPanel.qml→TRAVERSE 根Item类型→INSERT 候选行+第二Connections监听onKeyPressed
回滚: 删 pinyin.qmd + restart xochitl
