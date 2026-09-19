import io

p = 'src/ui/cad_viewport.gd'
s = io.open(p, encoding='utf-8').read()

old = '''	renderer.ltscale = doc.ltscale
	renderer.clip_enabled = true
	renderer.clip_rect = screen_rect
	renderer.draw(doc, vp_view, self, [])
	renderer.clip_enabled = false'''
new = '''	renderer.ltscale = doc.ltscale
	renderer.clip_enabled = true
	renderer.clip_rect = screen_rect
	# 线宽要按**纸张缩放**换算，而不是固定常数：
	# 布局的意义就是所见即所得，1.0mm 的墙线在纸上必须真的是 1.0mm。
	# view.zoom 此时正是「图纸毫米 -> 像素」，直接拿它当 px_per_mm。
	var saved_px := renderer.px_per_mm
	renderer.px_per_mm = view.zoom
	renderer.draw(doc, vp_view, self, [])
	renderer.px_per_mm = saved_px
	renderer.clip_enabled = false'''
assert old in s, 'paper view anchor missing'
s = s.replace(old, new)
io.open(p, 'w', encoding='utf-8').write(s)
print('cad_viewport: 视口内的线宽已按纸张缩放换算')
