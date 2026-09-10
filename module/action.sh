#!/system/bin/sh
#
# action.sh —— 模块卡片上的「操作」按钮
#
# KernelSU / Magisk 会在用户点击时执行本脚本，stdout 直接显示给用户，
# 所以这里输出的是给人看的中文，不是给程序解析的 key=value。
#
# 行为：把当前状态说清楚 —— 有没有在接管、接管到哪个地址、开关怎么样。
# 相当于一个"不用打开 WebUI 也能确认状况"的按钮。
#
# 本模块的 WebUI 只在 KernelSU 系环境里能开；纯 Magisk 下没有内置 WebUI，
# 这个按钮就是唯一的查看入口，所以实现成本虽低但不能省。

MODDIR=$(readlink -f "$0" 2>/dev/null)
MODDIR=${MODDIR%/*}
[ -n "$MODDIR" ] || MODDIR=/data/adb/modules/dns-modifier
[ -d "$MODDIR" ] || MODDIR=/data/adb/modules/dns-modifier

CTL="$MODDIR/scripts/dns-apply.sh"

_out=$("$CTL" status 2>/dev/null)

get() { printf '%s\n' "$_out" | sed -n "s/^$1=//p" | head -n 1; }

en=$(get ENABLED)
ipv4=$(get IPV4)
ipv6=$(get IPV6)
tcp=$(get TCP)
block6=$(get BLOCK6)
autostart=$(get AUTOSTART)
a4=$(get ACTIVE4)
rules=$(get RULES)
ip6nat=$(get IP6NAT)

yes_no() { [ "$1" = "1" ] && echo "开" || echo "关"; }

echo "自定义 DNS"
echo "──────────────"

if [ "$en" = "1" ]; then
	echo "状态：已接管"
	[ -n "$a4" ] && echo "生效目标：$a4"
else
	echo "状态：未接管（DNS 走系统默认）"
fi

if [ -n "$ipv4" ]; then
	echo "IPv4 DNS：$ipv4"
else
	echo "IPv4 DNS：（未设置）"
fi

if [ -n "$ipv6" ]; then
	echo "IPv6 DNS：$ipv6"
else
	echo "IPv6 DNS：（未设置）"
fi

echo "接管 TCP 53：$(yes_no "$tcp")"
echo "屏蔽 IPv6 DNS：$(yes_no "$block6")"
echo "开机自动应用：$(yes_no "$autostart")"
echo "生效规则条数：$rules"

# 本内核没有 ip6tables 的 nat 表（实测 Table does not exist），IPv6 那一路
# 改向不了。把这件事直说，免得用户填了 IPv6 DNS 却以为它生效了。
if [ "$ip6nat" = "0" ]; then
	echo "提示：本内核无 ip6tables nat 表，IPv6 DNS 无法改向，"
	echo "      只能靠「屏蔽 IPv6 DNS」逼解析器回落到 IPv4。"
fi
