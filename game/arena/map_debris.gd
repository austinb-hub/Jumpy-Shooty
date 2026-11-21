class_name MapDebris
extends Node3D
## What comes off a wall that breaks, on a map that breaks fine (see MapDestruction):
## chunks that fly out, land and stay where they stop as rubble; small bits that scatter
## and are gone in a second; and dust.
##
## It is all for show, and each copy of the game makes its own: nothing here is sent, and
## nothing here can be stood on or stops a shot (chunks land on the level and no more).
## Where the pieces fly depends on what broke the wall: the shots and blasts this copy
## was told about just before (push_shot(), push_blast()). There are only so many of
## each, the oldest going first, and rubble lying on a floor that breaks falls again.
## Rubble that comes to rest on something that moves (a flying island) is drawn from
## that, so it goes where it goes.
##
## MapRoot makes one (`debris`) on a map with fine destruction.

const MAX_FLYING := 120     ## chunks in the air (simulated) at once
const MAX_RESTING := 160    ## chunks lying about at once, of each kind of wall
const BATCH_CHUNKS := 70    ## chunks one lot of breaks can make
const BATCH_BITS := 10      ## scatters of small bits one lot can make
const BATCH_PUFFS := 6      ## dust clouds one lot can make
const BATCH_SOUNDS := 3     ## crashes one lot can play
const PUSH_FOR := 0.7       ## seconds a shot or blast is remembered as what broke a wall
const REST_AFTER := 8.0     ## seconds: a chunk still moving after this stays where it is
const SEEN_TO := 90.0       ## metres: further off rubble is not drawn

## Rubble is made in a headless run too (tests; normally there is no one to see it).
static var headless_too := false

var root: MapRoot
var breaks: MapDestruction

var _flying: Array = []    # [{body: RigidBody3D, kind, size: Vector3, tint: Color, born: float}]
# What lies about, a lot for each kind on the map and on each mover: "kind#mover's body" ->
# {kind, frame: Node3D or null, mm: MultiMesh, xf: Array (Transform3D or null, in the
# frame), tint: Array, next: int}
var _resting := {}
var _pushes: Array = []    # [{at: Vector3, from: Vector3 (INF: a blast), time: float, power: float}]
var _tick := 0
var _materials := {}       # kind (and shade) -> the plain material its chunks are drawn with

static var _chunk: ArrayMesh
static var _puff: Texture2D


func setup(map: MapRoot, destruction: MapDestruction) -> void:
	root = map
	breaks = destruction
	name = "Debris"
	breaks.cells_changed.connect(_on_cells_changed)


## The debris of the map being played, or null.
static func current() -> MapDebris:
	var map := MapRoot.current
	return map.debris if map and is_instance_valid(map) and map.debris and is_instance_valid(map.debris) else null


## A round went from `from` to `to`: what it breaks flies on the way it was going.
func push_shot(from: Vector3, to: Vector3, power: float = 1.0) -> void:
	_push({"at": to, "from": from, "time": _now(), "power": power})


## Something blew up at `at` (`radius`: its splash): what it breaks flies away from it.
func push_blast(at: Vector3, radius: float) -> void:
	_push({"at": at, "from": Vector3.INF, "time": _now(), "power": radius})


func _push(p: Dictionary) -> void:
	_pushes.append(p)
	if _pushes.size() > 24:
		_pushes.pop_front()


## Seconds, by the game's own clock (a run slower or faster than real time keeps its timing).
func _now() -> float:
	return float(Engine.get_physics_frames()) / Engine.physics_ticks_per_second


## The way, and how fast, a piece at `at` is thrown by what was going on just now:
## Vector3.ZERO if nothing was (it just drops).
func _thrown(at: Vector3) -> Vector3:
	var now := _now()
	for i in range(_pushes.size() - 1, -1, -1):
		var p: Dictionary = _pushes[i]
		if now - p.time > PUSH_FOR:
			break
		if p.from == Vector3.INF:
			var d: float = at.distance_to(p.at)
			var reach: float = float(p.power) * 1.2 + 1.0
			if d < reach:
				return (at - p.at).normalized() * lerpf(9.0, 3.5, d / reach)
		else:
			var dir: Vector3 = (p.at - p.from).normalized()
			var along: float = (at - p.from).dot(dir)
			if along > 0.0 and (p.from + dir * along).distance_to(at) < 1.2:
				return dir * 4.0 * float(p.power)
	return Vector3.ZERO


# ---------------------------------------------------------------------------
# Breaks

## Cells of fine panels just broke (MapDestruction calls this, not for a killcam's
## replay): their crash, chunks, bits and dust.
func broke(cells: PackedInt32Array) -> void:
	if cells.is_empty():
		return
	_sounds(cells)
	if DisplayServer.get_name() == "headless" and not headless_too:
		return
	var per_cell := clampf(float(BATCH_CHUNKS) / cells.size(), 0.34, 2.0)
	var owed := 0.0
	var every := maxi(1, ceili(float(cells.size()) / BATCH_BITS))
	var puff_every := maxi(1, ceili(float(cells.size()) / BATCH_PUFFS))
	for n in cells.size():
		var c := cells[n]
		var panel: Dictionary = breaks.panels[breaks.cells[c].panel]
		var xf := breaks._panel_xf(panel)
		var box: AABB = breaks._local_box(panel, breaks.cells[c].ijk)
		var centre := xf * box.get_center()
		var thrown := _thrown(centre)
		var face: Vector3 = xf.basis[panel.thin].normalized()
		owed += per_cell
		while owed >= 1.0:
			owed -= 1.0
			var size := _chunk_size(panel, box)
			var inside := (box.size - size).max(Vector3.ZERO) * 0.5
			var at := xf * (box.get_center() + Vector3(randf_range(-inside.x, inside.x), randf_range(-inside.y, inside.y), randf_range(-inside.z, inside.z)))
			var v := thrown
			if v == Vector3.ZERO:   # (nothing known broke it: it tips out one side or the other)
				v = face * (1.0 if randf() < 0.5 else -1.0) * randf_range(0.6, 1.8)
			elif randf() < 0.25 and absf(thrown.normalized().dot(face)) > 0.5:
				v = v.bounce(face) * 0.45   # (some comes back off the face that was hit)
			v = v * randf_range(0.5, 1.15) + Vector3(randf_range(-1.2, 1.2), randf_range(0.2, 2.4), randf_range(-1.2, 1.2))
			_fly(panel.kind, panel.tint, size, Transform3D(Basis.from_euler(Vector3(randf() * TAU, randf() * TAU, randf() * TAU)), at), v,
				Vector3(randf_range(-7, 7), randf_range(-7, 7), randf_range(-7, 7)))
		if n % every == 0:
			_bits(panel, centre, thrown if thrown != Vector3.ZERO else face * (1.5 if randf() < 0.5 else -1.5))
		if n % puff_every == 0:
			dust(centre, panel.material, thrown)


## How big one chunk of a cell (`box`, in its panel's frame) is: lumps of blockwork and
## concrete, splinters of a board, flat torn pieces of sheet. Never bigger than the cell.
func _chunk_size(panel: Dictionary, box: AABB) -> Vector3:
	var thin: int = panel.thin
	var thick: float = box.size[thin]
	var size := Vector3.ZERO
	var long: int = panel.u if box.size[panel.u] >= box.size[panel.v] else panel.v
	if (panel.xf as Transform3D).basis[panel.u].normalized().abs().y > 0.7 and panel.material == "wood":
		long = panel.u   # (a board wall: the splinters stand the way the boards do)
	for a in 3:
		if a == thin:
			size[a] = clampf(thick * randf_range(0.6, 1.0), 0.03, 0.34)
		elif panel.material == "wood":
			size[a] = randf_range(0.28, 0.48) if a == long else randf_range(0.05, 0.12)
		elif thick < 0.15:
			size[a] = randf_range(0.14, 0.34)
		else:
			size[a] = randf_range(0.14, 0.3)
		size[a] = minf(size[a], box.size[a] * 0.95)
	return size


func _fly(kind: String, tint: Color, size: Vector3, xf: Transform3D, velocity: Vector3, spin: Vector3) -> void:
	if _flying.size() >= MAX_FLYING:
		var oldest: Dictionary = _flying[0]
		if _now() - oldest.born < 1.0:
			return   # (all of them only just thrown: no room for more)
		_land(0)
	var body := RigidBody3D.new()
	body.collision_layer = 0
	body.collision_mask = 1   # it lands on the level, and nothing lands on it
	body.mass = maxf(size.x * size.y * size.z * 1800.0, 0.2)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	var mesh := MeshInstance3D.new()
	mesh.mesh = chunk_mesh()
	mesh.scale = size
	var shade: float = [0.8, 0.9, 1.0][randi() % 3] if tint.a > 0.0 else 1.0   # (alpha 0: one that lay there already, shaded)
	tint = Color(tint.r * shade, tint.g * shade, tint.b * shade, 0.0)
	mesh.material_override = _material(kind, tint)
	body.add_child(mesh)
	add_child(body)
	body.global_transform = xf
	body.linear_velocity = velocity
	body.angular_velocity = spin
	if not WorldGravity.zones.is_empty():
		body.gravity_scale = WorldGravity.zone_at(xf.origin)   # (a map whose gravity differs by place: outside a tower in orbit rubble drifts)
	_flying.append({"body": body, "kind": kind, "size": size, "tint": tint, "born": _now()})


## Small bits: a scatter that is gone in a second (no bodies: they fall through things).
func _bits(panel: Dictionary, at: Vector3, thrown: Vector3) -> void:
	var p := CPUParticles3D.new()
	var bit := BoxMesh.new()
	var s := 0.09 if panel.material != "wood" else 0.05
	bit.size = Vector3(s, s * 0.7, s * (1.0 if panel.material != "wood" else 3.5))
	p.mesh = bit
	p.material_override = _material(panel.kind, Color.WHITE)
	p.amount = 7
	p.one_shot = true
	p.explosiveness = 1.0
	p.lifetime = 1.1
	p.direction = thrown.normalized()
	p.spread = 55.0
	p.initial_velocity_min = 1.5
	p.initial_velocity_max = 3.0 + thrown.length() * 0.6
	p.gravity = Vector3(0, -16.0, 0)
	p.scale_amount_min = 0.5
	p.scale_amount_max = 1.3
	var shrink := Curve.new()
	shrink.add_point(Vector2(0.0, 1.0))
	shrink.add_point(Vector2(0.7, 1.0))
	shrink.add_point(Vector2(1.0, 0.0))
	p.scale_amount_curve = shrink
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 0.15
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(p)
	p.global_position = at
	p.emitting = true
	get_tree().create_timer(1.6).timeout.connect(p.queue_free)


## Something solid blown to bits (a column storey): chunks out of `box` every way, and dust.
func burst(box: AABB, kind: String, mat: String) -> void:
	if DisplayServer.get_name() == "headless" and not headless_too:
		return
	for n in 14:
		var size := Vector3(randf_range(0.18, 0.4), randf_range(0.18, 0.4), randf_range(0.18, 0.4)).min(box.size * 0.6)
		var at := box.position + Vector3(randf(), randf(), randf()) * box.size
		var away := (at - box.get_center()) * Vector3(1, 0.3, 1)
		away = away.normalized() if away.length() > 0.01 else Vector3.RIGHT
		_fly(kind, Color.WHITE, size, Transform3D(Basis.from_euler(Vector3(randf() * TAU, randf() * TAU, randf() * TAU)), to_global(at)),
			away * randf_range(2.0, 6.0) + Vector3(0, randf_range(0.0, 2.5), 0), Vector3(randf_range(-6, 6), randf_range(-6, 6), randf_range(-6, 6)))
	for n in 4:
		dust(to_global(box.position + Vector3(randf(), randf(), randf()) * box.size), mat, Vector3.ZERO)


## Dust: a few soft clouds that drift the way the pieces went, spread and thin out.
func dust(at: Vector3, mat: String, thrown: Vector3) -> void:
	var p := CPUParticles3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(1.1, 1.1)
	p.mesh = quad
	p.material_override = _dust_material()
	p.amount = 5
	p.one_shot = true
	p.explosiveness = 0.85
	p.lifetime = 1.9
	p.direction = thrown.normalized() if thrown != Vector3.ZERO else Vector3.UP
	p.spread = 70.0
	p.initial_velocity_min = 0.3
	p.initial_velocity_max = 1.2 + thrown.length() * 0.25
	p.damping_min = 1.0
	p.damping_max = 2.0
	p.gravity = Vector3(0, 0.25, 0)
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 0.25
	p.angle_min = 0.0
	p.angle_max = 360.0
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.1
	var grow := Curve.new()
	grow.add_point(Vector2(0.0, 0.35))
	grow.add_point(Vector2(0.25, 0.9))
	grow.add_point(Vector2(1.0, 1.5))
	p.scale_amount_curve = grow
	var dust: Color = BlockMaterials.info(mat).dust
	var fade := Gradient.new()
	fade.set_color(0, Color(dust.r, dust.g, dust.b, minf(dust.a * 1.5, 0.7)))
	fade.set_color(1, Color(dust.r, dust.g, dust.b, 0.0))
	p.color_ramp = fade
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(p)
	p.global_position = at
	p.emitting = true
	get_tree().create_timer(2.4).timeout.connect(p.queue_free)


## The crash of a lot of breaks: a few of them, apart from each other, not one each.
func _sounds(cells: PackedInt32Array) -> void:
	var sound := get_node_or_null("/root/Sound")   # (not there in map-only tests)
	if sound == null:
		return
	var played: Array = []
	for c in cells:
		if played.size() >= BATCH_SOUNDS:
			return
		var at := breaks.cell_center(c)
		var apart := true
		for other: Vector3 in played:
			if other.distance_to(at) < 2.5:
				apart = false
		if not apart:
			continue
		played.append(at)
		var info := BlockMaterials.info(breaks.material_of(c))
		var p = sound.play_at(info.break, at, "body", -3.0 if cells.size() < 4 else 0.0, 0.08)
		if p:
			p.pitch_scale *= info.break_pitch * (1.25 if cells.size() < 4 else 1.0)   # (one small piece: a lighter crack)


# ---------------------------------------------------------------------------
# Landing, lying there, falling again

func _physics_process(_delta: float) -> void:
	_tick += 1
	if _tick % 12 != 0 or _flying.is_empty():
		return
	var now := _now()
	for i in range(_flying.size() - 1, -1, -1):
		var f: Dictionary = _flying[i]
		var body: RigidBody3D = f.body
		if not WorldGravity.zones.is_empty():
			body.gravity_scale = WorldGravity.zone_at(body.global_position)
		# (Away below the map, or still falling through the open after all this time: it is gone.)
		if body.global_position.y < -80.0 or (now - f.born > REST_AFTER and body.linear_velocity.y < -3.0):
			body.queue_free()
			_flying.remove_at(i)
		elif (body.sleeping and now - f.born > 0.5) or now - f.born > REST_AFTER:
			_land(i)


## Flying chunk `i` stops being simulated and is drawn where it is with the rest of
## the rubble of its kind (in place of the oldest, when there is no room).
func _land(i: int) -> void:
	var f: Dictionary = _flying[i]
	_flying.remove_at(i)
	var body: RigidBody3D = f.body
	var xf := Transform3D(body.global_transform.basis.orthonormalized() * Basis.from_scale(f.size), body.global_position)
	body.queue_free()
	var frame := _under(xf.origin, maxf(f.size.x, maxf(f.size.y, f.size.z)))
	var lot := _lot(f.kind, frame)
	xf = (frame if frame else self).global_transform.affine_inverse() * xf
	var slot: int = lot.next
	lot.next = (slot + 1) % MAX_RESTING
	lot.xf[slot] = xf
	lot.tint[slot] = f.tint
	var mm: MultiMesh = lot.mm
	mm.set_instance_transform(slot, xf)
	mm.set_instance_color(slot, Color(f.tint.r, f.tint.g, f.tint.b, 1.0))


## The mover's body a chunk `size` across at `at` has come to rest on, or null (it lies
## on the map, or on nothing).
func _under(at: Vector3, size: float) -> Node3D:
	if root.movers.is_empty() or not is_inside_tree():
		return null
	var hit := get_world_3d().direct_space_state.intersect_ray(
		PhysicsRayQueryParameters3D.create(at + Vector3.UP * 0.05, at + Vector3.DOWN * (size + 0.3), 1))
	return null if hit.is_empty() else BulletMarks.frame_of(hit.collider)


func _lot(kind: String, frame: Node3D = null) -> Dictionary:
	var key := "%s#%d" % [kind, frame.get_instance_id() if frame else 0]
	if _resting.has(key):
		return _resting[key]
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = chunk_mesh()
	mm.instance_count = MAX_RESTING
	for i in MAX_RESTING:
		mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO))
	mm.custom_aabb = AABB(Vector3.ONE * -600.0, Vector3.ONE * 1200.0)
	var node := MultiMeshInstance3D.new()
	node.name = "Rubble_" + kind
	node.multimesh = mm
	node.material_override = _material(kind, Color.WHITE)
	node.visibility_range_end = SEEN_TO
	node.visibility_range_end_margin = 10.0
	(frame if frame else self).add_child(node)
	var xfs := []
	xfs.resize(MAX_RESTING)
	var tints := []
	tints.resize(MAX_RESTING)
	_resting[key] = {"kind": kind, "frame": frame, "mm": mm, "xf": xfs, "tint": tints, "next": 0}
	return _resting[key]


## Walls or floors broke: rubble lying on or against them falls again.
func _on_cells_changed(cells: PackedInt32Array, stages: PackedByteArray) -> void:
	if _resting.is_empty():
		return
	var boxes: Array = []
	var all := AABB()
	for i in mini(cells.size(), stages.size()):
		if int(stages[i]) < MapDestruction.BROKEN or cells[i] < 0 or cells[i] >= breaks.cells.size():
			continue
		var box := breaks.cell_box(cells[i]).grow(0.25)
		box.size.y += 0.35   # (what lies on top of it)
		all = box if boxes.is_empty() else all.merge(box)
		boxes.append(box)
	if boxes.is_empty():
		return
	for key: String in _resting:
		var lot: Dictionary = _resting[key]
		var frame := lot.frame as Node3D
		if frame and not frame.is_visible_in_tree():
			continue   # (an island parked below the map)
		var placed := (frame if frame else self).global_transform
		for slot in MAX_RESTING:
			if lot.xf[slot] == null or not all.has_point(placed * (lot.xf[slot] as Transform3D).origin):
				continue
			var xf: Transform3D = placed * (lot.xf[slot] as Transform3D)
			for box: AABB in boxes:
				if box.has_point(xf.origin):
					var size := xf.basis.get_scale()
					lot.xf[slot] = null
					(lot.mm as MultiMesh).set_instance_transform(slot, Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO))
					_fly(lot.kind, lot.tint[slot], size, Transform3D(xf.basis.orthonormalized(), xf.origin), Vector3.ZERO, Vector3.ZERO)
					break


## Every chunk gone (a new round: the walls are whole again).
func clear() -> void:
	for f: Dictionary in _flying:
		(f.body as RigidBody3D).queue_free()
	_flying.clear()
	for key: String in _resting:
		_empty(_resting[key])


## Every chunk lying on `frame` (a mover's body) gone: it has been mended.
func clear_on(frame: Node3D) -> void:
	for key: String in _resting:
		if _resting[key].frame == frame:
			_empty(_resting[key])


func _empty(lot: Dictionary) -> void:
	for slot in MAX_RESTING:
		if lot.xf[slot] != null:
			lot.xf[slot] = null
			(lot.mm as MultiMesh).set_instance_transform(slot, Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO))


## What a chunk of `kind` is drawn with: the kind's colour, plain (a lump of blockwork
## has no courses of its own), shaded by `tint`.
func _material(kind: String, tint: Color) -> Material:
	var key := "%s %.2f %.2f %.2f" % [kind, tint.r, tint.g, tint.b]
	if not _materials.has(key):
		var m := StandardMaterial3D.new()
		var colour: Color = root.palette.colors.get(kind, Color(0.6, 0.6, 0.6)) if root.palette else Color(0.6, 0.6, 0.6)
		m.albedo_color = Color(colour.r * tint.r, colour.g * tint.g, colour.b * tint.b, 1.0)
		m.roughness = root.palette.roughness if root.palette else 0.9
		m.vertex_color_use_as_albedo = true
		_materials[key] = m
	return _materials[key]


## What a cloud of dust is drawn with (one for them all).
func _dust_material() -> Material:
	if not _materials.has("dust"):
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		m.albedo_texture = puff_texture()
		m.vertex_color_use_as_albedo = true
		m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		_materials["dust"] = m
	return _materials["dust"]


## One of everything this draws, under `stage` (see FxWarmup): a chunk in the air, the
## batch of chunks lying about, a scatter of bits and a cloud of dust. They are made the
## way the real ones are, so that what the graphics card builds for these serves those.
func warm(stage: Node3D) -> void:
	var plain := _material("", Color.WHITE)
	var chunk := MeshInstance3D.new()
	chunk.mesh = chunk_mesh()
	chunk.material_override = plain
	stage.add_child(chunk)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = chunk_mesh()
	mm.instance_count = 1
	mm.set_instance_transform(0, Transform3D.IDENTITY)
	mm.set_instance_color(0, Color.WHITE)
	var lying := MultiMeshInstance3D.new()
	lying.multimesh = mm
	lying.material_override = plain
	stage.add_child(lying)
	for dusty in 2:
		var p := CPUParticles3D.new()
		if dusty:
			var quad := QuadMesh.new()
			quad.size = Vector2.ONE * 0.002   # (a puff always faces the camera at its own size, whatever the stage's)
			p.mesh = quad
			p.material_override = _dust_material()
			p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var fade := Gradient.new()
			fade.set_color(0, Color(1, 1, 1, 0.5))
			fade.set_color(1, Color(1, 1, 1, 0.0))
			p.color_ramp = fade
		else:
			var bit := BoxMesh.new()
			bit.size = Vector3(0.09, 0.063, 0.09)
			p.mesh = bit
			p.material_override = plain
			p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		p.local_coords = true   # (they stay with the stage, and are as small as it is)
		p.amount = 2
		p.lifetime = 20.0
		p.explosiveness = 1.0
		p.preprocess = 1.0
		p.gravity = Vector3.ZERO
		p.initial_velocity_min = 0.0
		p.initial_velocity_max = 0.0
		stage.add_child(p)
		p.emitting = true


## How many chunks there are: [in the air, lying about] (tests).
func counts() -> Array:
	var lying := 0
	for key: String in _resting:
		for xf in _resting[key].xf:
			if xf != null:
				lying += 1
	return [_flying.size(), lying]


## How many chunks lie on `frame` (a mover's body) (tests).
func lying_on(frame: Node3D) -> int:
	var lying := 0
	for key: String in _resting:
		if _resting[key].frame == frame:
			for xf in _resting[key].xf:
				if xf != null:
					lying += 1
	return lying


# ---------------------------------------------------------------------------
# Shapes

## One chunk, a metre across: a box knocked out of square, scaled to each chunk's size.
## Its surface pattern is measured from the chunk, so it travels with it.
static func chunk_mesh() -> ArrayMesh:
	if _chunk:
		return _chunk
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var corners: Array = []
	for i in 8:
		var c := Vector3(-0.5 if i & 1 == 0 else 0.5, -0.5 if i & 2 == 0 else 0.5, -0.5 if i & 4 == 0 else 0.5)
		corners.append(c + Vector3(rng.randf_range(-0.16, 0.16), rng.randf_range(-0.16, 0.16), rng.randf_range(-0.16, 0.16)))
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var marks := PackedVector2Array()
	# (each face's corners, counter-clockwise seen from outside)
	for face: Array in [[0, 4, 6, 2], [1, 3, 7, 5], [0, 1, 5, 4], [2, 6, 7, 3], [0, 2, 3, 1], [4, 5, 7, 6]]:
		var a: Vector3 = corners[face[0]]
		var b: Vector3 = corners[face[1]]
		var c: Vector3 = corners[face[2]]
		var d: Vector3 = corners[face[3]]
		for tri: Array in [[a, c, b], [a, d, c]]:   # Godot's front faces are clockwise
			var n: Vector3 = ((tri[2] as Vector3) - tri[0]).cross((tri[1] as Vector3) - tri[0]).normalized()
			for v: Vector3 in tri:
				verts.append(v)
				normals.append(n)
				colors.append(Color.WHITE)
				marks.append(Vector2(1, 0))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV2] = marks
	_chunk = ArrayMesh.new()
	_chunk.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return _chunk


## A soft round cloud.
static func puff_texture() -> Texture2D:
	if _puff:
		return _puff
	var size := 64
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var noise := FastNoiseLite.new()
	noise.seed = 3
	noise.frequency = 0.07
	for y in size:
		for x in size:
			var p := (Vector2(x + 0.5, y + 0.5) / size - Vector2(0.5, 0.5)) * 2.0
			var r := p.length() + noise.get_noise_2d(x, y) * 0.25
			img.set_pixel(x, y, Color(1, 1, 1, smoothstep(1.0, 0.25, r) * smoothstep(0.98, 0.75, p.length())))   # (nothing at its edges: no square shows)
	_puff = ImageTexture.create_from_image(img)
	return _puff
