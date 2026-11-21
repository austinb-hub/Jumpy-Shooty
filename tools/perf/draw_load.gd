extends SceneTree
## How much a map asks the graphics card to draw: the triangles and draw calls in one
## frame (shadows included) from a few viewpoints. Run it through tools/perf/draw_load.sh
## (it needs a window, so that script gives it a hidden one):
##
##   tools/perf/draw_load.sh --map=empyrean
##
## --arena: as an arena match has it, with what breaks set up to break (a map with fine
## destruction is then drawn in more, smaller meshes).
##
## The numbers come from a software renderer, so they say how much work there is, not
## how fast a real card does it: use them to compare maps, or one map before and after.
var _map: MapRoot
var _cam: Camera3D
var _views := []
var _i := -1
var _wait := 0
var _sum := [0, 0]

static func at(r: float, deg: float, y: float) -> Vector3:
	return Vector3(r * sin(deg_to_rad(deg)), y, r * cos(deg_to_rad(deg)))

func _initialize() -> void:
	var id := "empyrean"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--map="):
			id = a.trim_prefix("--map=")
	_map = Maps.make(id)
	_map.destructible = "--arena" in OS.get_cmdline_user_args()
	root.add_child(_map)
	_map.build(true)
	_cam = Camera3D.new()
	_cam.near = 0.05
	_cam.far = 800.0
	_cam.fov = 90.0
	root.add_child(_cam)
	_cam.make_current()
	if id == "empyrean":
		_views = [["Library, across the room", at(12, 140, 32.2), at(24, 60, 36)], ["Engine, up the shaft", at(5.5, 200, 1.7), at(2, 20, 150)],
			["Summoning, at the altar", at(14, 30, 123.6), at(20, 100, 126)], ["a corridor", at(22.5, 195, 32.2), at(22.5, 250, 33)],
			["docking ring, along the wall", at(52, 112, 100), at(30, 62, 91)], ["far outside", at(150, 40, 90), at(0, 0, 95)]]
	else:
		_views = [["middle", Vector3(0, 3, 0), Vector3(20, 3, 20)], ["corner", Vector3(40, 12, 40), Vector3(0, 2, 0)]]

func _process(_d: float) -> bool:
	if _wait > 0:
		_wait -= 1
		if _wait == 0:
			var tris := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
			var calls := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
			print("DRAW %-30s %8d triangles  %5d draw calls" % [_views[_i][0], tris, calls])
			_sum[0] += tris
			_sum[1] += calls
		return false
	_i += 1
	if _i >= _views.size():
		print("DRAW %-30s %8d triangles  %5d draw calls" % ["average", _sum[0] / _views.size(), _sum[1] / _views.size()])
		return true
	_cam.look_at_from_position(_views[_i][1], _views[_i][2])
	_wait = 4
	return false
