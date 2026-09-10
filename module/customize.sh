#!/system/bin/sh
#
# customize.sh —— 安装 / 升级时执行
#
# KernelSU 与 Magisk 都会带着 $MODPATH 调用它，$MODPATH 指向**临时解包目录**。
#
# 这个模块是纯 shell 的：只跑脚本、只改 iptables，**不替换任何系统文件**。
# 所以不需要 meta-overlayfs 这类元模块（KernelSU 3.0+ / ReSukiSU 已经不内置
# 模块挂载了，但那影响的是"替换系统文件"的模块，与本模块无关）。
#
# 这里刻意**不做**任何需要 root 生效的动作：
#   · 不挂规则 —— 客户端的配置还没填，挂了也是空的；而且此刻 /data/adb
#     下还没有用户的配置。挂规则的时机是「用户点应用」或「开机 service.sh」。
#   · 不启动任何进程 —— 本模块零常驻。

PREFIX=/data/adb/dns-modifier

if ! command -v ui_print >/dev/null 2>&1; then
	ui_print() { echo "$1"; }
fi

ui_print "- 安装自定义 DNS 模块"

# ── 1. 可执行位 ───────────────────────────────────────────────────
# /data/adb 下挂载的模块文件不带可执行位时，service.sh 会被静默跳过 ——
# 这是"装完了但开机什么都不发生"最常见的原因，所以这里显式补一遍。
# （webroot 的权限由管理器自己设，不要碰。）
chmod 0755 "$MODPATH/service.sh" 2>/dev/null
chmod 0755 "$MODPATH/action.sh" 2>/dev/null
chmod 0755 "$MODPATH/uninstall.sh" 2>/dev/null
chmod 0755 "$MODPATH/scripts/dns-apply.sh" 2>/dev/null

# ── 2. 运行期目录 ─────────────────────────────────────────────────
# /data/adb 是 0700 root，普通 shell 进不去 —— 配置和日志都放这里面。
mkdir -p "$PREFIX" 2>/dev/null
chmod 0700 "$PREFIX" 2>/dev/null

# ── 3. 配置：只有不存在时才写默认值 ───────────────────────────────
# 升级时保留用户已经填好的 DNS，只补上新增的字段。
if [ -x "$MODPATH/scripts/dns-apply.sh" ]; then
	if [ ! -f "$PREFIX/config.conf" ]; then
		# enable=0：装完先不接管。用户还没填 DNS，此时接管毫无意义，
		# 反而会让人以为"装完 DNS 就变了"。
		umask 077
		cat > "$PREFIX/config.conf" <<'EOF'
ipv4=
ipv6=
tcp=1
block6=1
autostart=1
enable=0
EOF
		chmod 0600 "$PREFIX/config.conf" 2>/dev/null
		ui_print "- 已生成默认配置（尚未接管，请在 WebUI 里填 DNS）"
	else
		ui_print "- 已存在配置，保留原有 DNS 设置"
	fi
fi

ui_print "- 装好了。重启后在模块的 WebUI 里填 DNS，点「应用并生效」即可；"
ui_print "  也可以直接点「应用并生效」，不重启就生效（规则立刻挂上）。"
