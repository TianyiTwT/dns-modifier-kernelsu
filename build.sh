#!/bin/sh
#
# build.sh —— 把 module/ 打成一个可安装的 KernelSU / Magisk 模块 zip
#
# 本模块是纯 shell 的：没有需要编译的二进制，所以打包这一步就是全部构建。
#
# 用法：
#   sh build.sh               # 打包
#   sh build.sh --install     # 打包后用 adb + ksud 直接装到设备

set -e

ROOT=$(cd "$(dirname "$0")" && pwd)
cd "$ROOT"

DO_INSTALL=0
ADB=${ADB:-adb}

while [ $# -gt 0 ]; do
	case "$1" in
		--install) DO_INSTALL=1; shift ;;
		-h|--help) sed -n '2,14p' "$0"; exit 0 ;;
		*) echo "未知参数: $1" >&2; exit 2 ;;
	esac
done

VERSION=$(sed -n 's/^version=//p' module/module.prop | head -n 1)
[ -n "$VERSION" ] || VERSION=dev
ZIP="dist/dns-modifier-$VERSION.zip"

# ── 行尾自检 ─────────────────────────────────────────────────────
#
# module/ 下的 shell 脚本会被系统直接 exec，而 CRLF 会让 shebang 变成
# "#!/system/bin/sh\r" —— 解释器路径带 \r 找不到，结果是 exec 失败且报错
# 信息很不直观（表现为"开机什么都不发生"）。
#
# 用 tr 数 CR 的个数：纯 LF 文件输出 0。**不要**用 `grep -c $'\r'` 判断，
# 那个方法本身就是错的（纯 LF 文件也会被数成"每行都有 CR"）。
echo "── 行尾检查 ──"
_bad=0
for f in module/*.sh module/scripts/*.sh; do
	[ -f "$f" ] || continue
	n=$(tr -cd '\r' < "$f" | wc -c | tr -d ' ')
	if [ "$n" != "0" ]; then
		echo "错误：$f 含有 $n 个 CR，必须是纯 LF" >&2
		_bad=1
	fi
done
[ "$_bad" = 0 ] || exit 1
echo "全部为纯 LF"

# ── 打包 ─────────────────────────────────────────────────────────
mkdir -p dist
rm -f "$ZIP"

echo "── 打包 ──"
# zip 的**根目录就是模块内容**（module.prop 在最外层），不带 module/ 前缀。
# dev-preview.html 只是给人看渲染效果的预览页，不进模块包。
if command -v zip >/dev/null 2>&1; then
	( cd module && zip -qr "../$ZIP" . -x 'webroot/dev-preview.html' )
else
	# Windows 上通常没有 zip，用 python 兜底
	PY=$(command -v python3 || command -v python || true)
	if [ -z "$PY" ]; then
		echo "错误：环境里既没有 zip 也没有 python，无法打包" >&2
		exit 1
	fi
	"$PY" - "$ZIP" <<'PYEOF'
import os
import sys
import zipfile

out = sys.argv[1]
os.makedirs(os.path.dirname(out) or '.', exist_ok=True)
if os.path.exists(out):
    os.remove(out)

SKIP = {'.DS_Store', 'Thumbs.db', 'dev-preview.html'}

with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for root, dirs, files in os.walk('module'):
        dirs[:] = [d for d in dirs if d not in ('.git',)]
        for name in sorted(files):
            if name in SKIP:
                continue
            path = os.path.join(root, name)
            # 相对 module/ 打包，让 module.prop 落在 zip 根目录
            z.write(path, os.path.relpath(path, 'module'))
print('已写入 ' + out)
PYEOF
fi

echo "产物：$ZIP（$(wc -c < "$ZIP") 字节）"

# ── 可选：直接装到设备 ───────────────────────────────────────────
if [ "$DO_INSTALL" = 1 ]; then
	REMOTE=/data/local/tmp/$(basename "$ZIP")
	echo "── 安装到设备 ──"
	"$ADB" push "$ZIP" "$REMOTE"
	"$ADB" shell "su -c 'ksud module install $REMOTE'"
	echo "装好了。KernelSU 系的模块内容替换要下次开机才生效，请重启。"
fi
