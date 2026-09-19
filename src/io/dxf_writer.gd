class_name DxfWriter
extends RefCounted
## DXF R12 (AC1009) ASCII 导出。
##
## 为什么选 R12 而不是 R2000+：
## R2000 及以上需要完整的 handle / owner(330) 体系与 CLASSES / OBJECTS 段，
## 少一项 AutoCAD 就打不开，手工构造的可靠度很低。
## R12 的结构简单得多（无 handle、无对象字典），
## 且 AutoCAD、中望、浩辰、LibreCAD、QCAD 全都读得进。
## 交流图纸的核心诉求是"对方能打开"，这一点 R12 做得最好。
##
## 中文编码用 GBK（R12 的规范），见 io/gbk.gd。
##
## 不支持 R12 语法的图元（椭圆、样条、填充、标注）一律**打散为基础图元**：
##   · 椭圆 / 样条 -> POLYLINE 折线近似
##   · 填充       -> 填充线逐条 LINE
##   · 标注       -> 拆成尺寸线 + 尺寸数字（与 AutoCAD 的"标注打散"一致）
## 这样输出永远只含 R12 的五种基本实体，兼容性最高。

enum Version { R12 }

var doc: CadDocument = null
var _out := PackedByteArray()
## 建立块名到已写出块的映射，避免重复写 BLOCKS 段
var _written_blocks := {}


func _init(p_doc: CadDocument) -> void:
	doc = p_doc


## 导出为字节。返回的字节是 GBK 编码的 ASCII DXF。
func write() -> PackedByteArray:
	_out = PackedByteArray()
	_written_blocks.clear()
	_write_header()
	_write_tables()
	_write_blocks()
	_write_entities()
	_tag(0, "EOF")
	return _out


## 导出并写入文件
func save(path: String) -> Error:
	var data := write()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_buffer(data)
	f.close()
	return OK


# ---------------------------------------------------------------------------
# 写出原语
# ---------------------------------------------------------------------------

## 一个 DXF 组码：一行组码、一行值，均以换行结束。字符串走 GBK 编码。
func _tag(code: int, value) -> void:
	_out.append_array(("%d\n" % code).to_utf8_buffer())
	if value is float:
		# DXF 的实数不接受科学计数法，且过长的小数位会拖慢对方解析
		_out.append_array(_real(value).to_utf8_buffer())
	else:
		# 用 str() 而不是 String()：String() 对非字符串参数在某些类型上会报
		# Invalid call 构造错误，str() 对任意 Variant 都成立
		var s := str(value)
		if _is_ascii(s):
			_out.append_array(s.to_utf8_buffer())
		else:
			_out.append_array(Gbk.encode(s))
	_out.append(0x0A)


## DXF 实数格式：固定小数位，去掉尾随零
static func _real(v: float) -> String:
	var s := "%.6f" % v
	if s.contains("."):
		s = s.rstrip("0")
		if s.ends_with("."):
			s += "0"
	return s


static func _is_ascii(s: String) -> bool:
	for i in range(s.length()):
		if s.unicode_at(i) >= 0x80:
			return false
	return true


# ---------------------------------------------------------------------------
# 段
# ---------------------------------------------------------------------------

func _write_header() -> void:
	_tag(0, "SECTION")
	_tag(2, "HEADER")
	_tag(9, "$ACADVER")
	_tag(1, "AC1009")
	# 必须声明代码页！否则读的人只能按默认的 cp1252 解码，
	# 我们的 GBK 中文会全部变成乱码（ezdxf 实测确认过这一点）。
	_tag(9, "$DWGCODEPAGE")
	_tag(3, "ANSI_936")
	# 4 = 毫米。国内建筑图以毫米为单位，必须声明，
	# 否则对方按英寸读会把整张图缩到 1/25.4。
	_tag(9, "$INSUNITS")
	_tag(70, 4)
	_tag(9, "$MEASUREMENT")
	_tag(70, 1)
	var bb := doc.get_bbox()
	_tag(9, "$EXTMIN")
	_tag(10, bb.position.x)
	_tag(20, bb.position.y)
	_tag(30, 0.0)
	_tag(9, "$EXTMAX")
	_tag(10, bb.position.x + bb.size.x)
	_tag(20, bb.position.y + bb.size.y)
	_tag(30, 0.0)
	_tag(0, "ENDSEC")


func _write_tables() -> void:
	_tag(0, "SECTION")
	_tag(2, "TABLES")
	_write_linetypes()
	_write_layers()
	_write_styles()
	_tag(0, "ENDSEC")


func _write_linetypes() -> void:
	_tag(0, "TABLE")
	_tag(2, "LTYPE")
	_tag(70, doc.linetypes.size())
	# 实线必须存在
	var cont := CadLinetype.make("CONTINUOUS", PackedFloat64Array(), "Solid line")
	_write_linetype(cont)
	for k in doc.linetypes.keys():
		if String(k) == "CONTINUOUS":
			continue
		_write_linetype(doc.linetypes[k])
	_tag(0, "ENDTAB")


func _write_linetype(lt: CadLinetype) -> void:
	_tag(0, "LTYPE")
	_tag(2, lt.name)
	_tag(70, 0)
	_tag(3, lt.description)
	_tag(72, 65)  # 对齐方式：A
	_tag(73, lt.pattern.size())
	_tag(40, lt.cycle_length())
	for v in lt.pattern:
		_tag(49, float(v))


func _write_layers() -> void:
	_tag(0, "TABLE")
	_tag(2, "LAYER")
	_tag(70, doc.layers.size())
	for k in doc.layer_names():
		var l: CadLayer = doc.layers[k]
		_tag(0, "LAYER")
		_tag(2, l.name)
		# 位标志：1=冻结，4=锁定；图层关闭用负的 color 表示
		var flags := 0
		if l.frozen:
			flags |= 1
		if l.locked:
			flags |= 4
		_tag(70, flags)
		_tag(62, -l.aci if (not l.visible and l.aci > 0) else l.aci)
		_tag(6, l.linetype)
	_tag(0, "ENDTAB")


func _write_styles() -> void:
	_tag(0, "TABLE")
	_tag(2, "STYLE")
	_tag(70, doc.text_styles.size() + 1)
	# 标准样式
	_tag(0, "STYLE")
	_tag(2, "STANDARD")
	_tag(70, 0)
	_tag(40, 0.0)
	_tag(41, 0.7)      # 长仿宋的宽高比
	_tag(50, 0.0)
	_tag(71, 0)
	_tag(42, 2.5)
	_tag(3, "txt")
	_tag(4, "")
	for k in doc.text_styles.keys():
		var s: CadTextStyle = doc.text_styles[k]
		_tag(0, "STYLE")
		_tag(2, s.name)
		_tag(70, 0)
		_tag(40, s.height)
		_tag(41, s.width_factor)
		_tag(50, rad_to_deg(s.oblique_angle))
		_tag(71, 0)
		_tag(42, maxf(s.height, 2.5))
		_tag(3, "simfang.ttf")
		_tag(4, "")
	_tag(0, "ENDTAB")


# ---------------------------------------------------------------------------
# 块
# ---------------------------------------------------------------------------

func _write_blocks() -> void:
	_tag(0, "SECTION")
	_tag(2, "BLOCKS")
	# 模型空间块必须存在，部分读取器会要求
	_tag(0, "BLOCK")
	_tag(8, "0")
	_tag(2, "*Model_Space")
	_tag(70, 0)
	_tag(10, 0.0)
	_tag(20, 0.0)
	_tag(30, 0.0)
	_tag(3, "*Model_Space")
	_tag(1, "")
	_tag(0, "ENDBLK")
	_tag(8, "0")
	# 用户块：只写被引用到的，减小文件
	for k in doc.blocks.keys():
		var b: CadBlock = doc.blocks[k]
		if not _block_referenced(String(k)):
			continue
		_write_block(b)
	_tag(0, "ENDSEC")


func _block_referenced(name: String) -> bool:
	for e in doc.entities:
		if e is EntInsert and (e as EntInsert).block_name == name:
			return true
	return false


func _write_block(b: CadBlock) -> void:
	_written_blocks[b.name] = true
	_tag(0, "BLOCK")
	_tag(8, "0")
	_tag(2, b.name)
	_tag(70, 0)
	_tag(10, b.base_point.x)
	_tag(20, b.base_point.y)
	_tag(30, 0.0)
	_tag(3, b.name)
	_tag(1, "")
	for e in b.entities:
		_entity(e)
	_tag(0, "ENDBLK")
	_tag(8, "0")


# ---------------------------------------------------------------------------
# 图元
# ---------------------------------------------------------------------------

func _write_entities() -> void:
	_tag(0, "SECTION")
	_tag(2, "ENTITIES")
	for e in doc.entities:
		if not e.visible:
			continue
		var l := doc.get_layer(e.layer)
		if l != null and not l.is_displayable():
			continue
		_entity(e)
	_tag(0, "ENDSEC")


## 公共组码：图层、颜色、线型
func _common(e: CadEntity, dxf_type: String) -> void:
	_tag(0, dxf_type)
	_tag(8, e.layer)
	var aci := e.aci
	if aci == 0 or aci == 256:
		# 随层 / 随块：R12 里写 256 表示随层，0 表示随块
		aci = 0 if e.aci == 0 else 256
	_tag(62, aci)
	var lt := doc.resolve_linetype(e)
	if lt != "" and lt != "BYLAYER":
		_tag(6, lt)


func _entity(e: CadEntity) -> void:
	# 优先用原生 DXF 实体，语义保留最好
	if e is EntLine:
		var ln := e as EntLine
		_common(e, "LINE")
		_tag(10, ln.p0.x)
		_tag(20, ln.p0.y)
		_tag(30, 0.0)
		_tag(11, ln.p1.x)
		_tag(21, ln.p1.y)
		_tag(31, 0.0)
		return
	if e is EntCircle:
		var ci := e as EntCircle
		_common(e, "CIRCLE")
		_tag(10, ci.center.x)
		_tag(20, ci.center.y)
		_tag(30, 0.0)
		_tag(40, ci.radius)
		return
	if e is EntArc:
		var ar := e as EntArc
		_common(e, "ARC")
		_tag(10, ar.center.x)
		_tag(20, ar.center.y)
		_tag(30, 0.0)
		_tag(40, ar.radius)
		# DXF 角度为度、逆时针，与模型空间一致，无需翻转
		_tag(50, rad_to_deg(ar.start_angle))
		_tag(51, rad_to_deg(ar.end_angle))
		return
	if e is EntPolyline:
		var pl := e as EntPolyline
		# 全为直线段时用最简洁的 POLYLINE；含圆弧段则带上 bulge
		_common(e, "POLYLINE")
		_tag(66, 1)  # 后面跟 VERTEX
		_tag(70, 1 if pl.is_closed() else 0)
		_tag(10, 0.0)
		_tag(20, 0.0)
		_tag(30, 0.0)
		var pts := pl.points()
		var bls := pl.bulges()
		for i in range(pts.size()):
			_tag(0, "VERTEX")
			_tag(8, e.layer)
			_tag(10, pts[i].x)
			_tag(20, pts[i].y)
			_tag(30, 0.0)
			var b := bls[i] if i < bls.size() else 0.0
			if absf(b) > 1.0e-12:
				_tag(42, b)
		_tag(0, "SEQEND")
		_tag(8, e.layer)
		return
	if e is EntPoint:
		var pt := e as EntPoint
		_common(e, "POINT")
		_tag(10, pt.position.x)
		_tag(20, pt.position.y)
		_tag(30, 0.0)
		return
	if e is EntText:
		var t := e as EntText
		_common(e, "TEXT")
		_tag(10, t.position.x)
		_tag(20, t.position.y)
		_tag(30, 0.0)
		_tag(40, t.height)
		_tag(1, t.text)
		_tag(50, rad_to_deg(t.rotation))
		_tag(7, t.text_style)
		_tag(72, _h_align(t.h_align))
		_tag(73, _v_align(t.v_align))
		# 有对齐方式时，第二个对齐点(11,21)是必须的
		if t.h_align != EntText.HAlign.LEFT or t.v_align != EntText.VAlign.BASELINE:
			_tag(11, t.position.x)
			_tag(21, t.position.y)
			_tag(31, 0.0)
		return
	if e is EntInsert:
		var ins := e as EntInsert
		if not doc.blocks.has(ins.block_name):
			return
		_common(e, "INSERT")
		_tag(2, ins.block_name)
		_tag(10, ins.position.x)
		_tag(20, ins.position.y)
		_tag(30, 0.0)
		_tag(41, ins.scale.x)
		_tag(42, ins.scale.y)
		_tag(43, 1.0)
		_tag(50, rad_to_deg(ins.rotation))
		return
	# 其余类型一律打散 —— R12 没有对应实体，强行写只会让对方读不了
	_exploded(e)


## 把不支持 R12 语法的图元打散成基础实体
func _exploded(e: CadEntity) -> void:
	# 填充：实心用 SOLID 面片，图案用逐条 LINE
	if e is EntHatch:
		var h := e as EntHatch
		if h.is_solid():
			var ring := h.boundary_closed()
			if ring.size() >= 3:
				# R12 的 SOLID 是四边形，多边形需三角扇近似
				for i in range(1, ring.size() - 1):
					_write_solid(h.layer, ring[0], ring[i], ring[i + 1], ring[i + 1])
			return
		for c in h.get_curves():
			_explode_curve(c, e)
		return
	# 标注：拆成尺寸线与尺寸数字（与 AutoCAD 的标注打散一致）
	if e is EntDim:
		for c in e.get_curves():
			_explode_curve(c, e)
		for a in e.get_annotation_texts():
			_write_text_from_annotation(e, a)
		return
	# 墙体 / 符号 / 椭圆 / 样条 / 构造线：逐段输出
	for c in e.get_curves():
		_explode_curve(c, e)
	for a in e.get_annotation_texts():
		_write_text_from_annotation(e, a)


func _explode_curve(c: GeoCurve, owner: CadEntity) -> void:
	match c.kind():
		GeoCurve.Kind.SEG:
			var s := c as GeoSeg
			_common(owner, "LINE")
			_tag(10, s.a.x)
			_tag(20, s.a.y)
			_tag(30, 0.0)
			_tag(11, s.b.x)
			_tag(21, s.b.y)
			_tag(31, 0.0)
		GeoCurve.Kind.ARC:
			var a := c as GeoArc
			if a.is_full_circle():
				_common(owner, "CIRCLE")
				_tag(10, a.center.x)
				_tag(20, a.center.y)
				_tag(30, 0.0)
				_tag(40, a.radius)
			else:
				_common(owner, "ARC")
				_tag(10, a.center.x)
				_tag(20, a.center.y)
				_tag(30, 0.0)
				_tag(40, a.radius)
				_tag(50, rad_to_deg(a.start_angle))
				_tag(51, rad_to_deg(a.end_angle))
		_:
			# 多段线、椭圆、样条：按细分折线输出
			var pts := c.tessellate(_sagitta(c))
			if pts.size() < 2:
				return
			_write_polyline(owner, pts, c.is_closed())


func _sagitta(c: GeoCurve) -> float:
	var bb := c.bbox()
	return maxf(maxf(bb.size.x, bb.size.y) * 1.0e-4, 0.05)


func _write_polyline(owner: CadEntity, pts: PackedVector2Array, closed: bool) -> void:
	_common(owner, "POLYLINE")
	_tag(66, 1)
	_tag(70, 1 if closed else 0)
	_tag(10, 0.0)
	_tag(20, 0.0)
	_tag(30, 0.0)
	for p in pts:
		_tag(0, "VERTEX")
		_tag(8, owner.layer)
		_tag(10, p.x)
		_tag(20, p.y)
		_tag(30, 0.0)
	_tag(0, "SEQEND")
	_tag(8, owner.layer)


func _write_solid(layer: String, a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> void:
	_tag(0, "SOLID")
	_tag(8, layer)
	_tag(62, 256)
	_tag(10, a.x)
	_tag(20, a.y)
	_tag(30, 0.0)
	_tag(11, b.x)
	_tag(21, b.y)
	_tag(31, 0.0)
	_tag(12, c.x)
	_tag(22, c.y)
	_tag(32, 0.0)
	_tag(13, d.x)
	_tag(23, d.y)
	_tag(33, 0.0)


func _write_text_from_annotation(owner: CadEntity, a: Dictionary) -> void:
	var txt := String(a.get("text", ""))
	if txt == "":
		return
	var pos: Vector2 = a.get("position", Vector2.ZERO)
	_common(owner, "TEXT")
	_tag(10, pos.x)
	_tag(20, pos.y)
	_tag(30, 0.0)
	_tag(40, float(a.get("height", 3.5)))
	_tag(1, txt)
	_tag(50, rad_to_deg(float(a.get("rotation", 0.0))))
	_tag(7, String(a.get("style", "STANDARD")))
	_tag(72, _h_align(int(a.get("h_align", EntText.HAlign.LEFT))))
	_tag(73, _v_align(int(a.get("v_align", EntText.VAlign.BASELINE))))
	_tag(11, pos.x)
	_tag(21, pos.y)
	_tag(31, 0.0)


static func _h_align(a: int) -> int:
	match a:
		EntText.HAlign.CENTER:
			return 1
		EntText.HAlign.RIGHT:
			return 2
		EntText.HAlign.MIDDLE:
			return 4
	return 0


static func _v_align(a: int) -> int:
	match a:
		EntText.VAlign.BOTTOM:
			return 1
		EntText.VAlign.MIDDLE:
			return 2
		EntText.VAlign.TOP:
			return 3
	return 0
