#!/usr/bin/env python3
"""U01 battery-bar LEDs driven straight from the GPIO cdev (ABI v2).

The running ImmortalWrt build has no battery driver and no bat:x LED nodes, but
/dev/gpiochip* is there with CONFIG_GPIO_CDEV=y, so the four production battery
bars (gpio 0 / 91 / 1 / 100, taken from the stock DTB) can be driven from user
space and refilled from the PM8916 VADC VSYS channel.

Layouts and ioctl numbers are read off include/uapi/linux/gpio.h at tag v6.18:
magic 0xB4, gpiochip_info = 68 bytes (no base field), gpio_v2_line_request = 592.
"""
import ctypes, os, struct, sys, time

BAR_PINS = [0, 91, 1, 100]              # bar1..bar4, stock-DTB order
POLL = 15                               # seconds between reads
MV = [(4050, 4), (3850, 3), (3650, 2), (3400, 1)]
HYST = 40                               # 升档要再多涨这么多 mV，防阈值附近跳格
USBIN_MIN = 4000                        # USBIN 高于此值算插着电（只用于日志）
INVERT = 0                              # set 1 if a bar lights when driven low
LOG_PATH = "/tmp/batled.log"
DARK = "/tmp/leds_dark"                 # ledidle 立的牌子：3 分钟没按按键，全灭
DARK_FRESH = 60                         # 牌子 60 秒没被刷过就当 ledidle 死了

MAGIC = 0xB4
SZ_CHIPINFO, SZ_REQ, SZ_VALUES = 68, 592, 16
IOC_CHIPINFO = (2 << 30) | (SZ_CHIPINFO << 16) | (MAGIC << 8) | 0x01
IOC_GET_LINE = (3 << 30) | (SZ_REQ << 16) | (MAGIC << 8) | 0x07
IOC_SET_VALUES = (3 << 30) | (SZ_VALUES << 16) | (MAGIC << 8) | 0x0F
FLAG_ACTIVE_LOW, FLAG_OUTPUT = 1 << 1, 1 << 3
OFF_CONF_FLAGS, OFF_NUM_LINES, OFF_FD = 288, 560, 588

libc = ctypes.CDLL("libc.so.6", use_errno=True)


def _ioctl(fd, num, buf):
    return libc.ioctl(fd, ctypes.c_ulong(num), buf)


def chips():
    out = []
    for n in range(8):
        path = "/dev/gpiochip%d" % n
        if not os.path.exists(path):
            continue
        fd = os.open(path, os.O_RDWR | os.O_CLOEXEC)
        buf = ctypes.create_string_buffer(SZ_CHIPINFO)
        if _ioctl(fd, IOC_CHIPINFO, buf) < 0:
            os.close(fd)
            continue
        name, label, lines = struct.unpack("32s32sI", buf.raw)
        out.append((fd, path, name.rstrip(b"\0").decode(), label.rstrip(b"\0").decode(), lines))
    return out


def chip_for(pin):
    best = None
    for c in chips():
        if c[4] > pin and (best is None or c[4] > best[4]):
            best = c
    return best


class Bars:
    def __init__(self):
        c = chip_for(max(BAR_PINS))
        if not c:
            raise SystemExit("no gpiochip covers gpio %d (seen: %s)"
                             % (max(BAR_PINS), [(x[2], x[4]) for x in chips()]))
        self.cfd, self.path, self.chip, self.label, self.lines = c
        self.buf = ctypes.create_string_buffer(SZ_REQ)
        struct.pack_into("4I", self.buf, 0, *BAR_PINS)
        self.buf[256:288] = b"batled".ljust(32, b"\0")
        struct.pack_into("Q", self.buf, OFF_CONF_FLAGS, FLAG_OUTPUT)
        struct.pack_into("I", self.buf, OFF_NUM_LINES, len(BAR_PINS))
        if _ioctl(self.cfd, IOC_GET_LINE, self.buf) < 0:
            raise SystemExit("GPIO_V2_GET_LINE failed: %s" % os.strerror(ctypes.get_errno()))
        self.fd = struct.unpack_from("i", self.buf, OFF_FD)[0]
        if self.fd < 0:
            raise SystemExit("kernel returned fd %d" % self.fd)

    def show(self, n):
        on = [1 if i <= n else 0 for i in range(1, 5)]
        bits = 0
        for i, v in enumerate(on):
            if v ^ INVERT:
                bits |= 1 << i
        rc = _ioctl(self.fd, IOC_SET_VALUES,
                    ctypes.create_string_buffer(struct.pack("QQ", bits, (1 << 4) - 1)))
        if rc < 0:
            raise SystemExit("SET_VALUES failed: %s" % os.strerror(ctypes.get_errno()))
        return on

    def close(self):
        os.close(self.fd)


def adc_mv(label):
    """按 *_label 找 PMIC ADC 通道并读回 mV；读不到返回 None（不猜）。"""
    root = "/sys/bus/iio/devices"
    if not os.path.isdir(root):
        return None
    for d in sorted(os.listdir(root)):
        base = os.path.join(root, d)
        for f in os.listdir(base):
            if f.endswith("_label"):
                try:
                    if open(os.path.join(base, f)).read().strip() != label:
                        continue
                except OSError:
                    continue
                try:
                    return int(open(os.path.join(base, f[:-6] + "_input")).read()) // 1000
                except Exception:
                    return None
    return None


def vsys_mv():
    return adc_mv("VSYS")


def bars_from_mv(mv, cur=None):
    """电压 -> 格数。读不到电压就全灭（宁可没指示，也别给一个假满格）。

    cur=None 表示"还不知道上一档"（刚开机、或刚按键亮回来），这时不加迟滞：
    迟滞是防止已经显示的格数在阈值附近来回跳，不是用来阻止第一格亮起来。
    """
    if mv is None:
        return 0
    lvl = 0
    for thresh, n in MV:
        if mv >= thresh:
            lvl = n
            break
    if cur is not None and lvl > cur:
        need = dict((n, t) for t, n in MV).get(lvl)
        if need is not None and mv < need + HYST:
            lvl = cur
    return lvl


def log(msg):
    line = time.strftime("[%m-%d %H:%M:%S] ") + msg
    try:
        print(line, flush=True)
    except Exception:
        pass
    try:
        with open(LOG_PATH, "a", encoding="utf-8", errors="replace") as f:
            f.write(line + "\n")
    except Exception as e:
        try:
            with open("/tmp/batled.err", "a") as f:
                f.write("log() 写 %s 失败: %s %s\n" % (LOG_PATH, type(e).__name__, e))
        except Exception:
            pass


def is_dark():
    try:
        return time.time() - os.path.getmtime(DARK) < DARK_FRESH
    except OSError:
        return False


def main():
    b = Bars()
    print("chip=%s label=%s (%s, %d lines) pins=%s INVERT=%d"
          % (b.chip, b.label, b.path, b.lines, BAR_PINS, INVERT))
    log("启动 pid=%d 阈值=%s 迟滞=%d" % (os.getpid(), MV, HYST))
    if "--test" in sys.argv:
        for n in range(5):
            print("  bars=%d driven=%s" % (n, b.show(n)))
            time.sleep(1.2)
        mv = vsys_mv()
        print("VSYS=%s mV -> %d bars" % (mv, bars_from_mv(mv)))
        b.close()
        return
    cur = -1
    while True:
        if is_dark():
            if cur != -2:
                b.show(0)
                cur = -2
                log("牌子在（3 分钟没按键）：四格灭")
            time.sleep(0.5)
            continue
        if cur == -2:
            cur = -1          # 刚按键亮回来，重判一次
        mv = vsys_mv()
        usb = adc_mv("USBIN")
        n = bars_from_mv(mv, cur if cur >= 0 else None)
        if n != cur:
            log("VSYS=%s mV USBIN=%s mV(%s) -> %d 格"
                % (mv, usb, "插电" if (usb or 0) >= USBIN_MIN else "电池", n))
            cur = n
        b.show(cur)
        time.sleep(POLL)


main()
