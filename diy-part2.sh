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
# 5) 蜂窝（第 14 跑新烘的三件）：
#    a. WCNSS/Pronto 固件盖回本机原厂九件。镜像的 mba/modem 已逐个 md5 对上原厂，但
#       /lib/firmware/wcnss.* 还是 WF2 那套 —— QMI_CSI 的服务端在 WCNSS、客户端在 MPSS，
#       原厂 MPSS 配别人家 Pronto 的结果是每次开机 T+24 必炸
#       coex_interface.c:530:MCS_CXM assertion（dmesg 里 remoteproc crash #1）。
#       已核对原厂九个和 WF2 九个同名（mdt/b00/b01/b02/b04/b06/b09/b10/b11），盖完不留混代文件。
#       ⚠️ 代价：热点/Wi-Fi 用的是这颗 Pronto，刷完要实测 AP 起不起得来；起不来就把这九件
#       退回 WF2 版重编（adb 走 USB，不受影响）。
#    b. 两颗原厂 qmi 服务在覆盖层里换成空壳（同名文件覆盖，已用 files/etc/rc.local 的 md5
#       逐字节证实覆盖层确实能盖住包装进去的同一份文件）。qmi-modem-410-init 开机 25 秒
#       无条件 repower SIM：emm-detached → QMI error 37 UimUninitialized → netifd 拆会话并
#       disable modem → MM 重编号 Modem/0→/1 → 之后 ifstatus modem 恒 up=false 且不自愈。
#       手动 `ifup modem` 约 20~25 秒恢复（这台机上三次独立复现，含 MPSS 自己崩的那次）。
#    c. u01netmond 就是把这个 remedy 常驻化：只在"没有走 wwan 的 IPv4 默认路由 + 接口既没
#       up 也没 pending"时才 ifup 一次，开机头 90 秒不动，两次动作隔 120 秒。
#    d. ramoops 烘进 DT：/proc/config.gz 里 PSTORE/PSTORE_CONSOLE/PSTORE_RAM 早就 =y，
#       只缺节点。周期重启的成因到现在没抓到现行（panic 后 /proc/sys/kernel/panic=3 直接
#       复位，logring 全丢），刷完第一次复现就能从 /sys/fs/pstore/console-ramoops-0 看到
#       复位前最后的控制台输出。槽位选 512 MB 那条 bank 的最顶端 0x9fe00000 2 MB + no-map，
#       这是拿本机 r13 的真 dmesg 量的，不是猜的：
#         Memory: 372360K/524288K available  ⇒ RAM = 0x80000000..0xA0000000，这 2 MB 正好贴顶；
#         cma: Reserved 16 MiB at 0x9e600000 ⇒ CMA 到 0x9f600000 就停，够不着；
#         OF: reserved mem 最高的一条是 wcnss 0x8e200000..0x8e7fffff，其余全在 0x86~0x8d。
#    e. u01pstore 开机归档：上面那块是 RAM 里的环形缓冲，下一次 panic 就把上一次的盖掉，
#       而这台 12~15 分钟复位一次 ⇒ 只看 /sys/fs/pstore 等于永远只能拿到"最近一次"。
#       挂载不用管：base-files 的 etc/init.d/boot 里已有
#       `grep -q pstore /proc/filesystems && mount -t pstore pstore /sys/fs/pstore`
#       （锁定树 05d3cf2a 那份就有），所以这个服务只做"复制走 + 删原记录 + 记一行
#       bootlog"。bootlog 的 crashed=0/1/nodir 才是判据：复位过而 crashed=0，就说明
#       这条路（panic→pstore）根本不适用于这次复位，得换方向查。
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
		/* 4.35 V，不是 4.20 V：原厂关机档案 qcom,qrd-4v2-2200mah-data 里
		 * qcom,max-voltage-uv=4350000，而实测 VBAT 静置 4.303~4.307 V。
		 * pm8916_lbc.c 把 charge_voltage_max 夹到 charge_voltage_safe 之后才编 VDD_MAX，
		 * 4.20 V → 0x08，永远低于电池现压 ⇒ 充电环根本不启动。两处必须一起改。 */
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
	/* 和上面 u01_bat 的 4.35 V 配对：lbc 先用这个 safe 值夹 charge_voltage_max，
	 * 只改电池节点会被这里夹回 4.20 V，VDD_MAX 还是 0x08。 */
	qcom,fast-charge-safe-voltage = <4350000>;
	qcom,fast-charge-safe-current = <700000>;
	monitored-battery = <&u01_bat>;
};

&pm8916_usbin {
	status = "disabled";
};
CHGEOF
fi

# 崩溃日志通道（第 14 跑新增）：这台机器每 12~15 分钟自己重启一次，而
# /proc/sys/kernel/panic=3 ⇒ panic 的打印还没来得及出控制台就复位了，pstore 里空的，
# 于是"重启"这件事完全没有证据。/proc/config.gz 里 PSTORE / PSTORE_RAM / PSTORE_CONSOLE /
# PSTORE_PMSG 全都已经是 y，唯一缺的是 DT 里那段保留内存，所以纯 DTS 就能补上。
# 落点：本机 r13 的真 dmesg 量的 —— Memory: 372360K/524288K ⇒ RAM 就是 0x80000000+0x20000000，
# cma: Reserved 16 MiB at 0x9e600000（到 0x9f600000 停），OF: reserved mem 最高一条到
# 0x8e7fffff，所以取最顶 2 MB（0x9fe00000..0xA0000000）并 no-map，谁也不压。
# 刷好后 /sys/fs/pstore/console-ramoops-0 = 上次复位前最后的控制台输出。
if ! grep -q 'compatible = "ramoops"' $DTS; then
cat >> $DTS <<'RMEOF'

/* last-resort crash log: 2 MB at the very top of the 512 MB bank.
 * reg is 4 cells because msm8916.dtsi's reserved-memory sets #address-cells/#size-cells
 * = <2> (siblings write <0x0 0x86000000 0x0 0x300000>); a 2-cell reg here is a dtc error. */
/ {
	reserved-memory {
		ramoops@9fe00000 {
			compatible = "ramoops";
			reg = <0x0 0x9fe00000 0x0 0x200000>;
			record-size = <0x20000>;
			console-size = <0x100000>;
			pmsg-size = <0x20000>;
			no-map;
		};
	};
};
RMEOF
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

# ---- 7c) 第 11 跑：bam-dmux 不做电源塌陷（"读卡却一个字节不上网"的根因） ----
# 现象（本机实测）：卡读得到、驻网正常（CHN-UNICOM 46001 / LTE）、bearer 已连、
# IPv4+网关+DNS 都发给 netifd 了，可 wwan0 死：
#   ip link set wwan0 up -> EINVAL，carrier_up_count=0，RX/TX 全 0 字节，
#   没有默认路由，ping 直接 "Network unreachable"。
# 链路：wwan0 由 qcom_bam_dmux 在 modem 通告通道时才 register_netdev 创建；
# ndo_open -> bam_dmux_submit_skb -> pm_runtime_get_sync()。而本机这版原厂 MPSS
# 不回 power-collapse 的 pc-ack（开机日志 "Timed out waiting for remote side to
# suspend" 就是它），于是 runtime_suspend 里那句 reinit_completion(&pc_ack_completion)
# 之后的任何一次 runtime_resume，三处 BAM_DMUX_REMOTE_TIMEOUT(2s) 等待全超时，
# 或 !dmux->rx 直接 -ENXIO —— PM core 把设备永久 latch 进 RPM_ERROR
# （sysfs runtime_status=error，重启前解不开）。
# 用户态判死：echo on > power/control 不但解不开，还会在 MPSS 还没起来时抢先做
# 一次必失败的 resume，同样 latch；手动 stop/start remoteproc 更糟（modem 断电后
# 再也不通告 bam-dmux 通道，wwan0 直接消失，只能重启）。所以只能内核侧断掉这条路。
# 补丁基线 = api.github.com 下的 gregkh/linux@v6.18.35 该文件原文，本地
# make_bam_patch.py 按函数整体切块生成 + patch --batch -p1 往返逐字节自证，
# 和 900/910 两颗不重叠（那两颗动 drivers/power/supply，这颗动 drivers/net/wwan）。
# 改法：
#   runtime_suspend -> 只 dev_dbg，永不 pc_vote(false)，也就不再 reinit_completion；
#   runtime_resume  -> 照常 pc_vote(true)，但不再等 ack、不等 pc_state；缺 rx 时
#                      用 bam_dmux_power_on()+bam_dmux_pc_ack() 原地重建；
#                      TX 申请失败不再反手调 suspend（那会把刚建好的 RX 拆掉）。
# 代价：数据通路一直保持功耗投票，省不下基带侧那点电——这台是插电实验台，
# 换来的是"网能通"。验收看 ip link set wwan0 up 能否成功 + carrier/RX 计数是否动。
KPCB="$REPO_DIR/u01_local/patches/pm8916-bam-dmux-pc.patch"
KPD=target/linux/msm89xx/patches-$KV
mkdir -p $KPD
if [ -f "$KPD/911-pm8916-bam-dmux-pc.patch" ]; then
	echo "== U01：patches-$KV 里已经有 911-pm8916-bam-dmux-pc.patch（fork 同步过？），不覆盖 =="
elif [ -f "$KPCB" ]; then
	cp "$KPCB" "$KPD/911-pm8916-bam-dmux-pc.patch"
	echo "== U01：已把 bam-dmux 不塌陷补丁放进 $KPD/911-pm8916-bam-dmux-pc.patch =="
else
	echo "!! 仓库里没带 u01_local/patches/pm8916-bam-dmux-pc.patch，wwan0 还会被 RPM_ERROR 卡死"
fi

# ---- 912：modem 重启后把 bam-dmux 的数据面重建起来 ------------------------
# 911 只解决"别把 RX 拆掉"，解决不了"modem 换了实例"：两条环的描述符都是对着
# 上一个 MPSS 武装的。实测拆干净会话再 reload，wwan0 能 up、能配上 IP，
# ping 依然 3/3 全丢、dmesg 里 dmux 一行都不多——RX 环静默失灵，比报错更难查。
# 另一条路（会话还活着时 reload）则是 TX 环游标卡死，ndo_open 恒 -EAGAIN。
# 这颗把两件事都交给 remoteproc 的 subdev 钩子：stop（在 q6v5_stop 断电之前）
# 冲 TX 环、拆 RX 环、把 remote_channels 清零并 detach 网卡；prepare（在 MBA
# 点火之前）按冷启动同序重建，通道由 modem 重新发 CMD_OPEN 开回来。
# 顺带两处：pc 中断改成采样真实电平（重启期间这条线跳不止一次，取反推导会反），
# bam_dmux_power_on() 做成幂等（钩子和 modem 自己的上电请求都会调它）。
# 和 911 同一颗文件，串打顺序 911 -> 912，本地 make_bam_ssr_patch.py 已逐字节自证。
KPSB="$REPO_DIR/u01_local/patches/pm8916-bam-dmux-ssr.patch"
if [ -f "$KPD/912-pm8916-bam-dmux-ssr.patch" ]; then
	echo "== U01：patches-$KV 里已经有 912-pm8916-bam-dmux-ssr.patch（fork 同步过？），不覆盖 =="
elif [ -f "$KPSB" ]; then
	cp "$KPSB" "$KPD/912-pm8916-bam-dmux-ssr.patch"
	echo "== U01：已把 bam-dmux 重启重建补丁放进 $KPD/912-pm8916-bam-dmux-ssr.patch =="
else
	echo "!! 仓库里没带 u01_local/patches/pm8916-bam-dmux-ssr.patch，modem 重启后数据面还是死的"
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
# bam-dmux：只验 + 行（- 行是要拆掉的老代码，命中它反而说明没拆），三笔改动各验一条
[ -f "$KPD/911-pm8916-bam-dmux-pc.patch" ]                             || { echo "!! $KPD/911-pm8916-bam-dmux-pc.patch 不在位，读卡没网那个死 latch 还在"; u01_fail=1; }
grep -q '^--- a/drivers/net/wwan/qcom_bam_dmux.c' "$KPD/911-pm8916-bam-dmux-pc.patch" \
	|| { echo "!! 911 补丁动的不是 drivers/net/wwan/qcom_bam_dmux.c，文件拿错了"; u01_fail=1; }
for g in 'power collapse not used' 'bam_dmux_power_on(dmux)' 'bam_dmux_pc_ack(dmux)'; do
	grep -Fq "$g" "$KPD/911-pm8916-bam-dmux-pc.patch" \
		|| { echo "!! bam-dmux 补丁缺 $g 这一笔，多半是复制错了文件或版本不对"; u01_fail=1; }
done
# 这两条验的是"老代码必须已经拆掉"。用 if 而不是 A && { }：set -e 下 grep 没命中
# 会让整条语句返回非 0，脚本提前退出，门还没跑完就没了结论。
if grep -Eq '^\+.*wait_for_completion_timeout|^\+.*wait_event_timeout' "$KPD/911-pm8916-bam-dmux-pc.patch"; then
	echo "!! bam-dmux 补丁还在等 pc-ack/pc_state（原厂 MPSS 不回），resume 必超时 latch RPM_ERROR"; u01_fail=1
fi
if grep -Eq '^\+.*bam_dmux_pc_vote\(dmux, false\)|^\+.*bam_dmux_runtime_suspend\(dev\)' "$KPD/911-pm8916-bam-dmux-pc.patch"; then
	echo "!! bam-dmux 补丁还留着往下投票/反手调 suspend，RX 会被拆掉"; u01_fail=1
fi
# 数据网卡就是这颗模块编出来的（wwan0 由它在通道通告时创建）；没开的话补丁白打。
# 这里只警告不终止：.config 这时可能还没生成，硬失败会误杀。
grep -Eq '^CONFIG_QCOM_BAM_DMUX=[ym]' .config 2>/dev/null \
	|| echo "!! 警告：.config 里 QCOM_BAM_DMUX 没 =y/=m，设备上根本不会有 wwan0"
grep -q '^CONFIG_QCOM_SMP2P=y' .config 2>/dev/null \
	|| echo "!! 警告：QCOM_SMP2P 没开，pc/pc-ack 中断通道不存在"
# 912 只验 + 行；- 行是老代码，命中反而说明没拆干净。
[ -f "$KPD/912-pm8916-bam-dmux-ssr.patch" ]                             || { echo "!! $KPD/912-pm8916-bam-dmux-ssr.patch 不在位，modem 一重启 wwan0 就又成死数据面"; u01_fail=1; }
grep -q '^--- a/drivers/net/wwan/qcom_bam_dmux.c' "$KPD/912-pm8916-bam-dmux-ssr.patch" \
	|| { echo "!! 912 补丁动的不是 drivers/net/wwan/qcom_bam_dmux.c，文件拿错了"; u01_fail=1; }
for g in 'rproc_add_subdev' 'bam_dmux_subdev_prepare' 'bam_dmux_subdev_stop' \
		 'bam_dmux_tx_flush' 'bam_dmux_rx_rearm' 'IRQCHIP_STATE_LINE_LEVEL' 'restart_pending'; do
	grep -Fq "$g" "$KPD/912-pm8916-bam-dmux-ssr.patch" \
		|| { echo "!! 912 补丁缺 $g 这一笔，多半是复制错了文件或版本不对"; u01_fail=1; }
done
if grep -Eq '^\+.*(wait_for_completion_timeout|wait_event_timeout)' "$KPD/912-pm8916-bam-dmux-ssr.patch"; then
	echo "!! 912 补丁把 pc-ack 等待又带回来了（原厂 MPSS 不回），resume 必超时 latch RPM_ERROR"; u01_fail=1
fi
if grep -Eq '^\+.*bam_dmux_pc_vote\(dmux, false\)' "$KPD/912-pm8916-bam-dmux-ssr.patch"; then
	echo "!! 912 补丁还留着往下投票，RX 会被 modem 侧掉电拆走"; u01_fail=1
fi
# 实测：重启后的 MPSS 不会自己补 CMD_OPEN，只会应答 ndo_open 发的那条。一 detach，
# ip link set wwan0 up 就变 ENETDOWN，等于把唯一能开通道的路也堵死——不许出现在 912 里。
if grep -Eq '^\+.*netif_device_detach' "$KPD/912-pm8916-bam-dmux-ssr.patch"; then
	echo "!! 912 补丁把网卡 detach 了，重启后 wwan0 会卡在 ENETDOWN 打不开"; u01_fail=1
fi
# 设备侧实测过两条硬禁忌，写进内核就是雷：unbind 活着的 bam-dmux（MSS 断电态）
# = 整机硬复位；拿内核符号地址喂 devmem（高通 VA != PA）= 当场 panic。
if grep -Eq '^\+.*(device_release_driver|driver_detach|of_platform_device_destroy)' "$KPD/912-pm8916-bam-dmux-ssr.patch"; then
	echo "!! 912 补丁里出现了拆设备的那类调用，先停下来核一遍"; u01_fail=1
fi
# u01mpssd：点火服务必须"先拆会话再断电"，顺序反了就是把活会话留在 MSS 电源下。
[ -n "$OVL" ] && [ -s "$OVL/usr/libexec/u01mpssd.sh" ] \
	|| { echo "!! 覆盖层缺 usr/libexec/u01mpssd.sh，900 秒死线没人管"; u01_fail=1; }
if [ -n "$OVL" ] && [ -s "$OVL/usr/libexec/u01mpssd.sh" ]; then
	u01_ms="$OVL/usr/libexec/u01mpssd.sh"
	u01_a=$(grep -n -F 'service u01netmond stop' "$u01_ms" | head -1 | cut -d: -f1)
	u01_b=$(grep -n -F 'service modemmanager stop' "$u01_ms" | head -1 | cut -d: -f1)
	u01_c=$(grep -n -F 'ifdown "$INTF"' "$u01_ms" | head -1 | cut -d: -f1)
	u01_d=$(grep -n -F 'echo stop > "$RPROC"' "$u01_ms" | head -1 | cut -d: -f1)
	u01_e=$(grep -n -F 'echo start > "$RPROC"' "$u01_ms" | head -1 | cut -d: -f1)
	if [ -n "$u01_a" ] && [ -n "$u01_b" ] && [ -n "$u01_c" ] && [ -n "$u01_d" ] && [ -n "$u01_e" ] &&
	   [ "$u01_a" -lt "$u01_b" ] && [ "$u01_b" -lt "$u01_c" ] &&
	   [ "$u01_c" -lt "$u01_d" ] && [ "$u01_d" -lt "$u01_e" ]; then
		echo "== U01：u01mpssd 是 停netmond($u01_a)->停MM($u01_b)->ifdown($u01_c)->断电($u01_d)->点火($u01_e) =="
	else
		echo "!! u01mpssd 的拆会话->断电->点火 顺序不对($u01_a/$u01_b/$u01_c/$u01_d/$u01_e)：必须先拆会话再给 MSS 断电"; u01_fail=1
	fi
	for g in 'mba_anchor()' 'echo disabled > "$RECOV"' 'HORIZON=900' '--status'; do
		grep -qF -- "$g" "$u01_ms" || { echo "!! u01mpssd.sh 里没有 $g"; u01_fail=1; }
	done
	# 实测：崩溃自愈重点 MBA 时只打 "MBA booted"，不打 "Booting fw image mba.mbn"。
	# 锚点要是取后者，自愈之后读到的是旧时间，死线一路往前赶，服务变成每轮立刻断电。
	grep -qF 'grep -a "MBA booted"' "$u01_ms" \
		|| { echo "!! u01mpssd.sh 的 MBA 锚点没锚在 \"MBA booted\" 上，自愈之后计时会读到旧锚点"; u01_fail=1; }
	# 这台 BusyBox 没有 bc（算术只走 $(( )) 和 awk），写了 bc 服务就是起来报错
	if grep -Eq '(^|[^[:alnum:]_])bc([[:space:]]|$)' "$u01_ms"; then
		echo "!! u01mpssd.sh 用了 bc，这台 BusyBox 没有它"; u01_fail=1
	fi
	# 崩溃路径不能出现在这里：unbind 会把 wwan0 直接变没（实测只能重启找回）
	if grep -Eq 'unbind|rmmod' "$u01_ms"; then
		echo "!! u01mpssd.sh 里有 unbind/rmmod，那条路实测是整机硬复位"; u01_fail=1
	fi
fi
grep -q 'u01mpssd' "$OVL/etc/uci-defaults/99-u01-net" 2>/dev/null \
	|| { echo "!! 99-u01-net 没把 u01mpssd enable+start，第一次开机没人做定点点火"; u01_fail=1; }

grep -q '^CONFIG_CHARGER_PM8916_LBC=y' $CFG                           || { echo "!! CHARGER_PM8916_LBC 没进 $CFG"; u01_fail=1; }
grep -q '^CONFIG_DEBUG_FS=y' $CFG                                     || { echo "!! DEBUG_FS 没进 $CFG，刷完还是读不到 PMIC 寄存器"; u01_fail=1; }
grep -q "DEVICE_DTS := msm8916-xinxun-wf2" target/linux/msm89xx/image/msm8916.mk || echo "!! 警告：上游 device 规则没登记 wf2 的 DTS，$DTS 可能不参与编译"
grep -q "$U01_MARK" $DTS                                             || { echo "!! DTS 没打进 wf2"; u01_fail=1; }
grep -q '&pm8916_charger' $DTS                                       || { echo "!! 充电块没进 $DTS"; u01_fail=1; }
grep -q '&pm8916_usbin' $DTS                                         || { echo "!! 没把 pm8916_usbin 关掉，usb_vbus 中断线会撞车(-EBUSY)"; u01_fail=1; }
grep -q 'u01_bat:' $DTS                                              || { echo "!! $DTS 里没有 u01_bat，充电器引用的 battery 节点不存在"; u01_fail=1; }
# 充电压：上一版两个 4.20 V 让充电环根本不启动（实测 VBAT 静置 4.303~4.307 V，
# VDD_MAX 夹在 0x08 恒低于现压）。原厂关机档案 qcom,qrd-4v2-2200mah-data 写的是
# qcom,max-voltage-uv=4350000，所以这两处必须同时是 4.35 V，少改一处都会被另一处夹回。
grep -q 'voltage-max-design-microvolt = <4350000>' $DTS               || { echo "!! u01_bat 的 voltage-max 不是 4350000，充电环起不来"; u01_fail=1; }
grep -q 'fast-charge-safe-voltage = <4350000>' $DTS                   || { echo "!! pm8916_charger 的 safe-voltage 不是 4350000，会被夹回 4.20 V"; u01_fail=1; }
# 只看我们注入的那一段（文件末尾到 U01_MARK），基线 dts 里本来就有 4200000，那是被覆盖的旧值，不算错
if sed -n "/$U01_MARK/,\$p" $DTS | grep -q '4200000'; then
	echo "!! 注入段里还留着 4200000，两处电压没改干净"; u01_fail=1
fi
grep -q "model = \"$U01_MODEL\"" $DTS                                || { echo "!! 机型名没覆盖进 $DTS，首页还会显示 ufi-wf2 4G Modem Stick"; u01_fail=1; }
# 用户件走 files/ 覆盖层，这里验的是"镜像会吃到的那一份"里齐全
# （首启由 etc/uci-defaults/99-u01-* 补 chmod + enable，git 带过来的权限位不可靠）
for f in usr/libexec/u01simd.py usr/libexec/netled.py usr/libexec/ledidle.py \
         usr/libexec/batled.py usr/libexec/chg_regs.py usr/libexec/u01band.py \
         usr/libexec/u01netmond.sh \
         usr/libexec/u01mpssd.sh \
         etc/init.d/u01sim etc/init.d/netled etc/init.d/ledidle \
         etc/init.d/batled etc/init.d/u01band etc/init.d/u01netmond \
         etc/init.d/u01mpssd \
         etc/init.d/u01pstore \
         etc/u01band.conf \
         etc/hotplug-gcreboot.json \
         etc/uci-defaults/99-u01-lamps etc/uci-defaults/99-u01-rndis \
         etc/uci-defaults/99-u01-ssh etc/uci-defaults/99-u01-net \
         etc/uci-defaults/99-u01-pstore \
         etc/init.d/qmi-modem-410-init etc/init.d/qmi_auto_activate \
         etc/dropbear/authorized_keys; do
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
# 两颗原厂 qmi 服务必须是"空壳"。只看不像空壳的东西，注释里写着那些关键词是故意的
# （要说清原版干了什么），所以先把注释行剥掉再判。
if grep -vE '^[[:space:]]*#' "$OVL/etc/init.d/qmi-modem-410-init" 2>/dev/null | grep -qE 'procd_open_instance|uim-sim-power|/usr/bin/qmi'; then
	echo "!! 覆盖层的 qmi-modem-410-init 不是空壳：开机 25 秒那一脚 repower 会把刚建好的数据会话打死"; u01_fail=1
fi
if grep -vE '^[[:space:]]*#' "$OVL/etc/init.d/qmi_auto_activate" 2>/dev/null | grep -qE 'procd_open_instance|inhibit|/usr/bin/qmi'; then
	echo "!! 覆盖层的 qmi_auto_activate 不是空壳：respawn 常驻挂 monitor+inhibit，和 ModemManager 抢同一根 QMI 控制口"; u01_fail=1
fi
# 看门狗对 /proc/net/route 的解析：ash 的 read 会把"剩余全部字段"塞进最后一个变量，
# 少一个 rest 时 mask 会变成 "00000000 0 0 0"，判据恒假 —— 服务在跑但永远不动作，等于没烘。
# （这不是假想：本地写完就是这样，是真设备上拿三个样本跑出来的。）
grep -q 'read -r iface dest gw flags refcnt use metric mask rest' "$OVL/usr/libexec/u01netmond.sh" 2>/dev/null \
	|| { echo "!! u01netmond.sh 的 route 解析少了 rest 字段，默认路由判据恒假"; u01_fail=1; }
# 首启脚本必须 enable 之后还 start：uci-defaults 跑在 boot 的 done 阶段，rc.d 软链早读过了，
# 只 enable 的话第一次开机这服务是死的。
grep -qE '/etc/init.d/\$s start' "$OVL/etc/uci-defaults/99-u01-net" 2>/dev/null \
	|| { echo "!! 99-u01-net 只 enable 没 start，第一次开机看门狗不跑"; u01_fail=1; }
# 崩溃日志这条链：ramoops 有节点还不够，开机不归档就等于"下一次 panic 把它盖掉"。
grep -qE '>>[[:space:]]*/root/pstore/bootlog\.txt' "$OVL/etc/init.d/u01pstore" 2>/dev/null \
	|| { echo "!! u01pstore 不往 bootlog.txt 记那行 crashed=…：只有归档目录判不出'这次复位是不是 panic'"; u01_fail=1; }
grep -qE '/etc/init.d/\$s start' "$OVL/etc/uci-defaults/99-u01-pstore" 2>/dev/null \
	|| { echo "!! 99-u01-pstore 只 enable 没 start，第一次开机既不归档也没有 bootlog 第一行"; u01_fail=1; }
# ramoops 三个 size 加起来不能超过 reg 那 2 MB：超了内核只会 pr_info 一句
# "ramoops: memory size is too small" 然后整个 pstore 没有——DT 烘了等于没烘。
if [ -f $DTS ]; then
	u01_sum=0
	for u01_kv in $(sed -n '/ramoops@/,/};/p' $DTS |
			sed -n 's/^[[:space:]]*\(console\|record\|pmsg\|ftrace\|dmesg\)-size[[:space:]]*=[[:space:]]*<\(0x[0-9a-fA-F]*\)>;.*/\1=\2/p'); do
		u01_v=$(( ${u01_kv#*=} ))
		u01_sum=$((u01_sum + u01_v))
	done
	if [ "$u01_sum" -gt 0 ] 2>/dev/null && [ "$u01_sum" -le 2097152 ] 2>/dev/null; then
		echo "== U01：ramoops 三个 size 合计 $u01_sum B，落在 2 MB 窗口内 =="
	else
		echo "!! ramoops 的 console/record/pmsg-size 合计 $u01_sum B，超过 2 MB 窗口（内核会整块放弃 pstore）"
		u01_fail=1
	fi
fi
# u01simd 的 MPSS 重启要带上"当前没有 wwan 默认路由"这道闸，否则它会主动把数据会话打死
grep -q 'default_via_wwan' "$OVL/usr/libexec/u01simd.py" 2>/dev/null \
	|| { echo "!! u01simd.py 还是老逻辑（读不出就重启 MPSS，最多 3 次再来一轮），会把蜂窝打死"; u01_fail=1; }
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
# WCNSS（Pronto）固件：第 13 跑刷机后每次开机 T+22~24 必炸
#   qcom-q6v5-mss: fatal error received: coex_interface.c:530:MCS_CXM assertion
#                  QMI_CSI_CB_NO_ERR == req_cb_retval fail
# QMI_CSI 的服务端在 WCNSS 里、客户端在 MPSS 里。镜像的 mba/modem 已逐个 md5 对上本机原厂，
# 但 /lib/firmware/wcnss.* 九个全是 WF2 那套（wcnss.mdt 41d715d8 ≠ 原厂 62bb56b2，
# wcnss.b06 差 51 万字节），等于原厂 MPSS 配别人家 Pronto。这里把原厂九个也盖进去。
# 原厂九个和 WF2 九个同名（mdt/b00/b01/b02/b04/b06/b09/b10/b11），盖完不会留混代文件。
FWMD5_WC=62bb56b2bfd0a1aa1ef57ec44b51a396	# wcnss.mdt
for pair in "wcnss.mdt $FWMD5_WC"; do
	set -- $pair
	f="$OVL/lib/firmware/$1"; want="$2"
	if [ ! -s "$f" ]; then
		echo "!! 覆盖层缺 lib/firmware/$1（不盖住 WF2 的 wcnss，coex 断言每boot必炸）"; u01_fail=1
	else
		got=$(md5sum "$f" | cut -d" " -f1)
		[ "$got" = "$want" ] || { echo "!! 覆盖层 lib/firmware/$1 md5=$got 应为 $want"; u01_fail=1; }
	fi
done
nwc=$(ls "$OVL/lib/firmware" 2>/dev/null | grep -c -E '^wcnss\.(b[0-9]+|mdt)$')
[ "$nwc" = 9 ] || { echo "!! 覆盖层 lib/firmware 只有 $nwc 个 wcnss 文件，应为 9（少一个 PIL 分段就加载失败，WiFi 整个没了）"; u01_fail=1; }
grep -q 'compatible = "ramoops"' $DTS \
	|| { echo "!! ramoops 那块没进 $DTS，周期重启还是抓不到最后打印"; u01_fail=1; }
# ramoops 的 reg 必须和 reserved-memory 里的兄弟节点同宽。真凭据在 $DTS 自己的 include 链上：
# msm8916-xinxun-wf2.dts → msm8916-mifi.dtsi → msm8916-pm8916.dtsi → msm8916.dtsi，
# 最后那份 reserved-memory 写 #address-cells=<2> + #size-cells=<2>（tz@86500000 =
# <0x0 0x86500000 0x0 0x180000>）⇒ 只能是 4 cell；写成 2 cell dtc 当场报错，四个小时白等。
# 上一版这条门是拿"和 heredoc 一模一样的字面"去 grep，改坏字面就两边一起通过（沙箱反例抓的正是它），
# 现在改成数真树里兄弟节点的 cell，来源和 heredoc 不同，改任何一边都会露。
u01_reg_cells() { # u01_reg_cells <块起始样式> <文件>：该块里第一个 reg 的 cell 数（数不到给 0）
	sed -n "/$1/,/};/p" "$2" 2>/dev/null |
		sed -n 's/^[[:space:]]*reg[[:space:]]*=[[:space:]]*<\(.*\)>[[:space:]]*;.*$/\1/p' |
		head -1 | wc -w
}
u01_ddir=$(dirname $DTS)
u01_chain=" $DTS "
u01_lvl=$DTS
u01_hop=0
while [ $u01_hop -lt 6 ]; do
	u01_hop=$((u01_hop + 1))
	u01_next=""
	for u01_f in $u01_lvl; do
		for u01_i in $(sed -n 's/^[[:space:]]*#include[[:space:]]*"\([^"]*\.dtsi\)"[[:space:]]*$/\1/p' "$u01_f" 2>/dev/null); do
			u01_p="$u01_ddir/$u01_i"
			[ -f "$u01_p" ] || continue
			case "$u01_chain" in *" $u01_p "*) continue ;; esac
			u01_chain="$u01_chain$u01_p "
			u01_next="$u01_next $u01_p"
		done
	done
	u01_lvl=$u01_next
	[ -n "$u01_lvl" ] || break
done
u01_sib=0
u01_sibsrc=""
for u01_f in $u01_chain; do
	# $DTS 自己跳过：它那份 reserved-memory 就是本次注入写进去的，拿它当对照等于自己证自己。
	[ "$u01_f" = "$DTS" ] && continue
	u01_n=$(u01_reg_cells 'reserved-memory[[:space:]]*{' "$u01_f")
	if [ "$u01_n" -gt 0 ] 2>/dev/null; then u01_sib=$u01_n; u01_sibsrc=$u01_f; break; fi
done
u01_me=$(u01_reg_cells 'ramoops@[0-9a-fA-F]*' $DTS)
if [ "$u01_sib" -gt 0 ] 2>/dev/null && [ "$u01_me" -gt 0 ] 2>/dev/null; then
	if [ "$u01_me" = "$u01_sib" ]; then
		echo "== U01：ramoops 的 reg 是 $u01_me cell，和 $u01_sibsrc 里 reserved-memory 兄弟一致 =="
	else
		echo "!! ramoops 的 reg 是 $u01_me cell，$u01_sibsrc 的 reserved-memory 兄弟是 $u01_sib cell ⇒ dtc 会报错"
		u01_fail=1
	fi
else
	# include 链上没数到兄弟节点（树换了结构、dtsi 不在 target/linux/msm89xx/dts）：退回字面，
	# 4 cell 这条是照 msm8916.dtsi@05d3cf2a 定下来的，别让它静默跳过。
	grep -q 'reg = <0x0 0x9fe00000 0x0 0x200000>' $DTS \
		|| { echo "!! ramoops 的 reg 不是 4 cell 形式（且 include 链里数不到兄弟可比），dtc 会报错"; u01_fail=1; }
fi
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
echo "== U01 注入自检通过：BMS-VM + LBC 充电（含 910 补门补丁：CHGR/BAT_IF/CHG_USB/MISC 四路门 + DT 兜底）+ 充电压 4.35 V×2 + bat:1..4 + 机型名=$U01_MODEL + DEBUG_FS + ramoops（cell 数已和 dtsi 兄弟对过、三个 size 在窗口内）+ 崩溃日志开机归档 + 覆盖层用户件齐全（拔线钩子/频段锁/网卡看门狗/两颗 qmi 空壳）+ 本机原厂基带固件 22 件 + 原厂 WCNSS 9 件 + libffi/mcopy 就位 + netfilter 已合一 =="

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
