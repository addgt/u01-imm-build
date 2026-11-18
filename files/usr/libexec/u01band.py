#!/usr/bin/env python3
# 频段锁：把 modem 只允许驻留在指定 LTE 频段，掉电/重启后自动重下发。
# 配置 /etc/u01band.conf：  lte=8   （单个频段号；留空或删掉＝不改，保持全开）
import os
import re
import subprocess
import time

CONF = "/etc/u01band.conf"
LOG = "/tmp/u01band.log"
QMI_DEV = "/dev/wwan0qmi0"
POLL = 30


def log(line):
    stamp = time.strftime("%H:%M:%S")
    try:
        with open(LOG, "a", encoding="utf-8", errors="replace") as fh:
            fh.write("%s %s\n" % (stamp, line))
    except Exception:
        pass
    try:
        print("%s %s" % (stamp, line), flush=True)
    except Exception:
        pass


def run(args, timeout=30):
    try:
        p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           timeout=timeout)
        return p.returncode, p.stdout.decode("utf-8", "replace")
    except Exception as exc:
        return -1, str(exc)


def read_conf():
    want = None
    if not os.path.exists(CONF):
        return None
    for raw in open(CONF, encoding="utf-8", errors="replace"):
        m = re.match(r"\s*lte\s*=\s*([0-9]+)", raw)
        if m:
            want = int(m.group(1))
    return want


def modem_index():
    rc, out = run(["mmcli", "-L"])
    if rc != 0:
        return None
    m = re.search(r"/Modem/(\d+)", out)
    return m.group(1) if m else None


def current_lte_bands():
    rc, out = run(["qmicli", "-p", "-d", QMI_DEV,
                   "--nas-get-system-selection-preference"])
    if rc != 0:
        return None
    m = re.search(r"LTE band preference:\s*'([^']*)'", out)
    if not m:
        return None
    return [int(x) for x in re.findall(r"\d+", m.group(1))]


def apply_band(idx, band):
    rc, out = run(["mmcli", "-m", idx, "--set-current-bands=eutran-%d" % band])
    return rc == 0, out.strip().splitlines()[-1:] and out.strip().splitlines()[0]


def main():
    # 这里绝不能一"没配频段"就 return：etc/init.d/u01band 用的是
    # respawn 3600 5 0（间隔 5 秒、次数不限），进程一退出 procd 就再 fork 一次，
    # 于是开机起每 5 秒白起一个 python、同一句话刷满 /tmp/u01band.log。
    # 改成常驻轮询还有个附带好处：改了 conf 不用 restart 服务就能跟上。
    # 默认 conf 是注释掉的（不锁），所以后台 mmconfig 那页锁频段时这里不会抢着下发；
    # 只有你手写 lte= 之后才由本服务负责"重启后重下发"。
    last = "init"
    while True:
        band = read_conf()
        if band is None:
            if last != "none":
                log("配置里没有 lte= ，不改频段（保持全开）")
                last = "none"
            time.sleep(POLL)
            continue
        if last != band:
            log("目标：只允许 LTE B%d" % band)
            last = band
        idx = modem_index()
        if idx is None:
            log("还没认到 modem，%d 秒后重试" % POLL)
            time.sleep(POLL)
            continue
        now = current_lte_bands()
        if now == [band]:
            time.sleep(POLL)
            continue
        ok, msg = apply_band(idx, band)
        after = current_lte_bands()
        log("下发 %s，回读 %s" % ("成功" if ok else "失败", after))
        if not ok:
            log("mmcli 原文：%s" % msg)
        time.sleep(POLL)


if __name__ == "__main__":
    main()
