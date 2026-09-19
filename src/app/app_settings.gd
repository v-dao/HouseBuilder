class_name AppSettings
extends RefCounted
## 用户偏好持久化。
##
## 存在 user:// 下的 ConfigFile（Windows 上即 %APPDATA%\Godot\app_userdata\<项目名>\）。
## 只存"用户的习惯"，不存图纸内容 —— 图纸内容归 .hbd 文件。
##
## 设计原则：
##   · 每个键都有合理默认值，缺键不报错 —— 首次运行、旧版本升级都能正常启动
##   · 读取时做范围校验，手工改坏的配置文件不会让程序进入异常状态

const PATH := "user://settings.cfg"

# --- 视图 ---
var show_grid := true
var show_crosshair := true
var show_lineweight := false
var show_axes := true
var bg_color := Color(0.075, 0.082, 0.098)

# --- 捕捉 ---
var osnap_enabled := true
var osnap_mask := -1          ## -1 表示用捕捉引擎的默认值
var ortho := false
var grid_snap := false
var grid_step := 100.0
var polar_enabled := false
var polar_step_deg := 15.0
var aperture_px := 12.0

# --- 出图 ---
var plot_scale := 100.0
var paper_format := "A3"
var paper_portrait := false
var ltscale := 20.0
var font_path := ""           ## 为空表示自动查找系统仿宋

# --- 窗口 ---
var window_size := Vector2i(1600, 900)
var window_maximized := true

# --- 最近文件 ---
var recent_files: Array[String] = []


## 从磁盘读取。文件不存在时保持默认值并返回 false。
func load_from_disk() -> bool:
	var cf := ConfigFile.new()
	if cf.load(PATH) != OK:
		return false
	show_grid = bool(cf.get_value("view", "show_grid", show_grid))
	show_crosshair = bool(cf.get_value("view", "show_crosshair", show_crosshair))
	show_lineweight = bool(cf.get_value("view", "show_lineweight", show_lineweight))
	show_axes = bool(cf.get_value("view", "show_axes", show_axes))
	var bg := String(cf.get_value("view", "bg_color", bg_color.to_html(false)))
	bg_color = Color.html(bg)

	osnap_enabled = bool(cf.get_value("snap", "osnap_enabled", osnap_enabled))
	osnap_mask = int(cf.get_value("snap", "osnap_mask", osnap_mask))
	ortho = bool(cf.get_value("snap", "ortho", ortho))
	grid_snap = bool(cf.get_value("snap", "grid_snap", grid_snap))
	grid_step = _clampf(cf.get_value("snap", "grid_step", grid_step), 0.001, 100000.0)
	polar_enabled = bool(cf.get_value("snap", "polar_enabled", polar_enabled))
	polar_step_deg = _clampf(cf.get_value("snap", "polar_step_deg", polar_step_deg), 1.0, 90.0)
	aperture_px = _clampf(cf.get_value("snap", "aperture_px", aperture_px), 2.0, 40.0)

	plot_scale = _clampf(cf.get_value("plot", "plot_scale", plot_scale), 1.0, 10000.0)
	paper_format = String(cf.get_value("plot", "paper_format", paper_format))
	paper_portrait = bool(cf.get_value("plot", "paper_portrait", paper_portrait))
	ltscale = _clampf(cf.get_value("plot", "ltscale", ltscale), 0.01, 1000.0)
	font_path = String(cf.get_value("plot", "font_path", font_path))

	var ws = cf.get_value("window", "size", [window_size.x, window_size.y])
	if ws is Array and (ws as Array).size() >= 2:
		window_size = Vector2i(maxi(int((ws as Array)[0]), 640), maxi(int((ws as Array)[1]), 480))
	window_maximized = bool(cf.get_value("window", "maximized", window_maximized))

	var rf = cf.get_value("files", "recent", [])
	if rf is Array:
		recent_files.clear()
		for r in (rf as Array):
			recent_files.append(String(r))
	return true


## 写入磁盘。返回是否成功。
func save_to_disk() -> bool:
	var cf := ConfigFile.new()
	cf.set_value("view", "show_grid", show_grid)
	cf.set_value("view", "show_crosshair", show_crosshair)
	cf.set_value("view", "show_lineweight", show_lineweight)
	cf.set_value("view", "show_axes", show_axes)
	cf.set_value("view", "bg_color", bg_color.to_html(false))
	cf.set_value("snap", "osnap_enabled", osnap_enabled)
	cf.set_value("snap", "osnap_mask", osnap_mask)
	cf.set_value("snap", "ortho", ortho)
	cf.set_value("snap", "grid_snap", grid_snap)
	cf.set_value("snap", "grid_step", grid_step)
	cf.set_value("snap", "polar_enabled", polar_enabled)
	cf.set_value("snap", "polar_step_deg", polar_step_deg)
	cf.set_value("snap", "aperture_px", aperture_px)
	cf.set_value("plot", "plot_scale", plot_scale)
	cf.set_value("plot", "paper_format", paper_format)
	cf.set_value("plot", "paper_portrait", paper_portrait)
	cf.set_value("plot", "ltscale", ltscale)
	cf.set_value("plot", "font_path", font_path)
	cf.set_value("window", "size", [window_size.x, window_size.y])
	cf.set_value("window", "maximized", window_maximized)
	cf.set_value("files", "recent", recent_files)
	return cf.save(PATH) == OK


## 记录最近打开的文件，最多 10 条，重复的提到最前
func push_recent(path: String) -> void:
	if path == "":
		return
	recent_files.erase(path)
	recent_files.push_front(path)
	while recent_files.size() > 10:
		recent_files.remove_at(recent_files.size() - 1)


static func _clampf(v, lo: float, hi: float) -> float:
	var f := 0.0
	if v is float or v is int:
		f = float(v)
	else:
		f = String(v).to_float()
	if is_nan(f):
		f = lo
	return clampf(f, lo, hi)
