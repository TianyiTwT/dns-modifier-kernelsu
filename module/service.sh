#!/system/bin/sh
#
# service.sh —— 开机自启（late_start service 阶段）
#
# 只做一件事：如果用户之前点过「应用并生效」并且没关掉「开机自动应用」，
# 就把规则重新挂上。挂完立刻返回。
#
# 为什么必须是 late_start：
#   · 规则本身不依赖网络（iptables 加规则不需要接口就绪），但放在 post-fs-data
#     阶段会阻塞开机流程；而这个阶段又太早，data 分区上的配置可能还没就绪。
#   · late_start service 时 /data 一定挂好了，也不会拖慢开机。
#
# 为什么不需要守护进程：
#   实测这套规则扛得过 svc wifi disable/enable 和 cmd connectivity
#   airplane-mode enable/disable —— 切网后链还在、计数继续涨。规则是挂在
#   全局 OUTPUT 上的，不绑任何接口，网络重连不会把它冲掉。所以开机挂一次足够。
#
# 为什么不需要等网络：
#   包走到 nat/OUTPUT 时规则已经在了，第一次查询就能被改向，不存在"错过"。

MODDIR=$(readlink -f "$0" 2>/dev/null)
MODDIR=${MODDIR%/*}
[ -n "$MODDIR" ] || MODDIR=/data/adb/modules/dns-modifier
[ -d "$MODDIR" ] || MODDIR=/data/adb/modules/dns-modifier

# 模块被停用 / 待卸载时什么都不做。KernelSU 会在目录下放一个 disable 标记，
# 收到这层保护后即便用户只是临时停用模块，也不会留下没人管的规则。
if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
	exit 0
fi

# boot 子命令自己会判断 enable / autostart，配置没填也不会乱挂规则
"$MODDIR/scripts/dns-apply.sh" boot

exit 0
