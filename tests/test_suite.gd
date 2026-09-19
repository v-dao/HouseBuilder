class_name TestSuite
extends RefCounted
## 测试套件基类。
##
## 拆分的理由：主入口 run_tests.gd 必须 extends SceneTree（Godot 的 --script 要求），
## 而 GDScript 没有多继承，所以断言工具放在本类里，主入口持有一个实例并转发；
## 各测试模块继承本类，由主入口调用 run() 后 merge() 结果。

var suite: String = ""
var pass_count: int = 0
var fail_count: int = 0
var failures: Array[String] = []


func ok(cond: bool, msg: String) -> void:
	if cond:
		pass_count += 1
	else:
		fail_count += 1
		failures.append("[%s] %s" % [suite, msg])


func close(a: float, b: float, msg: String, tol := 1.0e-6) -> void:
	# 注意：GDScript 的 % 格式化不支持 %e / %g
	ok(absf(a - b) <= tol, "%s  (期望 %.9f, 实际 %.9f, 差 %s)" % [msg, b, a, str(absf(a - b))])


func vclose(a: Vector2, b: Vector2, msg: String, tol := 1.0e-6) -> void:
	ok(a.distance_to(b) <= tol, "%s  (期望 (%.6f, %.6f), 实际 (%.6f, %.6f))" % [msg, b.x, b.y, a.x, a.y])


## 合并子套件的结果
func merge(other: TestSuite) -> void:
	pass_count += other.pass_count
	fail_count += other.fail_count
	for f in other.failures:
		failures.append(f)
