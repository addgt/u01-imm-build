#!/bin/sh
# U01 MPSS 定点点火。
#
# 这台 410/U01 上原厂 LTE L1 有个死线：MBA 起来整 900 秒必断言
#   lte_ml1_common_timer.c:390:Assert 0 failed
# 连续四轮实测（boot42/44/45/…）断言点全都落在 MBA+900s±3s，跟驻网、跟流量、
# 跟卡都不相干。断言本身不致命——致命的是崩溃路径：它会带着还活着的 bam-dmux
# 会话给 MSS 断电，实测 45 毫秒后整机硬复位，dmesg 连一行 reboot 都留不下。
#
# 所以不能等它断言。在断言前主动把会话拆干净，再 stop/start remoteproc0，
# 计时器跟着新的 MBA 重新起算；实测每 reload 一次续 900 秒，AP 安然无恙。
# 内核侧 912b 在 MSS 断电期间关掉 bam-dmux 总闸，prepare 不再碰 BAM；
# 等新实例上电、pc 线抬起来后才重建 TX/RX。这里负责拆装用户态会话。
#
# 拆会话的顺序不能换（netmond 先把 ifup 抢掉 → MM 放掉 bearer → ifdown 关通道
# → 才轮到断电）。crashed 是电源已经没了，必须先走 recovery=recover；普通
# stop/start 对 crashed 无效（stop 回 EINVAL，start 会因 power 仍为 1 空返回）。
RPROC=/sys/class/remoteproc/remoteproc0/state
RECOV=/sys/class/remoteproc/remoteproc0/recovery
LOG=/tmp/log/u01mpssd.log
HORIZON=900			# MBA -> 断言的实测死线
LEAD=75			# 提前动手：拆会话 ~10s + 断电 ~8s + 点火 ~33s + 余量
STEP=10
GRACE=60			# 开机头一分钟不碰，等 netmond/MM 把首轮拨号做完
DEADMAX=45			# 不在 running 态连续这么久就去补一次点火

INTF=modem

say() {
	echo "up=$(cut -d. -f1 /proc/uptime 2>/dev/null) $*" >> "$LOG"
}

# 最近一次 MBA 点火的时间戳（dmesg 里那行的 [ 秒.微秒 ]）。
# 锚点选 "MBA booted" 而不是 remoteproc 的 "Booting fw image mba.mbn"：实测
# 内核崩溃自愈（recovery）那条路重新点 MBA 时只补前者，取后者的话自愈之后
# 永远读到的是上一轮的旧时间，死线一路往前赶，服务就变成每轮都立刻断电。
mba_anchor() {
	dmesg 2>/dev/null | grep -a "MBA booted" | tail -1 |
		sed -n 's/.*\[\ *\([0-9][0-9]*\)\.[0-9]*\].*/\1/p'
}

rproc_state() {
	[ -f "$RPROC" ] || { echo missing; return; }
	cat "$RPROC" 2>/dev/null
}

# 断电 -> 点火这一段绝不许被 stop/TERM 打断：modem 停在 offline 没人接手，
# 蜂窝就再也回不来了（除非整机重启）。TERM 只置标记，本轮走完了再退。
STOPREQ=0
on_term() { STOPREQ=1; }
trap on_term TERM INT

wait_running() {
	local tries=0 old_anchor="$1" state anchor

	while [ "$tries" -lt 40 ]; do
		state=$(rproc_state)
		anchor=$(mba_anchor)
		if [ "$state" = "running" ] && [ -n "$anchor" ] && [ "$anchor" != "$old_anchor" ]; then
			return 0
		fi
		sleep 1
		tries=$((tries + 1))
	done
	say "  等新 MBA 超时：state=$(rproc_state) anchor=$(mba_anchor) old=$old_anchor"
	return 1
}

wait_interface_up() {
	local tries=0 up

	while [ "$tries" -lt 30 ]; do
		up=$(ubus call network.interface.modem status 2>/dev/null |
			jsonfilter -e '@.up' 2>/dev/null)
		[ "$up" = "true" ] && return 0
		sleep 2
		tries=$((tries + 1))
	done
	say "  modem 接口 60s 未 up"
	return 1
}

cycle() {
	local why="$1" state old_anchor

	old_anchor=$(mba_anchor)
	say "cycle($why) deadline=$2：先拆会话"
	service u01netmond stop >/dev/null 2>&1
	sleep 2
	service modemmanager stop >/dev/null 2>&1
	sleep 3
	ifdown "$INTF" >/dev/null 2>&1
	sleep 3

	state=$(rproc_state)
	if [ "$state" = "crashed" ]; then
		say "  crashed -> recovery=recover"
		echo recover > "$RECOV" 2>/dev/null
	else
		say "  stop remoteproc（会话已拆，state=$state）"
		echo stop > "$RPROC" 2>/dev/null
		sleep 8
		say "  start remoteproc"
		echo start > "$RPROC" 2>/dev/null
	fi

	if ! wait_running "$old_anchor"; then
		say "  点火未确认，暂不重装会话"
		return 1
	fi

	# 912b 已在新实例上电后重建两条环，这里只把会话装回去并等 netifd 真 up。
	say "  重装会话 state=$(rproc_state) mba=$(mba_anchor)"
	service modemmanager start >/dev/null 2>&1
	sleep 12
	ifup "$INTF" >/dev/null 2>&1
	if wait_interface_up; then
		say "  modem 接口已 up"
	else
		say "  modem 接口未 up，交给 netmond 继续重试"
	fi
	service u01netmond start >/dev/null 2>&1
	say "  本轮点火完成，下一轮锚点=$(mba_anchor)"
}

# --status：只回一句当前计时，不动任何东西（验收/排查时对着它看）
if [ "$1" = "--status" ]; then
	a=$(mba_anchor)
	u=$(cut -d. -f1 /proc/uptime)
	if [ -n "$a" ]; then
		f=$(awk -v x="$a" -v h="$HORIZON" -v l="$LEAD" 'BEGIN{printf "%d", x+h}')
		printf 'state=%s mba=%s assert_at=%s now=%s left=%s
' 			"$(rproc_state)" "$a" "$f" "$u" "$((f - u))"
	else
		printf 'state=%s mba=none now=%s
' "$(rproc_state)" "$u"
	fi
	exit 0
fi

say "start pid=$$ horizon=${HORIZON}s lead=${LEAD}s"

# 断言时内核 recovery 会自己走一遍崩溃重启——那正是带着活会话断电的那条路。
# 实测 recovery=disabled 能跨过 925 秒，所以常驻关掉它，重启由本服务发起。
if [ -w "$RECOV" ]; then
	echo disabled > "$RECOV" 2>/dev/null && say "recovery=disabled"
fi

dead=0
while : ; do
	up=$(cut -d. -f1 /proc/uptime 2>/dev/null)
	[ -n "$up" ] || up=0

	state=$(rproc_state)
	if [ "$state" = "missing" ]; then
		say "没有 $RPROC，这颗 SoC 不归本服务管，退出"
		exit 0
	fi

	# remoteproc 不在（崩溃后停在 offline、或别人手动 stop 过）：攒够时间就补点火。
	if [ "$state" != "running" ]; then
		dead=$((dead + STEP))
		if [ "$dead" -ge "$DEADMAX" ] && [ "$up" -ge "$GRACE" ]; then
			dead=0
			cycle "state=$state" "-"
			echo disabled > "$RECOV" 2>/dev/null
			if [ "$STOPREQ" = 1 ]; then
				say "收到停止请求，本轮已收尾，退出"
				exit 0
			fi
		fi
		sleep "$STEP"
		continue
	fi
	dead=0

	[ "$up" -ge "$GRACE" ] || { sleep "$STEP"; continue; }

	anchor=$(mba_anchor)
	if [ -z "$anchor" ]; then
		# dmesg 环里找不到 MBA 行：宁可不点火，也别照 0 去算出一个早就过期的死线。
		say "找不到 MBA 锚点，本轮跳过"
		sleep 30
		continue
	fi
	fire=$(awk -v a="$anchor" -v h="$HORIZON" -v l="$LEAD" 'BEGIN{printf "%d", a+h-l}')

	if [ "$up" -ge "$fire" ]; then
		cycle "MBA=$anchor +${HORIZON}s 将到" "$fire"
		echo disabled > "$RECOV" 2>/dev/null
		if [ "$STOPREQ" = 1 ]; then
			say "收到停止请求，本轮已收尾，退出"
			exit 0
		fi
		sleep 5
		continue
	fi

	sleep "$STEP"
done
