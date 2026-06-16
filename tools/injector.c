/* 纸镇·点击翻页 最小验证程序
 * 读 /dev/input/event2(手指多点触摸)的真实能力与坐标范围,照搬建一个 uinput 虚拟触摸设备,
 * 然后周期性合成"右→左滑动"(reMarkable 的下一页手势),验证 xochitl 是否接受虚拟设备。
 * 用法: injector [次数] [方向]   方向: 0=右往左(下一页,默认) 1=左往右(上一页)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/ioctl.h>
#include <linux/input.h>
#include <linux/uinput.h>

#define SRC "/dev/input/event2"
#define NBITS(x) ((((x)-1)/(8*sizeof(long)))+1)

static int test_bit(const unsigned long *arr, int bit) {
    return (arr[bit/(8*sizeof(long))] >> (bit%(8*sizeof(long)))) & 1;
}
static void msleep(long ms){ struct timespec ts={ms/1000,(ms%1000)*1000000L}; nanosleep(&ts,NULL); }

static int have_btn_touch=0, have_pressure=0, have_major=0, have_tid=0, have_slot=0;
static int press_val=50, major_val=8;

static void emit(int fd,int type,int code,int val){
    struct input_event ev; memset(&ev,0,sizeof(ev));
    ev.type=type; ev.code=code; ev.value=val;
    if(write(fd,&ev,sizeof(ev))<0) perror("write ev");
}
static void syn(int fd){ emit(fd,EV_SYN,SYN_REPORT,0); }

static void do_swipe(int fd,int x0,int x1,int y,int steps){
    int tid=137;
    if(have_slot) emit(fd,EV_ABS,ABS_MT_SLOT,0);
    if(have_tid)  emit(fd,EV_ABS,ABS_MT_TRACKING_ID,tid);
    if(have_btn_touch) emit(fd,EV_KEY,BTN_TOUCH,1);
    if(have_pressure)  emit(fd,EV_ABS,ABS_MT_PRESSURE,press_val);
    if(have_major)     emit(fd,EV_ABS,ABS_MT_TOUCH_MAJOR,major_val);
    emit(fd,EV_ABS,ABS_MT_POSITION_X,x0);
    emit(fd,EV_ABS,ABS_MT_POSITION_Y,y);
    syn(fd);
    msleep(12);
    for(int i=1;i<=steps;i++){
        int x=x0+(int)((long)(x1-x0)*i/steps);
        if(have_slot) emit(fd,EV_ABS,ABS_MT_SLOT,0);
        emit(fd,EV_ABS,ABS_MT_POSITION_X,x);
        emit(fd,EV_ABS,ABS_MT_POSITION_Y,y);
        syn(fd);
        msleep(8);
    }
    if(have_slot) emit(fd,EV_ABS,ABS_MT_SLOT,0);
    if(have_tid)  emit(fd,EV_ABS,ABS_MT_TRACKING_ID,-1);
    if(have_btn_touch) emit(fd,EV_KEY,BTN_TOUCH,0);
    syn(fd);
}

int main(int argc,char**argv){
    int reps = argc>1?atoi(argv[1]):12;
    int dir  = argc>2?atoi(argv[2]):0;   /* 0 右->左(下一页) 1 左->右(上一页) */

    int src=open(SRC,O_RDONLY);
    if(src<0){ perror("open "SRC); return 1; }

    unsigned long absbits[NBITS(ABS_CNT)]; memset(absbits,0,sizeof(absbits));
    unsigned long keybits[NBITS(KEY_CNT)]; memset(keybits,0,sizeof(keybits));
    ioctl(src,EVIOCGBIT(EV_ABS,sizeof(absbits)),absbits);
    ioctl(src,EVIOCGBIT(EV_KEY,sizeof(keybits)),keybits);

    int ufd=open("/dev/uinput",O_WRONLY|O_NONBLOCK);
    if(ufd<0){ perror("open /dev/uinput"); return 1; }
    ioctl(ufd,UI_SET_EVBIT,EV_SYN);
    ioctl(ufd,UI_SET_EVBIT,EV_KEY);
    ioctl(ufd,UI_SET_EVBIT,EV_ABS);

    if(test_bit(keybits,BTN_TOUCH)){ have_btn_touch=1; ioctl(ufd,UI_SET_KEYBIT,BTN_TOUCH); }
    if(test_bit(keybits,BTN_TOOL_FINGER)) ioctl(ufd,UI_SET_KEYBIT,BTN_TOOL_FINGER);

    int xmin=0,xmax=0,ymin=0,ymax=0;
    struct input_absinfo ai;
    struct uinput_abs_setup absetups[ABS_CNT]; int nabs=0;
    for(int code=0;code<ABS_CNT;code++){
        if(!test_bit(absbits,code)) continue;
        if(ioctl(src,EVIOCGABS(code),&ai)<0) continue;
        ioctl(ufd,UI_SET_ABSBIT,code);
        struct uinput_abs_setup s; memset(&s,0,sizeof(s));
        s.code=code; s.absinfo=ai; absetups[nabs++]=s;
        if(code==ABS_MT_POSITION_X){ xmin=ai.minimum; xmax=ai.maximum; }
        if(code==ABS_MT_POSITION_Y){ ymin=ai.minimum; ymax=ai.maximum; }
        if(code==ABS_MT_TRACKING_ID) have_tid=1;
        if(code==ABS_MT_SLOT) have_slot=1;
        if(code==ABS_MT_PRESSURE){ have_pressure=1; press_val=ai.minimum+(ai.maximum-ai.minimum)/2; if(press_val<=0)press_val=50; }
        if(code==ABS_MT_TOUCH_MAJOR){ have_major=1; major_val=ai.minimum+(ai.maximum-ai.minimum)/8; if(major_val<=0)major_val=8; }
    }

    struct uinput_setup us; memset(&us,0,sizeof(us));
    us.id.bustype=BUS_VIRTUAL; us.id.vendor=0x16c0; us.id.product=0x05df; us.id.version=1;
    strncpy(us.name,"pt_mt_virt",sizeof(us.name)-1);
    if(ioctl(ufd,UI_DEV_SETUP,&us)<0){ perror("UI_DEV_SETUP"); return 1; }
    for(int i=0;i<nabs;i++) if(ioctl(ufd,UI_ABS_SETUP,&absetups[i])<0) perror("UI_ABS_SETUP");
    if(ioctl(ufd,UI_DEV_CREATE)<0){ perror("UI_DEV_CREATE"); return 1; }

    printf("[injector] 虚拟触摸已建: X[%d..%d] Y[%d..%d] btn=%d tid=%d slot=%d press=%d major=%d\n",
           xmin,xmax,ymin,ymax,have_btn_touch,have_tid,have_slot,have_pressure,have_major);
    fflush(stdout);

    int span=xmax-xmin; if(span<=0) span=1404;
    int y=ymin+(ymax-ymin)/2;
    int xr=xmin+span*8/10, xl=xmin+span*2/10;
    int x0 = dir==0 ? xr : xl;   /* dir0: 右->左 */
    int x1 = dir==0 ? xl : xr;

    sleep(2);  /* 给 xochitl/udev 发现虚拟设备的时间 */
    for(int i=1;i<=reps;i++){
        do_swipe(ufd,x0,x1,y,14);
        printf("[injector] 第 %d/%d 次滑动 (%s) 已发\n", i, reps, dir==0?"下一页":"上一页");
        fflush(stdout);
        msleep(2500);
    }
    ioctl(ufd,UI_DEV_DESTROY);
    close(ufd); close(src);
    printf("[injector] 结束\n");
    return 0;
}
