#!/usr/bin/env python3
"""U01 信号灯：有网络亮蓝，没网络亮红。

脚位是这台机壳上一步步点名点出来的（他肉眼确认）：
  gpio72 = class red:power   = 信号灯红
  gpio71 = class green:wan   = 信号灯蓝  ← 类别名叫 green 但肉眼是蓝，别看名字
  gpio73 = class blue:wlan   = WiFi 灯（另一个孔，归 ledidle 管，这里不碰）
class 已经占住脚位，直接写 brightness 就行，不像 u01sim/batled 那样要 cdev 常驻占 line。

"有网络"的判据用真实通路，不看枚举值：
  1) /proc 里有走 wwan0 的默认路由；
  2) 能 ping 通公网（两个探测地址轮流，连续两次不通才算断）。
红/蓝只在状态变化时写一次，避免一直刷 sysfs。

另外认 /tmp/leds_dark 这块牌子（ledidle 立的）：牌子在＝超过 3 分钟没按按键，
信号灯一律灭；牌子撤掉后 0.5 秒内回到该显示的颜色。

用法：netled.py            常驻（procd 拉起）
      netled.py once       判一次、写一次灯，然后退出
      netled.py test       红 3 秒 -> 蓝 3 秒，肉眼确认脚位对应哪个颜色
"""
import os, re, subprocess, sys, time

RED = "/sys/class/leds/red:power/brightness"
BLUE = "/sys/class/leds/green:wan/brightness"
CONF = "/etc/netled.conf"
LOGF = "/tmp/netled.log"
DARK = "/tmp/leds_dark"
DARK_FRESH = 60   # 牌子 60 秒内没被 ledidle 刷过就当它死了，正常显示
PING_HOSTS = ["223.5.5.5", "114.114.114.114"]
POLL = 3          # 路由多久看一次
PING_EVERY = 10   # 有路由时多久 ping 一次
PING_FAIL_MAX = 2 # 连掉这么多次才算"没网络"
DATA_IFACE = "wwan0"


def log(*a):
    line = time.strftime("[%m-%d %H:%M:%S] ") + " ".join(str(x) for x in a)
    print(line, flush=True)
    try:
        with open(LOGF, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def conf():
    iface, hosts = DATA_IFACE, list(PING_HOSTS)
    if os.path.exists(CONF):
        for ln in open(CONF, encoding="utf-8", errors="replace"):
            ln = ln.strip()
            if ln.startswith("iface"):
                iface = ln.split("=", 1)[1].strip() if "=" in ln else iface
            elif ln.startswith("hosts"):
                hosts = [h for h in re.split(r"[,\s]+", ln.split("=", 1)[1]) if h]
    return iface, hosts


def route_up(iface):
    try:
        out = subprocess.run(["ip", "route", "show", "default"], capture_output=True, timeout=5)
        return ("dev %s" % iface) in out.stdout.decode("utf-8", "replace")
    except Exception:
        return False


def ping_ok(hosts):
    for h in hosts:
        try:
            r = subprocess.run(["ping", "-c", "1", "-W", "2", h], capture_output=True, timeout=6)
            if r.returncode == 0:
                return True
        except Exception:
            pass
    return False


def set_led(path, val):
    try:
        with open(path, "w") as f:
            f.write("1" if val else "0")
        return True
    except OSError as e:
        log("写灯失败", path, e)
        return False


def apply(on_line):
    """on_line=True：蓝（有网络）；False：红（没网络）"""
    set_led(BLUE, on_line)
    set_led(RED, not on_line)


def is_dark():
    """ledidle 立着牌子且还在刷心跳 = 现在该全灭。"""
    try:
        return time.time() - os.path.getmtime(DARK) < DARK_FRESH
    except OSError:
        return False


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "run"
    iface, hosts = conf()
    for p in (RED, BLUE):
        if not os.path.exists(p):
            raise SystemExit("找不到 %s，DTB 的 leds 节点没起来" % p)

    if mode == "test":
        log("自检：红灯 3 秒")
        set_led(BLUE, 0); set_led(RED, 1); time.sleep(3)
        log("自检：蓝灯 3 秒")
        set_led(RED, 0); set_led(BLUE, 1); time.sleep(3)
        log("自检结束")
        return

    if mode == "once":
        if is_dark():
            log("once: 牌子在，先不判")
            set_led(BLUE, 0); set_led(RED, 0)
            return
        up = route_up(iface) and ping_ok(hosts)
        log("once: 路由=%s -> %s" % (up, "蓝" if up else "红"))
        apply(up)
        return

    log("启动 iface=%s hosts=%s 蓝=%s 红=%s" % (iface, ",".join(hosts), BLUE, RED))
    online = None
    applied = None
    last_ping = 0.0
    fails = 0
    while True:
        if is_dark():
            if applied != "dark":
                set_led(BLUE, 0); set_led(RED, 0)
                applied = "dark"
                log("牌子在（3 分钟没按键）：信号灯灭")
            time.sleep(0.5)
            continue
        if applied == "dark":
            applied = None      # 刚按键亮回来，逼它重写一次
        if route_up(iface):
            if online is None or time.time() - last_ping >= PING_EVERY:
                last_ping = time.time()
                if ping_ok(hosts):
                    fails, online_new = 0, True
                else:
                    fails += 1
                    online_new = False if fails >= PING_FAIL_MAX else online
            else:
                online_new = online
        else:
            fails, online_new = PING_FAIL_MAX, False
        want = "blue" if online_new else "red"
        if online_new != online:
            log("判据 %s -> %s（ping 连掉 %d 次）"
                % ({None: "?", True: "蓝", False: "红"}[online],
                   {True: "蓝", False: "红"}[online_new], fails))
            online = online_new
        if want != applied:
            apply(online)
            applied = want
        time.sleep(POLL)


main()
