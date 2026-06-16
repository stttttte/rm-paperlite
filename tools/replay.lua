-- 通过虚拟触摸设备(带 INPUT_PROP_DIRECT,xochitl 已验证会读)原样重放 /tmp/swipe.rec
-- 用法: luajit replay.lua [次数=10] [间隔秒=2.5]
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
local ABS_CNT, KEY_CNT = 0x40, 0x300
local INPUT_PROP_DIRECT = 0x01
local function IOC(d,t,n,s) return d*1073741824 + t*256 + n + s*65536 end
local U,E = string.byte("U"), string.byte("E")
local SZ_INT=4
local SZ_SETUP=ffi.sizeof("struct uinput_setup")
local SZ_ABSSETUP=ffi.sizeof("struct uinput_abs_setup")
local SZ_ABSINFO=ffi.sizeof("struct input_absinfo")
local UI_SET_EVBIT=IOC(1,U,100,SZ_INT)
local UI_SET_KEYBIT=IOC(1,U,101,SZ_INT)
local UI_SET_ABSBIT=IOC(1,U,103,SZ_INT)
local UI_SET_PROPBIT=IOC(1,U,110,SZ_INT)
local UI_DEV_SETUP=IOC(1,U,3,SZ_SETUP)
local UI_ABS_SETUP=IOC(1,U,4,SZ_ABSSETUP)
local UI_DEV_CREATE=IOC(0,U,1,0)
local UI_DEV_DESTROY=IOC(0,U,2,0)
local function EVIOCGABS(a) return IOC(2,E,0x40+a,SZ_ABSINFO) end
local function EVIOCGBIT(ev,len) return IOC(2,E,0x20+ev,len) end
local function iv(fd,r,v) return C.ioctl(fd,r,ffi.cast("void*",v)) end
local function ip(fd,r,p) return C.ioctl(fd,r,ffi.cast("void*",p)) end
local function tb(buf,b) return bit.band(bit.rshift(buf[math.floor(b/8)], b%8),1)==1 end

-- 1) 读 event2 能力,照搬建虚拟设备
local src=C.open("/dev/input/event2",O_RDONLY); assert(src>=0)
local absb=ffi.new("uint8_t[?]",8); ip(src,EVIOCGBIT(EV_ABS,8),absb)
local keyb=ffi.new("uint8_t[?]",96); ip(src,EVIOCGBIT(EV_KEY,96),keyb)
local ufd=C.open("/dev/uinput",O_WRONLY); assert(ufd>=0)
iv(ufd,UI_SET_EVBIT,EV_SYN); iv(ufd,UI_SET_EVBIT,EV_KEY); iv(ufd,UI_SET_EVBIT,EV_ABS)
iv(ufd,UI_SET_PROPBIT,INPUT_PROP_DIRECT)
for c=0,KEY_CNT-1 do if tb(keyb,c) then iv(ufd,UI_SET_KEYBIT,c) end end
local ai=ffi.new("struct input_absinfo"); local setups={}
for code=0,ABS_CNT-1 do
  if tb(absb,code) and ip(src,EVIOCGABS(code),ai)>=0 then
    iv(ufd,UI_SET_ABSBIT,code)
    local s=ffi.new("struct uinput_abs_setup"); s.code=code; s.absinfo=ai; setups[#setups+1]=s
  end
end
local us=ffi.new("struct uinput_setup")
us.id.bustype=0x06; us.id.vendor=0x16c0; us.id.product=0x05df; us.id.version=1
ffi.copy(us.name,"pt_mt_virt",10)
assert(ip(ufd,UI_DEV_SETUP,us)>=0,"UI_DEV_SETUP")
for _,s in ipairs(setups) do ip(ufd,UI_ABS_SETUP,s) end
assert(iv(ufd,UI_DEV_CREATE,0)>=0,"UI_DEV_CREATE")
C.close(src)

-- 2) 读录制
local seq={}
for line in io.lines("/tmp/swipe.rec") do
  local sec,usec,typ,code,val = line:match("(%-?%d+) (%-?%d+) (%-?%d+) (%-?%d+) (%-?%d+)")
  if sec then seq[#seq+1]={t=tonumber(sec)*1000000+tonumber(usec), typ=tonumber(typ), code=tonumber(code), val=tonumber(val)} end
end
print("[replay] 载入 "..#seq.." 个事件")
io.flush()
if #seq==0 then print("[replay] 录制为空,退出"); os.exit(1) end

local ev=ffi.new("struct input_event")
local function emit(typ,code,val)
  ev.time.tv_sec=0; ev.time.tv_usec=0; ev.type=typ; ev.code=code; ev.value=val
  C.write(ufd,ev,ffi.sizeof("struct input_event"))
end

local reps=tonumber(arg and arg[1]) or 10
local gap =tonumber(arg and arg[2]) or 2.5
sleep_us = function(u) C.usleep(u) end
C.usleep(1500000)  -- xochitl 已读设备,稍候
for r=1,reps do
  local prev=nil
  for i,e in ipairs(seq) do
    if prev then
      local d=e.t-prev
      if d>0 and d<300000 then C.usleep(d) end  -- 保留原始时序,异常间隔截断
    end
    emit(e.typ,e.code,e.val)
    prev=e.t
  end
  print(string.format("[replay] 第 %d/%d 次回放",r,reps)); io.flush()
  C.usleep(math.floor(gap*1000000))
end
iv(ufd,UI_DEV_DESTROY,0); C.close(ufd)
print("[replay] 结束")
