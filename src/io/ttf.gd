class_name Ttf
extends RefCounted
## TrueType 字体解析（只解析 PDF 嵌入所必需的那几张表）。
##
## 需要它的原因：PDF 里嵌入中日韩字体要用 Identity-H 编码，
## 此时文本内容是**字形序号(GID)** 而不是 Unicode，
## 因此必须读字体的 cmap 表把 Unicode 映射成 GID，
## 再读 hhea/hmtx 拿字宽、head 拿 em 尺寸与包围盒。
##
## 只做读取，不改写字体数据 —— PDF 的 FontFile2 直接嵌入原始字节，
## 配合 CIDToGIDMap /Identity 与原始 cmap，字形数据完全不用重建。
## 代价是嵌入整份字体（simfang 约 10MB，Flate 压缩后约 5MB），
## 换来的是"任何阅读器都能正确显示中文"，这个取舍对施工图是值得的。

var data: PackedByteArray = PackedByteArray()
var ok := false
var units_per_em := 1000
var num_glyphs := 0
var ascender := 800
var descender := -200
## [xMin, yMin, xMax, yMax]
var bbox := PackedInt32Array([0, 0, 1000, 1000])
var family_name := ""
var postscript_name := "EmbeddedCJK"

var _tables := {}
var _cmap := {}
var _advances := PackedInt32Array()
var _default_advance := 500


func load_from_file(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	data = f.get_buffer(f.get_length())
	f.close()
	return _parse()


func load_from_bytes(bytes: PackedByteArray) -> bool:
	data = bytes
	return _parse()


func _u8(off: int) -> int:
	if off < 0 or off >= data.size():
		return 0
	return data[off]


func _u16(off: int) -> int:
	if off < 0 or off + 1 >= data.size():
		return 0
	return (data[off] << 8) | data[off + 1]


func _i16(off: int) -> int:
	var v := _u16(off)
	return v - 0x10000 if v >= 0x8000 else v


func _u32(off: int) -> int:
	if off < 0 or off + 3 >= data.size():
		return 0
	return (data[off] << 24) | (data[off + 1] << 16) | (data[off + 2] << 8) | data[off + 3]


func _parse() -> bool:
	ok = false
	if data.size() < 12:
		return false
	var tag := _u32(0)
	# 0x00010000 = TrueType，'true'，'OTTO' = CFF/OpenType
	if tag != 0x00010000 and tag != 0x74727565 and tag != 0x4F54544F:
		# 也可能是 TTC（字体集合），取第一个字体
		if tag == 0x74746366:
			if data.size() >= 16:
				var first := _u32(12)
				if first + 12 <= data.size():
					# 简化处理：把集合内第一个字体的偏移当作起点重新解析
					return _parse_at(first)
		return false
	return _parse_at(0)


func _parse_at(base: int) -> bool:
	var num_tables := _u16(base + 4)
	var arrays_base := base + 12
	for i in range(num_tables):
		var rec := arrays_base + i * 16
		if rec + 16 > data.size():
			break
		var t := _u32(rec)
		_tables[t] = {"off": _u32(rec + 8), "len": _u32(rec + 12)}
	if not _tables.has(_tag("head")) or not _tables.has(_tag("cmap")):
		return false
	_parse_head()
	_parse_hhea()
	_parse_maxp()
	_parse_hmtx()
	_parse_cmap()
	ok = num_glyphs > 0
	return ok


static func _tag(s: String) -> int:
	var v := 0
	for i in range(4):
		v = (v << 8) | (s.unicode_at(i) if i < s.length() else 0x20)
	return v


func _table_off(name: String) -> int:
	var t: Dictionary = _tables.get(_tag(name), {})
	return int(t.get("off", -1))


func _table_len(name: String) -> int:
	var t: Dictionary = _tables.get(_tag(name), {})
	return int(t.get("len", 0))


func _parse_head() -> void:
	var o := _table_off("head")
	if o < 0:
		return
	units_per_em = _u16(o + 18)
	bbox = PackedInt32Array([_i16(o + 36), _i16(o + 38), _i16(o + 40), _i16(o + 42)])


func _parse_hhea() -> void:
	var o := _table_off("hhea")
	if o < 0:
		return
	ascender = _i16(o + 4)
	descender = _i16(o + 6)


func _parse_maxp() -> void:
	var o := _table_off("maxp")
	if o < 0:
		return
	num_glyphs = _u16(o + 4)


func _parse_hmtx() -> void:
	var hh := _table_off("hhea")
	var hm := _table_off("hmtx")
	if hh < 0 or hm < 0:
		return
	var n_metrics := _u16(hh + 34)
	if n_metrics <= 0:
		return
	_advances.resize(num_glyphs)
	var last := 0
	for i in range(num_glyphs):
		if i < n_metrics:
			last = _u16(hm + i * 4)
		# 超出 numberOfHMetrics 的字形沿用最后一个宽度（TrueType 规范）
		_advances[i] = last
	if n_metrics > 0:
		_default_advance = _u16(hm)


## 解析 cmap，建立 Unicode -> GID 映射。
## 优先取 (3,10) 或 (3,1)：前者是 UCS-4、后者是 BMP，都是 Windows 平台的标准子表。
func _parse_cmap() -> void:
	var o := _table_off("cmap")
	if o < 0:
		return
	var n := _u16(o + 2)
	var best := -1
	var best_score := -1
	for i in range(n):
		var rec := o + 4 + i * 8
		var plat := _u16(rec)
		var enc := _u16(rec + 2)
		var sub := o + _u32(rec + 4)
		var score := -1
		if plat == 3 and enc == 10:
			score = 4      # Windows UCS-4
		elif plat == 3 and enc == 1:
			score = 3      # Windows BMP
		elif plat == 0:
			score = 2      # Unicode
		elif plat == 3 and enc == 0:
			score = 1      # Symbol
		if score > best_score:
			best_score = score
			best = sub
	if best < 0:
		return
	var fmt := _u16(best)
	if fmt == 4:
		_parse_cmap_format4(best)
	elif fmt == 12:
		_parse_cmap_format12(best)
	elif fmt == 6:
		_parse_cmap_format6(best)


func _parse_cmap_format4(base: int) -> void:
	var seg_x2 := _u16(base + 6)
	var seg := seg_x2 / 2
	if seg <= 0:
		return
	var end_base := base + 14
	var start_base := end_base + seg_x2 + 2
	var delta_base := start_base + seg_x2
	var range_base := delta_base + seg_x2
	for i in range(seg):
		var end_c := _u16(end_base + i * 2)
		var start_c := _u16(start_base + i * 2)
		var delta := _i16(delta_base + i * 2)
		var ro := _u16(range_base + i * 2)
		if start_c > end_c:
			continue
		for cp in range(start_c, end_c + 1):
			if cp == 0xFFFF:
				continue
			var gid := 0
			if ro == 0:
				gid = (cp + delta) & 0xFFFF
			else:
				# idRangeOffset 是相对它自身位置的字节偏移
				var addr := range_base + i * 2 + ro + (cp - start_c) * 2
				gid = _u16(addr)
				if gid != 0:
					gid = (gid + delta) & 0xFFFF
			if gid != 0:
				_cmap[cp] = gid


func _parse_cmap_format12(base: int) -> void:
	var n_groups := _u32(base + 12)
	var g := base + 16
	for i in range(n_groups):
		var off := g + i * 12
		if off + 12 > data.size():
			break
		var s := _u32(off)
		var e := _u32(off + 4)
		var gid0 := _u32(off + 8)
		# 避免超长区间把内存撑爆
		if e - s > 0x20000:
			continue
		for cp in range(s, e + 1):
			_cmap[cp] = gid0 + (cp - s)


func _parse_cmap_format6(base: int) -> void:
	var first := _u16(base + 6)
	var count := _u16(base + 8)
	for i in range(count):
		var gid := _u16(base + 10 + i * 2)
		if gid != 0:
			_cmap[first + i] = gid


# ---------------------------------------------------------------------------
# 查询
# ---------------------------------------------------------------------------

func glyph_id(cp: int) -> int:
	return int(_cmap.get(cp, 0))


func advance(gid: int) -> int:
	if gid >= 0 and gid < _advances.size():
		return _advances[gid]
	return _default_advance


## 字形宽度，单位是 1/1000 em（PDF 的宽度单位）
func advance_1000(gid: int) -> int:
	if units_per_em <= 0:
		return 500
	return int(round(float(advance(gid)) * 1000.0 / float(units_per_em)))


func ascent_1000() -> int:
	if units_per_em <= 0:
		return 800
	return int(round(float(ascender) * 1000.0 / float(units_per_em)))


func descent_1000() -> int:
	if units_per_em <= 0:
		return -200
	return int(round(float(descender) * 1000.0 / float(units_per_em)))


## 字体包围盒，单位 1/1000 em
func bbox_1000() -> PackedInt32Array:
	if units_per_em <= 0:
		return PackedInt32Array([-200, -300, 1000, 900])
	var k := 1000.0 / float(units_per_em)
	return PackedInt32Array([
		int(round(bbox[0] * k)), int(round(bbox[1] * k)),
		int(round(bbox[2] * k)), int(round(bbox[3] * k))])


func glyph_count() -> int:
	return num_glyphs


func has_glyph(cp: int) -> bool:
	return _cmap.has(cp)
