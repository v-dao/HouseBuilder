class_name CadLinetype
extends RefCounted
## 线型。对应 DXF 的 LTYPE 表项。
##
## pattern 是"画-空"交替的长度序列，单位 mm（1:1 打印尺度）：
##   正值 = 画线长度，负值 = 间隔长度，0 = 点
## 渲染时按 LTSCALE（全局线型比例）与视图缩放换算到屏幕。
##
## 国标 GB/T 50001—2017 / GB/T 50104—2010 规定的线型用途：
##   粗实线 b        —— 平/剖面图中被剖切的主要建筑构造轮廓、立面外轮廓、详图主轮廓
##   中粗实线 0.7b   —— 被剖切的次要构造轮廓、构配件轮廓
##   中实线 0.5b     —— 尺寸线、尺寸界线、索引符号、标高符号、引出线、粉刷线
##   细实线 0.25b    —— 图例填充线、家具线、纹样线
##   中粗虚线 0.7b   —— 不可见轮廓线
##   细单点长画线 0.25b —— 中心线、对称线、定位轴线
##   细双点长画线 0.25b —— 相邻/原有/拆除建筑物轮廓线
##   折断线、波浪线 0.25b —— 断开界线
##
## 注意：折断线与波浪线不是"画-空"模式，而是特定的几何形状，
## 应作为几何图元绘制，不在此处定义。

var name: String = "CONTINUOUS"
var description: String = "实线"
var pattern: PackedFloat64Array = PackedFloat64Array()


static func make(p_name: String, p_pattern: PackedFloat64Array, p_desc := "") -> CadLinetype:
	var t := CadLinetype.new()
	t.name = p_name
	t.pattern = p_pattern
	t.description = p_desc
	return t


func is_continuous() -> bool:
	return pattern.is_empty()


## 一个完整周期的长度（mm）。用于校验与 DXF 的 total length 字段。
func cycle_length() -> float:
	var s := 0.0
	for v in pattern:
		s += absf(v)
	return s


func duplicate_linetype() -> CadLinetype:
	return CadLinetype.make(name, pattern.duplicate(), description)


# ---------------------------------------------------------------------------
# 国标线型库
# ---------------------------------------------------------------------------

## 返回符合国内建筑制图习惯的默认线型表（键为线型名）。
## 长度取自国内 CAD（天正/中望）常用默认值，单位为 mm。
static func gb_library() -> Dictionary:
	var lib := {}
	lib["CONTINUOUS"] = make("CONTINUOUS", PackedFloat64Array(), "实线")
	lib["DASHED"] = make("DASHED", PackedFloat64Array([12.0, -6.0]), "虚线")
	lib["HIDDEN"] = make("HIDDEN", PackedFloat64Array([6.0, -3.0]), "细虚线")
	lib["CENTER"] = make("CENTER", PackedFloat64Array([24.0, -3.0, 0.0, -3.0]), "单点长画线（定位轴线/中心线）")
	lib["PHANTOM"] = make("PHANTOM", PackedFloat64Array([24.0, -3.0, 0.0, -3.0, 0.0, -3.0]), "双点长画线")
	lib["DASHDOT"] = make("DASHDOT", PackedFloat64Array([12.0, -3.0, 0.0, -3.0]), "点画线")
	lib["BORDER"] = make("BORDER", PackedFloat64Array([12.0, -3.0, 0.0, -3.0, 0.0, -3.0]), "图框线")
	return lib
