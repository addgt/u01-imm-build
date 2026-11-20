#!/usr/bin/env python3
"""从镜像里直接解析扁平设备树（FDT），拿到真实的节点路径 + 属性 + status。

为什么要它：DTB 里根本没有 DTS 的 label 名和文件名，拿 "u01_bat"、"msm8916-xinxun-wf2"
去 grep 二进制只能骗自己；status=okay 这种改动也压成了属性值，字符串搜不出来。
只有按 FDT 格式走完结构块，才能证明"节点在树上、状态是对的、phandle 指得到"。

用法：
  python fdtpeek.py boot.img                 # 列出所有 DTB 的位置和大小
  python fdtpeek.py boot.img lbc bms usbin   # 打印路径里含这些关键字的节点及其属性
"""
import os
import struct
import sys

FDT_BEGIN_NODE, FDT_END_NODE, FDT_PROP, FDT_NOP, FDT_END = 1, 2, 3, 0, 9
MAGIC = 0xD00DFEED


def find_blobs(data):
    """返回 [(偏移, 声明长度, 版本, 次要版本, off_struct, off_str)]。

    只认 magic 会吃进假头（老 boot 里就有一处 0xD00DFEED 后面跟的不是设备树），
    所以再加一条：off_struct 处第一个 token 必须是 FDT_BEGIN_NODE(1)。

    ⚠️ 不能拿"偏移是否 4 字节对齐"当过滤器：arm 的 zImage 段是 gzip 流后面直接 cat
    上 dtb，gzip 流长度是任意值，于是 DTB 基址常常只 2 字节对齐（2026-11-17 第 5 跑
    的 boot.img 就是这样：真树落在 off%4==2 的位置，被老写法跳掉 ⇒ 门假红）。
    对齐性不靠偏移保证，靠 load_blob 截出来复制一份再解析。
    """
    out = []
    pos = 0
    while True:
        i = data.find(b"\xd0\x0d\xfe\xed", pos)
        if i < 0:
            return out
        pos = i + 4
        if i + 40 > len(data):
            continue
        mg, size, off_struct, off_str, off_rsv, ver, lver, _, sz_str, sz_struct = \
            struct.unpack(">10I", data[i:i + 40])
        if mg != MAGIC or not (40 <= size <= len(data) - i):
            continue
        if not (40 <= off_struct < size and 40 <= off_str < size and off_rsv < size):
            continue
        if off_struct + 4 > size:
            continue
        first = struct.unpack(">I", data[i + off_struct:i + off_struct + 4])[0]
        if first != FDT_BEGIN_NODE:
            print("  跳过假头：偏移 %#x 处 magic 对但 struct 首 token=%d（应为 1）" % (i, first))
            continue
        out.append((i, size, ver, lver, off_struct, off_str))


def load_blob(data, base, size):
    """把这段 DTB 原样截出来，让它的基址就是缓冲区开头。

    DTB 内部所有偏移都相对自身基址；原地按 4 字节步进读而基址只 2 字节对齐时，
    整个结构块会挪偏 2 字节，token 全认错。截一份出来，base=0 天然对齐。
    """
    return data[base:base + size]


def parse(data, base, size):
    """走一遍结构块，返回 [(节点路径, {属性名: 原始字节})]。"""
    hdr = struct.unpack(">10I", data[base:base + 40])
    _, _, off_struct, off_str, _, _, _, _, sz_str, _ = hdr
    strs = data[base + off_str: base + off_str + sz_str]
    p = base + off_struct
    path = []
    nodes = []
    cur = None
    while p < base + size:
        tok = struct.unpack(">I", data[p:p + 4])[0]
        p += 4
        if tok == FDT_BEGIN_NODE:
            e = data.index(b"\0", p)
            name = data[p:e].decode("ascii", "replace")
            p = (e + 4) & ~3
            path.append(name if name else "/")
            cur = ("/" + "/".join(x for x in path[1:] if x), {})
            nodes.append(cur)
        elif tok == FDT_END_NODE:
            path.pop()
            cur = None
        elif tok == FDT_PROP:
            ln, nameoff = struct.unpack(">II", data[p:p + 8])
            p += 8
            val = data[p:p + ln]
            p += (ln + 3) & ~3
            z = strs.find(b"\0", nameoff)
            if cur is not None:
                cur[1][strs[nameoff:z].decode("ascii", "replace")] = val
        elif tok == FDT_NOP:
            continue
        elif tok == FDT_END:
            break
        else:
            raise SystemExit("!! FDT 结构块偏移 %#x 处 token=%d 不认识，解析器对不上这个 blob" % (p - 4, tok))
    return nodes


def s(b):
    """只有整段都可打印（或就是空）才当字符串返回，否则按二进制交给调用方。"""
    if b is None:
        return None
    if b and b[-1:] == b"\0":
        b = b[:-1]
    if b and not all(32 <= c < 127 for c in b):
        return None
    return b.decode("ascii", "replace")


def u32(b, i=0):
    return struct.unpack(">I", b[i:i + 4])[0] if b and len(b) >= i + 4 else None


def strs(b):
    """compatible / reg-names 这类"NUL 分隔多字符串"。"""
    if not b:
        return []
    return [x.decode("ascii", "replace") for x in b.split(b"\0") if x]


def by_compat(nodes, compat):
    return [(p, pr) for p, pr in nodes if compat in strs(pr.get("compatible"))]


def check_charging(nodes):
    """把"这版能不能充电"落到设备树的具体事实上，返回 [(成立?, 说明)]。

    只认这些：label 名和 DTS 文件名都不会出现在编译出的 DTB 里，status 也不是明文，
    所以拿字符串去 grep 二进制只能自证个寂寞（run#5 我就是这么把绿的判成红的）。
    条目数固定（节点缺失也照样出条目判红），这样下游能断言"全绿"而条目数不会随输入变。
    """
    by_ph = {}
    for p, pr in nodes:
        if "phandle" in pr:
            by_ph[u32(pr["phandle"])] = p
    out = []
    for compat, want in (("qcom,pm8916-lbc", "LBC 充电"), ("qcom,pm8916-bms-vm", "BMS-VM 电量计")):
        hit = by_compat(nodes, compat)
        if not hit:
            out.append((False, "%s：树上根本没有 %s 节点" % (want, compat)))
            out.append((False, "%s：没有节点可谈 monitored-battery" % want))
            continue
        p, pr = hit[0]
        st = s(pr.get("status"))
        out.append((st == "okay", "%s %s status=%s" % (want, p, st or "缺省")))
        mb = u32(pr.get("monitored-battery"))
        tgt = by_ph.get(mb)
        if tgt is None:
            out.append((False, "%s 没有 monitored-battery（驱动拿不到电池信息就 -ENODEV 退出）" % want))
        else:
            tc = strs(dict(nodes).get(tgt, {}).get("compatible"))
            out.append(("simple-battery" in tc,
                        "%s monitored-battery -> %s compatible=%s（必须是 simple-battery）"
                        % (want, tgt, ",".join(tc) or "无")))
    lbc = by_compat(nodes, "qcom,pm8916-lbc")
    cur = u32(lbc[0][1].get("qcom,fast-charge-safe-current")) if lbc else None
    out.append((cur is not None, "LBC 充电 我们独有的注入属性 qcom,fast-charge-safe-current=%s"
                % ("%d uA" % cur if cur else "没有")))
    ud = by_compat(nodes, "qcom,pm8941-misc")
    if not ud:
        out.append((False, "让出 usb_vbus：找不到 qcom,pm8941-misc（usb-detect）节点"))
    else:
        st = s(ud[0][1].get("status"))
        out.append((st == "disabled", "让出 usb_vbus %s status=%s（要 disabled，否则和 LBC 抢 vbus）"
                    % (ud[0][0], st or "缺省")))
    # —— 第 14 跑加的两条硬账：编译期的 grep 只证"我改了 dts"，这里证"产物那棵树里真是这个值"。
    # 充电电压必须两处同时 4.35 V：pm8916_lbc.c 先用 charge_voltage_safe 夹 charge_voltage_max
    # 再编 VDD_MAX，只改电池节点会被 charger 那边的 4.20 V 夹回去（r13 实测 VBAT 4.30 V＞4.20 V
    # ⇒ 充电环根本不启动）。
    # ⚠️ 这两个属性都挂在【lbc 节点】上：产物里那个节点叫 charger@1000，但 compatible 是
    #    qcom,pm8916-lbc（驱动 of_match 就写这一条，device_property_read_u32 读的也是它的 of_node）；
    #    按 qcom,pm8916-charger 去找会找到另一颗节点，结果假红（第 15 跑验货时就踩过）。
    nd = dict(nodes)
    sv = u32(lbc[0][1].get("qcom,fast-charge-safe-voltage")) if lbc else None
    bat = nd.get(by_ph.get(u32(lbc[0][1].get("monitored-battery")))) if lbc else None
    if bat is None:
        hit = by_compat(nodes, "simple-battery")
        bat = hit[0][1] if hit else {}
    vmax = u32(bat.get("voltage-max-design-microvolt"))
    out.append((sv == 4350000 and vmax == 4350000,
                "充电电压 4.35 V 两处都在产物树里：lbc 节点 qcom,fast-charge-safe-voltage=%s，"
                "电池 voltage-max-design-microvolt=%s（任一处是 4200000 就等于不充电）" % (sv, vmax)))
    # ramoops：这台机器每 12~15 分钟自己重启一次，没这段保留内存，pstore 就是空的，
    # "重启"这件事完全没有证据。reg 必须是 4 cell（reserved-memory 的 #address-cells=2）：
    # [addr 高, addr 低, size 高, size 低] —— 要比的是第 1、3 格，不是最后两格。
    ro = by_compat(nodes, "ramoops")
    reg = ro[0][1].get("reg") if ro else None
    cell = list(struct.unpack(">%dI" % (len(reg) // 4), reg)) if reg and len(reg) % 4 == 0 else []
    good = (len(cell) == 4 and cell[0] == 0 and cell[1] == 0x9fe00000
            and cell[2] == 0 and cell[3] == 0x200000)
    out.append((good, "崩溃日志 ramoops 落在 0x9fe00000+2MB（4 cell：高半格都得是 0），实际 reg=%s"
                % (" ".join("%#x" % c for c in cell) if cell else "没有这个节点")))
    return out


# 内核侧要存在的字符串：compatible 表项证明驱动编进来了（=y，不是 =m，.ko 不在这个包里），
# power_supply 名字那两条证明它注册出来的名字就是我们验收要查的那个。
KERN_TOKENS = [
    (b"qcom,pm8916-lbc", "内核里有 LBC 驱动的 of_match 表项"),
    (b"pm8916-lbc-chgr", "内核里会注册 power_supply 名 pm8916-lbc-chgr"),
    (b"qcom,pm8916-bms-vm", "内核里有 BMS-VM 驱动的 of_match 表项"),
    (b"pm8916-bms-vm", "内核里会注册 power_supply 名 pm8916-bms-vm"),
    (b"qcom,fast-charge-safe-current", "内核真会去读我们注入的那个属性"),
]


def kernel_from_boot(data):
    """从 android boot 里把内核解出来。解不出来返回 None（调用方判红，别默认通过）。"""
    import zlib
    o, n = 0, 0
    while True:
        i = data.find(b"\x1f\x8b\x08", o)
        if i < 0:
            return None
        try:
            raw = zlib.decompressobj(47).decompress(data[i:])
        except Exception:
            raw = None
        if raw and len(raw) > 1 << 20:
            print("  内核：gzip @ %#x，解出 %d B（第 %d 个候选流）" % (i, len(raw), n + 1))
            return raw
        o, n = i + 1, n + 1


def check_kernel(data):
    """boot 里那半是 gz 压缩的内核，明文 grep 搜不到——必须解压后再查字符串。"""
    raw = kernel_from_boot(data)
    if raw is None:
        return [(False, "boot 里解不出 gzip 内核流（内核若改成 LZMA/未压缩，这条得在脚本来这里加一路）")]
    return [(raw.count(tok) >= 1, "%s（命中 %d 次）" % (desc, raw.count(tok)))
            for tok, desc in KERN_TOKENS]


if __name__ == "__main__":
    argv = [x for x in sys.argv[1:]]
    check = "--check" in argv
    argv = [x for x in argv if x != "--check"]
    dtb_arg = None
    if "--dtb" in argv:
        i = argv.index("--dtb")
        if i + 1 >= len(argv):
            sys.exit("!! --dtb 后面要跟一个 built .dtb 文件路径")
        dtb_arg = argv[i + 1]
        del argv[i:i + 2]
    if not argv:
        sys.exit(__doc__)
    data = open(argv[0], "rb").read()
    blobs = find_blobs(data)
    if not blobs:
        raise SystemExit("!! %s 里找不到合法 FDT 头（0xD00DFEED）" % argv[0])
    print("%s：%d 个 DTB" % (argv[0], len(blobs)))
    for base, size, ver, lver, so, st in blobs:
        print("  偏移 %#x 声明 %d B，v%d.%d struct@%d strings@%d" % (base, size, ver, lver, so, st))
    keys = [k.lower() for k in argv[1:]]
    bad = 0
    for base, size, *_ in blobs:
        nodes = parse(load_blob(data, base, size), 0, size)
        print("\n== DTB @ %#x 共 %d 个节点 ==" % (base, len(nodes)))
        if check:
            for ok, msg in check_charging(nodes):
                print("  [%s] %s" % ("OK " if ok else "缺!", msg))
                bad += 0 if ok else 1
            if dtb_arg:
                # 闭第二环：验的这棵树必须就是产物镜像里那一段字节，不是 build_dir 里的另一份
                want = open(dtb_arg, "rb").read()
                n = data.count(want)
                print("  [%s] built %s 的整块字节（%d B）在产物里出现 %d 处"
                      % ("OK " if n else "缺!", os.path.basename(dtb_arg), len(want), n))
                bad += 0 if n else 1
            continue
        for path, props in nodes:
            low = path.lower()
            if keys and not any(k in low for k in keys):
                continue
            print("%s" % path)
            for n in sorted(props):
                v = props[n]
                txt = s(v)
                if txt:
                    print("    %-40s = \"%s\"" % (n, txt))
                elif txt == "":
                    print("    %-40s = <empty>" % n)
                else:
                    words = struct.unpack(">%dI" % (len(v) // 4), v[:len(v) - len(v) % 4])
                    print("    %-40s = <%s>  %s" % (n, " ".join("%08x" % x for x in words),
                                                    " ".join(strs(v)) if b"\0" in v else ""))
    if check:
        print("\n== 内核侧（boot 里 gzip 解出来查字符串，明文 grep 是搜不到的）==")
        for ok, msg in check_kernel(data):
            print("  [%s] %s" % ("OK " if ok else "缺!", msg))
            bad += 0 if ok else 1
        sys.exit(1 if bad else 0)
