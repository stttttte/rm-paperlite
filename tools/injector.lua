-- 纸镇·点击翻页 最小验证 (luajit + FFI,设备端直接跑,免编译)
-- 读 /dev/input/event2 真实能力照搬建 uinput 虚拟触摸设备,周期性合成滑动,验证 xochitl 是否接受。
-- 用法: luajit injector.lua [次数=12] [方向 0下一页/1上一页]
local ffi = require("ffi")
local bit = require("bit")
local C = ffi.C

ffi.cdef[[
int open(const char *pathname, int flags);
int close(int fd);
int ioctl(int fd, unsigned long request, void *arg);
long write(int fd, const void *buf, unsigned long count);
int usleep(unsigned int usec);
struct timeval32 { long tv_sec; long tv_usec; };
struct input_event { struct timeval32 time; unsigned short type; unsigned short code; int value; };
struct input_absinfo { int value; int minimum; int maximum; int fuzz; int flat; int resolution; };
struct input_id { unsigned short bustype; unsigned short vendor; unsigned short product; unsigned short version; };
struct uinput_setup { struct input_id id; char name[80]; unsigned int ff_effects_max; };
struct uinput_abs_setup { unsigned short code; struct input_absinfo absinfo; };
]]

local O_RDONLY, O_WRONLY = 0, 1
local EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
local SYN_REPORT = 0
local BTN_TOUCH, BTN_TOOL_FINGER = 0x14a, 0x145
local ABS_MT_SLOT, ABS_MT_TOUCH_MAJOR = 0x2f, 0x30
local ABS_MT_POSITION_X, ABS_MT_POSITION_Y = 0x35, 0x36
local ABS_MT_TRACKING_ID, ABS_MT_PRESSURE = 0x39, 0x3a
local ABS_CNT, KEY_CNT = 0x40, 0x300

-- _IOC 编码(asm-generic, ARM 用):用算术避免 32 位符号问题
local function IOC(dir,typ,nr,size) return dir*1073741824 + typ*256 + nr + size*65536 end
local DNONE,DWRITE,DREAD = 0,1,2
local U, E = string.byte("U"), string.byte("E")
local SZ_INT = 4
local SZ_SETUP = ffi.sizeof("struct uinput_setup")
local SZ_ABSSETUP = ffi.sizeof("struct uinput_abs_setup")
local SZ_ABSINFO = ffi.sizeof("struct input_absinfo")
local UI_SET_EVBIT   = IOC(DWRITE,U,100,SZ_INT)
local UI_SET_KEYBIT  = IOC(DWRITE,U,101,SZ_INT)
local UI_SET_ABSBIT  = IOC(DWRITE,U,103,SZ_INT)
local UI_SET_PROPBIT = IOC(DWRITE,U,110,SZ_INT)
local INPUT_PROP_DIRECT = 0x01
local UI_DEV_SETUP  = IOC(DWRITE,U,3,SZ_SETUP)
local UI_ABS_SETUP  = IOC(DWRITE,U,4,SZ_ABSSETUP)
local UI_DEV_CREATE = IOC(DNONE,U,1,0)
local UI_DEV_DESTROY= IOC(DNONE,U,2,0)
local function EVIOCGABS(a) return IOC(DREAD,E,0x40+a,SZ_ABSINFO) end
local function EVIOCGBIT(ev,len) return IOC(DREAD,E,0x20+ev,len) end

local function ioc_val(fd,req,val) return C.ioctl(fd,req,ffi.cast("void*",val)) end
local function ioc_ptr(fd,req,ptr) return C.ioctl(fd,req,ffi.cast("void*",ptr)) end
local function test_bit(buf,b) return bit.band(bit.rshift(buf[math.floor(b/8)], b%8),1)==1 end

local ev = ffi.new("struct input_event")
local function emit(fd,typ,code,val)
  ev.time.tv_sec=0; ev.time.tv_usec=0; ev.type=typ; ev.code=code; ev.value=val
  C.write(fd,ev,ffi.sizeof("struct input_event"))
end

local reps = tonumber(arg and arg[1]) or 12
local dir  = tonumber(arg and arg[2]) or 0

local src = C.open("/dev/input/event2", O_RDONLY)
assert(src>=0, "打不开 event2")
local absbits = ffi.new("uint8_t[?]", 8)   -- NBITS(ABS_CNT)
local keybits = ffi.new("uint8_t[?]", 96)  -- NBITS(KEY_CNT)
ioc_ptr(src, EVIOCGBIT(EV_ABS,8), absbits)
ioc_ptr(src, EVIOCGBIT(EV_KEY,96), keybits)

local ufd = C.open("/dev/uinput", O_WRONLY)
assert(ufd>=0, "打不开 /dev/uinput")
ioc_val(ufd,UI_SET_EVBIT,EV_SYN)
ioc_val(ufd,UI_SET_EVBIT,EV_KEY)
ioc_val(ufd,UI_SET_EVBIT,EV_ABS)
do local r=ioc_val(ufd,UI_SET_PROPBIT,INPUT_PROP_DIRECT); print("[injector] UI_SET_PROPBIT ret="..tostring(r)) end  -- 关键:标成"直接触摸"=触摸屏

local have = {}
if test_bit(keybits,BTN_TOUCH) then have.btn=true; ioc_val(ufd,UI_SET_KEYBIT,BTN_TOUCH) end
if test_bit(keybits,BTN_TOOL_FINGER) then ioc_val(ufd,UI_SET_KEYBIT,BTN_TOOL_FINGER) end

local ai = ffi.new("struct input_absinfo")
local setups = {}
local xmin,xmax,ymin,ymax = 0,0,0,0
for code=0,ABS_CNT-1 do
  if test_bit(absbits,code) and ioc_ptr(src,EVIOCGABS(code),ai)>=0 then
    ioc_val(ufd,UI_SET_ABSBIT,code)
    local s = ffi.new("struct uinput_abs_setup")
    s.code=code; s.absinfo=ai
    setups[#setups+1]=s
    if code==ABS_MT_POSITION_X then xmin=ai.minimum; xmax=ai.maximum end
    if code==ABS_MT_POSITION_Y then ymin=ai.minimum; ymax=ai.maximum end
    if code==ABS_MT_TRACKING_ID then have.tid=true end
    if code==ABS_MT_SLOT then have.slot=true end
    if code==ABS_MT_PRESSURE then have.press=ai.minimum+math.floor((ai.maximum-ai.minimum)/2) end
    if code==ABS_MT_TOUCH_MAJOR then have.major=ai.minimum+math.floor((ai.maximum-ai.minimum)/8) end
  end
end

local us = ffi.new("struct uinput_setup")
us.id.bustype=0x06; us.id.vendor=0x16c0; us.id.product=0x05df; us.id.version=1
ffi.copy(us.name,"pt_mt_virt",10)
assert(ioc_ptr(ufd,UI_DEV_SETUP,us)>=0, "UI_DEV_SETUP 失败")
for _,s in ipairs(setups) do ioc_ptr(ufd,UI_ABS_SETUP,s) end
assert(ioc_val(ufd,UI_DEV_CREATE,0)>=0, "UI_DEV_CREATE 失败")

print(string.format("[injector] 虚拟触摸已建 X[%d..%d] Y[%d..%d] btn=%s tid=%s slot=%s press=%s major=%s",
  xmin,xmax,ymin,ymax,tostring(have.btn),tostring(have.tid),tostring(have.slot),
  tostring(have.press),tostring(have.major)))
io.flush()

local function swipe(fd,x0,x1,y,steps)
  if have.slot then emit(fd,EV_ABS,ABS_MT_SLOT,0) end
  if have.tid  then emit(fd,EV_ABS,ABS_MT_TRACKING_ID,137) end
  if have.btn  then emit(fd,EV_KEY,BTN_TOUCH,1) end
  if have.press then emit(fd,EV_ABS,ABS_MT_PRESSURE,have.press) end
  if have.major then emit(fd,EV_ABS,ABS_MT_TOUCH_MAJOR,have.major) end
  emit(fd,EV_ABS,ABS_MT_POSITION_X,x0); emit(fd,EV_ABS,ABS_MT_POSITION_Y,y)
  emit(fd,EV_SYN,SYN_REPORT,0); C.usleep(12000)
  for i=1,steps do
    local x = math.floor(x0+(x1-x0)*i/steps)
    if have.slot then emit(fd,EV_ABS,ABS_MT_SLOT,0) end
    emit(fd,EV_ABS,ABS_MT_POSITION_X,x); emit(fd,EV_ABS,ABS_MT_POSITION_Y,y)
    emit(fd,EV_SYN,SYN_REPORT,0); C.usleep(8000)
  end
  if have.slot then emit(fd,EV_ABS,ABS_MT_SLOT,0) end
  if have.tid  then emit(fd,EV_ABS,ABS_MT_TRACKING_ID,-1) end
  if have.btn  then emit(fd,EV_KEY,BTN_TOUCH,0) end
  emit(fd,EV_SYN,SYN_REPORT,0)
end

local span = xmax-xmin; if span<=0 then span=1404 end
local y  = ymin+math.floor((ymax-ymin)/2)
local xr = xmin+math.floor(span*8/10)
local xl = xmin+math.floor(span*2/10)
local x0 = (dir==0) and xr or xl
local x1 = (dir==0) and xl or xr

if arg and arg[3]=="wait" then
  print("[injector] 设备已建,挂起等待 /tmp/go 触发滑动(此间可重启 xochitl)...")
  io.flush()
  while true do
    local f=io.open("/tmp/go","r"); if f then f:close(); break end
    C.usleep(200000)
  end
  print("[injector] 收到 go,开始滑动")
  io.flush()
else
  C.usleep(2000000)  -- 给 udev/xochitl 发现虚拟设备的时间
end
for i=1,reps do
  swipe(ufd,x0,x1,y,14)
  print(string.format("[injector] 第 %d/%d 次滑动(%s)", i, reps, dir==0 and "下一页" or "上一页"))
  io.flush()
  C.usleep(2500000)
end
ioc_val(ufd,UI_DEV_DESTROY,0)
C.close(ufd); C.close(src)
print("[injector] 结束")
