#!/usr/bin/env python3
"""Go 包预检：在主编译之前单独把选中的 Go 包编一遍，失败就地自愈或剔除，别让它拖到 3 小时后。

为什么要有这一步：第 14 跑整轮 235 分钟里，前 202 分钟全白烧，最后死在
librespeed-go / ddns-go 两颗 Go 附加包上——日志是
`service_openrc_linux.go:107:17: s.execPath undefined (type *openrc has no field or method execPath)`，
同一个错误在 openrc/procd/rcs/systemd/sysv/upstart 六个文件上都出现一次。这不是源码问题：第 13 跑成功的
镜像清单里这两颗版本一模一样（ddns-go 6.17.8-r1 / librespeed-go 1.1.5-r5），而且 execPath 是 v1.3.0
里 systemd 结构体的字段、六个文件全靠内嵌它取路径——只有【模块缓存里同一版本被混进了两份不同内容】才会这样。
那颗模块就在 dl/go-mod-cache 里，而 dl 是用 actions/cache + restore-keys 跨跑复用的，
所以坏缓存会被每一跑继承下去，光重跑没用。

于是这里做两件事：
  1) 只编 Go 包（-k 一把过），失败先按"缓存脏了"处理：删 dl/go-mod-cache 再单包重编一次。
     能过就一颗功能都不少，只是多花几分钟。
  2) 清完缓存还编不过的，才真是包本身的问题：只允许剔 package/feeds/ 下的，连同依赖它的
     luci-app-*/luci-i18n-* 一起剔，剔完 make defconfig 复验没被依赖拉回来。
     核心包（不在 feeds 下）、剔超过 12 颗、或被拉回 → 判红停手，因为那时候产物已经没意义了。

预检自己没跑成（make 用法错、目录不对、一颗 Go 包都没选中）一律 exit 2 让 workflow 继续，
不能因为这道保险丝自己断了就把 4 小时掐掉。

用法：python3 go_preflight.py <openwrt 目录>
退出：0 通过或已安全剔除；1 判红（值得为它停一轮）；2 预检没跑成，按老样子直接编

⚠️ 第 16 跑就是死在这一步的判读上：预检在 T+32 分钟直接编 Go 包，make 顺带把
package/libs/toolchain 拉进来编，而那会儿 staging_dir/toolchain-*/lib/libgcc_s.so.* 根本还不存在
（cp: cannot stat ... ⇒ Error 1）。它不是"核心包编不过"，是【工具链还没装】这个先后顺序问题，
可当时按包名一判就成了红，整轮 32 分钟白烧，912 那颗补丁也跟着没产出。所以这里改成：
先把交叉工具链按上游自己的顺序装好（make toolchain/install —— 这个目标不是我编的，
include/toplevel.mk 里 `prepare_kernel_conf: .config toolchain/install FORCE` 就依赖它），
再编 Go 包；并且只有"挂在预检对象自己身上"才允许判红，挂在依赖包上一律 exit 2 让路。
"""
import os
import re
import shlex
import shutil
import subprocess
import sys

JOBS = os.environ.get("U01_JOBS") or str(os.cpu_count() or 4)
MAKE = shlex.split(os.environ.get("U01_MAKE") or "make")
FEAT_MAX_DROP = 12
# 交叉工具链的预装目标。上游 include/toplevel.mk:155 那行 prepare_kernel_conf 就依赖它，
# toolchain/Makefile 里 $(curdir)/install: $(curdir)/compile —— 不是我自己编出来的名字；
# 装完 staging_dir/toolchain-*/lib/libgcc_s.so.* 才有东西可 cp。
TOOLCHAIN_PRE = "toolchain/install"
GO_MARK = re.compile(r"GO_PKG\s*:?=|golang-package\.mk|\$\(call GoBinary")
# feed 里 Go 包的真写法是 GO_PKG:=… + include ../../lang/golang/golang-package.mk（第 15 跑就是
# 被这一条教的：只认 $(call GoBinary 会扫到 0 颗，预检变成空跑）。wf2 自带那些包用 GoBinary。
BUILD_PKG = re.compile(r"BuildPackage\s*,\s*([A-Za-z0-9._+-]+)")
PKG_NAME = re.compile(r"^PKG_NAME\s*:?=\s*(\S+)", re.M)
DEPENDS = re.compile(r"^[ \t]*(?:PKG_)?DEPENDS\s*([+:?]?=)\s*(.*)$", re.M)
ERR_DIR = re.compile(r"ERROR:\s+(package/\S+)\s+failed to build")
CUT = ("build_dir", "staging_dir", "ipk", ".git", "logs", "tmp", "bin")


def read(p):
    try:
        return open(p, encoding="utf-8", errors="replace").read()
    except OSError:
        return ""


def selected(cfg_text):
    return set(re.findall(r"^CONFIG_PACKAGE_(\S+)=y$", cfg_text, re.M))


def mklist(root, sub):
    """root/sub 下所有 Makefile → (相对目录, [包名]) ；sub 用来把扫描范围限制住。"""
    out, n = [], 0
    base = os.path.join(root, sub)
    if not os.path.isdir(base):
        return out
    for dp, dn, fn in os.walk(base, followlinks=True):
        dn[:] = [x for x in dn if x not in CUT and not x.startswith(".")]
        if "Makefile" not in fn:
            continue
        n += 1
        text = read(os.path.join(dp, "Makefile"))
        rel = os.path.relpath(dp, root).replace(os.sep, "/")
        syms = set(BUILD_PKG.findall(text))
        m = PKG_NAME.search(text)
        if m:
            syms.add(m.group(1))
        out.append((rel, syms, text))
    return out


def go_targets(root):
    """树里用 Go 打包、且 .config 选中的包目录。"""
    sel = selected(read(os.path.join(root, ".config")))
    hits = [(rel, syms) for rel, syms, text in mklist(root, "package")
            if GO_MARK.search(text) and (syms & sel)]
    return sorted(hits), sel


def run(cmd, cwd, log):
    """跑一条命令，输出直接落进 log（不经过内存），返回 (退出码, 这段输出在 log 里的起点)。"""
    off = os.path.getsize(log) if os.path.exists(log) else 0
    with open(log, "a", encoding="utf-8", errors="replace") as f:
        f.write("\n$ %s\n" % " ".join(cmd))
        f.flush()
        p = subprocess.Popen(cmd, cwd=cwd, stdout=f, stderr=subprocess.STDOUT)
        rc = p.wait()
        f.flush()
    return rc, off


def drop(cfg_path, syms):
    """把这几颗从 .config 上摘掉（写成 not set），返回真正改动过的行号数。"""
    txt = read(cfg_path)
    gone = []
    lines = []
    for ln in txt.split("\n"):
        m = re.match(r"^CONFIG_PACKAGE_(\S+)=", ln)
        if m and m.group(1) in syms and ln.rstrip().endswith(("=y", "=m")):
            gone.append(m.group(1))
            lines.append("# CONFIG_PACKAGE_%s is not set" % m.group(1))
            continue
        lines.append(ln)
    if gone:
        with open(cfg_path, "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(lines))
    return gone


def dependents(entries, syms):
    """feed 树里 DEPENDS 提到这几颗的包（luci-app-* / luci-i18n-* 之类）。"""
    pat = re.compile(r"(^|[\s,+])(" + "|".join(re.escape(s) for s in sorted(syms)) + r")($|[\s,+-])")
    out = set()
    for rel, ss, text in entries:
        if not rel.startswith("package/feeds/"):
            continue
        for _op, val in DEPENDS.findall(text):
            if pat.search(val.replace("\\", " ")):
                out |= ss
                break
    return out - syms


def tail(text, n=25):
    return "\n".join("      " + l for l in text.splitlines()[-n:])


def after(log, off):
    """读日志里 off 之后新增的那段（编 Go 包的输出能有几十 MB，不能整份留在内存里）。"""
    with open(log, "r", encoding="utf-8", errors="replace") as f:
        f.seek(off)
        return f.read()


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    root = os.path.abspath(sys.argv[1])
    cfg = os.path.join(root, ".config")
    if not os.path.isfile(cfg):
        print("!! 预检没跑成：找不到 %s（必须在 make defconfig 之后、install feeds 之后跑）" % cfg)
        return 2
    if not os.path.isdir(os.path.join(root, "package")):
        print("!! 预检没跑成：%s 下没有 package/" % root)
        return 2

    gos, sel = go_targets(root)
    print("== Go 包预检：选中 %d 颗包，其中用 Go 打包的 %d 颗 ==" % (len(sel), len(gos)))
    if not gos:
        print("== 预检没活干（一颗 Go 包都没选中），跳过 ==")
        return 2
    print("   " + " ".join(sorted({s for _, ss in gos for s in ss})))

    log = os.path.join(root, "u01_go_preflight.log")
    if os.path.exists(log):
        os.remove(log)

    # 预检第一步先把交叉工具链装进 staging_dir：Go 包全吃它，不装的话 make 顺带编
    # package/libs/toolchain 时 cp 不到 libgcc_s.so.*，十几颗包一起挂在依赖上，
    # 预检就什么都判不出来了（run#16 的 32 分钟白烧）。
    print("== 预检第一步：%s（%d 颗 Go 包都吃它）==" % (TOOLCHAIN_PRE, len(gos)))
    rc0, off0 = run(MAKE + ["-j" + JOBS, TOOLCHAIN_PRE], root, log)
    if rc0 != 0:
        print("!! 预检没跑成：%s 自己退出 %d —— 这是工具链/环境的事，不是 Go 包的事，"
              "主编译会按自己的顺序再编它" % (TOOLCHAIN_PRE, rc0))
        print(tail(after(log, off0), 15))
        print("== 判不了就不拦，按老样子直接编 ==")
        return 2

    targets = ["%s/compile" % rel for rel, _ in gos]
    rc, off = run(MAKE + ["-j" + JOBS, "-k"] + targets, root, log)
    if rc == 0:
        print("== 预检通过：%d 颗 Go 包全编出来了，主编译直接复用这些成果 ==" % len(gos))
        return 0

    out = after(log, off)
    hit = sorted(set(ERR_DIR.findall(out)))
    # 只有"挂在预检对象自己身上"才允许往下判：依赖包（toolchain、target/linux 之类）挂掉
    # 说的是环境顺序，不是 Go 包的问题——第 16 跑就是把 package/libs/toolchain 当成了核心包判红。
    testee = set(rel for rel, _ in gos)
    failed = [d for d in hit if d in testee]
    other = [d for d in hit if d not in testee]
    if other:
        print("-- 挂掉但不是预检对象的依赖包（主编译按自己的顺序编，这里不替它判红）：%s --"
              % " ".join(other))
    if not hit:
        # make 自己的问题（用法错、目标写错、被信号打断），不是包的问题——别为这道保险丝停整轮
        print("!! 预检没跑成：make 退出 %d，但日志里一条 ERROR: package/xxx failed to build 都没有" % rc)
        print("   头 12 行：")
        print("\n".join("      " + l for l in out.splitlines()[:12]))
        print("== 判不了就不拦，按老样子直接编 ==")
        return 2
    if not failed:
        print("!! 预检没跑成：挂的全是依赖包，%d 颗 Go 包一颗都没轮到，判不了" % len(gos))
        print(tail(out, 15))
        print("== 判不了就不拦，按老样子直接编 ==")
        return 2

    print("!! 预检抓到 %d 颗编不过：%s" % (len(failed), " ".join(failed)))
    modcache = os.path.join(root, "dl", "go-mod-cache")
    if os.path.isdir(modcache):
        print('-- 先按"模块缓存脏了"处理：删 %s，逐颗重编 --' % modcache)
        shutil.rmtree(modcache, ignore_errors=True)
    else:
        print("-- dl/go-mod-cache 不在，没什么可清的，逐颗重编看真实原因 --")

    real = []
    for d in failed:
        run(MAKE + ["%s/clean" % d], root, log)
        rc3, off3 = run(MAKE + ["-j1", "V=s", "%s/compile" % d], root, log)
        if rc3 == 0:
            print("   救回来了：%s（就是缓存脏，清掉重下即可）" % d)
        else:
            print("   还是不过：%s —— 真问题，最后 25 行：" % d)
            print(tail(after(log, off3)))
            real.append(d)
    if not real:
        print("== 预检结果：一颗功能都没少，全部靠清缓存救回 ==")
        return 0

    core = [d for d in real if not d.startswith("package/feeds/")]
    if core:
        print("!! 判红：核心包（不在 package/feeds/ 下）编不过：[%s]，这个不能靠剔包绕开" % ", ".join(core))
        return 1

    entries = mklist(root, "package")
    victim_syms = set()
    for d in real:
        for rel, ss, _ in entries:
            if rel == d:
                victim_syms |= ss
    pull = dependents(entries, victim_syms)
    if pull:
        print("-- 连带要剔（DEPENDS 里点名了上面这些）：%s" % " ".join(sorted(pull)))
    victim_syms |= pull

    gone = drop(cfg, victim_syms)
    if len(gone) > FEAT_MAX_DROP:
        print("!! 判红：要剔 %d 颗（上限 %d），这已经不是\"少个附加功能\"而是清单塌了"
              % (len(gone), FEAT_MAX_DROP))
        return 1
    if not gone:
        print("!! 判红：%s 在 .config 里本来就没选中，剔无可剔，说明失败来自别处" % real)
        return 1

    rc4, off4 = run(MAKE + ["defconfig"], root, log)
    if rc4 != 0:
        print("!! 判红：剔完包 make defconfig 自己都过不去（退出 %d）" % rc4)
        print(tail(after(log, off4)))
        return 1
    back = sorted(s for s in gone if "CONFIG_PACKAGE_%s=y" % s in read(cfg))
    if back:
        print("!! 判红：这几颗被别的包当依赖拉回来了，剔不掉：[%s]。要剔得连拉它的那颗一起剔" % ", ".join(back))
        return 1

    feat = set()
    fp = os.path.join(os.path.dirname(os.path.abspath(__file__)), "feat_pkgs.txt")
    if os.path.isfile(fp):
        feat = {l.strip() for l in read(fp).split("\n") if l.strip()}
    lost = sorted(s for s in gone if s in feat)
    print("== 预检收尾：剔掉 %d 颗后 defconfig 复验干净：[%s]" % (len(gone), " ".join(gone)))
    if lost:
        print("!! 其中 %d 颗在功能清单里，后台会缺这些功能：%s" % (len(lost), " ".join(lost)))
        print("   （清单原文 %s；要捡回来得修那颗包的本身，别指望重跑）" % fp)
    else:
        print("   功能清单里的一颗没少")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
