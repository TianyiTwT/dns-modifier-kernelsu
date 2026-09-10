/*
 * app.js —— 自定义 DNS WebUI 逻辑
 *
 * 三件事：
 *   1. 从 dns-apply.sh status 读回配置与**实测的**生效状态，填进页面；
 *   2. 「应用并生效」把输入框 + 开关一次性交给脚本（校验、落盘、挂规则都在
 *      一次调用里完成），成功后重新读一次；
 *   3. 皮肤与明暗的读写（设置面板）。
 *
 * ── 「保存」和「已生效」必须分开表达 ─────────────────────────────
 *
 * 状态卡说的是"现在是否真的在接管"，输入框里是"用户填的字"。两者本来
 * 就可能不一致：填错了没点应用、应用时规则挂了但 iptables 出错、用户
 * 手动把规则清了……页面绝不把"填进去了"当成"已经生效"。
 *
 * 判据来自脚本：ENABLED 是实测（iptables 里真有跳转），WANT 是配置意图。
 * 两者不一致就明说"已保存但未生效"，而不是含糊地报一句成功。
 */

import { exec, toast, hasBridge } from './kernelsu.js';

/* 模块自身路径从 URL 反推，不写死 —— 免得改了模块 id 这里就失效。
   file:///data/adb/modules/<id>/webroot/index.html */
const MODDIR = (() => {
	const p = decodeURIComponent(location.pathname || '');
	const m = p.match(/^(.*)\/webroot\/index\.html$/);
	return m ? m[1] : '/data/adb/modules/dns-modifier';
})();
const CTL = MODDIR + '/scripts/dns-apply.sh';

const KEY_SKIN = 'dns.skin';
const KEY_THEME = 'dns.theme';

const el = {
	settings: document.getElementById('btnSettings'),
	sheet: document.getElementById('sheet'),
	scrim: document.getElementById('scrim'),
	statusCard: document.getElementById('statusCard'),
	statusTitle: document.getElementById('statusTitle'),
	statusSub: document.getElementById('statusSub'),
	statusIcon: document.getElementById('statusIcon'),
	banner: document.getElementById('banner'),
	in4: document.getElementById('in4'),
	in6: document.getElementById('in6'),
	chips: document.getElementById('chips'),
	swTcp: document.getElementById('swTcp'),
	swBlock6: document.getElementById('swBlock6'),
	swAuto: document.getElementById('swAuto'),
	hintBlock6: document.getElementById('hintBlock6'),
	footnote: document.getElementById('footnote'),
	btnApply: document.getElementById('btnApply'),
	btnOff: document.getElementById('btnOff'),
	sRules: document.getElementById('sRules'),
	sActive: document.getElementById('sActive'),
	sNat6: document.getElementById('sNat6'),
	sVersion: document.getElementById('sVersion'),
};

/* ── 偏好存取 ────────────────────────────────────────────────────
 *
 * localStorage 在 file:// 源上不一定可用（取决于 WebView 有没有开
 * DOM storage）。所以内存里**总是**先存一份，localStorage 只是尽力而为 ——
 * 它抛异常时设置就只活这一次会话，而不是整个页面崩掉。 */
const mem = Object.create(null);

function prefGet(key, dflt) {
	try {
		const v = localStorage.getItem(key);
		if (v !== null) return v;
	} catch (e) { /* 落到内存份 */ }
	return key in mem ? mem[key] : dflt;
}

function prefSet(key, value) {
	mem[key] = value;
	try { localStorage.setItem(key, value); } catch (e) { /* 只影响持久化 */ }
}

/* ── 皮肤与主题 ────────────────────────────────────────────────── */

let mq = null;
try { mq = window.matchMedia('(prefers-color-scheme: dark)'); } catch (e) { mq = null; }

function applySkin(skin) {
	document.documentElement.dataset.skin = skin;
	for (const b of el.sheet.querySelectorAll('[data-skin]')) {
		b.setAttribute('aria-pressed', String(b.dataset.skin === skin));
	}
}

function applyTheme(pref) {
	/* 「跟随系统」在这里就被解析掉了，style.css 只认 light / dark ——
	   这样深色 token 只有一份，不会在两处之间跑偏。 */
	const dark = pref === 'dark' || (pref === 'system' && !!mq && mq.matches);
	document.documentElement.dataset.theme = dark ? 'dark' : 'light';
	for (const b of el.sheet.querySelectorAll('[data-theme-opt]')) {
		b.setAttribute('aria-pressed', String(b.dataset.themeOpt === pref));
	}
}

const getSkin = () => prefGet(KEY_SKIN, 'miuix');
const getTheme = () => prefGet(KEY_THEME, 'system');

function initPrefs() {
	applySkin(getSkin());
	applyTheme(getTheme());

	el.sheet.querySelectorAll('[data-skin]').forEach(b => {
		b.addEventListener('click', () => {
			prefSet(KEY_SKIN, b.dataset.skin);
			applySkin(b.dataset.skin);
		});
	});

	el.sheet.querySelectorAll('[data-theme-opt]').forEach(b => {
		b.addEventListener('click', () => {
			prefSet(KEY_THEME, b.dataset.themeOpt);
			applyTheme(b.dataset.themeOpt);
		});
	});

	/* 选了「跟随系统」时，系统在页面开着的时候换深浅也要跟上 */
	if (mq) {
		const onSystemChange = () => {
			if (getTheme() === 'system') applyTheme('system');
		};
		if (mq.addEventListener) mq.addEventListener('change', onSystemChange);
		else if (mq.addListener) mq.addListener(onSystemChange);
	}
}

/* ── 设置面板 ──────────────────────────────────────────────────── */

let sheetTimer = null;

function openSheet() {
	clearTimeout(sheetTimer);
	el.sheet.hidden = false;
	el.scrim.hidden = false;
	requestAnimationFrame(() => {
		el.sheet.classList.add('is-open');
		el.scrim.classList.add('is-open');
	});
}

function closeSheet() {
	el.sheet.classList.remove('is-open');
	el.scrim.classList.remove('is-open');
	/* 动画结束后再真正隐藏，否则位移过渡看不见 */
	sheetTimer = setTimeout(() => {
		el.sheet.hidden = true;
		el.scrim.hidden = true;
	}, 240);
}

/* ── 解析 ─────────────────────────────────────────────────────── */

function parseKV(text) {
	const out = {};
	for (const line of String(text).split('\n')) {
		const i = line.indexOf('=');
		if (i <= 0) continue;
		out[line.slice(0, i).trim()] = line.slice(i + 1).trim();
	}
	return out;
}

/* ── 状态卡 ────────────────────────────────────────────────────── */

/* 图标统一用 CSS 变量取色，这样深浅色跟着 token 走。
   绿色只出现在这里 —— 状态卡的文字一律用前景色，不染绿。 */
const ICON_OK = '<svg width="34" height="34" viewBox="0 0 34 34" fill="none">'
	+ '<circle cx="17" cy="17" r="12.5" stroke="var(--ok)" stroke-width="3.2" '
	+ 'stroke-linecap="round" stroke-dasharray="58 21" stroke-dashoffset="12"/>'
	+ '<path d="M11.6 17.4l3.9 3.9 7-7.9" stroke="var(--ok)" stroke-width="3.2" '
	+ 'stroke-linecap="round" stroke-linejoin="round"/></svg>';

/* 灰用 --text-2 而不是 --text-3：--text-3 在深色下是 #636366，压在
   --surface-2 (#2c2c2e) 上几乎看不见，会像图标漏画了。 */
const ICON_WARN = '<svg width="34" height="34" viewBox="0 0 34 34" fill="none">'
	+ '<circle cx="17" cy="17" r="12.5" stroke="var(--text-2)" stroke-width="3" '
	+ 'stroke-dasharray="2.5 5.5" stroke-linecap="round"/></svg>';

const ICON_OFF = '<svg width="34" height="34" viewBox="0 0 34 34" fill="none">'
	+ '<circle cx="17" cy="17" r="9.5" stroke="var(--text-2)" stroke-width="3"/></svg>';

function renderStatus(st) {
	const en = st.ENABLED === '1';
	const want = st.WANT === '1';
	const has4 = !!st.IPV4;

	let kind, title, sub;
	if (en) {
		kind = 'ok';
		title = 'DNS 已接管';
		/* sub 里的目标是**实测**反查出来的，不是配置里抄的 */
		sub = st.ACTIVE4 || st.IPV4;
		if (st.IPV6 && st.ACTIVE6) sub += ' / ' + st.ACTIVE6;
	} else if (want && has4) {
		/* 配置说要接管、实际没有 —— 这是最需要说清楚的一种状态：
		   用户点了保存没错，但规则没挂上，DNS 走的还是系统默认。 */
		kind = 'warn';
		title = '已保存，但未生效';
		sub = '规则没有挂上，DNS 仍走系统默认';
	} else if (has4) {
		kind = 'off';
		title = '未接管';
		sub = '填好地址后点「应用并生效」';
	} else {
		kind = 'off';
		title = '未设置 DNS';
		sub = '在上方填入一个 IPv4 地址';
	}

	el.statusCard.className = 'status-card is-' + kind;
	el.statusTitle.textContent = title;
	el.statusSub.textContent = sub;
	el.statusIcon.innerHTML = kind === 'ok' ? ICON_OK : kind === 'warn' ? ICON_WARN : ICON_OFF;

	return { en, want, has4 };
}

/* ── 表单 ─────────────────────────────────────────────────────── */

/* 上一次从设备读回来的值。用来判断"输入框里是不是有没保存的改动" ——
   这个判断放在 JS 里做，脚本不需要知道页面的状态。 */
let saved = { ipv4: '', ipv6: '', tcp: 1, block6: 1, autostart: 1 };

/* 「用户动过哪些字段」要**按字段**记，不能用一个全局的 dirty 布尔。
 *
 * 用一个布尔会出这种事故：页面刚打开、status 还没回来（桥是一次跨进程往返，
 * 有可感知的延迟），用户随手点了个「常用」胶囊 —— 此时 dirty 已经为真，
 * 于是后到的 fillForm 把**所有**控件都跳过不填，三个开关停在 unchecked。
 * 用户什么都没碰，但一点「应用并生效」，提交上去的就是 tcp=0/block6=0/
 * autostart=0 —— 把他原本开着的功能全关了。 */
const dirtyFields = new Set();

function markDirty(...fields) {
	for (const f of fields) dirtyFields.add(f);
	updateFoot();
}

function fillForm(st) {
	saved = {
		ipv4: st.IPV4 || '',
		ipv6: st.IPV6 || '',
		tcp: st.TCP === '1' ? 1 : 0,
		block6: st.BLOCK6 === '1' ? 1 : 0,
		autostart: st.AUTOSTART === '1' ? 1 : 0,
	};

	/* 只覆盖用户**没碰过**的控件。否则用户正在打字、定时刷新把光标位置和
	   内容一起冲掉 —— 那是最让人恼火的一种"智能"。 */
	if (!dirtyFields.has('ipv4')) el.in4.value = saved.ipv4;
	if (!dirtyFields.has('ipv6')) el.in6.value = saved.ipv6;
	if (!dirtyFields.has('tcp')) el.swTcp.checked = saved.tcp === 1;
	if (!dirtyFields.has('block6')) el.swBlock6.checked = saved.block6 === 1;
	if (!dirtyFields.has('autostart')) el.swAuto.checked = saved.autostart === 1;
	switchVisual();
	dirtyFields.clear();

	/* 脏标记清掉之后必须重算一次脚注。少了这一句，点完「应用并生效」、
	   状态卡已经变绿了，脚注却还挂着"有改动尚未应用" —— 页面自己打自己脸。 */
	updateFoot();

	/* 本内核没有 ip6tables nat 表时，把话说在开关旁边 —— 用户填了 IPv6 DNS
	   却发现没生效，在这里就能看到原因。 */
	if (st.IP6NAT === '0') {
		el.hintBlock6.textContent = '本内核无 IPv6 NAT，靠丢弃逼回落 IPv4（建议开启）';
	} else {
		el.hintBlock6.textContent = '本内核支持 IPv6 NAT，改向可达时无需屏蔽';
	}

	el.sRules.textContent = st.RULES || '0';
	el.sActive.textContent = st.ACTIVE4 || '—';
	el.sNat6.textContent = st.IP6NAT === '1' ? '支持' : '不支持（已屏蔽回落）';
	if (st.VER) el.sVersion.textContent = st.VER;
}

/* 开关的配色靠 .toggle-row.is-on 这个类（CSS 里刻意没用 :has()，
   见 style.css 的注释）。每次同步 checkbox 的视觉状态都走这里，
   免得"改了 checked 但忘了同步类"导致开关看着是关的、其实是开的。 */
const SWITCHES = [];
function switchVisual() {
	for (const s of SWITCHES) {
		s.input.closest('.toggle-row').classList.toggle('is-on', s.input.checked);
	}
}

function updateFoot() {
	const v4 = el.in4.value.trim();
	const v6 = el.in6.value.trim();
	const cur = { ipv4: v4, ipv6: v6, tcp: el.swTcp.checked ? 1 : 0,
		block6: el.swBlock6.checked ? 1 : 0, autostart: el.swAuto.checked ? 1 : 0 };
	const changed = Object.keys(cur).some(k => cur[k] !== saved[k]);

	if (!v4) {
		el.footnote.textContent = 'IPv4 地址是必填的；IPv6 可以留空。';
	} else if (changed) {
		el.footnote.textContent = '有改动尚未应用。点「应用并生效」立刻生效，不需要重启。';
	} else {
		el.footnote.textContent = '';
	}
}

function setBusy(busy) {
	el.btnApply.disabled = busy;
	el.btnOff.disabled = busy;
	el.btnApply.textContent = busy ? '处理中…' : '应用并生效';
}

function showError(message) {
	el.banner.hidden = false;
	el.banner.className = 'banner banner-error';
	el.banner.textContent = message;
}

/* 值要拼进 shell 命令，所以只允许地址里合法出现的字符。
   真正的校验在脚本里（is_ip4 / is_ip6），这里只是不让引号之类的东西
   进到命令行 —— 两道防线，各自守自己那一层。 */
function safeArg(v) {
	return /^[0-9a-fA-F:.]*$/.test(v);
}

/* ── 调用脚本 ─────────────────────────────────────────────────── */

async function callCtl(args) {
	const r = await exec(CTL + ' ' + args);
	/* 脚本的错误信息都走 stderr，直接拿它当用户可见的失败原因 */
	if (r.errno !== 0) {
		const msg = (r.stderr || r.stdout || '').trim() || ('退出码 ' + r.errno);
		throw new Error(msg);
	}
	return r;
}

async function reload(quiet) {
	let out;
	try {
		out = await exec(CTL + ' status');
	} catch (e) {
		if (!quiet) showError('读取状态失败：' + (e && e.message ? e.message : e));
		return null;
	}
	if (out.errno !== 0 && !out.stdout) {
		if (!quiet) showError('读取状态失败（退出码 ' + out.errno + '）');
		return null;
	}
	el.banner.hidden = true;
	const st = parseKV(out.stdout);
	renderStatus(st);
	fillForm(st);
	return st;
}

async function applyChanges() {
	const v4 = el.in4.value.trim();
	const v6 = el.in6.value.trim();

	if (!v4) {
		showError('请填写 IPv4 DNS 地址。');
		el.in4.focus();
		return;
	}
	if (!safeArg(v4) || !safeArg(v6)) {
		showError('地址里含有非法字符。');
		return;
	}

	setBusy(true);
	try {
		/* 一次调用里：校验 + 落盘 + 挂规则。任何一步失败都会原样退回来，
		   并且脚本在挂规则失败时会把规则回滚干净，不会留下半套规则。 */
		const args = 'use ipv4=' + v4
			+ ' ipv6=' + v6
			+ ' tcp=' + (el.swTcp.checked ? 1 : 0)
			+ ' block6=' + (el.swBlock6.checked ? 1 : 0)
			+ ' autostart=' + (el.swAuto.checked ? 1 : 0);
		await callCtl(args);

		const st = await reload(true);
		/* 退出码 0 只说明脚本没报错。真正要不要报"成功"，看的是规则有没有
		   真的挂上（st.ENABLED）——「保存了」和「生效了」是两件事。 */
		if (st && st.ENABLED === '1') {
			toast('已生效：DNS 查询改走 ' + (st.ACTIVE4 || v4));
		} else {
			toast('已保存，但规则未生效');
			showError('配置已保存，但规则没有挂上。DNS 仍走系统默认，可点「关闭并清除」退回。');
		}
	} catch (e) {
		toast('应用失败');
		showError('应用失败：' + (e && e.message ? e.message : e));
		/* 失败后一定要重读：脚本可能已经把规则回滚掉了 */
		await reload(true);
	} finally {
		setBusy(false);
	}
}

async function turnOff() {
	setBusy(true);
	try {
		await callCtl('disable');
		toast('已关闭，规则已清除');
		await reload(true);
	} catch (e) {
		toast('关闭失败');
		showError('关闭失败：' + (e && e.message ? e.message : e));
		await reload(true);
	} finally {
		setBusy(false);
	}
}

/* ── 启动 ─────────────────────────────────────────────────────── */

initPrefs();

el.settings.addEventListener('click', openSheet);
el.scrim.addEventListener('click', closeSheet);
document.addEventListener('keydown', e => {
	if (e.key === 'Escape') closeSheet();
});

el.btnApply.addEventListener('click', applyChanges);
el.btnOff.addEventListener('click', turnOff);

el.in4.addEventListener('input', () => markDirty('ipv4'));
el.in6.addEventListener('input', () => markDirty('ipv6'));

for (const [input, field] of [[el.swTcp, 'tcp'], [el.swBlock6, 'block6'], [el.swAuto, 'autostart']]) {
	SWITCHES.push({ input });
	input.addEventListener('change', () => {
		switchVisual();
		markDirty(field);
	});
}

/* 「常用」胶囊：点一下把两个框都填好（没带 IPv6 的就只填 IPv4） */
el.chips.addEventListener('click', e => {
	const b = e.target.closest('.chip');
	if (!b) return;
	el.in4.value = b.dataset.v4 || '';
	el.in6.value = b.dataset.v6 || '';
	markDirty('ipv4', 'ipv6');
});

/* 初始就同步一次开关外观，别等第一次 reload 才画对 */
switchVisual();

if (!hasBridge()) {
	showError('未检测到 KernelSU 的 WebUI 环境。请在 KernelSU 管理器里打开本页面，'
		+ '而不是用浏览器直接访问。');
	el.btnApply.disabled = true;
	el.btnOff.disabled = true;
} else {
	reload();
	/* 低频自动刷新；页面不可见时不做，省电。
	   有未保存改动时 fillForm 不会覆盖输入框，所以不会打断用户。 */
	setInterval(() => {
		if (document.visibilityState === 'visible') reload(true);
	}, 10000);
}
