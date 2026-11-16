#!/usr/bin/env python3
"""U01 读卡常驻：开机按配置把 SIM 选择脚拉成"卡槽"或"内置卡"那一档并一直占住，
卡读不出来就重启一次 MPSS 让 modem 重新给卡上电。

为什么必须常驻：这台 WF2 的 DTB 把 sim_en/sel 指向了错误的控制器和脚位，内核侧不会驱动；
而 /sys/class/gpio 没开，只能用 cdev ABI v2 申请 line —— line 的持有者一退出脚就掉回默认电平，
所以要做成常驻进程（跟 batled 一个套路）。

脚位用的是原厂安卓 DTB 里 /soc/gpio_leds 那组（SimSwitchThread 写的就是它们）：
  gpio119 = esim1_en = 托盘卡槽，gpio14 = esim2_en = 原机内置卡。两根互斥，只拉高要读的那根。
（旧版用的 gpio49 实测对选卡没有作用，已去掉。）

卡位切换：/etc/u01sim.conf 里写 sim_slot=0（只读卡槽）或 sim_slot=1（内置卡），改完 restart。
只保证"读卡"这一件事：不置 CFUN=1、不拨号。
"""
import ctypes, os, select, struct, subprocess, sys, time

CONF = "/etc/u01sim.conf"
DEFAULT_SLOT = 1
PIN_TRAY = 119      # esim1_en -> slot 0
PIN_BUILTIN = 14    # esim2_en -> slot 1
PINS = [PIN_TRAY, PIN_BUILTIN]
SLOT_LEVELS = {0: [1, 0], 1: [0, 1]}
QMI_DEV = "/dev/wwan0qmi0"
CHIP_LABEL = "u01sim"
MAGIC = 0xB4
SZ_CHIPINFO, SZ_REQ, SZ_VALUES = 68, 592, 16
IOC_CHIPINFO = (2 << 30) | (SZ_CHIPINFO << 16) | (MAGIC << 8) | 0x01
IOC_GET_LINE = (3 << 30) | (SZ_REQ << 16) | (MAGIC << 8) | 0x07
IOC_SET_VALUES = (3 << 30) | (SZ_VALUES << 16) | (MAGIC << 8) | 0x0F
FLAG_OUTPUT = 1 << 3
OFF_CONF_FLAGS, OFF_NUM_LINES, OFF_FD = 288, 560, 588
RPROC = "/sys/class/remoteproc/remoteproc0/state"
ATDEV = "/dev/wwan0at0"
libc = ctypes.CDLL("libc.so.6", use_errno=True)


def log(*a):
    line = " ".join(str(x) for x in a)
    print(time.strftime("[%m-%d %H:%M:%S]"), line, flush=True)
    try:
        with open("/tmp/u01sim.log", "a") as f:
            f.write(time.strftime("[%m-%d %H:%M:%S] ") + line + "\n")
    except OSError:
        pass


def ioctl(fd, num, buf):
    return libc.ioctl(fd, ctypes.c_ulong(num), buf)


def chips():
    out = []
    for n in range(8):
        p = "/dev/gpiochip%d" % n
        if not os.path.exists(p):
            continue
        fd = os.open(p, os.O_RDWR | os.O_CLOEXEC)
        buf = ctypes.create_string_buffer(SZ_CHIPINFO)
        if ioctl(fd, IOC_CHIPINFO, buf) < 0:
            os.close(fd)
            continue
        name, label, lines = struct.unpack("32s32sI", buf.raw[:72])
        out.append((fd, p, name.rstrip(b"\0").decode(), lines))
    return out


def read_conf():
    slot = DEFAULT_SLOT
    if os.path.exists(CONF):
        for line in open(CONF):
            line = line.strip()
            if line.startswith("sim_slot"):
                try:
                    slot = int(line.split("=")[1].strip()) & 1
                except Exception:
                    pass
    return slot


def reenumerate():
    """换档后让 modem 重新给 UIM 上电，否则它还会报旧那张卡。"""
    for op in ("--uim-sim-power-off=1", "--uim-sim-power-on=1"):
        try:
            subprocess.run(["qmicli", "-d", QMI_DEV, op], timeout=20,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception as e:
            log("%s 没跑成: %s" % (op, e))
        time.sleep(1)


def hold(slot):
    """返回 (chipfd, linefd)；linefd 不关，脚就一直保持。119=托盘卡槽电源，14=内置卡电源。"""
    pins = PINS
    vals = SLOT_LEVELS[slot]
    bits = 0
    for i, v in enumerate(vals):
        if v:
            bits |= 1 << i
    cs = [c for c in chips() if c[3] > max(pins)]
    if not cs:
        raise SystemExit("没有能覆盖 gpio%d 的 chip" % max(pins))
    c = max(cs, key=lambda x: x[3])
    buf = ctypes.create_string_buffer(SZ_REQ)
    struct.pack_into("%dI" % len(pins), buf, 0, *pins)
    buf[256:288] = CHIP_LABEL.encode().ljust(32, b"\0")
    struct.pack_into("Q", buf, OFF_CONF_FLAGS, FLAG_OUTPUT)
    struct.pack_into("I", buf, OFF_NUM_LINES, len(pins))
    if ioctl(c[0], IOC_GET_LINE, buf) < 0:
        raise SystemExit("GET_LINE 失败: %s" % os.strerror(ctypes.get_errno()))
    lfd = struct.unpack_from("i", buf, OFF_FD)[0]
    mask = (1 << len(pins)) - 1
    if ioctl(lfd, IOC_SET_VALUES, ctypes.create_string_buffer(struct.pack("QQ", bits, mask))) < 0:
        raise SystemExit("SET_VALUES 失败: %s" % os.strerror(ctypes.get_errno()))
    log("gpio%d(卡槽)=%d gpio%d(内置卡)=%d  chip=%s %s (%d lines)"
        % (PIN_TRAY, vals[0], PIN_BUILTIN, vals[1], c[2], c[1], c[3]))
    return c[0], lfd


def rproc(op):
    fd = os.open(RPROC, os.O_WRONLY)
    os.write(fd, op.encode())
    os.close(fd)


def at_once(cmd, wait=3.0):
    """发一条 AT。返回 None=口被占/无应答（不算失败），否则返回应答文本。"""
    if not os.path.exists(ATDEV):
        return None
    try:
        fd = os.open(ATDEV, os.O_RDWR)
    except OSError:
        return None
    buf = b""
    try:
        os.write(fd, (cmd + "\r\n").encode())
        deadline = time.time() + wait
        while time.time() < deadline:
            r, _, _ = select.select([fd], [], [], 0.2)
            if r:
                d = os.read(fd, 4096)
                if not d:
                    break
                buf += d
                if b"OK" in buf or b"ERROR" in buf:
                    break
    except OSError:
        pass
    finally:
        os.close(fd)
    txt = buf.decode("utf-8", "replace").replace("\r", " ").strip()
    return txt or None


def wait_ready(sec):
    """轮询 AT+CPIN?。READY 返回 True；只有 modem 明确回了"卡不在/未初始化"才返回 False。
    AT 口没应答（多半被 ModemManager/sigmo 占着）时不判失败，一直等到超时。"""
    end = time.time() + sec
    while time.time() < end:
        txt = at_once("AT+CPIN?")
        if txt is None:
            time.sleep(3)
            continue
        if "READY" in txt:
            return True
        if "ERROR" in txt or "SIM" in txt:
            log("CPIN 明确不可用: %s" % txt[:80])
            return False
        log("CPIN 还没好: %s" % txt[:80])
        time.sleep(3)
    log("等 %ds 没有明确结果（多半是 AT 口被占用），不折腾 MPSS" % sec)
    return None


def main():
    for _ in range(60):
        if os.path.exists(RPROC) and os.path.exists("/dev/gpiochip0"):
            break
        time.sleep(2)
    else:
        raise SystemExit("等不到 remoteproc0/gpiochip0")
    slot = read_conf()
    for i, a in enumerate(sys.argv):
        if a == "--slot":
            slot = int(sys.argv[i + 1]) & 1
    log("档位: sim_slot=%d (%s)" % (slot, "只读卡槽" if slot == 0 else "内置卡"))
    cfd, lfd = hold(slot)
    if "--switch" in sys.argv:
        log("切档：先放掉旧 line 再重新上电")
        os.close(lfd)
        os.close(cfd)
        time.sleep(1)
        cfd, lfd = hold(slot)
    reenumerate()
    if "--once" in sys.argv:
        log("结果: %s" % at_once("AT+CPIN?", 6))
        return

    restarts = 0
    last = None
    while True:
        r = wait_ready(20 if restarts == 0 else 10)
        if r != last:
            log("状态 -> %s" % {True: "读卡正常", False: "读卡失败", None: "AT 口没结果"}[r])
            last = r
        if r is True:
            restarts = 0
        elif r is None:
            pass                      # AT 口被占，什么都不做，下轮再看
        elif restarts < 3:
            restarts += 1
            log("卡明确不可用，第 %d 次重启 MPSS 重新给卡上电" % restarts)
            rproc("stop")
            time.sleep(4)
            rproc("start")
            time.sleep(12)
        else:
            log("三次重启都读不出，只保持脚位")
            restarts = 0              # 再等一轮，别彻底放弃
        time.sleep(30)


main()
