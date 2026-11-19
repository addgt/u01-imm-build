#!/usr/bin/env python3
"""host 依赖闸门：在动手编译之前，把「已选中的包里谁会把 Node.js 拖进编译」点名列出来。

为什么要有这一步：Node.js/V8 这颗 host 工具一个就能吃掉整轮预算（GitHub 每个 job 硬顶
6 小时，抬不了）。filebrowser / frpc 这类包在 Makefile 顶层无条件写 PKG_BUILD_DEPENDS :=
node/host，.config 里却只看得到 CONFIG_PACKAGE_node 是 not set，所以从配置上根本发现不了，
只有烧完几个小时才在日志里看见 build_dir/hostpkg/node-vX 还在编。

判据只认「顶层无条件赋值」：写在 ifeq/ifneq/else 里的 PKG_BUILD_DEPENDS 是条件依赖，
那颗子包没选上就不会真拖，所以不算（smartdns 的 node/host 就是这么挂的）。
golang/host 只报不拦：tailscale / mosdns / openclash 都要它，而实测 Go 只要几分钟。

用法：python3 check_host_deps.py <openwrt 目录>
退出：0 通过；1 有 node/host 拖入者或有必炸的包；2 环境不对（.config / feeds 没就位）
"""
import os
import re
import sys

# 一选就必炸的包：不是依赖问题，是源码下载地址本身是死的
DEAD = {
    "openlist2": "Build/Prepare 要解的 openlist-frontend-dist-*.tar.gz 下载 404，编到它必炸",
}

DEP_RE = re.compile(r"^PKG_BUILD_DEPENDS\s*([+:?]?=)\s*(.*)$")
NODE_RE = re.compile(r"(^|[\s/])node/host")
GO_RE = re.compile(r"(^|[\s/])golang/host")
COND_OPEN = re.compile(r"^if(n?eq|def)\b", re.I)
BUILD_PKG = re.compile(r"BuildPackage\s*,\s*([A-Za-z0-9._+-]+)")
PKG_NAME = re.compile(r"^PKG_NAME\s*:?=\s*(\S+)", re.M)


def dep_lines(text):
    """返回顶层（不在 if/ifneq/ifdef 块里）的 PKG_BUILD_DEPENDS 赋值行，续行已拼回。"""
    phys = []
    for ln in text.split("\n"):
        if phys and phys[-1][1]:
            phys[-1] = (phys[-1][0] + ln.rstrip("\r"), ln.endswith("\\"))
            continue
        phys.append((ln.rstrip("\r"), ln.endswith("\\")))
    uncond = []
    depth = 0
    for ln, _ in phys:
        s = ln.strip()
        if COND_OPEN.match(s):
            depth += 1
            continue
        if s.startswith("endif"):
            depth = max(0, depth - 1)
            continue
        m = DEP_RE.match(s)
        if m and depth == 0:
            uncond.append(s)
    return uncond


def scan(root):
    hits, go_hits, n_mk = [], [], 0
    for base in ("package", "feeds"):
        d0 = os.path.join(root, base)
        if not os.path.isdir(d0):
            continue
        for dp, dn, fn in os.walk(d0):
            cut = [x for x in dn if x in ("build_dir", "staging_dir", "ipk") or x.startswith(".")]
            for x in cut:
                dn.remove(x)
            if "Makefile" not in fn:
                continue
            p = os.path.join(dp, "Makefile")
            try:
                text = open(p, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            n_mk += 1
            uncond = dep_lines(text)
            has_node = any(NODE_RE.search(l) for l in uncond)
            has_go = any(GO_RE.search(l) for l in uncond)
            if not (has_node or has_go):
                continue
            syms = set(BUILD_PKG.findall(text))
            m = PKG_NAME.search(text)
            if m:
                syms.add(m.group(1))
            for s in sorted(syms):
                item = (s, p, [l for l in uncond if NODE_RE.search(l) or GO_RE.search(l)][:1])
                (hits if has_node else go_hits).append(item)
    return hits, go_hits, n_mk


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    root = sys.argv[1]
    cfg = os.path.join(root, ".config")
    if not os.path.isfile(cfg):
        print("!! 找不到 %s —— 这一步必须放在 make defconfig 之后" % cfg)
        return 2
    txt = open(cfg, encoding="utf-8", errors="replace").read()
    sel = set(re.findall(r"^CONFIG_PACKAGE_(\S+)=y$", txt, re.M))
    if not sel:
        print("!! .config 里一条 CONFIG_PACKAGE_*=y 都没有")
        return 2
    if not os.path.isdir(os.path.join(root, "feeds")):
        print("!! 没有 feeds/ —— install feeds 之前跑这个没意义")
        return 2

    node_hits, go_hits, n_mk = scan(root)
    bad = [h for h in node_hits if h[0] in sel]
    dead = [s for s in sorted(DEAD) if s in sel]
    print("== host 依赖闸门：扫了 %d 个 Makefile，.config 选中 %d 颗 ==" % (n_mk, len(sel)))
    show = [h for h in go_hits if h[0] in sel]
    if show:
        print("-- 拖进 golang/host 的（只报不拦，实测几分钟）--")
        for s, p, l in show:
            print("   %s <- %s" % (s, p))
    rest = sorted({h[0] for h in node_hits if h[0] not in sel})
    if rest:
        print("-- 顺带记着：树里这些也会拖 node/host，现在没选，以后要加功能前先想到 6 小时 --")
        print("   " + " ".join(rest))
    if bad:
        print("!! 这些【已选中】的包会无条件把 node/host 拖进编译（单颗就能吃掉几小时）：")
        for s, p, l in bad:
            print("   CONFIG_PACKAGE_%s=y  <-  %s" % (s, p))
            print("        %s" % l[0] if l else "")
        print("!! 处理：在 config/wf2.config 里把上面这些连同它们的 luci-app-* / luci-i18n-* 一起关掉，别编")
    if dead:
        print("!! 这些包一选就必炸：")
        for s in dead:
            print("   CONFIG_PACKAGE_%s=y  ——  %s" % (s, DEAD[s]))
    if bad or dead:
        return 1
    print("== 通过：没有 node/host 拖入者；上面 golang 那几颗按历史耗时是可以接受的 ==")
    return 0


if __name__ == "__main__":
    sys.exit(main())
