class_name NativeFormat
extends RefCounted
## 自有工程格式 `.hbd`（House Building Document）。
##
## 设计取向：
##   · **可读**：JSON + UTF-8。出问题时打开文件就能看出是哪一步写坏的，
##     这对一个还在演进的项目比二进制紧凑重要得多。
##   · **带版本号**：load 时按版本决定要不要做兼容处理。
##   · **预留扩展位**：三维模型、施工工序、工程量数据都还没做，
##     但格式里已经留了 `extensions` 段，后续加数据不会破坏旧文件的读取。
##
## 文件体积通过 zlib 压缩控制在可接受范围（十万级图元的图纸约几 MB）。

const FORMAT_TAG := "HBD"
const FORMAT_VERSION := 1


# ===========================================================================
# 图元工厂
# ===========================================================================

## 按 type 字段重建图元。未知类型返回 null 并给出警告，
## 而不是直接崩掉 —— 旧版本读新文件时应尽量降级而不是失败。
static func entity_from_dict(d: Dictionary) -> CadEntity:
	match int(d.get("type", -1)):
		CadEntity.Type.LINE:
			return EntLine.from_dict(d)
		CadEntity.Type.POLYLINE:
			return EntPolyline.from_dict(d)
		CadEntity.Type.CIRCLE:
			return EntCircle.from_dict(d)
		CadEntity.Type.ARC:
			return EntArc.from_dict(d)
		CadEntity.Type.ELLIPSE:
			return EntEllipse.from_dict(d)
		CadEntity.Type.SPLINE:
			return EntSpline.from_dict(d)
		CadEntity.Type.POINT:
			return EntPoint.from_dict(d)
		CadEntity.Type.TEXT:
			return EntText.from_dict(d)
		CadEntity.Type.MTEXT:
			return EntMText.from_dict(d)
		CadEntity.Type.HATCH:
			return EntHatch.from_dict(d)
		CadEntity.Type.DIMENSION:
			return EntDim.from_dict(d)
		CadEntity.Type.INSERT:
			return EntInsert.from_dict(d)
		CadEntity.Type.WALL:
			return EntWall.from_dict(d)
		CadEntity.Type.XLINE, CadEntity.Type.RAY:
			return EntXline.from_dict(d)
		CadEntity.Type.SYMBOL:
			return EntSymbols.from_dict(d)
	push_warning("未知图元类型 %s，已跳过" % str(d.get("type", -1)))
	return null


# ===========================================================================
# 写
# ===========================================================================

static func to_dict(doc: CadDocument) -> Dictionary:
	var ents := []
	for e in doc.entities:
		ents.append(e.to_dict())
	var layers := {}
	for k in doc.layers.keys():
		var l: CadLayer = doc.layers[k]
		layers[String(k)] = {
			"name": l.name, "color": l.color.to_html(false), "aci": l.aci,
			"linetype": l.linetype, "lineweight": l.lineweight,
			"visible": l.visible, "frozen": l.frozen, "locked": l.locked,
			"printable": l.printable, "description": l.description, "alpha": l.alpha,
		}
	var lts := {}
	for k in doc.linetypes.keys():
		var t: CadLinetype = doc.linetypes[k]
		lts[String(k)] = {"name": t.name, "description": t.description,
			"pattern": Array(t.pattern)}
	var tss := {}
	for k in doc.text_styles.keys():
		var st: CadTextStyle = doc.text_styles[k]
		tss[String(k)] = {
			"name": st.name, "description": st.description,
			"system_font": st.system_font, "font_file": st.font_file,
			"height": st.height, "width_factor": st.width_factor,
			"oblique_angle": st.oblique_angle,
			"oblique_75_letters_only": st.oblique_75_letters_only,
			"upside_down": st.upside_down, "backwards": st.backwards,
		}
	var dss := {}
	for k in doc.dim_styles.keys():
		var ds: CadDimStyle = doc.dim_styles[k]
		dss[String(k)] = _dim_style_to_dict(ds)
	var blks := {}
	for k in doc.blocks.keys():
		blks[String(k)] = (doc.blocks[k] as CadBlock).to_dict()

	return {
		"tag": FORMAT_TAG,
		"version": FORMAT_VERSION,
		"settings": {
			"plot_scale": doc.plot_scale,
			"ltscale": doc.ltscale,
			"dimscale": doc.dimscale,
			"unit_name": doc.unit_name,
			"current_layer": doc.current_layer,
			"current_aci": doc.current_aci,
			"current_linetype": doc.current_linetype,
			"current_lineweight": doc.current_lineweight,
			"current_text_style": doc.current_text_style,
			"current_dim_style": doc.current_dim_style,
		},
		"layers": layers,
		"linetypes": lts,
		"text_styles": tss,
		"dim_styles": dss,
		"blocks": blks,
		"entities": ents,
		"layouts": _layouts_to_arr(doc),
		# 预留：三维模型 / 施工工序 / 工程量 等后续阶段的数据
		"extensions": {},
	}


static func _layouts_to_arr(doc: CadDocument) -> Array:
	var out := []
	for l in doc.layouts:
		out.append((l as CadLayout).to_dict())
	return out


static func _dim_style_to_dict(ds: CadDimStyle) -> Dictionary:
	return {
		"name": ds.name,
		"dim_line_color": ds.dim_line_color.to_html(false),
		"dim_line_weight": ds.dim_line_weight,
		"dim_line_extension": ds.dim_line_extension,
		"ext_line_color": ds.ext_line_color.to_html(false),
		"ext_line_weight": ds.ext_line_weight,
		"ext_line_extension": ds.ext_line_extension,
		"ext_line_offset": ds.ext_line_offset,
		"ext_line_fixed_length": ds.ext_line_fixed_length,
		"terminator": ds.terminator,
		"terminator_size": ds.terminator_size,
		"arrow_size": ds.arrow_size,
		"dot_size": ds.dot_size,
		"terminator_weight": ds.terminator_weight,
		"text_style": ds.text_style,
		"text_height": ds.text_height,
		"text_color": ds.text_color.to_html(false),
		"text_gap": ds.text_gap,
		"text_align_above": ds.text_align_above,
		"text_inside": ds.text_inside,
		"text_round": ds.text_round,
		"prefix": ds.prefix,
		"suffix": ds.suffix,
		"suppress_zeros": ds.suppress_zeros,
		"baseline_spacing": ds.baseline_spacing,
		"origin_offset": ds.origin_offset,
		"overall_scale": ds.overall_scale,
		"elevation_symbol_size": ds.elevation_symbol_size,
		"elevation_decimals": ds.elevation_decimals,
		"radius_prefix": ds.radius_prefix,
		"diameter_prefix": ds.diameter_prefix,
	}


## 写出文件。返回错误码（OK 表示成功）。
static func save(doc: CadDocument, path: String, compress := true) -> Error:
	var payload := JSON.stringify(to_dict(doc))
	var bytes := payload.to_utf8_buffer()
	# 小文件压缩反而会变大（压缩头本身有开销），故设一个阈值
	if compress and bytes.size() >= 4096:
		# 文件头：4 字节魔数 + 4 字节原始长度（小端） + zstd 数据。
		# 之所以要写原始长度：Godot 的 decompress_dynamic 需要一个正的最大长度，
		# 传 -1 会直接失败；与其猜一个上限，不如把真实长度记下来。
		var head := "HBZ1".to_utf8_buffer()
		var n := bytes.size()
		var sz := PackedByteArray()
		sz.resize(4)
		sz.encode_u32(0, n)
		bytes = head + sz + bytes.compress(FileAccess.COMPRESSION_ZSTD)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_buffer(bytes)
	f.close()
	return OK


# ===========================================================================
# 读
# ===========================================================================

## 载入文件。成功时把内容写入 doc 并返回 OK。
static func load_into(doc: CadDocument, path: String) -> Error:
	if not FileAccess.file_exists(path):
		return ERR_FILE_NOT_FOUND
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return FileAccess.get_open_error()
	var raw := f.get_buffer(f.get_length())
	f.close()
	if raw.size() < 4:
		return ERR_FILE_CORRUPT
	var text := ""
	if raw.size() >= 4 and raw.slice(0, 4).get_string_from_utf8() == "HBZ1":
		if raw.size() < 8:
			return ERR_FILE_CORRUPT
		var want := int(raw.decode_u32(4))
		var body := raw.slice(8)
		# 注意：decompress_dynamic 只支持 gzip / DEFLATE / Brotli，**不支持 zstd**，
		# 而 compress 是支持 zstd 的。正因为读写不对称，
		# 才必须在文件头记录原始长度，改用按长度解压的 decompress()。
		var inflated := body.decompress(want, FileAccess.COMPRESSION_ZSTD)
		if inflated.is_empty():
			return ERR_FILE_CORRUPT
		text = inflated.get_string_from_utf8()
	else:
		text = raw.get_string_from_utf8()
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return ERR_FILE_CORRUPT
	return from_dict(doc, parsed)


static func from_dict(doc: CadDocument, d: Dictionary) -> Error:
	if String(d.get("tag", "")) != FORMAT_TAG:
		return ERR_FILE_UNRECOGNIZED
	var ver := int(d.get("version", 0))
	if ver > FORMAT_VERSION:
		push_warning("文件版本 %d 高于本程序支持的 %d，可能缺少部分内容" % [ver, FORMAT_VERSION])

	# 清空文档后重建。撤销栈也一并清掉 —— 跨文件的撤销没有意义。
	doc.entities.clear()
	doc._by_handle.clear()
	doc._next_handle = 1
	doc.undo.clear()
	doc.layers.clear()
	doc.blocks.clear()

	_load_layers(doc, d.get("layers", {}))
	_load_linetypes(doc, d.get("linetypes", {}))
	_load_text_styles(doc, d.get("text_styles", {}))
	_load_dim_styles(doc, d.get("dim_styles", {}))
	_load_blocks(doc, d.get("blocks", {}))
	_load_settings(doc, d.get("settings", {}))
	_load_layouts(doc, d.get("layouts", []))

	# 图元：先全部加入（此时块已就位，块引用能解析到定义）
	var ents = d.get("entities", [])
	for ed in (ents as Array):
		var e := entity_from_dict(ed as Dictionary)
		if e != null:
			doc.add_entity(e, false)
	doc._bump()
	return OK


static func _load_layers(doc: CadDocument, src) -> void:
	if not (src is Dictionary):
		return
	for k in (src as Dictionary).keys():
		var v: Dictionary = (src as Dictionary)[k]
		var l := CadLayer.new()
		l.name = String(v.get("name", k))
		l.color = Color.html(String(v.get("color", "ffffff")))
		l.aci = int(v.get("aci", 7))
		l.linetype = String(v.get("linetype", "CONTINUOUS"))
		l.lineweight = float(v.get("lineweight", CadLayer.LW_DEFAULT))
		l.visible = bool(v.get("visible", true))
		l.frozen = bool(v.get("frozen", false))
		l.locked = bool(v.get("locked", false))
		l.printable = bool(v.get("printable", true))
		l.description = String(v.get("description", ""))
		l.alpha = float(v.get("alpha", 1.0))
		doc.layers[l.name] = l


static func _load_linetypes(doc: CadDocument, src) -> void:
	if not (src is Dictionary):
		return
	for k in (src as Dictionary).keys():
		var v: Dictionary = (src as Dictionary)[k]
		var t := CadLinetype.new()
		t.name = String(v.get("name", k))
		t.description = String(v.get("description", ""))
		var pat := PackedFloat64Array()
		for x in (v.get("pattern", []) as Array):
			pat.append(float(x))
		t.pattern = pat
		doc.linetypes[t.name] = t


static func _load_text_styles(doc: CadDocument, src) -> void:
	if not (src is Dictionary):
		return
	for k in (src as Dictionary).keys():
		var v: Dictionary = (src as Dictionary)[k]
		var s := CadTextStyle.new()
		s.name = String(v.get("name", k))
		s.description = String(v.get("description", ""))
		s.system_font = String(v.get("system_font", "FangSong"))
		s.font_file = String(v.get("font_file", ""))
		s.height = float(v.get("height", 0.0))
		s.width_factor = float(v.get("width_factor", CadTextStyle.GB_ASPECT))
		s.oblique_angle = float(v.get("oblique_angle", 0.0))
		s.oblique_75_letters_only = bool(v.get("oblique_75_letters_only", false))
		s.upside_down = bool(v.get("upside_down", false))
		s.backwards = bool(v.get("backwards", false))
		doc.text_styles[s.name] = s


static func _load_dim_styles(doc: CadDocument, src) -> void:
	if not (src is Dictionary):
		return
	for k in (src as Dictionary).keys():
		var v: Dictionary = (src as Dictionary)[k]
		var ds := CadDimStyle.new()
		ds.name = String(v.get("name", k))
		ds.dim_line_color = Color.html(String(v.get("dim_line_color", "ffffff")))
		ds.dim_line_weight = float(v.get("dim_line_weight", 0.25))
		ds.dim_line_extension = float(v.get("dim_line_extension", 0.0))
		ds.ext_line_color = Color.html(String(v.get("ext_line_color", "ffffff")))
		ds.ext_line_weight = float(v.get("ext_line_weight", 0.25))
		ds.ext_line_extension = float(v.get("ext_line_extension", 2.5))
		ds.ext_line_offset = float(v.get("ext_line_offset", 2.0))
		ds.ext_line_fixed_length = float(v.get("ext_line_fixed_length", 0.0))
		ds.terminator = int(v.get("terminator", CadDimStyle.Terminator.OBLIQUE))
		ds.terminator_size = float(v.get("terminator_size", 2.5))
		ds.arrow_size = float(v.get("arrow_size", 3.5))
		ds.dot_size = float(v.get("dot_size", 1.0))
		ds.terminator_weight = float(v.get("terminator_weight", 0.7))
		ds.text_style = String(v.get("text_style", "标注_2.5"))
		ds.text_height = float(v.get("text_height", 2.5))
		ds.text_color = Color.html(String(v.get("text_color", "ffffff")))
		ds.text_gap = float(v.get("text_gap", 1.0))
		ds.text_align_above = bool(v.get("text_align_above", true))
		ds.text_inside = bool(v.get("text_inside", false))
		ds.text_round = int(v.get("text_round", 0))
		ds.prefix = String(v.get("prefix", ""))
		ds.suffix = String(v.get("suffix", ""))
		ds.suppress_zeros = bool(v.get("suppress_zeros", true))
		ds.baseline_spacing = float(v.get("baseline_spacing", 8.0))
		ds.origin_offset = float(v.get("origin_offset", 10.0))
		ds.overall_scale = float(v.get("overall_scale", 1.0))
		ds.elevation_symbol_size = float(v.get("elevation_symbol_size", 3.0))
		ds.elevation_decimals = int(v.get("elevation_decimals", 3))
		ds.radius_prefix = String(v.get("radius_prefix", "R"))
		ds.diameter_prefix = String(v.get("diameter_prefix", "⌀"))
		doc.dim_styles[ds.name] = ds


static func _load_blocks(doc: CadDocument, src) -> void:
	if not (src is Dictionary):
		return
	for k in (src as Dictionary).keys():
		var v: Dictionary = (src as Dictionary)[k]
		var b := CadBlock.new()
		b.name = String(v.get("name", k))
		var bp: Array = v.get("base_point", [0, 0])
		b.base_point = Vector2(float(bp[0]), float(bp[1]))
		b.description = String(v.get("description", ""))
		b.builtin = bool(v.get("builtin", false))
		var defs = v.get("attribute_defs", [])
		for ad in (defs as Array):
			b.attribute_defs.append((ad as Dictionary).duplicate())
		for ed in (v.get("entities", []) as Array):
			var e := entity_from_dict(ed as Dictionary)
			if e != null:
				e.owner_block = b.name
				b.entities.append(e)
		doc.blocks[b.name] = b


static func _load_layouts(doc: CadDocument, src) -> void:
	doc.layouts.clear()
	doc.active_layout = -1
	for ld in (src as Array):
		if ld is Dictionary:
			doc.layouts.append(CadLayout.from_dict(ld))


static func _load_settings(doc: CadDocument, src) -> void:
	if not (src is Dictionary):
		return
	var v: Dictionary = src
	doc.plot_scale = float(v.get("plot_scale", 100.0))
	doc.ltscale = float(v.get("ltscale", 20.0))
	doc.dimscale = float(v.get("dimscale", 100.0))
	doc.unit_name = String(v.get("unit_name", "mm"))
	doc.current_layer = String(v.get("current_layer", "0"))
	doc.current_aci = int(v.get("current_aci", 256))
	doc.current_linetype = String(v.get("current_linetype", "BYLAYER"))
	doc.current_lineweight = float(v.get("current_lineweight", CadLayer.LW_BYLAYER))
	doc.current_text_style = String(v.get("current_text_style", "仿宋_3.5"))
	doc.current_dim_style = String(v.get("current_dim_style", "国标-1:100"))
	# 0 层必须存在
	doc.ensure_layer("0")
