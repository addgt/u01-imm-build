#!/usr/bin/env python3
"""按键守夜：3 分钟没人按按键就把所有灯盖灭。

按键来自 /dev/input/event*，这台机上两个：
  event0 = pm8941_pwrkey（电源键）
  event1 = GPIO Buttons（侧键/WPS 之类）
任何一个出 EV_KEY 且 value!=0（按下）就算"按了按键"，只认按下、不认松开。

分工（避免两个服务抢同一个脚）：
  本服务      gpio73 blue:wlan  = WiFi 灯，并且立/撤牌子 /tmp/leds_dark
  netled      gpio72/71         = 信号灯红/蓝，看到牌子自己灭
  batled      gpio 0/91/1/100   = 电池四格（cdev 常驻占 line，只有它自己能关）
读牌子的人只认 60 秒内刷过心跳的牌子 —— 万一本服务被杀掉，灯会自动回到正常显示，
不会永久黑着。

用法：ledidle.py                 常驻（procd 拉起）
      ledidle.py once            打印现状（开了哪些按键设备、AP 在不在、牌子状态）
      ledidle.py run --idle 20   把等待时间临时改成 20 秒，用来当面验收
"""
import glob, os, select, signal, struct, sys, time

DARK = "/tmp/leds_dark"
LOGF = "/tmp/ledidle.log"
WIFI_LED = "/sys/class/leds/blue:wlan/brightness"
IDLE = 180          # 多少秒没按键就全灭
HEARTBEAT = 20      # 暗态多久刷一次牌子 mtime（读的人按 60 秒判活）
EV_KEY = 1
# aarch64 的 struct input_event = __kernel_ulong_t tv_sec, tv_usec; __u16 type, code; __s32 value
REC = struct.Struct("<QQHHi")


def log(*a):
    line = time.strftime("[%m-%d %H:%M:%S] ") + " ".join(str(x) for x in a)
    try:
        print(line, flush=True)
    except Exception:
        pass
    try:
        with open(LOGF, "a", encoding="utf-8", errors="replace") as f:
            f.write(line + "\n")
    except OSError:
        pass


def ap_up():
    """热点真开着才算 WiFi 灯该亮 —— 直接看 hostapd 进程，不看枚举值。"""
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            with open("/proc/%s/cmdline" % d, "rb") as f:
                cmd = f.read()
        except OSError:
            continue
        if b"hostapd" in cmd:
            return True
    return False


def wifi(on):
    try:
        with open(WIFI_LED, "w") as f:
            f.write("1" if on else "0")
    except OSError as e:
        log("写 WiFi 灯失败", WIFI_LED, e)


def open_devs():
    fds = {}
    for p in sorted(glob.glob("/dev/input/event*")):
        try:
            fds[os.open(p, os.O_RDONLY | os.O_NONBLOCK)] = p
        except OSError as e:
            log("开 %s 失败：%s" % (p, e))
    return fds


def drain(fds):
    """非阻塞把能读到的 input_event 都读干净，返回 [(设备, code, value)]；掉口的设备直接丢弃。"""
    out = []
    if not fds:
        time.sleep(1)
        return out
    try:
        r, _, _ = select.select(list(fds), [], [], 0.5)
    except (OSError, ValueError) as e:
        log("select 出错：%s" % e)
        return out
    for fd in r:
        try:
            data = os.read(fd, 4096)
        except OSError as e:
            log("%s 读失败，丢掉：%s" % (fds.get(fd, "?"), e))
            try:
                os.close(fd)
            except OSError:
                pass
            fds.pop(fd, None)
            continue
        for i in range(len(data) // REC.size):
            _, _, typ, code, val = REC.unpack_from(data, i * REC.size)
            if typ == EV_KEY:
                out.append((fds.get(fd, "?"), code, val))
    return out


def main():
    args = sys.argv[1:]
    mode = args[0] if args and not args[0].startswith("-") else "run"
    idle = int(args[args.index("--idle") + 1]) if "--idle" in args else IDLE

    if mode == "keys":
        fds = open_devs()
        log("抓 %d 秒按键（只报按下）：%s" % (idle, ",".join(sorted(fds.values())) or "无"))
        end = time.time() + idle
        seen = 0
        while time.time() < end:
            for dev, code, val in drain(fds):
                if val:
                    seen += 1
                    log("  按下 dev=%s code=%d" % (dev, code))
        log("抓到 %d 次按下" % seen)
        for fd in list(fds):
            try:
                os.close(fd)
            except OSError:
                pass
        return

    if mode == "once":
        fds = open_devs()
        try:
            age = time.time() - os.path.getmtime(DARK)
            state = "牌子还在（%.0f 秒前刷过）" % age
        except OSError:
            state = "没牌子（正常显示）"
        log("once: 按键设备=%s hostapd=%s %s"
            % (",".join(sorted(fds.values())) or "无", ap_up(), state))
        for fd in fds:
            os.close(fd)
        return

    if mode == "once":
        fds = open_devs()
        try:
            age = time.time() - os.path.getmtime(DARK)
            state = "牌子还在（%.0f 秒前立的）" % age
        except OSError:
            state = "没牌子（正常显示）"
        log("once: 按键设备=%s hostapd=%s %s"
            % (",".join(sorted(fds.values())) or "无", ap_up(), state))
        for fd in fds:
            os.close(fd)
        return

    fds = open_devs()
    log("启动 pid=%d idle=%ds WiFi灯=%s 按键设备=%s"
        % (os.getpid(), idle, WIFI_LED, ",".join(sorted(fds.values())) or "一个都没有"))

    state = {"dark": False, "last": time.time(), "hb": 0.0, "scan": 0.0}

    def go_dark():
        try:
            with open(DARK, "w") as f:
                f.write("dark pid=%d t=%d\n" % (os.getpid(), int(state["last"])))
        except OSError as e:
            log("立牌子失败", e)
        wifi(0)
        state["dark"], state["hb"] = True, time.time()
        log("%d 秒没按键：WiFi 灯灭、牌子立好，信号灯和四格由 netled/batled 自己关" % idle)

    def wake():
        try:
            os.remove(DARK)
        except OSError:
            pass
        on = ap_up()
        wifi(on)
        now = time.time()
        state.update(dark=False, last=now, hb=0.0)
        log("按键到了：撤牌子，WiFi 灯%s（信号灯/四格各自恢复）" % ("亮" if on else "灭"))

    def bye(signum, frame):
        if state["dark"]:
            try:
                os.remove(DARK)
            except OSError:
                pass
            wifi(ap_up())
        log("收到信号 %d，收摊退出" % signum)
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, bye)
    signal.signal(signal.SIGINT, bye)

    while True:
        now = time.time()
        if now - state["scan"] > 5 and not fds:
            state["scan"] = now
            fds = open_devs()
            if fds:
                log("补上按键设备：%s" % ",".join(sorted(fds.values())))
        for dev, code, val in drain(fds):
            if not val:
                continue
            if state["dark"]:
                log("按键 dev=%s code=%d -> 全回来" % (dev, code))
                wake()
            else:
                state["last"] = time.time()

        if not state["dark"]:
            if time.time() - state["last"] >= idle:
                go_dark()
        elif time.time() - state["hb"] >= HEARTBEAT:
            try:
                os.utime(DARK, None)
            except OSError as e:
                log("刷牌子心跳失败：%s" % e)
            state["hb"] = time.time()
            wifi(0)


main()
