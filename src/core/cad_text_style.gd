class_name CadTextStyle
extends RefCounted
## 文字样式。对应 DXF 的 STYLE 表项。
##
## 国标 GB/T 50001—2017 对字体的规定：
##   · 字高系列：2.5 / 3.5 / 5 / 7 / 10 / 14 / 20 mm（同一图纸不超过两种字高组合）
##   · 汉字应采用长仿宋体，宽高比 0.7，打印线宽 0.25~0.35mm
##   · 字母与数字可用正体或 75° 斜体，字高不应小于 2.5mm
##   · 字高与字宽的关系：字宽 = 字高 × 0.7（长仿宋）

## 国标字高系列 (mm)。Godot 不允许 PackedXxxArray(...) 出现在常量表达式中，
## 故用普通数组常量。
const GB_HEIGHTS := [2.5, 3.5, 5.0, 7.0, 10.0, 14.0, 20.0]

## 长仿宋宽高比（GB/T 50001 规定）
const GB_ASPECT: float = 0.7

## 字母数字 75° 斜体的剪切系数：1 / tan(75°)
const OBLIQUE_75: float = 0.267949192431123

var name: String = "标准"
var description: String = ""

## 优先使用的系统字体名（用于 OS.get_system_font_path 查找）
var system_font: String = "FangSong"
## 显式指定的字体文件路径；为空时按 system_font 查找，再回退到内置字体
var font_file: String = ""

## 固定字高 (mm)。为 0 表示每次输入时单独指定。
var height: float = 0.0
## 宽高比。长仿宋为 0.7；等宽西文可设 1.0。
var width_factor: float = GB_ASPECT
## 倾斜角（度）。国标允许字母数字用 75° 斜体。
var oblique_angle: float = 0.0
## 是否启用 75° 斜体（仅对字母数字生效，汉字保持正体）
var oblique_75_letters_only: bool = false

## 是否反向 / 颠倒（极少用，机械制图偶见）
var upside_down: bool = false
var backwards: bool = false


static func make(p_name: String, p_height: float, p_width_factor := GB_ASPECT) -> CadTextStyle:
	var s := CadTextStyle.new()
	s.name = p_name
	s.height = p_height
	s.width_factor = p_width_factor
	return s


## 应用国标字高系列与长仿宋宽高比
func apply_gb_fangsong(p_height: float) -> void:
	height = p_height
	width_factor = GB_ASPECT
	system_font = "FangSong"


## 由字高求字宽（mm）
func char_width(h: float) -> float:
	return h * width_factor


## 倾斜角的剪切矩阵（列向量形式；Transform2D 没有 6 标量构造函数）
func oblique_transform() -> Transform2D:
	var shear := OBLIQUE_75 if oblique_75_letters_only else tan(deg_to_rad(oblique_angle))
	return Transform2D(Vector2(1.0, 0.0), Vector2(shear, 1.0), Vector2.ZERO)


## 长仿宋的横向压缩矩阵
func aspect_transform() -> Transform2D:
	return Transform2D(Vector2(width_factor, 0.0), Vector2(0.0, 1.0), Vector2.ZERO)


## 综合变换：先横向压缩（长仿宋），再按需剪切（斜体）
func render_transform() -> Transform2D:
	return oblique_transform() * aspect_transform()


func has_scale() -> bool:
	return not is_equal_approx(width_factor, 1.0) or oblique_angle > 0.0 or oblique_75_letters_only


func duplicate_style() -> CadTextStyle:
	var s := CadTextStyle.new()
	s.name = name
	s.description = description
	s.system_font = system_font
	s.font_file = font_file
	s.height = height
	s.width_factor = width_factor
	s.oblique_angle = oblique_angle
	s.oblique_75_letters_only = oblique_75_letters_only
	s.upside_down = upside_down
	s.backwards = backwards
	return s


# ---------------------------------------------------------------------------
# 国标文字样式库
# ---------------------------------------------------------------------------

## 国内建筑制图常见的几种文字样式预设
static func gb_library() -> Dictionary:
	var lib := {}

	var body := make("仿宋_3.5", 3.5)
	body.description = "说明文字、尺寸标注（长仿宋）"
	lib[body.name] = body

	var dim := make("标注_2.5", 2.5)
	dim.description = "尺寸数字（长仿宋，最小字高）"
	lib[dim.name] = dim

	var room := make("房间名_5", 5.0)
	room.description = "房间名称"
	lib[room.name] = room

	var title := make("图名_7", 7.0)
	title.description = "图名、剖切编号"
	lib[title.name] = title

	# 图框标题栏用黑体较常见，宽度比接近 1.0
	var frame := make("标题栏_5", 5.0, 1.0)
	frame.system_font = "SimHei"
	frame.description = "标题栏、会签栏（黑体）"
	lib[frame.name] = frame

	# 字母数字 75° 斜体
	var lat := make("西文斜体_3.5", 3.5, 1.0)
	lat.oblique_75_letters_only = true
	lat.description = "字母与数字，75° 斜体（GB 允许）"
	lib[lat.name] = lat

	return lib
