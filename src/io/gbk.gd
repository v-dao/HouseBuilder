class_name Gbk
extends RefCounted
## Unicode ↔ GBK 编码转换。
##
## 为什么需要：DXF R12 的中文用 GBK(ANSI_936) 编码，
## 而 Godot 只支持 UTF-8 / UTF-16 / ASCII / Latin1，运行时无法做 GBK 转换。
##
## 表中数据由 tools/gen_gbk_table.py 生成（用 Python 自带的 GBK 编解码器建立），
## 覆盖全部可用 GBK 表示的 21791 个字符，按 Unicode 升序排列，查询用二分。

const TABLE_PATH := "res://assets/gbk_table.bin"

static var _uni: PackedInt32Array = PackedInt32Array()
static var _gbk: PackedInt32Array = PackedInt32Array()
static var _loaded := false
static var _available := false


## 表是否可用。缺失时调用方应降级（例如中文写成 '?'）。
static func is_available() -> bool:
	_ensure()
	return _available


static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	if not FileAccess.file_exists(TABLE_PATH):
		push_warning("GBK 映射表缺失：%s，DXF 中的中文将写成 '?'" % TABLE_PATH)
		return
	var f := FileAccess.open(TABLE_PATH, FileAccess.READ)
	if f == null:
		return
	var buf := f.get_buffer(f.get_length())
	f.close()
	if buf.size() < 4:
		return
	# 文件为小端：uint32 数量，随后每项两个 uint16（unicode, gbk）
	var n := int(buf.decode_u32(0))
	if buf.size() < 4 + n * 4:
		return
	_uni.resize(n)
	_gbk.resize(n)
	for i in range(n):
		_uni[i] = int(buf.decode_u16(4 + i * 4))
		_gbk[i] = int(buf.decode_u16(6 + i * 4))
	_available = n > 0


## 二分查找 Unicode 对应的 GBK 码，未收录返回 -1
static func gbk_of(cp: int) -> int:
	_ensure()
	if not _available:
		return -1
	var lo := 0
	var hi := _uni.size() - 1
	while lo <= hi:
		var mid := (lo + hi) / 2
		var v := _uni[mid]
		if v == cp:
			return _gbk[mid]
		if v < cp:
			lo = mid + 1
		else:
			hi = mid - 1
	return -1


## 把 UTF-8 字符串编码为 GBK 字节。
## ASCII 直通；GBK 表里没有的字符（如部分生僻字、emoji）写成 '?'，
## 保证输出的 DXF 在结构上始终合法。
static func encode(s: String) -> PackedByteArray:
	_ensure()
	var out := PackedByteArray()
	out.resize(s.length() * 2)
	var n := 0
	for i in range(s.length()):
		var cp := s.unicode_at(i)
		if cp < 0x80:
			out[n] = cp
			n += 1
			continue
		var code := gbk_of(cp)
		if code < 0:
			out[n] = 0x3F  # '?'
			n += 1
			continue
		out[n] = (code >> 8) & 0xFF
		out[n + 1] = code & 0xFF
		n += 2
	out.resize(n)
	return out


# ---------------------------------------------------------------------------
# 解码（DXF 导入用）
# ---------------------------------------------------------------------------

static var _rev: Dictionary = {}


## 把 GBK 字节解码为字符串。
## 反向对照表按需构建一次（21791 项），之后是常数时间的字典查询。
## 遇到无法识别的双字节序列时保留原字节的替代字符，不抛错 ——
## 导入外部图纸时宁可个别字显示不出来，也不能整张图读不进来。
static func decode(bytes: PackedByteArray) -> String:
	_ensure()
	var out := ""
	var i := 0
	while i < bytes.size():
		var b := bytes[i]
		if b < 0x80:
			out += String.chr(b)
			i += 1
			continue
		if i + 1 >= bytes.size():
			break
		var code := (b << 8) | bytes[i + 1]
		i += 2
		if _rev.is_empty():
			_build_rev()
		var cp = _rev.get(code)
		# 不能写成 out += X if cond else Y —— GDScript 的优先级会把它
		# 解析成 (out += X) if cond else Y，那是非法语句。
		if cp != null:
			out += String.chr(int(cp))
		else:
			out += "?"
	return out


static func _build_rev() -> void:
	_ensure()
	for i in range(_uni.size()):
		_rev[_gbk[i]] = _uni[i]


## 该字节序列是否像 GBK 编码（用于判定导入文件的中文编码）
static func looks_like_gbk(bytes: PackedByteArray) -> bool:
	var hi := 0
	var total := 0
	for b in bytes:
		total += 1
		if b >= 0x81 and b <= 0xFE:
			hi += 1
	return total > 0 and hi > 0
