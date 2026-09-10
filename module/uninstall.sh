#!/system/bin/sh
#
# uninstall.sh —— 卸载时执行
#
# 最重要的职责是**把规则摘干净**：iptables 规则活在当前内核里，模块目录被删掉
# 并不会让它消失。留着的话，用户卸载后 DNS 还在往一个可能已经不该用的地址上发，
# 而且再没有任何界面能把它关掉 —— 那就成了必须重启才恢复的幽灵规则。
#
# 配置目录一并删掉（里面没有需要保留的东西；重装就是全新的开始）。

MODDIR=$(readlink -f "$0" 2>/dev/null)
MODDIR=${MODDIR%/*}
[ -n "$MODDIR" ] || MODDIR=/data/adb/modules/dns-modifier
[ -d "$MODDIR" ] || MODDIR=/data/adb/modules/dns-modifier

"$MODDIR/scripts/dns-apply.sh" off >/dev/null 2>&1

PREFIX=/data/adb/dns-modifier
# 路径写死并再校验一次，避免变量异常时误伤别的目录
case "$PREFIX" in
	/data/adb/dns-modifier) rm -rf "$PREFIX" ;;
esac

exit 0
