class_name GbModular
extends RefCounted
## 建筑模数协调（GB/T 50002—2013）与常用尺寸预设。
##
## 模数的作用：把所有尺寸约束到一套协调的数列上，
## 这样构件之间才能互换、预制件才能通用。
## 制图时把尺寸吸附到模数序列上，能从源头避免"3600 配 3610"这类问题。
##
## 三套数列：
##   · 基本模数 M = 100mm
##   · 扩大模数（用于开间、进深、层高）3M/6M/12M/15M/30M/60M
##   · 分模数（用于缝隙、构造厚度）M/10、M/5、M/2

const M := 100.0

## 扩大模数
const EXPANDED := [300.0, 600.0, 1200.0, 1500.0, 3000.0, 6000.0]
## 分模数
const SUB := [10.0, 20.0, 50.0]

## 常用开间（住宅，mm）
const BAY_WIDTHS := [2700.0, 3000.0, 3300.0, 3600.0, 3900.0, 4200.0, 4500.0]
## 常用进深
const BAY_DEPTHS := [3900.0, 4200.0, 4500.0, 4800.0, 5100.0, 5400.0, 6000.0, 6600.0]
## 常用层高
const STOREY_HEIGHTS := [2700.0, 2800.0, 2900.0, 3000.0, 3300.0]
## 常用墙厚
const WALL_THICKNESSES := [60.0, 90.0, 120.0, 180.0, 190.0, 200.0, 240.0, 250.0, 300.0, 370.0]
## 常用门洞宽 / 窗洞宽
const DOOR_WIDTHS := [700.0, 800.0, 900.0, 1000.0, 1200.0, 1500.0, 1800.0]
const WINDOW_WIDTHS := [600.0, 900.0, 1200.0, 1500.0, 1800.0, 2100.0, 2400.0]
## 常用洞口高
const DOOR_HEIGHTS := [2000.0, 2100.0, 2400.0]
const WINDOW_HEIGHTS := [600.0, 900.0, 1200.0, 1500.0, 1800.0, 2100.0]


## 尺寸是否落在给定模数的整数倍上
static func is_module(value: float, module: float) -> bool:
	if module <= 0.0:
		return false
	return absf(value / module - roundf(value / module)) <= Tol.DIST


## 吸附到最近的模数倍数
static func snap_to_module(value: float, module: float) -> float:
	if module <= 0.0:
		return value
	return roundf(value / module) * module


## 从候选序列里取最接近的值
static func nearest_in(value: float, choices: Array) -> float:
	var best: float = float(choices[0])
	var bd := absf(value - best)
	for c in choices:
		var d := absf(value - float(c))
		if d < bd:
			bd = d
			best = float(c)
	return best


## 校验一批尺寸，返回不合模数的问题描述列表。
## 用于建筑工具的输入校验 —— 在源头提醒，比事后返工划算。
static func validate(value: float, label: String, module := M) -> String:
	if is_module(value, module):
		return ""
	return "%s %.0f 不是 %gmm 的整数倍（最近合规值 %.0f）" % [
		label, value, module, snap_to_module(value, module)]


## 一组常用尺寸校验，供轴距、墙厚、洞口宽等输入使用
static func validate_all(value: float, label: String, choices: Array) -> String:
	for c in choices:
		if absf(value - float(c)) <= Tol.DIST:
			return ""
	return "%s %.0f 不在常用尺寸序列中（最近 %.0f）" % [
		label, value, nearest_in(value, choices)]


## 按类型取常用尺寸序列
static func presets(kind: String) -> Array:
	match kind:
		"开间":
			return BAY_WIDTHS
		"进深":
			return BAY_DEPTHS
		"层高":
			return STOREY_HEIGHTS
		"墙厚":
			return WALL_THICKNESSES
		"门洞宽":
			return DOOR_WIDTHS
		"窗洞宽":
			return WINDOW_WIDTHS
		"门洞高":
			return DOOR_HEIGHTS
		"窗洞高":
			return WINDOW_HEIGHTS
	return []


## 供界面用的下拉项：[显示名, 值]
static func preset_items(kind: String) -> Array:
	var out := []
	for v in presets(kind):
		out.append(["%s %.0f" % [kind, float(v)], float(v)])
	return out


## 全部预设的分类名
static func kinds() -> Array[String]:
	return ["开间", "进深", "层高", "墙厚", "门洞宽", "窗洞宽", "门洞高", "窗洞高"] as Array[String]
