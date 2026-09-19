class_name FontManager
extends RefCounted
## 字体加载与缓存。
##
## 关键结论（详见 docs/引擎特性与坑.md）：
##   1. 必须用 FontFile.load_dynamic_font(绝对路径)，不要依赖 SystemFont 名字匹配
##   2. 长仿宋 = 对仿宋施加横向 0.7 压缩（FontVariation.variation_transform）
##   3. FontVariation 的 Transform2D 必须用**列向量**构造，没有 6 标量构造函数
##   4. 字形图集是延迟光栅化的，截图工具必须先预热再抓帧，否则拍到白色占位纹理
##
## 字体解析优先级：
##   样式指定的 font_file -> 系统字体（按名字查找）-> 内置 OFL 回退字体 -> 引擎默认
##
## 授权：Windows 自带字体（simfang.ttf 等）只在本机读取渲染，**不打包分发**。
## 分发时依赖 assets/fonts 下的 SIL OFL 开源仿宋。

## 打包分发的开源回退字体（SIL OFL-1.1，可自由商用）
## 注意：Godot 不允许 PackedStringArray(...) 出现在常量表达式里，
## 因此这里用普通数组常量。
const BUNDLED_FALLBACKS := [
	"res://assets/fonts/ZhuqueFangsong-Regular.ttf",
	"res://assets/fonts/HuiwenFangsong.ttf",
	"res://assets/fonts/NotoSansSC-Regular.ttf",
]

## 界面上可选的系统字体（显示名 -> 系统字体名）
const UI_FONT_CHOICES: Array = [
	["仿宋（长仿宋，工程字）", "FangSong"],
	["黑体（标题字）", "SimHei"],
	["楷体（说明文字）", "KaiTi"],
	["宋体", "SimSun"],
	["微软雅黑（界面）", "Microsoft YaHei"],
]

static var _instance: FontManager = null

## 字体名 -> FontFile（不含变换，变换在 FontVariation 层做）
var _files: Dictionary = {}
## 样式名 + 变换指纹 -> Font
var _variants: Dictionary = {}
var _warmed := false


static func instance() -> FontManager:
	if _instance == null:
		_instance = FontManager.new()
	return _instance


## 定位并加载一个系统字体文件，返回绝对路径。找不到返回空串。
static func find_system_font(font_name: String) -> String:
	if font_name == "":
		return ""
	var p := OS.get_system_font_path(font_name, 400, 100, false)
	if p != "" and FileAccess.file_exists(p):
		return p
	# 名称大小写与中文别名都试一遍
	for alt in [font_name.to_lower(), font_name.to_upper()]:
		var q := OS.get_system_font_path(alt, 400, 100, false)
		if q != "" and FileAccess.file_exists(q):
			return q
	return ""


## 按样式解析出 FontFile
func resolve_file(style: CadTextStyle) -> Font:
	# 1) 样式显式指定的文件
	if style.font_file != "" and FileAccess.file_exists(style.font_file):
		var f := _load(style.font_file)
		if f != null:
			return f
	# 2) 按系统字体名查找
	var sys := find_system_font(style.system_font)
	if sys != "":
		var f2 := _load(sys)
		if f2 != null:
			return f2
	# 3) 内置开源回退
	for p in BUNDLED_FALLBACKS:
		if FileAccess.file_exists(p) or ResourceLoader.exists(p):
			var f3 := _load(p)
			if f3 != null:
				return f3
	# 4) 引擎默认（无中文，仅在极端情况下兜底）
	return ThemeDB.fallback_font


func _load(path: String) -> FontFile:
	if _files.has(path):
		return _files[path]
	var ff := FontFile.new()
	var err := OK
	if path.begins_with("res://"):
		var res := ResourceLoader.load(path)
		if res is FontFile:
			_files[path] = res
			return res
		if res is Font:
			_files[path] = res
			return null
		err = FAILED
	else:
		err = ff.load_dynamic_font(path)
	if err != OK:
		push_warning("字体加载失败: %s (err=%d)" % [path, err])
		_files[path] = null
		return null
	if ff.get_face_count() == 0:
		return null
	ff.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	ff.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	ff.hinting = TextServer.HINTING_NONE
	_files[path] = ff
	return ff


## 取某个文字样式对应的可绘制 Font（带长仿宋压缩与可选的 75° 斜切）
func font_for(style: CadTextStyle) -> Font:
	var key := "%s|%.4f|%.4f|%s" % [style.name, style.width_factor, style.oblique_angle, str(style.oblique_75_letters_only)]
	if _variants.has(key):
		return _variants[key]
	var base := resolve_file(style)
	if base == null:
		return ThemeDB.fallback_font
	if not style.has_scale() and not style.upside_down and not style.backwards:
		_variants[key] = base
		return base
	var fv := FontVariation.new()
	fv.base_font = base
	fv.variation_transform = style.render_transform()
	_variants[key] = fv
	return fv


## 便捷方法：按样式名从文档取样式并解析字体
func font_for_name(doc: CadDocument, style_name: String) -> Font:
	if doc != null:
		var s := doc.get_text_style(style_name)
		if s != null:
			return font_for(s)
	return ThemeDB.fallback_font


# ---------------------------------------------------------------------------
# 预热
# ---------------------------------------------------------------------------

## 预光栅化字形图集。
## 动态字体的图集是延迟生成的，首次绘制后要过若干帧才上传到 GPU。
## 截图工具与出图流程必须先调用本方法并等待若干帧，否则会拍到白色占位纹理。
func warm_up(texts: PackedStringArray = PackedStringArray()) -> void:
	var sample := "0123456789.±⌀R:×—"
	sample += "建筑平面图立面剖面详图一层二三层标准层屋顶"
	sample += "钢筋混凝土砖墙砂浆抹灰防水保温门窗楼梯卫生间厨房"
	sample += "独立基础条形基础地圈梁构造柱圈梁现浇板阳台女儿墙"
	sample += "长度宽度高度厚度标高轴线尺寸比例设计制图审核校对"
	sample += "M1 M2 C1 C2 类别编号洞口宽高数量备注材料做法说明"
	if texts.size() > 0:
		for t in texts:
			sample += t
	var sizes := PackedInt32Array([10, 12, 14, 16, 20, 24, 28, 32, 40, 56, 72, 96])
	for k in _files.keys():
		var f = _files[k]
		if f == null:
			continue
		for s in sizes:
			# 这两个调用会触发字形光栅化并生成图集
			f.get_string_size(sample, HORIZONTAL_ALIGNMENT_LEFT, -1, s)
	_warmed = true


func is_warmed() -> bool:
	return _warmed


## 把常用文字的排版尺寸量出来，供包围盒与拾取使用。
## 返回 { 文本 -> Vector2 }。
func measure(style: CadTextStyle, texts: PackedStringArray, height: float) -> Dictionary:
	var f := font_for(style)
	var out := {}
	for t in texts:
		out[t] = f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, int(maxf(height, 1.0)))
	return out


## 供界面使用：返回可用于下拉框的系统字体候选
static func available_system_fonts() -> Array:
	var out := []
	for pair in UI_FONT_CHOICES:
		var sys := find_system_font(String(pair[1]))
		out.append([String(pair[0]), String(pair[1]), sys != ""])
	return out
