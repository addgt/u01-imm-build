#!/usr/bin/env python3
"""编译前的一次轻量预检：把交叉工具链先装上，并把选中的 Go 包点出来 —— 只报告，不拦路。

这一跑为什么要有这一步：
  1) `make toolchain/install` 是上游自己的目标（include/toplevel.mk 里
     `prepare_kernel_conf: .config toolchain/install FORCE` 就依赖它，toolchain/Makefile 里
     `$(curdir)/install: $(curdir)/compile`）。先单独跑一遍，让"工具链没装好"这一类环境问题在
     十几分钟内露头，而不是埋在几万个包中间；编好的东西主编译直接复用，不多干活。
  2) 把 .config 选中、Makefile 里又看得出用 Go 打包的包点名打出来。第 15 跑就是这条扫描漏了
     feed 的真写法（`GO_PKG:=…` + `include ../../lang/golang/golang-package.mk`），扫到 0 颗，
     整步变成没人发现得空跑。

【这里不再自己编 Go 包】—— 连着两轮它把自己判成红，两轮白烧，证据都在日志里：

  第 16 跑（T+32 分钟停）：Go 包单独编的时候 make 顺带把 package/libs/toolchain 拉进来编，
  而那会儿 staging_dir/toolchain-*/lib/libgcc_s.so.* 根本还不存在（cp: cannot stat ⇒ Error 1）。
  那是"还没轮到它装"的先后顺序问题，当时按包名一判成了"核心包编不过"→ 判红 → 整轮没了。
  上面第 1 件事就是那一笔留下的唯一有用的东西。

  第 17 跑（T+92 分钟停）：工具链装好了，单独编还是挂了四颗 —— ddns-go / librespeed-go /
  mosdns / xray-core。可这四颗在上一版镜像 dl/r15 的清单里【全都在】：
      ddns-go 6.17.8-r1 / librespeed-go 1.1.5-r5 / mosdns 5.3.3-r1 / xray-core 26.11.9-r1
  主编译证明它们编得出来，所以"单独编不过"说的是这条单独编译通路，不是包。报错也是自证的：
      golang.org/x/sys@v0.49.0/unix: undefined: Syscall / RawSyscall / isBigEndian / raceenabled
      github.com/wlynxg/anet@v0.0.5: build constraints exclude all Go files
      no required module provides package github.com/spf13/viper/internal/encoding/json
  这是【模块树被抽走一部分】的签名 —— 而抽走它的正是这一步自己：判到失败就
  rmtree(dl/go-mod-cache)，再 -j1 单包重编；单包重编不会把整个共享缓存重新填满，
  于是后面每一颗都挂在"缓存被我删空"上，越救越像真坏了。
  第 14 跑那个"同一模块版本混进两份内容"的坑，真正的解法早就落在工作流里
  （actions/cache 的 path 明确写了 `!/mnt/openwrt/dl/go-mod-cache`，Go 模块每跑现下），
  不需要这里再删一遍。

  还有一笔时间账：这一步 timeout-minutes: 90，而第 17 跑光预检就吃掉 82 分钟 ——
  就算判读全对，12 颗 Go 包挨个编也随时会让整步被 GitHub 掐掉。

所以宁可不拦：真要死在 Go 包上，主编译那一步会把完整日志留在原地，比在这里误杀两轮便宜。
退出码只发 0（清点 + 工具链预装做完了）和 2（这一步自己没跑成），永远不发 1。
不改 .config、不删 dl 下任何东西、不下任何 */compile 目标 —— 这三条由 out/t_rescue.py 断着。

用法：python3 go_preflight.py <openwrt 目录>
退出：0 干完了；2 没跑成（没 defconfig、一颗 Go 包都没扫到、工具链没装上）
"""
import os
import re
import shlex
import subprocess
import sys

JOBS = os.environ.get("U01_JOBS") or str(os.cpu_count() or 4)
MAKE = shlex.split(os.environ.get("U01_MAKE") or "make")
TOOLCHAIN_PRE = "toolchain/install"
# feed 里 Go 包的真写法是 GO_PKG:=… + include ../../lang/golang/golang-package.mk；
# wf2 自带那些用 $(call GoBinary)。三种都要认，否则扫描会变成空跑（第 15 跑）。
GO_MARK = re.compile(r"GO_PKG\s*:?=|golang-package\.mk|\$\(call GoBinary")
BUILD_PKG = re.compile(r"BuildPackage\s*,\s*([A-Za-z0-9._+-]+)")
PKG_NAME = re.compile(r"^PKG_NAME\s*:?=\s*(\S+)", re.M)
CUT = ("build_dir", "staging_dir", "ipk", ".git", "logs", "tmp", "bin")


def read(p):
    try:
        return open(p, encoding="utf-8", errors="replace").read()
    except OSError:
        return ""


def selected(cfg_text):
    return set(re.findall(r"^CONFIG_PACKAGE_(\S+)=y$", cfg_text, re.M))


def go_targets(root):
    """.config 选中、且 Makefile 看得出用 Go 打包的包目录 → (命中, 选中颗数, 扫过的 Makefile 数)"""
    sel = selected(read(os.path.join(root, ".config")))
    hits, scanned = [], 0
    for dp, dn, fn in os.walk(os.path.join(root, "package"), followlinks=True):
        dn[:] = [x for x in dn if x not in CUT and not x.startswith(".")]
        if "Makefile" not in fn:
            continue
        scanned += 1
        text = read(os.path.join(dp, "Makefile"))
        if not GO_MARK.search(text):
            continue
        syms = set(BUILD_PKG.findall(text))
        m = PKG_NAME.search(text)
        if m:
            syms.add(m.group(1))
        pick = sorted(syms & sel)
        if pick:
            hits.append((os.path.relpath(dp, root).replace(os.sep, "/"), pick))
    return sorted(hits), len(sel), scanned


def run(cmd, cwd, log):
    """输出直接落进 log（不经过内存），返回 (退出码, 这段在 log 里的起点)。"""
    off = os.path.getsize(log) if os.path.exists(log) else 0
    with open(log, "a", encoding="utf-8", errors="replace") as f:
        f.write("\n$ %s\n" % " ".join(cmd))
        f.flush()
        rc = subprocess.Popen(cmd, cwd=cwd, stdout=f, stderr=subprocess.STDOUT).wait()
    return rc, off


def after(log, off, n=15):
    with open(log, encoding="utf-8", errors="replace") as f:
        f.seek(off)
        return "\n".join("      " + l for l in f.read().splitlines()[-n:])


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    root = os.path.abspath(sys.argv[1])
    if not os.path.isfile(os.path.join(root, ".config")):
        print("!! 预检没跑成：找不到 %s（要在 make defconfig 之后跑）" % os.path.join(root, ".config"))
        return 2
    if not os.path.isdir(os.path.join(root, "package")):
        print("!! 预检没跑成：%s 下没有 package/" % root)
        return 2

    gos, nsel, scanned = go_targets(root)
    print("== Go 包清点：扫了 %d 个 Makefile，清单选中 %d 颗，其中用 Go 打包的 %d 颗 =="
          % (scanned, nsel, len(gos)))
    if not gos:
        print("!! 一颗 Go 包都没扫到：要么清单里真没有，要么扫描规则又跟不上 feed 的写法。"
              "这一步没信息量，直接交给主编译")
        return 2
    for rel, syms in gos:
        print("   %-46s %s" % (rel, " ".join(syms)))
    print("-- 这些包【不在这里编】：上一版镜像（r15）的清单证明主编译编得出来，"
          "单独编只会造出假的失败（理由见文件头） --")

    log = os.path.join(root, "u01_go_preflight.log")
    if os.path.exists(log):
        os.remove(log)
    print("== 预装交叉工具链：make -j%s %s ==" % (JOBS, TOOLCHAIN_PRE))
    rc, off = run(MAKE + ["-j" + JOBS, TOOLCHAIN_PRE], root, log)
    if rc != 0:
        print("!! 工具链没装上（退出 %d，原文见 u01_go_preflight.log）。这是环境的事，"
              "主编译会按自己的顺序再编它，这里不拦" % rc)
        print(after(log, off))
        return 2

    sd = os.path.join(root, "staging_dir")
    tcs = sorted(d for d in os.listdir(sd) if d.startswith("toolchain-")) if os.path.isdir(sd) else []
    gcc = sorted(x for d in tcs for x in os.listdir(os.path.join(sd, d, "lib"))
                 if x.startswith("libgcc_s.so")) if tcs else []
    print("== 预检到此为止：工具链就位 [%s] libgcc_s=[%s]；Go 包交给主编译按自己的依赖顺序编 =="
          % (" ".join(tcs) or "没看到 staging_dir/toolchain-*", " ".join(gcc) or "没找到"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
