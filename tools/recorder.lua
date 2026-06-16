-- 录制 /dev/input/event2 的真实触摸事件流到 /tmp/swipe.rec
-- 用法: luajit recorder.lua [秒数=10]   期间请做一次真实滑动
local ffi = require("ffi")
local C = ffi.C
ffi.cdef[[
int open(const char *pathname, int flags);
int close(int fd);
long read(int fd, void *buf, unsigned long count);
int usleep(unsigned int usec);
struct timeval32 { long tv_sec; long tv_usec; };
struct input_event { struct timeval32 time; unsigned short type; unsigned short code; int value; };
]]
local O_RDONLY, O_NONBLOCK = 0, 2048
local EV_ABS = 3
local ABS_MT_TRACKING_ID = 0x39
local maxdur = tonumber(arg and arg[1]) or 60
local fd = C.open("/dev/input/event2", O_RDONLY + O_NONBLOCK)
assert(fd>=0, "打不开 event2")
local ev = ffi.new("struct input_event")
local SZ = ffi.sizeof("struct input_event")
local out = assert(io.open("/tmp/swipe.rec","w"))
local start = os.time()
local n = 0
local saw_down, saw_up, up_at = false, false, nil
print("[recorder] 等待你滑动(最长 "..maxdur.." 秒),检测到一次完整滑动后自动停。随时滑都行...")
io.flush()
while os.time()-start < maxdur do
  local r = C.read(fd, ev, SZ)
  if r == SZ then
    out:write(string.format("%d %d %d %d %d\n",
      tonumber(ev.time.tv_sec), tonumber(ev.time.tv_usec), ev.type, ev.code, ev.value))
    out:flush()
    n = n + 1
    if ev.type==EV_ABS and ev.code==ABS_MT_TRACKING_ID then
      if ev.value >= 0 then saw_down = true
      elseif ev.value == -1 and saw_down then saw_up = true; up_at = os.time() end
    end
  else
    C.usleep(1500)
  end
  -- 抬起后再多收 1 秒(收尾事件)然后停
  if saw_up and up_at and os.time()-up_at >= 1 then break end
end
out:close(); C.close(fd)
print(string.format("[recorder] 录到 %d 个事件 (down=%s up=%s) -> /tmp/swipe.rec", n, tostring(saw_down), tostring(saw_up)))
