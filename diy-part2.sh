#!/bin/bash
# DIY脚本
# https://github.com/P3TERX/Actions-OpenWrt
# 文件名: diy-part2.sh
# 功能说明: OpenWrt DIY脚本第2部分（更新feeds之后）
# 版权: (c) 2019-2024 P3TERX <https://p3terx.com>
# 基于 MIT 开源协议，详见 /LICENSE

# 修改默认IP地址
#sed -i 's/192.168.1.1/192.168.100.1/g' package/base-files/files/bin/config_generate


# 修改默认主题为 argon（路径不存在时跳过，不中断编译）
sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci/Makefile 2>/dev/null || true

# 启用 IPv4 策略路由（直接写入内核 platform config，绕过 make defconfig 的依赖检查）
# CONFIG_KERNEL_IP_ADVANCED_ROUTER 在 OpenWrt Config.in 中无对应 wrapper，必须用此方式
#for cfg in target/linux/msm89xx/config-*; do
#  grep -q 'CONFIG_IP_ADVANCED_ROUTER' "$cfg" || echo 'CONFIG_IP_ADVANCED_ROUTER=y' >> "$cfg"
#  grep -q 'CONFIG_IP_MULTIPLE_TABLES' "$cfg" || echo 'CONFIG_IP_MULTIPLE_TABLES=y' >> "$cfg"
#done


# 临时添加的插件
# git clone https://github.com/lkiuyu/luci-app-cpu-perf package/luci-app-cpu-perf
# git clone https://github.com/lkiuyu/luci-app-cpu-status package/luci-app-cpu-status
# git clone https://github.com/gSpotx2f/luci-app-cpu-status-mini package/luci-app-cpu-status-mini
# git clone https://github.com/lkiuyu/luci-app-temp-status package/luci-app-temp-status
# git clone https://github.com/lkiuyu/DbusSmsForwardCPlus package/DbusSmsForwardCPlus

# ============================================================
# U01 电池机适配（改包：lkiuyu/immortalwrt 的 msm89xx target，profile=wf2）
#
# 1) 电量来源：打开 PM8916 BMS-VM（电压式电量计，drivers/power/supply/pm8916_bms_vm.c）
#    - 上游 pm8916.dtsi 的 pm8916_charger / pm8916_bms 都写死 status="disabled"，
#      且 config-6.18 里两个驱动符号根本没出现 => 现在 /sys/class/power_supply 是空的。
#    - 充电必须一起开：实测 CHG_CTRL=0x90（bit7 CHG_EN 已经是 1）、USBIN_VALID=1、
#      电池在位、温度 OK，但 IBAT_MAX 停在 PMIC 上电默认 0x00 = 90 mA，
#      插 500 mA 口时系统负载全吃掉 ⇒ 净放电（VSYS 13 分钟 3892→3831 mV）。
#      这个内核没有任何代码去抬它（config-6.18 里连 CHARGER_PM8916_LBC 都没出现），
#      而用户态三条写通道全被配置封死（regmap debugfs 的 registers/access 都是 0400、
#      # CONFIG_DEVMEM is not set、spmi 平台设备没有 resource0）⇒ 只能重编内核打开 lbc。
#    - lbc 的 probe 要抢 usb_vbus 这条 SPMI 中断线（0x13），本机现在由
#      pm8916_usbin (usb-detect@1300) 占着，所以开充电必须同时把它 disable，
#      否则后注册的那个 -EBUSY，充电和电量一起没。
#    - ⚠️ 代价（实测到）：现刷 rootfs 的 /etc/hotplug-gcreboot.json 盯的就是
#      usb-detect 那个 extcon0 的 "USB=0"（拔线）事件，条件成立就 /etc/init.d/gc restart；
#      这台 gc.config.mode=gadget、UDC role=gadget、S90gc 自启 ⇒ 这钩子是活的。
#      关掉 usbin 后 extcon0 消失，钩子不再触发。USB 在/不在这件事本身改由
#      pm8916-lbc 的 extcon 报（同一个 EXTCON_USB），但 DEVPATH/NAME 变了，
#      所以刷好后要按 /sys/class/extcon/*/{name,state} 实测把那份 json 改指过去。
#    - BMS-VM 的 probe 会调 power_supply_get_battery_info()，它在节点上找
#      "monitored-battery" -> compatible="simple-battery"，找不到就 -ENODEV 直接退出，
#      所以必须连电池描述节点一起补，否则驱动根本不绑、白开。
#    - 这个驱动只导出 voltage_now / voltage_ocv / status / health，没有 capacity，
#      所以电量是"电压查表"来的，不是库仑计（插着 USB 时 VBAT 顶在充电压，会显示满格）。
#
# 2) DTS：RGB 灯换成 U01 实脚位（72/71/73，和现在刷进去的 boot_u01.img 一致），
#    再补 4 格电量灯 bat:1..bat:4（脚 0/91/1/100 = 原厂 DTB 的 bat1/batl2/batl3/batl4），
#    并把这 4 个脚加进 &gpio_leds_default 的 pins，否则 pinctrl 不切功能。
#
# 3) 用户态文件走仓库顶层 files/ 覆盖层（不走 package/base-files/files）：
#    上游 include/image.mk 里有 `$(call prepare_rootfs,$(mkfs_cur_target_dir),$(TOPDIR)/files)`
#    ⇒ TOPDIR(files) 才是镜像吃的目录。workflow 先用 `cp -r files openwrt/files` 把它建出来（生效），
#    随后 `mv files openwrt/files` 把仓库根那份搬空、在 openwrt/files/files/ 留一坨重复垃圾
#    （本脚本会顺手删掉）。⇒ 想改 /etc 就往仓库 files/ 里放，但**自检要按 openwrt/files 验**。
#
# 4) DTS 是哪一份：target/linux/msm89xx/image/msm8916.mk 里 openstick-wf2 写死
#    DEVICE_DTS := msm8916-xinxun-wf2 + DEVICE_DTS_DIR := ../dts，
#    Device/Default 是 KERNEL = kernel-bin | gzip | append-dtb，boot.img = append-kernel|aboot-img
#    => 追加到 dts/msm8916-xinxun-wf2.dts 末尾的东西就是刷进去的 DTB（dts/Makefile 那份
#    内核 dtb-y 清单没有 wf2，别被它误导，编译由 OpenWrt 的 Device 规则做）。
#
# 依赖已核对：config-6.18 里 MFD_SPMI_PMIC=y、POWER_SUPPLY=y、EXTCON=y、IIO=y；
#             子目标 msm8916 只有 target.mk（没有自己的 config-6.18）=> 改 target 级那份就够。
# ============================================================
U01_MARK="U01 (battery stick) overrides"

# 内核配置片段的名字必须跟着上游走，不能写死：
#   lkiuyu/immortalwrt 上游锁 7fe583d9 => KERNEL_PATCHVER:=6.12，那棵树里【没有】config-6.18；
#   master HEAD 05d3cf2a             => KERNEL_PATCHVER:=6.18，有 config-6.18 + patches-6.18。
#   写死 config-6.18 的后果：用锁定 hash 编时这文件不存在，echo >> 会凭空造一个没人读的片段，
#   自检还照样"通过"，等于白等一个半小时。所以先解析、再要求它已存在，缺就直接停。
KV=$(sed -n 's/^KERNEL_PATCHVER:=[[:space:]]*\([0-9.][0-9.]*\).*/\1/p' target/linux/msm89xx/Makefile | head -1)
CFG=target/linux/msm89xx/config-$KV
DTS=target/linux/msm89xx/dts/msm8916-xinxun-wf2.dts
for f in "$CFG" "$DTS"; do
	[ -f "$f" ] || { echo "!! KERNEL_PATCHVER=$KV，但 $f 不存在（同目录有：$(ls target/linux/msm89xx/config-* 2>/dev/null | tr '\n' ' ')）"; exit 1; }
done
echo "== U01：KERNEL_PATCHVER=$KV，内核片段 = $CFG =="

for sym in CONFIG_BATTERY_PM8916_BMS_VM CONFIG_CHARGER_PM8916_LBC CONFIG_DEBUG_FS; do
	grep -q "^${sym}=y" $CFG || echo "${sym}=y" >> $CFG
done
# CONFIG_DEBUG_FS 是这版新加的：内核没编 debugfs 时 /sys/kernel/debug 连挂载都挂不上
# （实测 mount: unknown filesystem type 'debugfs'），于是 regmap debugfs 那条唯一能
# **只读** PMIC 寄存器的通道整个不存在，CHG_CTRL/CHG_STATUS/VDD_MAX 到底落没落上
# 全凭猜。开了之后 /sys/kernel/debug/regmap/<spmi pmic>/registers 是 0400，只读不写，
# 够用来做"驱动写了什么、硬件回什么"的对账，不引入新的写风险。
# 注意：这几个是内核内建符号，不是 CONFIG_PACKAGE_*，往 OpenWrt 的 .config 里追加没有意义
#（它们没有 config/Config-kernel.in 里的 CONFIG_KERNEL_* 包装），片段文件才是唯一入口。
# 唯一例外就是 DEBUG_FS：它确实有 CONFIG_KERNEL_DEBUG_FS 包装，所以除了片段，
# config/wf2.config 里那句 "# CONFIG_KERNEL_DEBUG_FS is not set" 也必须翻成 =y，
# 否则 include/kernel-build.mk 把 CONFIG_KERNEL_* 去掉前缀喂进内核 .config 时会把它按回 not set。

if ! grep -q "$U01_MARK" $DTS; then
cat >> $DTS <<'DTSEOF'

/* ---- U01 (battery stick) overrides, injected by diy-part2.sh ---- */
/* production pins: 4g_type=72 -> red/power, 4g_1=71 -> green/wan, wifistatus=73 -> blue/wlan */
&led_r { gpios = <&tlmm 72 GPIO_ACTIVE_HIGH>; };
&led_g { gpios = <&tlmm 71 GPIO_ACTIVE_HIGH>; };
&led_b { gpios = <&tlmm 73 GPIO_ACTIVE_HIGH>; };

/* battery bars: bat1=0, batl3=1, batl2=91, batl4=100 (all four idle in the stock build) */
&leds {
	bat1 { label = "bat:1"; gpios = <&tlmm 0 GPIO_ACTIVE_HIGH>;   default-state = "off"; };
	bat2 { label = "bat:2"; gpios = <&tlmm 91 GPIO_ACTIVE_HIGH>;  default-state = "off"; };
	bat3 { label = "bat:3"; gpios = <&tlmm 1 GPIO_ACTIVE_HIGH>;   default-state = "off"; };
	bat4 { label = "bat:4"; gpios = <&tlmm 100 GPIO_ACTIVE_HIGH>; default-state = "off"; };
};

&gpio_leds_default {
	pins = "gpio0", "gpio1", "gpio12", "gpio22", "gpio31", "gpio38",
	       "gpio71", "gpio72", "gpio73", "gpio91", "gpio97", "gpio98", "gpio100", "gpio108";
};

/ {
	u01_bat: battery {
		compatible = "simple-battery";
		technology = "li-ion";
		voltage-min-design-microvolt = <3400000>;
		voltage-max-design-microvolt = <4350000>;
	};
};

&pm8916_bms {
	status = "okay";
	monitored-battery = <&u01_bat>;
};
DTSEOF
fi

# 充电单独一段：老 fork 已经注入过上面那块（LED/电量灯），只缺这个，重跑也得补上
if ! grep -q '&pm8916_charger' $DTS; then
cat >> $DTS <<'CHGEOF'

/* IBAT_MAX sits at the PMIC power-on default (90 mA) until charger code raises it.
 * usb_vbus is one SPMI line: pm8916_usbin holds it today, so the charger must take it. */
&pm8916_charger {
	status = "okay";
	qcom,fast-charge-safe-voltage = <4350000>;
	qcom,fast-charge-safe-current = <700000>;
	monitored-battery = <&u01_bat>;
};

&pm8916_usbin {
	status = "disabled";
};
CHGEOF
fi

# 机型名（LuCI 首页"型号"那一栏 = /tmp/sysinfo/model = /proc/device-tree/model，
# 由 /lib/preinit/02_sysinfo 从 DTB 抄过去，用户态改不住，只能改 DTB）。
# 上游那份 dts 写的是作者板子的名字（ufi-wf2 4G Modem Stick），这里在同一节点里再赋一次
# 覆盖掉——dtc 的语义是"同一节点里后写的同名属性顶掉先写的"，所以追加在文件末尾就够。
U01_MODEL="U01 4G Modem Stick"
if ! grep -q "model = \"$U01_MODEL\"" $DTS; then
cat >> $DTS <<MODEOF

/* later assignment in the same node overrides the one from the base dts */
/ {
	model = "$U01_MODEL";
};
MODEOF
fi

# 用户态（u01simd/netled/ledidle/batled/chg_regs + 四个 init.d + /etc/u01sim.conf
# + etc/uci-defaults/99-u01-lamps + etc/hotplug-gcreboot.json）不由本脚本 cp 安装，
# 走仓库顶层 files/ 覆盖层。
# 覆盖层确实生效：上游 include/image.mk 里有 $(call prepare_rootfs,$(mkfs_cur_target_dir),$(TOPDIR)/files)。
#
# ⚠️ 但"仓库根那份 files/"在本步执行时已经不存在了 —— workflow 顺序是
#      step " files"                 : cp -r files openwrt/files        （建目录，这份才算数）
#      step "Load custom configuration": [ -e files ] && mv files openwrt/files
#    第二次是往已存在目录里挪 ⇒ 变成 openwrt/files/files/ 的重复垃圾，仓库根 files/ 被搬空。
#    11-16 那次编译就是在这里自检失败退出的（当时十项全去找仓库根 ⇒ 全空 ⇒ exit 1）。
#    所以要验就验 $(TOPDIR)/files（本步 CWD 就是 openwrt 根），它才是镜像真正吃的那一份。
OVL=files
if [ ! -s "$OVL/usr/libexec/batled.py" ]; then
	for c in "$GITHUB_WORKSPACE/files" "$(dirname -- "$0")/files"; do
		[ -s "$c/usr/libexec/batled.py" ] && { OVL="$c"; break; }
	done
fi
[ -s "$OVL/usr/libexec/batled.py" ] || OVL=""
echo "== U01：覆盖层落点 = ${OVL:-没找到（下面会报缺）} =="
# 清掉 mv 造出来的重复副本，否则它以 /files/ 白占镜像约 100KB
if [ -n "$OVL" ] && [ -s "$OVL/files/usr/libexec/batled.py" ]; then
	rm -rf "$OVL/files" && echo "== U01：已清掉 mv 造成的重复副本 $OVL/files/ =="
fi
# 这里刻意不再往 rc.local 塞 batled.sh：四格灯只留 init.d/batled 一个主人，
# 两份同时跑会抢同一组 bat:1..4，谁最后写谁说了算，格数会乱跳。

# ---- 5) 补 fork 缺的 libffi（run #2 就是死在这上面，编到 95 分钟才露出来）----
# 官方 immortalwrt 有 package/libs/libffi，lkiuyu 那份 fork 没有（package/libs 里数得出来）；
# 而 packages 源里的 glib2 2.88.1 已经把 gobject/gio 子包写成 DEPENDS += +libffi，
# ModemManager 又必须 glib2 ⇒ 树里没有 libffi，glib2 的 ipk 就打包不出来：
#   Package glib2-gobject is missing dependencies for the following libraries: libffi.so.8
#   ERROR: package/feeds/packages/glib2 failed to build.
# 仓库里带一份和官方同版的（immortalwrt@a4ba8240，libffi 3.8.0 + 官方 22 个 patch），缺才补，不覆盖。
REPO_DIR="$(cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)"
if [ -e package/libs/libffi/Makefile ]; then
	echo "== U01：树里已经有 package/libs/libffi（fork 同步过了），不覆盖 =="
elif [ -e "$REPO_DIR/u01_local/package/libs/libffi/Makefile" ]; then
	mkdir -p package/libs
	cp -a "$REPO_DIR/u01_local/package/libs/libffi" package/libs/
	echo "== U01：已补 package/libs/libffi（glib2 → ModemManager 的硬依赖）=="
else
	echo "!! 仓库里没带 u01_local/package/libs/libffi，libffi 补不上（下面自检会停）"
fi
grep -q '^CONFIG_PACKAGE_libffi=y' .config 2>/dev/null || echo 'CONFIG_PACKAGE_libffi=y' >> .config

# ---- 6) 补 mcopy：调制解调器固件包靠它切出来 ----
# feeds/openstick/firmware/qcom-firmware 的 Build/Compile 是 mcopy（mtools）从
# openstick-wf2-modem.bin 里取 ::image/mba.mbn ::image/modem.* ::image/wcnss.*，
# 而 workflow 装的那个依赖清单（xuxin1955/depend_ubuntu2204_openwrt，93 项）里没有 mtools。
# 缺它 ⇒  modem 固件包报错 ⇒ 又白等一次。这里现装，装不上就直接停。
if ! command -v mcopy >/dev/null 2>&1; then
	echo "== U01：runner 上没有 mcopy，尝试补装 mtools =="
	sudo -E apt-get -y install mtools >/tmp/u01_mtools.log 2>&1 || tail -5 /tmp/u01_mtools.log
	command -v mcopy >/dev/null 2>&1 && echo "== U01：mcopy 已就位 $(command -v mcopy) =="
fi

# ---- 7) 合掉 netfilter 那对抢同一个 .ko 的包（run #4 死因）----
# 锁定树 package/kernel/linux/modules/netfilter.mk 里同时有：
#   KernelPackage/iptables  HIDDEN, DEPENDS:=@!LINUX_6_12,
#                           FILES = net/ipv4/netfilter/ip_tables.ko + net/netfilter/x_tables.ko
#   KernelPackage/nf-ipt    DEPENDS:=+!LINUX_6_12:kmod-iptables,
#                           FILES = $(NF_IPT-m) = 上面同两个 .ko（include/netfilter.mk:32-33）
# 内核是 6.18（不是 6.12）⇒ 两个包都进 rootfs ⇒ opkg 在 package/install 判数据文件冲突：
#   check_data_file_clashes: Package kmod-nf-ipt wants to install file .../ip_tables.ko
#   Cannot install package kmod-nf-ipt / kmod-nf-ipt6 / kmod-ipt-core / kmod-nft-compat
#   package/Makefile:100: package/install Error 255     ← 96 分钟才走到这一步
# 上游 master 已经没有 KernelPackage/iptables，改把三个 *_LEGACY 的 KCONFIG 直接挂进
# nf-ipt / nf-ipt6 / ebtables（.ko 归 nf-ipt 一家打）。这里照 master 的做法合一，
# 补丁用 t_dep/mk_nfpatch.py 从锁定 hash 的真实文件生成，本地 patch -p1 往返验过。
NFMK=package/kernel/linux/modules/netfilter.mk
NFPATCH="$REPO_DIR/u01_local/patches/netfilter-ipt-clash.patch"
if ! grep -q '^define KernelPackage/iptables$' $NFMK 2>/dev/null; then
	echo "== U01：netfilter 已经是不重复打包的那版（fork 同步过了），跳过 =="
elif [ ! -f "$NFPATCH" ]; then
	echo "!! 仓库里没带 u01_local/patches/netfilter-ipt-clash.patch，合一补丁打不上"
elif ! command -v patch >/dev/null 2>&1; then
	echo "!! runner 上没有 patch(1)"
else
	if patch -p1 -N --dry-run < "$NFPATCH" >/tmp/u01_nf.log 2>&1 &&
	   patch -p1 -N < "$NFPATCH" >>/tmp/u01_nf.log 2>&1; then
		echo "== U01：已打 netfilter 合一补丁（ip_tables.ko/x_tables.ko 只留 kmod-nf-ipt 一个户主）=="
	else
		echo "!! netfilter 补丁试打/正打失败，树和锁定 hash 对不上号，尾部："
		tail -20 /tmp/u01_nf.log
	fi
	# 谁还引用被删掉的包名，第 1 分钟就说出来，别等 96 分钟后 opkg 报"依赖满足不了"
	u01_ref=$(grep -rl --include=Makefile --include='*.mk' 'kmod-iptables' package feeds 2>/dev/null | head -10 || true)
	[ -n "$u01_ref" ] && echo "::warning::打完补丁仍有文件引用 kmod-iptables：$(echo $u01_ref | tr '\n' ' ')"
fi

# ---- 8) 修上游两个驱动的类型判定（本次刷机后 dmesg 实测的失败点）----
# 刷进去的 6.18.35 跑起来后，lbc 和 bms-vm 都只走到 probe 第一步就 -ENODEV：
#   pm8916-bms-vm 200f000.spmi:pmic@0:battery@4000: error -ENODEV: Device reported wrong type: 0xFFFF020D
#   pm8916-lbc    200f000.spmi:pmic@0:charger@1000: error -ENODEV: Device reported wrong type: 0xFFFF1502
# 低 16 位 PM8916_BMS_VM_TYPE=0x020D / PM8916_LBC_CHGR_TYPE=0x1502 一模一样，高 16 位都是 0xFFFF。
# 两处都写成：
#   unsigned int tmp;
#   regmap_bulk_read(map, reg + PM8916_PERPH_TYPE, &tmp, 2);   // SPMI val_bits=8 ⇒ 只填低 2 字节
# count=2 只写缓冲区前 2 字节，`unsigned int` 的高半截是没初始化的栈垃圾就直接参与 != 比较
# ⇒ 判定在任何 PM8916 上都恒假，跟本机硬件好坏无关（同一份文件的 FIFO 读数用的就是 u16 数组）。
# BMS-VM 的 OCV 也用了同一个写法（last_ocv = tmp * 300），会把垃圾高位乘进电压里，一并换 u16。
# 补丁基线 = gregkh/linux@v6.18.35 的两个文件原文，本地 patch -p1 往返验过才提交。
# 目录名跟着 KERNEL_PATCHVER 走（别写死 patches-6.18）；内核片段会在 prepare 阶段按文件名排序打上。
KPD=target/linux/msm89xx/patches-$KV
KPPATCH_SRC="$REPO_DIR/u01_local/patches/pm8916-charger-type-check.patch"
mkdir -p $KPD
if [ -f "$KPD/900-pm8916-charger-type-check.patch" ]; then
	echo "== U01：patches-$KV 里已经有 900-pm8916-charger-type-check.patch（fork 同步过？），不覆盖 =="
elif [ -f "$KPPATCH_SRC" ]; then
	cp "$KPPATCH_SRC" "$KPD/900-pm8916-charger-type-check.patch"
	echo "== U01：已把类型判定补丁放进 $KPD/900-pm8916-charger-type-check.patch =="
else
	echo "!! 仓库里没带 u01_local/patches/pm8916-charger-type-check.patch，lbc/bms-vm 还是会 -ENODEV"
fi

# ---- 7b) 第 7 跑：内核侧补门（PMIC 门 + DT 缺属性兜底），一次全带上 ----
# 上游 drivers/power/supply/pm8916_lbc.c 只写 VDD_MAX/VDD_SAFE/IBAT_MAX/IBAT_SAFE/
# TCHG_MAX_EN/CHG_CTRL 这六个寄存器；CAF 原厂 qpnp-linear-charger.c 每次开机还要写：
#   CHGR(0x1000)：VIN_MIN(0x47)=4470mV、清 CHG_FAILED(0x4A bit7) 闩、关 IBATTERM
#                 EOC(0x5B bit3)、关 CHG_WDOG_EN(0x65)、把 VBAT_DET 比较器 override
#                 成低(0xEE bits1:0=2；安全寄存器，先往 0xD0 写 0xA5)
#   BAT_IF(0x1200)：BPD_CTRL(0x48) bits1:0 选"热敏检测"——原厂 DTB 没有 qcom,bpd-detection，
#                 CAF 走 default 分支 = BATT_THM_EN；选成 BID 或干脆关掉，PMIC 判
#                 "没电池"，通路不开；VREF_BAT_THM_CTRL(0x4A)=0xC0 把热敏基准强制常开
#   CHG_USB(0x1300)：ENUM_T_STOP(0x4E)=0，别留枚举超时
#   MISC(0x1600)：BOOT_DONE(0x42)=0x80——这颗不写，PMIC 一直按"开机阶段"的约束压着
#                 VDD/IBAT，CHGR 配成什么都不算数（原厂安卓是 LK 写的，我们这版没人写）
# 这四个外围基址就是原厂安卓 DTB 那颗的 chgr@1000/bat-if@1200/usb-chgpth@1300/
# chg-misc@1600，和作者 dtsi 里 pm8916_charger 的 reg 四个值逐字一致，所以补丁直接用
# chg->reg[LBC_BAT_IF/LBC_USB/LBC_MISC]，不自己加偏移。
# 还有一类不是"门"而是"DT 缺属性就整个不配"：probe_dt() 读不到
# qcom,fast-charge-safe-voltage/-current 就 return -EINVAL，于是 VDD_SAFE/IBAT_SAFE
# 没人写、charge_current_safe 停 0、IBAT_MAX 被 clamp 到 90mA 地板，
# charge_voltage_max 还会跟 0 做 clamp 出现下溢。现在按原厂值兜底
# （vddsafe 4350mV / ibatsafe 1000mA / ibatmax 500mA / max-voltage 4.35V）。
# 我们覆盖层注进 $DTS 的那几行今天是够的（4350mV/700mA/monitored-battery），
# 兜底是给 fork 同步、dts 改动、monitored-battery 缺失（那样 probe 直接 -ENOENT）留的。
# 实测形状：VSYS 一直贴着 VBAT-0.11V 从不往 4.2V 抬、加四核负载时 USBIN 不降
# (4.865→4.868) 而 VBAT 掉 70mV——"软件以为在充、电没进电池"就是这么个曲线。
# 补丁不是手写：本地 make_lbc_patch.py 以 api.github.com 下的 gregkh/linux v6.18.35
# 原文为基底做"锚点必须命中一次"的精确替换后 diff 生成，patch --batch -p1 回放自证，
# 和上面那颗 900-pm8916-charger-type-check.patch 按 CI 文件名顺序串打验过（不留 .rej），
# 再过"宏全有定义 / 无裸 min() / 括号配对"的静态自检——本机没有交叉编译器，
# 编译期才会炸的东西必须在这里先炸，不然白等两小时。
# 刷完验收就看 dmesg 里 "charge gates:" 那一行：VDD_MAX/IBAT_MAX/VIN_MIN/CHG_CTRL/
# CHG_STATUS/CHG_FAILED/BAT_PRES/TEMP_OK 一次读全，不用再依赖 regmap debugfs。
KPGB="$REPO_DIR/u01_local/patches/pm8916-lbc-gates.patch"
KPD=target/linux/msm89xx/patches-$KV
mkdir -p $KPD
if [ -f "$KPD/910-pm8916-lbc-gates.patch" ]; then
	echo "== U01：patches-$KV 里已经有 910-pm8916-lbc-gates.patch（fork 同步过？），不覆盖 =="
elif [ -f "$KPGB" ]; then
	cp "$KPGB" "$KPD/910-pm8916-lbc-gates.patch"
	echo "== U01：已把补门补丁放进 $KPD/910-pm8916-lbc-gates.patch =="
else
	echo "!! 仓库里没带 u01_local/patches/pm8916-lbc-gates.patch，门和兜底都仍靠 PMIC 上电默认值"
fi

# 注入自检：哪一项没落上就直接终止，别花一个半小时编一版跟上一版一样的固件
u01_fail=0
grep -q '^CONFIG_BATTERY_PM8916_BMS_VM=y' $CFG                       || { echo "!! BMS-VM 没进 $CFG"; u01_fail=1; }
[ -f "$KPD/910-pm8916-lbc-gates.patch" ]                             || { echo "!! $KPD/910-pm8916-lbc-gates.patch 不在位，PMIC 门和 DT 兜底都没人配"; u01_fail=1; }
for g in PM8916_LBC_CHGR_VIN_MIN PM8916_LBC_BAT_IF_BPD_CTRL PM8916_LBC_MISC_BOOT_DONE \
         PM8916_LBC_USB_ENUM_T_STOP PM8916_LBC_CURRENT_MAX_DEFAULT; do
	grep -q "$g" "$KPD/910-pm8916-lbc-gates.patch" \
		|| { echo "!! 补门补丁里没有 $g 那笔，八成复制错了文件或是旧版"; u01_fail=1; }
done
grep -q "charge gates:" "$KPD/910-pm8916-lbc-gates.patch"             || { echo "!! 补丁里没有 dmesg 回读，刷完没法一眼看门开没开"; u01_fail=1; }
grep -q '^CONFIG_CHARGER_PM8916_LBC=y' $CFG                           || { echo "!! CHARGER_PM8916_LBC 没进 $CFG"; u01_fail=1; }
grep -q '^CONFIG_DEBUG_FS=y' $CFG                                     || { echo "!! DEBUG_FS 没进 $CFG，刷完还是读不到 PMIC 寄存器"; u01_fail=1; }
grep -q "DEVICE_DTS := msm8916-xinxun-wf2" target/linux/msm89xx/image/msm8916.mk || echo "!! 警告：上游 device 规则没登记 wf2 的 DTS，$DTS 可能不参与编译"
grep -q "$U01_MARK" $DTS                                             || { echo "!! DTS 没打进 wf2"; u01_fail=1; }
grep -q '&pm8916_charger' $DTS                                       || { echo "!! 充电块没进 $DTS"; u01_fail=1; }
grep -q '&pm8916_usbin' $DTS                                         || { echo "!! 没把 pm8916_usbin 关掉，usb_vbus 中断线会撞车(-EBUSY)"; u01_fail=1; }
grep -q 'u01_bat:' $DTS                                              || { echo "!! $DTS 里没有 u01_bat，充电器引用的 battery 节点不存在"; u01_fail=1; }
grep -q "model = \"$U01_MODEL\"" $DTS                                || { echo "!! 机型名没覆盖进 $DTS，首页还会显示 ufi-wf2 4G Modem Stick"; u01_fail=1; }
# 用户件走 files/ 覆盖层，这里验的是"镜像会吃到的那一份"里齐全
# （首启由 etc/uci-defaults/99-u01-* 补 chmod + enable，git 带过来的权限位不可靠）
for f in usr/libexec/u01simd.py usr/libexec/netled.py usr/libexec/ledidle.py \
         usr/libexec/batled.py usr/libexec/chg_regs.py usr/libexec/u01band.py \
         etc/init.d/u01sim etc/init.d/netled etc/init.d/ledidle \
         etc/init.d/batled etc/init.d/u01band \
         etc/u01band.conf \
         etc/hotplug-gcreboot.json \
         etc/uci-defaults/99-u01-lamps etc/uci-defaults/99-u01-rndis \
         etc/uci-defaults/99-u01-ssh etc/dropbear/authorized_keys; do
	[ -n "$OVL" ] && [ -s "$OVL/$f" ] || { echo "!! 覆盖层缺文件 $f (OVL=${OVL:-无})"; u01_fail=1; }
done
# 两份覆盖件的内容也要当场验，光"文件在"不够：
#  - batled 必须是有 LedBars 后端的那版：DTB 的 leds-gpio 已经把四个脚请求走了，
#    裸 GPIO_V2_GET_LINE 必 EBUSY，上一版开机就是这样崩循环 6 次的。
#  - 拔线钩子不能再盯 usb-detect：那颗 usb-detect@1300 已经被上面 disable 掉，
#    extcon0 不存在，钩子条件恒假 = 白烘。
[ -n "$OVL" ] && grep -q 'class LedBars' "$OVL/usr/libexec/batled.py" \
	|| { echo "!! 覆盖层的 batled.py 还是没有 LedBars 后端的那版（裸 GPIO 会 EBUSY 崩循环）"; u01_fail=1; }
[ -n "$OVL" ] && grep -q 'usb-detect' "$OVL/etc/hotplug-gcreboot.json" \
	&& { echo "!! 覆盖层的 hotplug-gcreboot.json 还写着 usb-detect，得改指 pm8916-lbc 那颗 extcon"; u01_fail=1; }
# 基带固件：qcom-firmware 那个包切出来的是 WF2 的 mba.mbn/modem.*，这颗 U01 的 MPSS
# 认不了它（dmesg: MPSS authentication failed: -19，基带整个起不来、无 wwan0）。
# 覆盖层必须带本机自己的原厂固件盖住它，判据用 mba.mbn/modem.mdt 的 md5。
FWMD5_70=70ed2caf230b570da59b97e9ed36a582	# mba.mbn
FWMD5_AB=ab584c412654613237df7b98f107cb1e	# modem.mdt
for pair in "mba.mbn $FWMD5_70" "modem.mdt $FWMD5_AB"; do
	set -- $pair
	f="$OVL/lib/firmware/$1"; want="$2"
	if [ ! -s "$f" ]; then
		echo "!! 覆盖层缺 lib/firmware/$1（不盖住 WF2 的话刷完基带就死）"; u01_fail=1
	else
		got=$(md5sum "$f" | cut -d" " -f1)
		[ "$got" = "$want" ] || { echo "!! 覆盖层 lib/firmware/$1 md5=$got 应为 $want"; u01_fail=1; }
	fi
done
nfw=$(ls "$OVL/lib/firmware" 2>/dev/null | grep -c -E '^(mba\.mbn|modem\.(b[0-9]+|mdt))$')
[ "$nfw" = 22 ] || { echo "!! 覆盖层 lib/firmware 只有 $nfw 个 mba/modem 文件，应为 22（少一个 PIL 就认证不过）"; u01_fail=1; }
grep -q '^CONFIG_PACKAGE_python3=y' .config 2>/dev/null \
	|| echo "!! 警告：.config 里 python3 没开，用户态服务全都起不来（应改 config/wf2.config）"
[ -e package/libs/libffi/Makefile ] || { echo "!! package/libs/libffi 不在树里，glib2 打不出 ipk"; u01_fail=1; }
command -v mcopy >/dev/null 2>&1    || { echo "!! 没有 mcopy，qcom-firmware 切不出 mba.mbn/modem.*"; u01_fail=1; }
[ -f "$NFMK" ] || { echo "!! $NFMK 不在树里（锁定 hash 变了？路径找不到）"; u01_fail=1; }
grep -q '^define KernelPackage/iptables$' $NFMK 2>/dev/null \
	&& { echo "!! netfilter 合一补丁没生效，kmod-iptables 还在和 kmod-nf-ipt 抢 ip_tables.ko"; u01_fail=1; }
[ -f "$KPD/900-pm8916-charger-type-check.patch" ] \
	|| { echo "!! $KPD/900-pm8916-charger-type-check.patch 不在位，lbc/bms-vm 仍会 wrong type"; u01_fail=1; }
if [ "$u01_fail" != 0 ]; then
	echo "== U01 注入自检失败，终止编译 =="
	ls -l "$OVL/etc/" 2>&1 | sed 's/^/   /'
	exit 1
fi
echo "== U01 注入自检通过：BMS-VM + LBC 充电（含 910 补门补丁：CHGR/BAT_IF/CHG_USB/MISC 四路门 + DT 兜底）+ bat:1..4 + 机型名=$U01_MODEL + DEBUG_FS + 覆盖层用户件齐全（含拔线钩子/频段锁）+ 本机原厂基带固件 22 件 + libffi/mcopy 就位 + netfilter 已合一 =="

# ---- 7) 依赖缺口体检（只报，不拦）----
# prepare-tmpinfo 扫全部 Makefile 时会把"某包依赖一个整棵树都不存在的包名"打成
#   WARNING: Makefile 'package/feeds/packages/glib2/Makefile' has a dependency on 'libffi', which does not exist
# 上次这行在编译开头就印出来了（日志 L24），却要等到 95 分钟后的打包阶段才变成真错误。
# 这里把它提前打出来当线索。注意不能拿来当门槛：busybox→libpam/libtirpc、python3→libffi
# 都是条件依赖（没真选上那条扩展就永远不碰），按名字拦会把好端端的构建误杀。
# 真正会拦下来的是上面那条硬检查（libffi 必须已经在树里）+ workflow 里的"关键链先编"。
echo "== U01：依赖缺口体检 =="
u01_scan=/tmp/u01_scan.log
make prepare-tmpinfo >"$u01_scan" 2>&1 || make prereq >>"$u01_scan" 2>&1 || true
if grep -q "which does not exist" "$u01_scan" 2>/dev/null; then
	echo "   （下面这些是\"树里没有这个包名\"，被选中的包标了 STAR，只当线索）"
	u01_re="Makefile '([^']+)' has a (build )?dependency on '([^']+)', which does not exist"
	while IFS= read -r line; do
		[[ "$line" =~ $u01_re ]] || continue
		src="${BASH_REMATCH[1]}"; dep="${BASH_REMATCH[3]}"
		pkg="${src%/*}"; pkg="${pkg##*/}"
		if grep -qE "^CONFIG_(PACKAGE|DEFAULT)_${pkg}=y" .config 2>/dev/null; then
			echo "  ★ $pkg 需要 $dep（$pkg 已被选中，条件依赖也会这样显示，别直接当故障）"
		fi
	done < "$u01_scan"
else
	echo "   没有扫出依赖缺口"
fi
