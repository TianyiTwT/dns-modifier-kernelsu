#!/system/bin/sh
#
# dns-apply.sh —— DNS 接管规则的唯一入口
#
# ── 改的是什么 ────────────────────────────────────────────────────
#
# Android 10+ 没有任何官方手段去改系统解析器：setprop net.dns1/2 已被忽略
# （netd 从 per-network 的 ResolverParams 读，不看 system property），
# ndc resolver setnetdns 已被移除（Android 16 实测 500 0 Command not recognized），
# netd 的 resolver AIDL 又受 NETWORK_STACK 权限保护 —— root shell 也拿不到。
#
# 所以这里改的不是"系统设置"，而是**包的流向**：在 nat/OUTPUT 里把目的端口
# 53 的包直接改写目的地（DNAT）到用户填的地址。
#
# ── 为什么必须是 DNAT，不能是 REDIRECT ───────────────────────────
#
# REDIRECT --to-ports 的语义是"转到本机的某个端口"，这就要求本机真有一个
# 进程 listen 在那里 —— 那就得常驻一个 dnsmasq/dnscrypt-proxy 之类的东西。
# DNAT --to-destination 直接改写目的地，收包的是外部服务器，本机没有任何人
# 需要监听。这是本模块能做到「零常驻进程」的全部原因，换掉就立刻多一个进程。
#
# 规则只挂 OUTPUT，只管本机自己发出的查询；热点转发、别的容器的流量不碰。
#
# ── 为什么每条子命令都「先清后建」 ───────────────────────────────
#
# 链（DNSMOD / DNSMOD6）在整个操作开始时被整条删掉、最后重建。于是重复调用、
# 改配置、从旧版本升上来，结果都只取决于当前配置，脚本不需要维护"已经加过
# 什么"的状态。清理本身是幂等的，随时可以反复跑。
#
# ── 子命令 ────────────────────────────────────────────────────────
#
#   apply             按 config.conf 挂规则（幂等）
#   off               摘掉本模块的全部规则，配置原样保留
#   disable           off 之后落盘 enable=0（WebUI 的「关闭并清除」）
#   save  k=v [...]   校验并写入配置，不动现有规则
#   use   k=v [...]   save + enable=1 + apply（WebUI 的「应用并生效」）
#   boot              开机调用：只有 enable=1 且 autostart=1 才挂规则
#   status            key=value 状态，供 WebUI / action.sh 解析

CHAIN=DNSMOD
CHAIN6=DNSMOD6

PREFIX=/data/adb/dns-modifier
CONF="$PREFIX/config.conf"
LOGF="$PREFIX/dns-modifier.log"
LOCK="$PREFIX/.lock"

MAXLOG=65536

SELF=$(readlink -f "$0" 2>/dev/null)
[ -n "$SELF" ] || SELF=$0
MODDIR=${SELF%/*}
MODDIR=${MODDIR%/*}

# ══════════════════════════════════════════════════ 基础设施

say() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }

# 运行日志。只记"什么时候发生了一次变更/失败"，不记每次读取 —— 它同时也是
# 用户排障时唯一能拿到的时间线（WebUI 断网时打不开，日志还能用 cat 看）。
log() {
	[ -d "$PREFIX" ] || return 0
	printf '%s %s\n' "$(date '+%m-%d %H:%M:%S')" "$*" >> "$LOGF" 2>/dev/null
	return 0
}

trim_log() {
	[ -f "$LOGF" ] || return 0
	_sz=$(wc -c < "$LOGF" 2>/dev/null)
	case "$_sz" in ''|*[!0-9]*) return 0 ;; esac
	if [ "$_sz" -gt "$MAXLOG" ]; then
		tail -n 200 "$LOGF" > "$LOGF.tmp" 2>/dev/null && mv -f "$LOGF.tmp" "$LOGF" 2>/dev/null
	fi
	return 0
}

# 配置和日志都在 /data/adb 下，非 root 连目录都进不去 —— 与其让 iptables
# 打一堆 Permission denied，不如在门口就说清楚。
require_root() {
	[ "$(id -u 2>/dev/null)" = "0" ] && return 0
	err "需要 root 权限运行（请通过 KernelSU / Magisk 的 WebUI 或 su -c 调用）"
	exit 1
}

# ── 并发保护 ─────────────────────────────────────────────────────
#
# WebUI 的按钮、开机自启、action.sh 三处都能触发变更。两处同时进来的话，
# "先清后建"的两个 clean 会交错，可能留下半个规则集（清掉了链、另一个
# 又刚把跳转挂上去）。用 mkdir 做原子锁把它们串起来。
#
# 等待上限 10 秒；超过就认定是上一次被强杀留下的僵尸锁（脚本正常结束都会
# 自己 rmdir），强行接管一次。只抢一次，抢不到就放弃 —— 不会无限循环。
lock_take() {
	# 先保证父目录在：装完还没跑过任何写操作时 /data/adb/dns-modifier 可能
	# 还没被创建，此时 mkdir .lock 一律 "No such file or directory"，
	# 于是每次调用都要空等满 10 秒才报"另一个实例正在运行" —— 与事实相反。
	mkdir -p "$PREFIX" 2>/dev/null

	_n=0
	while ! mkdir "$LOCK" 2>/dev/null; do
		_n=$((_n + 1))
		if [ "$_n" -gt 100 ]; then
			log "lock: 等待超时，接管疑似残留的锁"
			case "$LOCK" in
				/data/adb/dns-modifier/.lock) rm -rf "$LOCK" ;;
			esac
			mkdir "$LOCK" 2>/dev/null || return 1
			return 0
		fi
		sleep 0.1 2>/dev/null || sleep 1
	done
	return 0
}

lock_drop() {
	rmdir "$LOCK" 2>/dev/null
	return 0
}

# ══════════════════════════════════════════════════ 校验

is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

# 0/1 归一化：WebUI 传的一律是 0/1，但配置文件有可能被人手改过。
norm01() { case "$1" in 1|true|on|yes) echo 1 ;; *) echo 0 ;; esac; }

is_ip4() {
	case "$1" in ''|*[!0-9.]*) return 1 ;; esac
	_s=$(printf '%s' "$1" | tr '.' ' ')
	# 不加引号是有意的：靠 IFS 把 "1.1.1.1" 拆成四个位置参数
	# shellcheck disable=SC2086
	set -- $_s
	[ $# -eq 4 ] || return 1
	for _o in "$@"; do
		case "$_o" in ''|*[!0-9]*) return 1 ;; esac
		[ "$_o" -le 255 ] || return 1
	done
	return 0
}

# IPv6 只做语法体检，不做完整 RFC 4291 解析：目的是拦住"手滑写错"，
# 而不是拦住一切非法写法。真正兜底的是 apply 末尾的自检 —— 规则挂不上
# 就整条链回滚，绝不会留下一半能把 DNS 打死的规则。
is_ip6() {
	case "$1" in ''|*:*) ;; *) return 1 ;; esac
	case "$1" in *[!0-9a-fA-F:.]*) return 1 ;; esac
	case "$1" in *:::*) return 1 ;; esac
	# "::" 最多出现一次
	case "${1#*::}" in *::*) return 1 ;; esac
	# 单个冒号不允许出现在首尾（"::" 是允许的）
	case "$1" in
		:*) case "$1" in ::*) ;; *) return 1 ;; esac ;;
	esac
	case "$1" in
		*:) case "$1" in *::) ;; *) return 1 ;; esac ;;
	esac

	_rest=$1
	_n=0
	while [ -n "$_rest" ]; do
		case "$_rest" in
			*:*) _g=${_rest%%:*}; _rest=${_rest#*:} ;;
			*)   _g=$_rest;       _rest= ;;
		esac
		_n=$((_n + 1))
		[ -z "$_g" ] && continue
		case "$_g" in
			*.*) is_ip4 "$_g" || return 1 ;;
			*)   case "$_g" in ?????*|*[!0-9a-fA-F]*) return 1 ;; esac ;;
		esac
	done
	[ "$_n" -le 8 ] || return 1
	return 0
}

# ══════════════════════════════════════════════════ 配置

D_IPV4=
D_IPV6=
D_TCP=1
D_BLOCK6=1
D_AUTOSTART=1
# 默认 0：装完还没填 DNS 就是"没启用"，而不是"启用了但没东西可挂"。
# 用户点一次「应用并生效」，use 会把它置 1，之后开机才会自动挂。
D_ENABLE=0

conf_get() {
	[ -r "$CONF" ] || return 0
	sed -n "s/^$1=//p" "$CONF" 2>/dev/null | head -n 1
}

load_conf() {
	C_IPV4=$(conf_get ipv4)
	C_IPV6=$(conf_get ipv6)
	C_TCP=$(conf_get tcp)
	C_BLOCK6=$(conf_get block6)
	C_AUTOSTART=$(conf_get autostart)
	C_ENABLE=$(conf_get enable)

	# 手改配置时容易带进空白，一律剥掉
	C_IPV4=$(printf '%s' "$C_IPV4" | tr -d ' \t\r')
	C_IPV6=$(printf '%s' "$C_IPV6" | tr -d ' \t\r')

	# 存档里的值先当"不可信"处理：格式不对就当没填，而不是让它进 iptables。
	# 这一步同时兜住了"配置文件被别的工具改坏了"这种情况。
	if [ -n "$C_IPV4" ] && ! is_ip4 "$C_IPV4"; then
		log "config: 忽略不合法的 ipv4 '$C_IPV4'"
		C_IPV4=
	fi
	if [ -n "$C_IPV6" ] && ! is_ip6 "$C_IPV6"; then
		log "config: 忽略不合法的 ipv6 '$C_IPV6'"
		C_IPV6=
	fi

	[ -n "$C_TCP" ]       || C_TCP=$D_TCP
	[ -n "$C_BLOCK6" ]    || C_BLOCK6=$D_BLOCK6
	[ -n "$C_AUTOSTART" ] || C_AUTOSTART=$D_AUTOSTART
	[ -n "$C_ENABLE" ]    || C_ENABLE=$D_ENABLE

	C_TCP=$(norm01 "$C_TCP")
	C_BLOCK6=$(norm01 "$C_BLOCK6")
	C_AUTOSTART=$(norm01 "$C_AUTOSTART")
	C_ENABLE=$(norm01 "$C_ENABLE")
	return 0
}

write_conf() {
	umask 077
	mkdir -p "$PREFIX" 2>/dev/null
	_tmp="$CONF.tmp.$$"
	{
		printf 'ipv4=%s\n'      "$C_IPV4"
		printf 'ipv6=%s\n'      "$C_IPV6"
		printf 'tcp=%s\n'       "$C_TCP"
		printf 'block6=%s\n'    "$C_BLOCK6"
		printf 'autostart=%s\n' "$C_AUTOSTART"
		printf 'enable=%s\n'    "$C_ENABLE"
	} > "$_tmp" 2>/dev/null || { err "写配置失败：$_tmp"; rm -f "$_tmp"; return 1; }
	# rename 是原子的：管理器/WebUI 不会读到写了一半的配置
	mv -f "$_tmp" "$CONF" 2>/dev/null || { err "写配置失败：$CONF"; rm -f "$_tmp"; return 1; }
	chmod 0600 "$CONF" 2>/dev/null
	return 0
}

# 一条 k=v 一条 k=v 地覆盖到 C_* 上。校验不通过就整批拒绝 ——
# user 拼错一个字符时，宁可什么都不改，也不要写进一个半对半错的配置。
apply_kv() {
	for _kv in "$@"; do
		_k=${_kv%%=*}
		_v=${_kv#*=}
		_v=$(printf '%s' "$_v" | tr -d ' \t\r\n')
		case "$_k" in
			ipv4)
				if [ -z "$_v" ]; then C_IPV4=
				elif is_ip4 "$_v"; then C_IPV4=$_v
				else err "IPv4 地址不合法：$_v"; return 1
				fi ;;
			ipv6)
				if [ -z "$_v" ]; then C_IPV6=
				elif is_ip6 "$_v"; then C_IPV6=$_v
				else err "IPv6 地址不合法：$_v"; return 1
				fi ;;
			tcp)       C_TCP=$(norm01 "$_v") ;;
			block6)    C_BLOCK6=$(norm01 "$_v") ;;
			autostart) C_AUTOSTART=$(norm01 "$_v") ;;
			enable)    C_ENABLE=$(norm01 "$_v") ;;
			*)         err "未知字段：$_k"; return 1 ;;
		esac
	done
	return 0
}

# ══════════════════════════════════════════════════ 规则

have() { command -v "$1" >/dev/null 2>&1; }

# 本内核有没有 ip6tables 的 nat 表（K30 Pro / Android 16 上是没有的：
# `ip6tables -t nat -L` 直接报 Table does not exist）。没有就只能靠
# DROP 把 IPv6 查询逼回 IPv4，这是「屏蔽 IPv6 DNS」这个开关存在的理由。
ip6_nat_ok() {
	have ip6tables || return 1
	ip6tables -t nat -L -n >/dev/null 2>&1
}

# 清 = 先删 OUTPUT 上的跳转（可能有多条残留，循环删干净），再清空并删除链。
# 绝不去动 OUTPUT 里的其它规则 —— 厂商链（wmsctrl_nat_OUTPUT 之类）就在旁边。
clean_rules() {
	if have ip6tables; then
		while ip6tables -t nat -D OUTPUT -j "$CHAIN" 2>/dev/null; do :; done
		ip6tables -t nat -F "$CHAIN" 2>/dev/null
		ip6tables -t nat -X "$CHAIN" 2>/dev/null

		while ip6tables -t filter -D OUTPUT -j "$CHAIN6" 2>/dev/null; do :; done
		ip6tables -t filter -F "$CHAIN6" 2>/dev/null
		ip6tables -t filter -X "$CHAIN6" 2>/dev/null
	fi

	if have iptables; then
		while iptables -t nat -D OUTPUT -j "$CHAIN" 2>/dev/null; do :; done
		iptables -t nat -F "$CHAIN" 2>/dev/null
		iptables -t nat -X "$CHAIN" 2>/dev/null
	fi
	return 0
}

# 建链（已有就先清空）。$1 是"iptables -t nat"这样的前缀。
chain_reset() {
	# shellcheck disable=SC2086
	$1 -N "$2" 2>/dev/null && return 0
	# shellcheck disable=SC2086
	$1 -F "$2" 2>/dev/null && return 0
	return 1
}

chain_count() {
	# shellcheck disable=SC2086
	$1 -S "$2" 2>/dev/null | grep -c '^-A '
}

# 从生效的规则里反查"真正在用的目标"，而不是回读配置 —— 页面上的
# 「当前生效目标」必须是实测值，否则保存成功和应用失败就分不出来了。
active_target() {
	# shellcheck disable=SC2086
	$1 -t nat -S "$CHAIN" 2>/dev/null \
		| sed -n 's/.*--to-destination \([^ ]*\):53.*/\1/p' \
		| head -n 1 | tr -d '[]'
}

rules_active() {
	have iptables || return 1
	iptables -t nat -C OUTPUT -j "$CHAIN" 2>/dev/null || return 1
	iptables -t nat -S "$CHAIN" 2>/dev/null | grep -q -- '--dport 53' || return 1
	return 0
}

count_rules() {
	_n=0
	if have iptables; then
		_n=$((_n + $(chain_count 'iptables -t nat' "$CHAIN")))
		iptables -t nat -C OUTPUT -j "$CHAIN" 2>/dev/null && _n=$((_n + 1))
	fi
	if have ip6tables; then
		_n=$((_n + $(chain_count 'ip6tables -t nat' "$CHAIN")))
		ip6tables -t nat -C OUTPUT -j "$CHAIN" 2>/dev/null && _n=$((_n + 1))
		_n=$((_n + $(chain_count 'ip6tables -t filter' "$CHAIN6")))
		ip6tables -t filter -C OUTPUT -j "$CHAIN6" 2>/dev/null && _n=$((_n + 1))
	fi
	echo "$_n"
}

# ── 挂规则 ───────────────────────────────────────────────────────
#
# 返回值：0 = 已接管；1 = 出错（规则已回滚）；2 = 配置里没有 IPv4 DNS
# （不是错误，是"用户还没填"，此时保证规则是干净的）。
apply_rules() {
	load_conf
	clean_rules

	if [ -z "$C_IPV4" ]; then
		log "apply: 配置里没有 IPv4 DNS，规则保持清空"
		return 2
	fi

	if ! have iptables; then
		log "apply: 失败，找不到 iptables"
		err "找不到 iptables 命令"
		return 1
	fi

	if ! chain_reset 'iptables -t nat' "$CHAIN"; then
		log "apply: 失败，无法创建 nat/$CHAIN"
		err "无法创建 nat/$CHAIN（iptables 不可用？）"
		return 1
	fi

	# 回环不参与：本机自己查自己（127.0.0.1:53 上的某些本地解析器）不该被改向
	iptables -t nat -A "$CHAIN" -d 127.0.0.0/8 -j RETURN
	iptables -t nat -A "$CHAIN" -p udp --dport 53 -j DNAT --to-destination "$C_IPV4:53"
	_want=2
	if [ "$C_TCP" = "1" ]; then
		iptables -t nat -A "$CHAIN" -p tcp --dport 53 -j DNAT --to-destination "$C_IPV4:53"
		_want=3
	fi
	iptables -t nat -A OUTPUT -j "$CHAIN"

	# IPv6：只有内核真有 nat 表才谈得上"改向"，否则只能走下面的 DROP 逼回落。
	_ip6on=0
	if [ -n "$C_IPV6" ]; then
		if ip6_nat_ok && chain_reset 'ip6tables -t nat' "$CHAIN"; then
			ip6tables -t nat -A "$CHAIN" -o lo -j RETURN
			ip6tables -t nat -A "$CHAIN" -p udp --dport 53 -j DNAT --to-destination "[$C_IPV6]:53"
			[ "$C_TCP" = "1" ] && \
				ip6tables -t nat -A "$CHAIN" -p tcp --dport 53 -j DNAT --to-destination "[$C_IPV6]:53"
			ip6tables -t nat -A OUTPUT -j "$CHAIN"
			_ip6on=1
			log "apply: IPv6 DNS 已改向到 $C_IPV6"
		else
			log "apply: 本内核没有 ip6tables nat 表，IPv6 DNS 未改向"
		fi
	fi

	# 屏蔽 IPv6 DNS：把 53 端口丢掉，逼解析器回落到能被改向的 IPv4。
	# 注意豁免顺序 —— nat/OUTPUT 在 filter/OUTPUT **之前**执行，包到 filter
	# 时目的地已经是 [$C_IPV6]:53，不豁免的话会被自己这条 DROP 打死。
	if [ "$C_BLOCK6" = "1" ] && have ip6tables; then
		if chain_reset 'ip6tables -t filter' "$CHAIN6"; then
			ip6tables -t filter -A "$CHAIN6" -o lo -j RETURN
			if [ "$_ip6on" = "1" ]; then
				ip6tables -t filter -A "$CHAIN6" -d "$C_IPV6" -p udp --dport 53 -j RETURN
				[ "$C_TCP" = "1" ] && \
					ip6tables -t filter -A "$CHAIN6" -d "$C_IPV6" -p tcp --dport 53 -j RETURN
			fi
			ip6tables -t filter -A "$CHAIN6" -p udp --dport 53 -j DROP
			[ "$C_TCP" = "1" ] && \
				ip6tables -t filter -A "$CHAIN6" -p tcp --dport 53 -j DROP
			ip6tables -t filter -A OUTPUT -j "$CHAIN6"
		fi
	fi

	# ── 自检 ──
	# 只要有一条 DNAT 没挂上去（地址写错、iptables 版本不支持某个选项……），
	# 就把整条链回滚。宁可"一点没接管"，也不要"接管了一半、TCP 走老路"这种
	# 状态 —— 后者排查起来最费时间，而且用户会以为模块坏了。
	_got=$(chain_count 'iptables -t nat' "$CHAIN")
	if [ "$_got" != "$_want" ]; then
		log "apply: 自检失败（链内应有 $_want 条，实际 $_got 条），回滚"
		err "规则自检失败，已回滚（没有留下任何规则）"
		clean_rules
		return 1
	fi
	if ! iptables -t nat -C OUTPUT -j "$CHAIN" 2>/dev/null; then
		log "apply: 自检失败（OUTPUT 跳转没挂上），回滚"
		err "规则自检失败，已回滚"
		clean_rules
		return 1
	fi

	log "apply: 已接管 udp${C_TCP:+/tcp}53 -> $C_IPV4${C_IPV6:+ / v6 $C_IPV6}  (block6=$C_BLOCK6)"
	return 0
}

# ══════════════════════════════════════════════════ 模块卡片上的状态短语
#
# 管理器每次打开模块列表都会重读 module.prop，所以直接把状态写进 description
# 就能在卡片上看到 —— 不需要任何管理器专有接口，KernelSU（含 SukiSU/ReSukiSU）
# 与 Magisk 都适用。
#
# 静态文案不另存一份，而是每次从当前 description 里剥掉【…】前缀得到：
# 模块更新时 live 目录被换成新解包的副本、description 回到静态版，
# 这样能自己恢复；另存一份的话两边迟早漂移。

desc_sync() {
	_prop="$MODDIR/module.prop"
	[ -f "$_prop" ] && [ -w "$_prop" ] || return 0

	_cur=$(sed -n 's/^description=//p' "$_prop" 2>/dev/null | head -n 1)
	_base=${_cur#*】}
	case "$_cur" in
		【*】*) ;;
		*) _base=$_cur ;;
	esac

	if rules_active; then
		_t=$(active_target 'iptables -t nat')
		_ph="DNS 已接管${_t:+ → $_t}"
	elif [ -n "$C_IPV4" ]; then
		_ph="DNS 未接管"
	else
		_ph="未设置 DNS"
	fi

	_new="【$_ph】$_base"
	[ "$_new" = "$_cur" ] && return 0

	# 替换值里的 & \ | 都得转义，不然 sed 会把它们当成替换指令
	_esc=$(printf '%s' "$_new" | sed -e 's/[\\&|]/\\&/g')
	_tmp="$_prop.tmp"
	sed "s|^description=.*|description=$_esc|" "$_prop" > "$_tmp" 2>/dev/null || return 0
	# 原子替换：管理器不会读到写了一半的 module.prop（在它眼里那就是模块坏了）
	mv -f "$_tmp" "$_prop" 2>/dev/null
	return 0
}

# ══════════════════════════════════════════════════ status

status() {
	load_conf

	# ENABLED 是实测（规则真的在），WANT 是配置里的意图。两者不一致时
	# 页面就该说"已保存但没生效"，而不是含糊地说一句"成功"。
	_en=0; rules_active && _en=1

	_a4=
	[ "$_en" = "1" ] && _a4=$(active_target 'iptables -t nat')
	_a6=
	[ "$_en" = "1" ] && _a6=$(active_target 'ip6tables -t nat')

	_ipt=0; have iptables && _ipt=1
	_ip6=0; have ip6tables && _ip6=1
	_n6nat=0; ip6_nat_ok && _n6nat=1

	_ver=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -n 1)
	[ -n "$_ver" ] || _ver=?

	say "ENABLED=$_en"
	say "WANT=$C_ENABLE"
	say "IPV4=$C_IPV4"
	say "IPV6=$C_IPV6"
	say "TCP=$C_TCP"
	say "BLOCK6=$C_BLOCK6"
	say "AUTOSTART=$C_AUTOSTART"
	say "ACTIVE4=$_a4"
	say "ACTIVE6=$_a6"
	say "RULES=$(count_rules)"
	say "IPT=$_ipt"
	say "IP6=$_ip6"
	say "IP6NAT=$_n6nat"
	say "VER=$_ver"
	return 0
}

# ══════════════════════════════════════════════════ 命令

usage() {
	sed -n '2,40p' "$SELF"
	exit 1
}

require_root

case "${1:-}" in

	apply)
		lock_take || { err "另一个实例正在运行"; exit 1; }
		apply_rules; _rc=$?
		lock_drop
		desc_sync
		trim_log
		exit $_rc
		;;

	# 只摘规则，不动配置：用户想临时停一下、之后还能一键回来。
	off)
		lock_take || { err "另一个实例正在运行"; exit 1; }
		load_conf
		clean_rules
		log "off: 规则已清除（配置保留）"
		lock_drop
		desc_sync
		trim_log
		exit 0
		;;

	# WebUI 的「关闭并清除」：不仅要摘规则，还要把 enable 落成 0，
	# 否则下次开机 service.sh 会照着旧配置把它又装回来 —— 用户会觉得
	# "点了关闭但重启之后又活了"。这是必须能自救的那条路。
	disable)
		lock_take || { err "另一个实例正在运行"; exit 1; }
		load_conf
		C_ENABLE=0
		write_conf
		clean_rules
		log "disable: 已关闭，规则清除且不再开机自启"
		lock_drop
		desc_sync
		trim_log
		exit 0
		;;

	save)
		shift
		lock_take || { err "另一个实例正在运行"; exit 1; }
		load_conf
		if apply_kv "$@"; then
			write_conf; _rc=$?
		else
			_rc=1
		fi
		lock_drop
		trim_log
		exit $_rc
		;;

	# WebUI 的「应用并生效」：一次调用里把校验、落盘、挂规则全做完，
	# 少一次 WebView ↔ native 往返，也不会出现"存了但忘了应用"的中间态。
	use)
		shift
		lock_take || { err "另一个实例正在运行"; exit 1; }
		load_conf
		if ! apply_kv "$@"; then
			lock_drop
			exit 1
		fi
		C_ENABLE=1
		if ! write_conf; then
			lock_drop
			exit 1
		fi
		apply_rules; _rc=$?
		lock_drop
		desc_sync
		trim_log
		exit $_rc
		;;

	# 开机走这条。放在 late_start service 阶段调，不阻塞 post-fs-data。
	boot)
		lock_take || { log "boot: 拿不到锁，跳过"; exit 1; }
		load_conf
		if [ "$C_ENABLE" = "1" ] && [ "$C_AUTOSTART" = "1" ]; then
			apply_rules; _rc=$?
			log "boot: apply 返回 $_rc"
		else
			log "boot: enable=$C_ENABLE autostart=$C_AUTOSTART，跳过（保持未接管）"
			_rc=0
		fi
		lock_drop
		desc_sync
		trim_log
		exit $_rc
		;;

	status) status ;;

	*) usage ;;
esac
