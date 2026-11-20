#!/bin/sh
# U01 蜂窝自愈看门狗。
#
# 为什么需要：这台机的 MPSS 会自己崩（第 13 跑镜像实测同一个 boot 里两次：
#   T+24  coex_interface.c:530:MCS_CXM assertion QMI_CSI_CB_NO_ERR == req_cb_retval fail
#   T+925 lte_ml1_common_timer.c:390:Assert 0 failed
# 每次崩完内核 remoteproc 会把 wwan0qmi0/at0/at1 拆掉重挂，ModemManager 于是重建对象并
# 换编号（logread: [modem1] ... -> creating modem ... -> [modem2]），netifd 的
# modemmanager 段拿的还是旧对象，结果 ifstatus modem 恒 up=false、available=true，
# 错误 MM_INVALID_ALLOWED_MODES_LIST，它自己永远不会再试。
# 实测 remedy：手动 `ifup modem`，25 秒内默认路由回来、api.github.com http 200（两次独立复现）。
#
# 所以这里只做一件事：确认真没路由了、而且 netifd 确实已经不在动手，才补一次 ifup。
# 三个条件缺一个都不动，免得和正常的开机建会话、或手工 ifdown 打架。

INTF=modem
LOG=/tmp/log/u01netmond.log
STAMP=/tmp/u01netmond.last
ROUTE_FILE=${ROUTE_FILE:-/proc/net/route}
STEP=30
GRACE=90			# 开机头 90 秒不动：基带、MM、netifd 都还在起来
COOL=120			# 两次动作至少隔 120 秒，别把 ifup 打成循环

say() {
	echo "up=$(cut -d. -f1 /proc/uptime) $*" >> "$LOG"
}

# IPv4 默认路由是否真走 wwan*。/proc/net/route 字段：
#   Iface Destination Gateway Flags RefCnt Use Metric Mask MTU Window IRTT
# Dest 和 Mask 同时为 00000000 才是默认路由；表头那行对不上，自然被跳过。
wwan_default() {
	local iface dest gw flags refcnt use metric mask rest
	# 最后一定要留一个 rest：ash 的 read 会把"剩余全部字段"塞进最后一个变量，
	# 只给 8 个变量时 mask 会变成 "00000000 0 0 0"（连着 MTU/Window/IRTT），永远比不中。
	while read -r iface dest gw flags refcnt use metric mask rest; do
		[ "$dest" = "00000000" ] || continue
		[ "$mask" = "00000000" ] || continue
		case "$iface" in wwan*) return 0 ;; esac
	done < "$ROUTE_FILE"
	return 1
}

ifstate() {
	ifstatus "$INTF" 2>/dev/null | jsonfilter -e "@.$1" 2>/dev/null
}

# --check：只回答"当前有没有走 wwan 的默认路由"，给自检和手工排查用，绝不动接口
if [ "$1" = "--check" ]; then
	wwan_default && echo yes || echo no
	exit 0
fi

say "start pid=$$ step=${STEP}s grace=${GRACE}s cool=${COOL}s"
while : ; do
	up=$(cut -d. -f1 /proc/uptime 2>/dev/null)
	[ -n "$up" ] || up=0
	if [ "$up" -ge "$GRACE" ] && ! wwan_default; then
		isup=$(ifstate up)
		pend=$(ifstate pending)
		# up=false 且 pending=false 才等于"netifd 已经不打算再连了"；pending=true 时它在重试，别插一脚
		if [ "$isup" != "true" ] && [ "$pend" != "true" ]; then
			last=$(cut -d. -f1 "$STAMP" 2>/dev/null)
			[ -n "$last" ] || last=0
			if [ $((up - last)) -ge "$COOL" ]; then
				echo "$up" > "$STAMP"
				say "no-wwan-default-route up=$isup pending=$pend -> ifup $INTF"
				ifup "$INTF" >> "$LOG" 2>&1
			fi
		fi
	fi
	sleep "$STEP"
done
