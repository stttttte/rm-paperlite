# 生成拼音输入法字典:单字表(PY) + 词组表(PYW,全拼) + 简拼表(SP,首字母) -> 紧凑 JS
# 输入: pinyin.txt (U+XXXX: yīn # 字), dict_small.txt (词 频率 词性)
# 输出: pinyin-dict.js  内容 = var PY={...}; var PYW={...}; var SP={...};
import re, json, unicodedata

TMP = '/Users/liusidi/.claude/jobs/3eee097f/tmp'

# 调参(控制词库大小与内存)
MAXC = 30          # 每个音节最多保留候选汉字数
WORD_LIMIT = 28000 # 词组总量上限(全拼)
WORD_PER_KEY = 6   # 每个全拼键最多词数
SP_LIMIT = 12000   # 简拼词总量上限
SP_PER_KEY = 6     # 每个简拼键最多词数

# 1) 读字频
char_freq = {}
word_freq = {}
for line in open(f'{TMP}/dict_small.txt', encoding='utf-8'):
    parts = line.split()
    if len(parts) < 2:
        continue
    w, f = parts[0], parts[1]
    try:
        f = int(f)
    except ValueError:
        continue
    word_freq[w] = f
    if len(w) == 1:
        char_freq[w] = max(char_freq.get(w, 0), f)
for w, f in word_freq.items():
    for ch in w:
        if ch not in char_freq or char_freq[ch] < f // 10:
            char_freq.setdefault(ch, f // 10)

def norm_pinyin(py):
    out = [c for c in unicodedata.normalize('NFD', py) if unicodedata.category(c) != 'Mn']
    s = ''.join(out).lower().replace('ü', 'v').replace('u:', 'v')
    return re.sub(r'[^a-z]', '', s)

# 2) 拼音读音(只取首读音,去异读)
py_to_chars = {}
char_first_py = {}
for line in open(f'{TMP}/pinyin.txt', encoding='utf-8'):
    m = re.match(r'U\+([0-9A-Fa-f]+):\s*([^#]+)#\s*(.+)', line)
    if not m:
        continue
    ch = chr(int(m.group(1), 16))
    if not ('一' <= ch <= '鿿'):
        continue
    first = norm_pinyin(m.group(2).strip().split(',')[0])
    if first:
        py_to_chars.setdefault(first, set()).add(ch)
        char_first_py[ch] = first

# 3) PY:单字表
PY = {}
for py, chars in py_to_chars.items():
    ranked = sorted([c for c in chars if char_freq.get(c, 0) > 0], key=lambda c: -char_freq.get(c, 0))[:MAXC]
    if ranked:
        PY[py] = ''.join(ranked)

# 4) PYW:词组表(全拼,逗号分隔) + SP:简拼表(首字母,逗号分隔)
cand_words = sorted(word_freq.items(), key=lambda kv: -kv[1])
PYW = {}
SP = {}
w_taken = 0
sp_taken = 0
for w, f in cand_words:
    if not (2 <= len(w) <= 4):
        continue
    if not all('一' <= c <= '鿿' for c in w):
        continue
    try:
        sylls = [char_first_py[c] for c in w]
    except KeyError:
        continue
    full = ''.join(sylls)
    if not full.isalpha():
        continue
    # 全拼词组
    if w_taken < WORD_LIMIT and len(full) >= 3:
        lst = PYW.setdefault(full, [])
        if len(lst) < WORD_PER_KEY and w not in lst:
            lst.append(w)
            w_taken += 1
    # 简拼(每字首字母)
    if sp_taken < SP_LIMIT:
        initials = ''.join(s[0] for s in sylls)
        if len(initials) >= 2:
            slst = SP.setdefault(initials, [])
            if len(slst) < SP_PER_KEY and w not in slst:
                slst.append(w)
                sp_taken += 1

PYW = {k: ','.join(v) for k, v in PYW.items() if v}
SP = {k: ','.join(v) for k, v in SP.items() if v}

# 5) 输出
out = []
out.append('// 墨阅拼音字典(自动生成):PY=单字音节->候选, PYW=全拼->词组, SP=简拼(首字母)->词组')
out.append('var PY=' + json.dumps(PY, ensure_ascii=False, separators=(',', ':')) + ';')
out.append('var PYW=' + json.dumps(PYW, ensure_ascii=False, separators=(',', ':')) + ';')
out.append('var SP=' + json.dumps(SP, ensure_ascii=False, separators=(',', ':')) + ';')
js = '\n'.join(out)
open(f'{TMP}/pinyin-dict.js', 'w', encoding='utf-8').write(js)

print('单音节数 PY:', len(PY))
print('全拼词组数 PYW:', len(PYW))
print('简拼数 SP:', len(SP))
print('JS 大小: %.1f KB' % (len(js.encode('utf-8')) / 1024))
print('抽样 ni ->', PY.get('ni'))
print('     nihao ->', PYW.get('nihao'))
print('     beijing ->', PYW.get('beijing'))
print('简拼 bjdx ->', SP.get('bjdx'))
print('简拼 nh ->', SP.get('nh'))
print('简拼 wm ->', SP.get('wm'))
