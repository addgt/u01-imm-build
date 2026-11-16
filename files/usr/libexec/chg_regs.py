#!/usr/bin/env python3
"""PM8916 充电器的只读通道（这版 OpenWrt 内核里没有任何充电驱动，只剩 regmap debugfs）。

内核 6.18 drivers/base/regmap/regmap-debugfs.c 的事实（已核对源码，别再试错）：
  - access  = 0400，DEFINE_SHOW_ATTRIBUTE，只能列出访问表，没有 .write  => 写它必 EINVAL
  - registers = 0400；只有编译时定义 REGMAP_ALLOW_WRITE_DEBUGFS 才 0600 且带 .write，
    这份内核走的是 #else 分支 => 整份 debugfs 只能读，写不了
  - registers 每行定长（reg_len + 2 + 2*val_bytes + 3 字节含 '\n'），
    行首会回显偏移 => 用 seek 定位到 addr*tot 就能只读那一个，不用整片扫

用法（设备侧 root）：
  chg_regs.py probe              认路：有哪些 map、范围、行长、SPMI 绑定、/dev/mem 在不在
  chg_regs.py read ADDR [N]      只读一个（或从这开始的 N 个）寄存器
  chg_regs.py dump START END     连续只读转储（最多 0x100 个，绝不越界）
  chg_regs.py stat               充电相关寄存器逐个点名 + 人话解释
  chg_regs.py check [秒]         刷机后验收：power_supply + IBAT 换算 + dmesg + VSYS 走势

环境变量 CHG_MAP 指定用哪个 regmap（默认 0-00，即 spmi bus0 sid0）。
"""
import glob, os, sys, time

MAXDUMP = 0x100

# PM8916 LBC 偏移（主线 drivers/power/supply/pm8916-lbc.c + CAF qpnp-linear-charger.c）
CHGR = {
    0x1008: ("CHG_OPTION", "bit7=1 才是 PMIC 充电器使能"),
    0x1009: ("CHG_STATUS", "bit7 chg_done/bit6 batt_ok/bit5 chg_not_done"),
    0x1010: ("CHG_INT_RT_STS", "bit0 vbat_lo/bit5 fast_chg/bit6 chg_failed/bit7 chg_done"),
    0x1040: ("VDD_MAX", "(mV-4000)/25，4.20V=0x08"),
    0x1041: ("VDD_SAFE", "同 VDD_MAX 刻度"),
    0x1044: ("IBAT_MAX", "mA/90-1"),
    0x1045: ("IBAT_SAFE", "mA/90-1"),
    0x1047: ("VIN_MIN", "(mV-4200)/27"),
    0x1049: ("CHG_CTRL", "bit7 CHG_ENABLE / bit5 PSTG_EN / bit0 FORCE_BATT_ON"),
    0x104A: ("CHG_FAILED", "bit7 写 1 清除"),
    0x1052: ("VBAT_WEAK", "(uV-3.0V)/18750"),
    0x1060: ("TCHG_MAX_EN", ""),
    0x1061: ("TCHG_MAX", "min/4-1"),
    0x1065: ("CHG_WDOG_EN", ""),
    0x10D0: ("SEC_ACCESS", "写 0xA5 才解锁 0x10DA/0x10EE"),
    0x10EE: ("VBAT_DETECT", "bits1:0=2 强制'低于 VBAT'"),
}
BATIF = {
    0x1208: ("BATT_ST_RDY?", "bit7 电池在位（读的是充电器的判断）"),
    0x1210: ("BAT_IF_RT_STS", "bit0 batt_pres/bit1 temp_ok"),
}
USB = {
    0x1310: ("USB_RT_STS", "bit1 USBIN_VALID（USB 电源在不在）"),
}


def maps():
    return sorted(d for d in glob.glob("/sys/kernel/debug/regmap/*") if os.path.isdir(d))


def pick():
    want = os.environ.get("CHG_MAP")
    ms = maps()
    if not ms:
        raise SystemExit("没有 regmap debugfs（挂载了吗？）")
    if want:
        for m in ms:
            if os.path.basename(m) == want:
                return m
        raise SystemExit("CHG_MAP=%s 不在 %s 里" % (want, [os.path.basename(x) for x in ms]))
    for m in ms:
        if os.path.basename(m) == "0-00":
            return m
    return ms[0]


def layout(m):
    """量一次 registers 的行长：第 0 行就是偏移 0，行文本 + 换行 = tot。"""
    with open(os.path.join(m, "registers"), "rb") as f:
        s = f.read(64).decode("ascii", "replace")
    first = s.splitlines()[0]
    tot = len(first) + 1
    reg_len = first.index(":")
    return reg_len, tot


def _lines(m, addr, n):
    reg_len, tot = layout(m)
    with open(os.path.join(m, "registers"), "rb") as f:
        f.seek(addr * tot)
        s = f.read(n * tot).decode("ascii", "replace")
    out = []
    for ln in s.splitlines():
        head, _, val = ln.partition(":")
        try:
            got = int(head.strip(), 16)
        except ValueError:
            raise SystemExit("行格式没认出来：%r" % ln)
        out.append((got, val.strip()))
    if out and out[0][0] != addr:
        raise SystemExit("定位没对上：想要 0x%x，行首给 0x%x（tot=%d）" % (addr, out[0][0], tot))
    return out


def rd(addr, m=None):
    m = m or pick()
    return _lines(m, addr, 1)[0][1]


def val(v):
    return None if "X" in v.upper() else int(v, 16)


def show(addr, v, table):
    name, note = table.get(addr, ("?", ""))
    n = val(v)
    dec = "" if n is None else "  =0b%s" % format(n, "08b")
    print("0x%04x %-14s %s%s   %s" % (addr, name, v, dec, note))


def dump(m, lo, hi):
    if hi - lo + 1 > MAXDUMP:
        raise SystemExit("一次最多读 %d 个，别贪" % MAXDUMP)
    print("# %s  0x%x-0x%x  逐行 = 偏移: 值" % (os.path.basename(m), lo, hi))
    for got, v in _lines(m, lo, hi - lo + 1):
        print("0x%04x %s" % (got, v))


def stat():
    m = pick()
    reg_len, tot = layout(m)
    print("== map %s (range=%s, 行长 %d)" % (os.path.basename(m),
          open(os.path.join(m, "range")).read().strip() if os.path.exists(os.path.join(m, "range")) else "?", tot))
    for base, tbl in ((CHGR, CHGR), (BATIF, BATIF), (USB, USB)):
        for a in sorted(tbl):
            try:
                show(a, rd(a, m), tbl)
            except Exception as e:
                print("0x%04x 读失败：%s" % (a, e))
    # 充电使能位现场判读
    try:
        c = val(rd(0x1049, m))
        o = val(rd(0x1008, m))
        u = val(rd(0x1310, m))
        f = val(rd(0x1010, m))
        print("--- 判读")
        print("   CHG_CTRL.bit7 使能 = %s" % (None if c is None else (c >> 7) & 1))
        print("   CHG_OPTION.bit7 使能 = %s" % (None if o is None else (o >> 7) & 1))
        print("   USBIN_VALID = %s" % (None if u is None else (u >> 1) & 1))
        print("   CHG_FAILED = %s  CHG_DONE = %s  FAST_CHG = %s" % (
            None if f is None else (f >> 6) & 1,
            None if f is None else (f >> 7) & 1,
            None if f is None else (f >> 5) & 1))
    except Exception as e:
        print("判读失败：%s" % e)


def probe():
    ms = maps()
    print("可用 map：%s" % " ".join(os.path.basename(x) for x in ms))
    for m in ms:
        print("== %s  文件=%s" % (os.path.basename(m), " ".join(sorted(os.listdir(m)))))
        for f in ("name", "range", "access"):
            p = os.path.join(m, f)
            if not os.path.exists(p):
                continue
            st = os.stat(p)
            if f == "access":
                print("   %s mode=%o（0400=只读，源码里没有 .write）" % (f, st.st_mode & 0o777))
                continue
            print("   %s = %s" % (f, open(p).read().strip()[:120]))
        try:
            reg_len, tot = layout(m)
            print("   行长 tot=%d（reg_len=%d）" % (tot, reg_len))
            for a in (0x0004, 0x0005, 0x0006, 0x0007, 0x0008, 0x1008, 0x1049, 0x1310, 0x4008):
                print("   0x%04x -> %s" % (a, rd(a, m)))
        except Exception as e:
            print("   读通道还没通：%s" % e)
    print("== 写通道候选")
    print("   /dev/mem = %s" % ("在" if os.path.exists("/dev/mem") else "没有"))
    for base in ("/sys/bus/spmi/devices", "/sys/bus/spmi/drivers"):
        if os.path.isdir(base):
            for d in sorted(os.listdir(base)):
                p = os.path.join(base, d)
                extra = ""
                for f in ("name", "driver", "of_node"):
                    q = os.path.join(p, f)
                    if os.path.exists(q):
                        extra += " %s=%s" % (f, os.readlink(q) if os.path.islink(q)
                                             else open(q).read().strip())
                print("   %s/%s%s" % (base, d, extra))


def dtb():
    """把 DTB 里跟充电沾边的节点属性原样打出来（文本能读就读，读不通给 hex）。"""
    import fnmatch
    roots = glob.glob("/proc/device-tree/soc@0/spmi@*/pmic@*")
    if not roots:
        print("找不到 spmi/pmic 节点")
        return
    for pm in roots:
        print("== %s" % pm)
        for node in sorted(glob.glob(os.path.join(pm, "*"))):
            if not os.path.isdir(node):
                continue
            tag = os.path.basename(node)
            if not (fnmatch.fnmatch(tag.lower(), "*charg*") or
                    fnmatch.fnmatch(tag.lower(), "*batt*") or
                    fnmatch.fnmatch(tag.lower(), "*usb*")):
                continue
            print("  -- %s" % tag)
            for f in sorted(glob.glob(os.path.join(node, "*"))):
                raw = open(f, "rb").read()
                txt = raw.replace(b"\0", b" ").decode("utf-8", "replace").strip()
                printable = all(32 <= b < 127 or b in (9, 32) for b in raw)
                print("     %-24s %s" % (os.path.basename(f),
                                         txt if printable and txt else raw.hex()))
        for f in sorted(glob.glob(os.path.join(pm, "*"))):
            if os.path.isfile(f):
                raw = open(f, "rb").read()
                txt = raw.replace(b"\0", b" ").decode("utf-8", "replace").strip()
                print("   (直属) %-22s %s" % (os.path.basename(f), txt if txt else raw.hex()))


def adc_mv(label):
    """按 *_label 找 PMIC ADC 通道读 mV（和 batled.py 同一套找法，读不到给 None）。"""
    root = "/sys/bus/iio/devices"
    if not os.path.isdir(root):
        return None
    for d in sorted(os.listdir(root)):
        base = os.path.join(root, d)
        for f in os.listdir(base):
            if not f.endswith("_label"):
                continue
            try:
                if open(os.path.join(base, f)).read().strip() != label:
                    continue
                return int(open(os.path.join(base, f[:-6] + "_input")).read()) // 1000
            except OSError:
                return None
    return None


def check(secs=10):
    """刷机后一条命令验收：驱动起来没、寄存器被抬到多少、电压是涨还是掉。全程只读。"""
    m = pick()
    print("== 1) power_supply")
    ps = "/sys/class/power_supply"
    names = sorted(os.listdir(ps)) if os.path.isdir(ps) else []
    if not names:
        print("   空 => 充电/电量驱动根本没起来（config 或 DTB 注入没进产物）")
    for d in names:
        p = os.path.join(ps, d)
        got = []
        for k in ("type", "online", "status", "health", "voltage_now",
                  "constant_charge_voltage_max_uv_now", "constant_charge_current_max_uv_now"):
            f = os.path.join(p, k)
            if os.path.exists(f):
                try:
                    got.append("%s=%s" % (k, open(f).read().strip()))
                except OSError:
                    pass
        drv = ""
        link = os.path.join(p, "device")
        if os.path.islink(link):
            drv = " <- " + os.path.basename(os.path.realpath(link))
        print("   %s%s\n      %s" % (d, drv, "  ".join(got)))

    print("== 2) 关键寄存器（IBAT 单位换算：mA=(code+1)*90，90mA=复位默认=没人配过）")
    for a, name in ((0x1044, "IBAT_MAX"), (0x1045, "IBAT_SAFE"),
                    (0x1040, "VDD_MAX"), (0x1049, "CHG_CTRL"), (0x1009, "CHG_STATUS")):
        v = val(rd(a, m))
        extra = ""
        if v is not None and a in (0x1044, 0x1045):
            extra = " = %d mA" % ((v + 1) * 90)
        if v is not None and a == 0x1040:
            extra = " = %d mV" % (4000 + v * 25)
        print("   0x%04x %-11s %s%s" % (a, name, rd(a, m), extra))

    print("== 3) 内核说的话")
    try:
        import subprocess
        log = subprocess.run(["dmesg"], capture_output=True, timeout=30).stdout.decode("utf-8", "replace")
        hits = [l for l in log.splitlines()
                if any(k in l.lower() for k in ("pm8916-lbc", "pm8916-bms", "charger@1000",
                                                "usb-detect", "power_supply"))]
        print("\n".join("   " + h for h in hits[-15:]) if hits else "   dmesg 里没有充电相关行")
    except Exception as e:
        print("   dmesg 读不了：%s" % e)

    print("== 4) VSYS 走势（隔 %d 秒两次；涨=在充，掉=还在放电）" % secs)
    a = adc_mv("VSYS")
    time.sleep(secs)
    b = adc_mv("VSYS")
    print("   %s mV -> %s mV  %s" % (a, b, "（读不到 VSYS 通道）" if a is None or b is None else
          ("涨 %d mV ⇒ 真在充" % (b - a) if b > a else "没涨 ⇒ 没在充" if b == a else "掉 %d mV ⇒ 还在放电" % (a - b))))


def main():
    args = sys.argv[1:]
    mode = args[0] if args else "probe"
    if mode == "dtb":
        dtb()
        return
    if mode == "probe":
        probe()
        return
    if mode == "stat":
        stat()
        return
    if mode == "check":
        check(int(args[1]) if len(args) > 1 else 10)
        return
    m = pick()
    if mode == "dump" and len(args) >= 3:
        dump(m, int(args[1], 16), int(args[2], 16))
    elif mode == "read" and len(args) >= 2:
        a = int(args[1], 16)
        n = int(args[2]) if len(args) > 2 else 1
        for got, v in _lines(m, a, min(n, MAXDUMP)):
            print("0x%04x %s" % (got, v))
    else:
        raise SystemExit(__doc__)


main()
