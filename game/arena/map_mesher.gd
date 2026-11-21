class_name MapMesher
extends RefCounted
## Turns a map's pieces into meshes: one mesh per kind (material), with every piece
## of that kind merged into it, so a map of a few thousand pieces draws in a handful
## of calls. Faces are flat-shaded; a piece's tint goes into the vertex colours.
##
## `shade` darkens faces by the way they point, baked into the vertex colours:
## (faces looking along x, faces looking along z, faces looking down); tops stay
## at 1. It gives plain boxes some form even in flat light. Vector3.ONE = off.
## `shade_basis` turns the normals before shading: the editor builds each block's
## mesh in the block's own frame, but shades it by the way its faces point in the map.

static var _shade := Vector3.ONE
static var _shade_basis := Basis()

const BOX_FACES := [   # normal, then the two in-plane axes (u, v) with u x v = normal
	[Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0)],
	[Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0)],
	[Vector3(0, 1, 0), Vector3(1, 0, 0), Vector3(0, 0, -1)],
	[Vector3(0, -1, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)],
	[Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0)],
	[Vector3(0, 0, -1), Vector3(-1, 0, 0), Vector3(0, 1, 0)],
]


## kind -> ArrayMesh
static func build(pieces: Array, shade: Vector3 = Vector3.ONE, shade_basis: Basis = Basis()) -> Dictionary:
	var result := {}
	var by_kind := build_arrays(pieces, shade, shade_basis)
	for kind in by_kind:
		var arrays: Array = by_kind[kind]
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, surface_flags(arrays))
		result[kind] = mesh
	return result


## kind -> the arrays for a mesh surface (Mesh.ARRAY_MAX long: corners, normals,
## colours, and CUSTOM0 when a face's pattern is moved), as build() would put in its
## mesh. Nothing is handed to the GPU: the editor keeps every block's arrays and
## draws them merged (MapRoot's editor drawing), since a GPU mesh for each of a big
## map's thousands of blocks runs some graphics drivers out of buffers.
static func build_arrays(pieces: Array, shade: Vector3 = Vector3.ONE, shade_basis: Basis = Basis()) -> Dictionary:
	var by_kind := {}
	add_to(by_kind, pieces, shade, shade_basis)
	var result := {}
	for kind in by_kind:
		result[kind] = surface_arrays(by_kind[kind])
	return result


## Draws `pieces` into the buffers in `by_kind` (kind -> buffer, see _buffer; {} to
## begin with), adding to what is there: a build done a few pieces at a time
## (MapCollapse draws a bay's loose things over several frames). meshes() makes the
## meshes of it.
static func add_to(by_kind: Dictionary, pieces: Array, shade: Vector3 = Vector3.ONE, shade_basis: Basis = Basis()) -> void:
	_shade = shade
	_shade_basis = shade_basis
	_by_kind = by_kind
	for piece in pieces:
		if piece.get("hidden", false):
			continue
		_face_kinds = piece.get("face_kinds", {})
		_face_patterns = piece.get("face_patterns", {})
		_key_scale = piece.get("scale", Vector3.ONE)
		_custom = Vector4.ZERO
		var buf := _buffer(piece.kind)
		match piece.shape:
			"cyl", "tube" when piece.has("arc"): _hulls(buf, piece)   # a slice: its sector's lumps
			"cyl": _prism(buf, piece, 0.0)
			"tube": _prism(buf, piece, piece.get("inner", 0.0))
			"cone": _cone(buf, piece)
			"wedge", "bevel", "dome", "arch", "hull", "spiral", "stairs": _hulls(buf, piece)
			_: _box(buf, piece)
	_by_kind = {}
	_face_kinds = {}
	_face_patterns = {}
	_custom = Vector4.ZERO


## kind -> a mesh, from the buffers add_to() filled.
static func meshes(by_kind: Dictionary) -> Dictionary:
	var result := {}
	for kind in by_kind:
		var arrays := surface_arrays(by_kind[kind])
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, surface_flags(arrays))
		result[kind] = mesh
	return result


## The arrays for a mesh surface (Mesh.ARRAY_MAX long) from a buffer: [corners, normals,
## colours] and, if any face in it has a pattern moved, its settings (see _buffer).
static func surface_arrays(buf: Array) -> Array:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = buf[0]
	arrays[Mesh.ARRAY_NORMAL] = buf[1]
	arrays[Mesh.ARRAY_COLOR] = buf[2]
	if buf.size() > 3 and buf[3] != null:
		arrays[Mesh.ARRAY_CUSTOM0] = buf[3]
	return arrays


## A buffer for one kind's faces drawn outside build() (see face_buffer).
static func new_buffer() -> Array:
	return [PackedVector3Array(), PackedVector3Array(), PackedColorArray(), null]


## Outside build() (MapDestruction drawing the ragged cells round a hole, face by face):
## the buffer in `by_kind` (kind -> new_buffer()) that the face of `piece` looking along
## `normal` (in the piece's own frame) goes in: its painted kind's (MapBlock.face_kinds)
## if it has one, else `kind`'s. What is drawn into it next carries that face's pattern
## (face_patterns). Pass {} for `piece` to draw a face of nothing painted.
static func face_buffer(by_kind: Dictionary, piece: Dictionary, kind: String, normal: Vector3) -> Array:
	_by_kind = by_kind
	_face_kinds = piece.get("face_kinds", {})
	_face_patterns = piece.get("face_patterns", {})
	_key_scale = piece.get("scale", Vector3.ONE)
	var buf := _route(_buffer(kind), normal)
	_by_kind = {}
	_face_kinds = {}
	_face_patterns = {}
	return buf


## Where the surface shader measures the pattern from for a corner at `pos` on a face
## looking along `normal`, with that face's pattern settings `custom` (what _route puts
## in CUSTOM0): map_surface.gdshader's vertex() does the same. For a mesh that keeps
## where its corners were in CUSTOM0 instead (MapCollapse's piles), worked out ahead.
static func pattern_place(pos: Vector3, normal: Vector3, custom: Vector4) -> Vector3:
	if custom == Vector4.ZERO:
		return pos
	var n := normal.normalized()
	var u := (Vector3.UP.cross(n) if absf(n.y) < 0.9 else Vector3.RIGHT.cross(n)).normalized()
	var v := n.cross(u)
	var grow := maxf(1.0 + custom.w, 0.01)
	var across := Vector2(pos.dot(u), pos.dot(v))
	var ct := cos(custom.z)
	var st := sin(custom.z)
	across = Vector2(across.x * ct - across.y * st, across.x * st + across.y * ct) / grow + Vector2(custom.x, custom.y)
	return u * across.x + v * across.y + n * pos.dot(n)


## The flags a surface made from `arrays` needs: a face pattern's settings (CUSTOM0)
## are four 32-bit numbers a corner.
static func surface_flags(arrays: Array) -> int:
	if arrays.size() > Mesh.ARRAY_CUSTOM0 and arrays[Mesh.ARRAY_CUSTOM0] != null:
		return Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
	return 0


# ---------------------------------------------------------------------------
# Faces of their own (MapBlock.face_kinds, face_patterns)

static var _by_kind := {}          # kind -> buffer, for the build going on
static var _face_kinds := {}       # the piece being built: face -> kind
static var _face_patterns := {}    # face -> Vector4(across, up, turn (degrees), scale)
static var _custom := Vector4.ZERO # what the face being drawn tells the surface shader
static var _key_scale := Vector3.ONE # the block's stretch (piece "scale"): faces are named unstretched


## The buffer for a kind: [corners, normals, colours, pattern settings (or null while
## no face in it has any)].
static func _buffer(kind: String) -> Array:
	if not _by_kind.has(kind):
		_by_kind[kind] = [PackedVector3Array(), PackedVector3Array(), PackedColorArray(), null]
	return _by_kind[kind]


## Where the face of the piece being built that looks along `normal` (in its own
## frame) goes: its own kind's buffer if it has one, else `buf`. Also sets what its
## corners tell the surface shader about its pattern: (across, up, turn in radians,
## scale - 1), all nothing for a face left as it is.
static func _route(buf: Array, normal: Vector3) -> Array:
	if _face_kinds.is_empty() and _face_patterns.is_empty():
		_custom = Vector4.ZERO
		return buf
	# (A face's way out in the stretched piece leans back toward the block's own: the
	# block names its faces unstretched, as the Paint tool sees them.)
	var key := MapBlock.face_key(normal * _key_scale)
	var p: Vector4 = _face_patterns.get(key, Vector4(0, 0, 0, 1))
	_custom = Vector4(p.x, p.y, deg_to_rad(p.z), p.w - 1.0)
	var kind: String = _face_kinds.get(key, "")
	return buf if kind == "" else _buffer(kind)


## Adds the pattern settings for the last `count` corners put in `buf`. A buffer gets
## them only once a face needs them (the corners before get nothing: as they are).
static func _put_custom(buf: Array, count: int) -> void:
	if buf.size() < 4:
		return   # (a buffer of three made by hand, outside build(): no face in it has a pattern)
	if buf[3] == null:
		if _custom == Vector4.ZERO:
			return
		var none := PackedFloat32Array()
		none.resize(((buf[0] as PackedVector3Array).size() - count) * 4)
		buf[3] = none
	var custom: PackedFloat32Array = buf[3]
	for i in count:
		custom.append(_custom.x)
		custom.append(_custom.y)
		custom.append(_custom.z)
		custom.append(_custom.w)
	buf[3] = custom


## Blanks `count` corners of a mesh from `first` on, in place: they are all put at one
## point, so the faces they made are no longer drawn. For something drawn as part of a
## big mesh that is gone now (a thing fallen with its floor, a panel with its first
## hole in it): the big mesh need not be made again, which is slow. (A surface's
## corners come first in its vertex data, three 32-bit numbers each.)
static func blank(mesh: ArrayMesh, first: int, count: int) -> void:
	var none := PackedByteArray()
	none.resize(count * 12)
	mesh.surface_update_vertex_region(0, first * 12, none)


## The same mesh, marked as part of something that moves (a MapMover's body): its
## second UV says "measure my pattern from my own frame, not the map's", which the
## surface shader reads (map_surface.gdshader). A pattern measured from the map stays
## where it is while the block moves through it, and that shimmers.
static func riding(mesh: ArrayMesh) -> ArrayMesh:
	var arrays := mesh.surface_get_arrays(0)
	var mark := PackedVector2Array()
	mark.resize((arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size())
	mark.fill(Vector2(1, 0))
	arrays[Mesh.ARRAY_TEX_UV2] = mark
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, surface_flags(arrays))
	return out


static func _quad(buf: Array, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3, color: Color) -> void:
	# a, b, c, d go counter-clockwise seen from the front (the side `n` points to).
	var verts: PackedVector3Array = buf[0]
	var normals: PackedVector3Array = buf[1]
	var colors: PackedColorArray = buf[2]
	color = _shaded(color, n)
	for v in [a, c, b, a, d, c]:   # Godot's front faces are clockwise
		verts.append(v)
		normals.append(n)
		colors.append(color)
	_put_custom(buf, 6)


static func _box(buf: Array, piece: Dictionary) -> void:
	var xf: Transform3D = piece.xf
	var h: Vector3 = piece.size * 0.5
	var color: Color = piece.get("tint", Color.WHITE)
	for face in BOX_FACES:
		var n: Vector3 = face[0]
		var u: Vector3 = face[1]
		var v: Vector3 = face[2]
		var c: Vector3 = n * h
		var du: Vector3 = u * h
		var dv: Vector3 = v * h
		_quad(_route(buf, n), xf * (c - du - dv), xf * (c + du - dv), xf * (c + du + dv), xf * (c - du + dv), xf.basis * n, color)


## A cylinder with flat sides (inner = 0), or a pipe you can see through (inner > 0).
static func _prism(buf: Array, piece: Dictionary, inner: float) -> void:
	var xf: Transform3D = piece.xf
	var color: Color = piece.get("tint", Color.WHITE)
	var sides: int = piece.get("sides", 12)
	var r: float = piece.size.x * 0.5
	var ri: float = inner * 0.5
	var hy: float = piece.size.y * 0.5
	for i in sides:
		var a0 := TAU * i / sides
		var a1 := TAU * (i + 1) / sides
		var am := (a0 + a1) * 0.5
		var d0 := Vector3(cos(a0), 0, sin(a0))
		var d1 := Vector3(cos(a1), 0, sin(a1))
		var n := Vector3(cos(am), 0, sin(am))
		var up := Vector3(0, hy, 0)
		# outside wall
		_quad(_route(buf, n), xf * (d1 * r - up), xf * (d0 * r - up), xf * (d0 * r + up), xf * (d1 * r + up), xf.basis * n, color)
		if ri > 0.0:
			_quad(_route(buf, -n), xf * (d0 * ri - up), xf * (d1 * ri - up), xf * (d1 * ri + up), xf * (d0 * ri + up), xf.basis * -n, color)
			_quad(_route(buf, Vector3.UP), xf * (d0 * ri + up), xf * (d1 * ri + up), xf * (d1 * r + up), xf * (d0 * r + up), xf.basis * Vector3.UP, color)
			_quad(_route(buf, Vector3.DOWN), xf * (d1 * ri - up), xf * (d0 * ri - up), xf * (d0 * r - up), xf * (d1 * r - up), xf.basis * Vector3.DOWN, color)
		else:
			_tri(_route(buf, Vector3.UP), xf * up, xf * (d1 * r + up), xf * (d0 * r + up), xf.basis * Vector3.UP, color)
			_tri(_route(buf, Vector3.DOWN), xf * -up, xf * (d0 * r - up), xf * (d1 * r - up), xf.basis * Vector3.DOWN, color)


## A cone with flat sides, coming to a point (top = 0) or cut off flat at the top.
## Its corners: cone_points() (the collision shape is built from the same points).
static func _cone(buf: Array, piece: Dictionary) -> void:
	var xf: Transform3D = piece.xf
	var color: Color = piece.get("tint", Color.WHITE)
	var sides: int = piece.get("sides", 12)
	var r: float = piece.size.x * 0.5
	var rt: float = minf(piece.get("top", 0.0) * 0.5, r)
	var up := Vector3(0, piece.size.y * 0.5, 0)
	for i in sides:
		var d0 := Vector3(cos(TAU * i / sides), 0, sin(TAU * i / sides))
		var d1 := Vector3(cos(TAU * (i + 1) / sides), 0, sin(TAU * (i + 1) / sides))
		var b0 := d0 * r - up
		var b1 := d1 * r - up
		var n := cone_side_normal(d0, d1, r, rt, piece.size.y)
		if rt > 0.0:
			_quad(_route(buf, n), xf * b1, xf * b0, xf * (d0 * rt + up), xf * (d1 * rt + up), xf.basis * n, color)
			_tri(_route(buf, Vector3.UP), xf * up, xf * (d1 * rt + up), xf * (d0 * rt + up), xf.basis * Vector3.UP, color)
		else:
			_tri(_route(buf, n), xf * b1, xf * b0, xf * up, xf.basis * n, color)
		_tri(_route(buf, Vector3.DOWN), xf * -up, xf * b0, xf * b1, xf.basis * Vector3.DOWN, color)


## The outward normal of the cone's side between the corners `d0` and `d1` (unit
## directions round its axis), for a foot radius `r`, top radius `rt` and `height`.
static func cone_side_normal(d0: Vector3, d1: Vector3, r: float, rt: float, height: float) -> Vector3:
	var mid := (d0 + d1) * 0.5           # the middle of that side, at radius 1 (flat part)
	var flat := mid.length()
	return (mid / flat * height + Vector3.UP * (r - rt) * flat).normalized()


## A cone's corners in its own frame: the foot's ring, then the top's ring (or the tip).
static func cone_points(piece: Dictionary) -> PackedVector3Array:
	var sides: int = piece.get("sides", 12)
	var r: float = piece.size.x * 0.5
	var rt: float = minf(piece.get("top", 0.0) * 0.5, r)
	var hy: float = piece.size.y * 0.5
	var pts := PackedVector3Array()
	for i in sides:
		pts.append(Vector3(cos(TAU * i / sides) * r, -hy, sin(TAU * i / sides) * r))
	if rt > 0.0:
		for i in sides:
			pts.append(Vector3(cos(TAU * i / sides) * rt, hy, sin(TAU * i / sides) * rt))
	else:
		pts.append(Vector3(0, hy, 0))
	return pts


## What a tube is to bump into: its wall, one convex lump per flat side (the four
## corners of that side's stretch of ring, at the top and at the foot), in its own
## frame. The corners are where _prism draws them: corner i at TAU * i / sides round
## from +x toward +z, outside at the diameter (x) and inside at Inner. A tube with no
## hole (Inner 0 or less) has no wall to give: it is drawn as a cylinder and is bumped
## into as one, so this gives nothing for it. A hole as wide as the tube or wider
## leaves the thinnest wall a hollow dome is allowed (1 cm), at the outside diameter,
## so what you see from outside is never something you walk through.
static func tube_hulls(piece: Dictionary) -> Array:
	var inner: float = piece.get("inner", 0.0)
	if inner <= 0.0:
		return []
	var sides: int = piece.get("sides", 12)
	var r: float = piece.size.x * 0.5
	var ri: float = maxf(minf(inner * 0.5, r - 0.01), 0.0)
	var hy: float = piece.size.y * 0.5
	var hulls := []
	for i in sides:
		var d0 := Vector3(cos(TAU * i / sides), 0, sin(TAU * i / sides))
		var d1 := Vector3(cos(TAU * (i + 1) / sides), 0, sin(TAU * (i + 1) / sides))
		var lump := PackedVector3Array()
		for reach in [ri, r]:
			for y in [-hy, hy]:
				lump.append(d0 * reach + Vector3(0, y, 0))
				lump.append(d1 * reach + Vector3(0, y, 0))
		hulls.append(lump)
	return hulls


# ---------------------------------------------------------------------------
# Wedges, bevelled boxes, domes and arches. Each is one or more convex lumps, given
# by their corners (hull_points); what you see and what you bump into are both made
# from those same corners, so they always agree.

## The convex lumps a piece is made of, each a list of corners in the piece's own
## frame. A wedge, a bevelled box, a whole solid dome and a hull are one lump; a
## hollow or cut-open dome, an arch, a slice of a cylinder or tube and a spiral are
## several. It is what the piece is bumped into as; draw_points is what is drawn.
static func hull_points(piece: Dictionary) -> Array:
	match piece.shape:
		"wedge": return [wedge_points(piece)]
		"bevel": return [bevel_points(piece)]
		"dome": return dome_hulls(piece)
		"arch": return arch_hulls(piece)
		"hull": return [piece.points]
		"cyl", "tube": return sector_hulls(piece) if piece.has("arc") else []
		"spiral", "stairs":
			if int(piece.get("steps", 0)) > 0 and not piece.get("smooth", true):
				return climb_steps(piece)   # (not smooth: its steps are what you bump into)
			return climb_walk(piece)
	return []


## The convex lumps a piece is drawn as: its hull_points, except a spiral or stairs with
## steps, drawn as its steps (over the smooth ramp it is walked on, when Smooth).
static func draw_points(piece: Dictionary) -> Array:
	if piece.shape in ["spiral", "stairs"] and int(piece.get("steps", 0)) > 0:
		return climb_steps(piece)
	return hull_points(piece)


# ---------------------------------------------------------------------------
# Slices of a cylinder or tube (an Arc under 360), and spirals. Their angle runs as a
# dome's does: the open slice faces +z.

## The angle (round from +x toward +z) a fraction `t` of the way across a piece's arc.
static func arc_angle(piece: Dictionary, t: float) -> float:
	var arc: float = deg_to_rad(piece.get("arc", 360.0))
	return PI * 0.5 + (TAU - arc) * 0.5 + arc * t


static func _round_at(piece: Dictionary, t: float, reach: float, y: float) -> Vector3:
	var a := arc_angle(piece, t)
	return Vector3(cos(a) * reach, y, sin(a) * reach)


## A slice of a cylinder (pie pieces, each no wider than half a turn) or of a tube (one
## lump per flat side, as tube_hulls): what an Arc under 360 leaves.
static func sector_hulls(piece: Dictionary) -> Array:
	var sides: int = maxi(int(piece.get("sides", 12)), 1)
	var r: float = piece.size.x * 0.5
	var hy: float = piece.size.y * 0.5
	var ri: float = 0.0
	if piece.shape == "tube":
		ri = maxf(minf(float(piece.get("inner", 0.0)) * 0.5, r - 0.01), 0.0)
	var hulls := []
	if ri > 0.0:
		for i in sides:
			var lump := PackedVector3Array()
			for t in [float(i) / sides, float(i + 1) / sides]:
				for reach in [ri, r]:
					for y in [-hy, hy]:
						lump.append(_round_at(piece, t, reach, y))
			hulls.append(lump)
		return hulls
	# A pie piece is convex short of half a turn round (at half a turn its flat side runs
	# right across, and would not meet its neighbour's); at most 14 sides each (32 corners).
	var arc: float = piece.get("arc", 360.0)
	var per := clampi(ceili(sides * 180.0 / arc) - 1, 1, 14)
	var i := 0
	while i < sides:
		var j := mini(i + per, sides)
		var lump := PackedVector3Array([Vector3(0, -hy, 0), Vector3(0, hy, 0)])
		for k in range(i, j + 1):
			for y in [-hy, hy]:
				lump.append(_round_at(piece, float(k) / sides, r, y))
		hulls.append(lump)
		i = j
	return hulls


# ---------------------------------------------------------------------------
# Spirals and straight stairs: a surface you walk that climbs from one end to the other
# (a fraction f of the way, 0 at the low end), drawn as a ramp or as steps. With Steps,
# laid out as a Stairs piece lays them: the first of steps + 1 equal stretches is the way
# on (at floor level, nothing drawn), then the steps, each a riser higher, the last level
# with the top; the walked ramp lies on their front edges and runs level over the last.

## A climb's numbers: [half its height, how far its walked surface rises, where that
## surface starts (y), what holds it ("solid", "slab", "treads"), how thick the slab or a
## tread is, how many steps (0 = a ramp)].
static func _climb(piece: Dictionary) -> Array:
	var hy: float = piece.size.y * 0.5
	var style: String = piece.get("step_style", "solid")
	var held: float = 0.0 if style == "solid" else clampf(float(piece.get("thickness", 0.3)), 0.02, piece.size.y)
	return [hy, piece.size.y - held, -hy + held, style, held, maxi(int(piece.get("steps", 0)), 0)]


## The angle a fraction `f` of the way up a spiral.
static func spiral_angle(piece: Dictionary, f: float) -> float:
	return arc_angle(piece, f if piece.get("clockwise", false) else 1.0 - f)


## The height of a spiral's or stairs' walked surface a fraction `f` of the way up.
static func climb_height(piece: Dictionary, f: float) -> float:
	var c := _climb(piece)
	var n: int = c[5]
	var t := f if n == 0 else minf(f * (n + 1) / n, 1.0)
	return c[2] + c[1] * t


## Step `k` (1 to Steps) of a spiral or stairs: [its tread's height, the fraction of the
## way up where it starts, where it ends].
static func climb_step(piece: Dictionary, k: int) -> Array:
	var c := _climb(piece)
	var n: int = maxi(c[5], 1)
	return [c[2] + c[1] * k / n, float(k) / (n + 1), float(k + 1) / (n + 1)]


## Where a corner of a climb is: a fraction `f` of the way up, on its inside or left edge
## (`side` 0) or its outside or right edge (1), at height `y`.
static func _climb_at(piece: Dictionary, f: float, side: int, y: float) -> Vector3:
	if piece.shape == "stairs":
		var half: Vector3 = piece.size * 0.5
		return Vector3(half.x * (side * 2 - 1), y, half.z - piece.size.z * f)
	var r: float = piece.size.x * 0.5
	var reach := r if side == 1 else clampf(float(piece.get("inner", 0.0)) * 0.5, 0.0, r - 0.05)
	var a := spiral_angle(piece, f)
	return Vector3(cos(a) * reach, y, sin(a) * reach)


## A lump of a climb between fractions f0 and f1 of the way up: its walked surface (or a
## step's tread) from `top0` to `top1`, its underside from `low0` to `low1`.
static func _climb_lump(piece: Dictionary, f0: float, f1: float, top0: float, top1: float, low0: float, low1: float) -> PackedVector3Array:
	var lump := PackedVector3Array()
	for end in [[f0, top0, low0], [f1, top1, low1]]:
		for side in 2:
			for y: float in [end[1], end[2]]:
				var p := _climb_at(piece, end[0], side, y)
				if not lump.has(p):
					lump.append(p)   # (a spiral with no Inner: its corners on the axis are one; a ramp's foot, a line)
	return lump


## Where a climb's walked surface is cut into lumps: a spiral's pieces of curve (Sides),
## and where the ramp over steps turns level.
static func _climb_cuts(piece: Dictionary) -> Array:
	var cuts := [0.0, 1.0]
	if piece.shape == "spiral":
		var n: int = maxi(int(piece.get("sides", 12)), 1)
		cuts = []
		for i in n + 1:
			cuts.append(float(i) / n)
	var steps: int = _climb(piece)[5]
	if steps > 0:
		var level := float(steps) / (steps + 1)
		if not cuts.any(func(c): return absf(c - level) < 0.0001):
			cuts.append(level)
	cuts.sort()
	return cuts


## A spiral or stairs as it is walked on: a smooth ramp (level over its last step).
static func climb_walk(piece: Dictionary) -> Array:
	var c := _climb(piece)
	var cuts := _climb_cuts(piece)
	var under: float = INF if c[3] == "solid" else c[4]
	var hulls := []
	for i in cuts.size() - 1:
		var t0 := climb_height(piece, cuts[i])
		var t1 := climb_height(piece, cuts[i + 1])
		hulls.append(_climb_lump(piece, cuts[i], cuts[i + 1], t0, t1, maxf(t0 - under, -c[0]), maxf(t1 - under, -c[0])))
	return hulls


## A spiral's or stairs' steps: each a level tread, down to the foot (solid), on the
## slab under the walked ramp (slab), or a tread of its own (treads). On a spiral a step is
## cut into as many lumps as the curve has pieces across it, so each stays all but flat.
static func climb_steps(piece: Dictionary) -> Array:
	var c := _climb(piece)
	var steps: int = maxi(c[5], 1)
	var per := 1
	if piece.shape == "spiral":
		per = maxi(ceili(float(maxi(int(piece.get("sides", 12)), 1)) / (steps + 1)), 1)
	var hy: float = c[0]
	var hulls := []
	for k in range(1, steps + 1):
		var step := climb_step(piece, k)
		var tread: float = step[0]
		for j in per:
			var f0: float = lerpf(step[1], step[2], float(j) / per)
			var f1: float = lerpf(step[1], step[2], float(j + 1) / per)
			var low0: float
			var low1: float
			match c[3]:
				"solid":
					low0 = -hy
					low1 = -hy
				"slab":   # under the slope, never closer than 2 cm under the tread
					low0 = minf(climb_height(piece, f0) - c[4], tread - 0.02)
					low1 = minf(climb_height(piece, f1) - c[4], tread - 0.02)
				_:        # a floating tread
					low0 = tread - c[4]
					low1 = tread - c[4]
			low0 = maxf(low0, -hy)
			low1 = maxf(low1, -hy)
			if tread - maxf(low0, low1) < 0.01:
				continue
			hulls.append(_climb_lump(piece, f0, f1, tread, tread, low0, low1))
	return hulls


# ---------------------------------------------------------------------------
# Hulls: blocks of any convex shape, given by their corners (MapBlock.Shape.HULL).

## A hull block has at most this many corners: finding a hull's faces gets slow past
## it, and the map is built from every block's faces when it loads.
const MAX_HULL_CORNERS := 32


## The corners of the convex lump round `pts`: the points that are a corner of one
## of its faces, in the order given, each once. Points inside it, or in the middle
## of a face or an edge, are left out. Empty if `pts` are all in one plane.
static func hull_corners(pts: PackedVector3Array) -> PackedVector3Array:
	var planes := hull_planes(pts)
	var out := PackedVector3Array()
	for p in pts:
		# A corner lies on three faces or more; a point in the middle of an edge on two,
		# in the middle of a face on one, inside on none.
		var on := 0
		for plane in planes:
			if absf(plane.distance_to(p)) <= 0.0005:
				on += 1
		if on < 3:
			continue
		var seen := false
		for q in out:
			if q.distance_to(p) <= 0.0005:
				seen = true
				break
		if not seen:
			out.append(p)
	return out


## The faces of the convex lump round `pts` as planes, each facing out (a point is
## inside the lump when it is behind every one of them). Fewer than 4 when the
## points are all in one plane (or there are too few): no solid shape.
static func hull_planes(pts: PackedVector3Array) -> Array[Plane]:
	var out: Array[Plane] = []
	for face in hull_faces(pts):
		var n: Vector3 = face[0]
		var d := 0.0
		for p: Vector3 in face[1]:
			d += n.dot(p)
		out.append(Plane(n, d / (face[1] as Array).size()))   # (through the middle of its corners)
	return out


## Is `p` (in the hull's own frame) inside the hull with these `planes`, or no more
## than `margin` metres outside it?
static func hull_has(planes: Array, p: Vector3, margin: float = 0.0) -> bool:
	for plane: Plane in planes:
		if plane.distance_to(p) > margin:
			return false
	return true


## How high the top of the hull with these `planes` is at (`x`, `z`) in its own
## frame: the y of its upper surface straight above or below that point. -INF if
## the point is not over the hull, with `margin` metres to spare round its sides.
static func hull_top(planes: Array, x: float, z: float, margin: float = 0.0) -> float:
	var top := INF
	var bottom := -INF
	for plane: Plane in planes:
		var n := plane.normal
		var level := plane.d - n.x * x - n.z * z
		if n.y > 0.001:
			top = minf(top, level / n.y)       # under this face
		elif n.y < -0.001:
			bottom = maxf(bottom, level / n.y)  # over this face
		elif -level > margin * Vector2(n.x, n.z).length():
			return -INF                         # outside an upright side
	if top == INF or bottom > top + margin:
		return -INF
	return top


## A slope: tall at the back (-z), down to nothing at the front (+z).
static func wedge_points(piece: Dictionary) -> PackedVector3Array:
	var h: Vector3 = piece.size * 0.5
	return PackedVector3Array([
		Vector3(-h.x, -h.y, -h.z), Vector3(h.x, -h.y, -h.z), Vector3(-h.x, -h.y, h.z), Vector3(h.x, -h.y, h.z),
		Vector3(-h.x, h.y, -h.z), Vector3(h.x, h.y, -h.z)])


## A box with every edge cut off: three corners where each of the box's was.
static func bevel_points(piece: Dictionary) -> PackedVector3Array:
	var h: Vector3 = piece.size * 0.5
	var c: float = clampf(piece.get("bevel", 0.1), 0.0, minf(h.x, minf(h.y, h.z)) * 0.98)
	var pts := PackedVector3Array()
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				pts.append(Vector3(sx * h.x, sy * (h.y - c), sz * (h.z - c)))
				pts.append(Vector3(sx * (h.x - c), sy * h.y, sz * (h.z - c)))
				pts.append(Vector3(sx * (h.x - c), sy * (h.y - c), sz * h.z))
	return pts


## How many rings a dome has from its foot to its top.
static func dome_rings(piece: Dictionary) -> int:
	return maxi(2, int(piece.get("sides", 12)) / 4)


## A point on a dome's skin (`shrink` metres inside it): `i` of `sides` steps round,
## ring `j` of dome_rings() up.
static func _dome_point(piece: Dictionary, i: int, j: int, shrink: float) -> Vector3:
	var sides: int = piece.get("sides", 12)
	var arc: float = deg_to_rad(piece.get("arc", 360.0))
	var a := PI * 0.5 + (TAU - arc) * 0.5 + arc * i / sides   # the open slice faces +z
	var up := PI * 0.5 * j / dome_rings(piece)
	var rx: float = maxf(piece.size.x * 0.5 - shrink, 0.0)
	var rz: float = maxf(piece.size.z * 0.5 - shrink, 0.0)
	var height: float = maxf(piece.size.y - shrink, 0.0)
	return Vector3(cos(a) * cos(up) * rx, sin(up) * height - piece.size.y * 0.5, sin(a) * cos(up) * rz)


static func _dome_wall(piece: Dictionary) -> float:
	var inner: float = piece.get("inner", 0.0)
	return clampf((piece.size.x - inner) * 0.5, 0.01, piece.size.x * 0.5) if inner > 0.0 else 0.0


static func dome_hulls(piece: Dictionary) -> Array:
	var sides: int = piece.get("sides", 12)
	var rings := dome_rings(piece)
	var wall := _dome_wall(piece)
	var whole: bool = piece.get("arc", 360.0) >= 359.9
	var foot := Vector3(0, -piece.size.y * 0.5, 0)
	var hulls := []
	if wall <= 0.0 and whole:
		var all := PackedVector3Array()
		for i in sides:
			for j in rings:
				all.append(_dome_point(piece, i, j, 0.0))
		all.append(_dome_point(piece, 0, rings, 0.0))
		return [all]
	for i in sides:
		if wall <= 0.0:   # solid, with a slice out: one lump per side, from the middle out
			var lump := PackedVector3Array([foot])
			for j in rings + 1:
				lump.append(_dome_point(piece, i, j, 0.0))
				if j < rings:
					lump.append(_dome_point(piece, i + 1, j, 0.0))
			hulls.append(lump)
			continue
		for j in rings:     # a shell: one lump per panel
			var lump := PackedVector3Array()
			for shrink in [0.0, wall]:
				lump.append(_dome_point(piece, i, j, shrink))
				lump.append(_dome_point(piece, i + 1, j, shrink))
				lump.append(_dome_point(piece, i, j + 1, shrink))
				if j + 1 < rings:
					lump.append(_dome_point(piece, i + 1, j + 1, shrink))
			hulls.append(lump)
	return hulls


## An arch's opening: half its width and its height.
static func arch_opening(piece: Dictionary) -> Vector2:
	var inner: float = piece.get("inner", 0.0)
	var half: float = piece.size.x * 0.5
	return Vector2(minf(inner * 0.5, half) if inner > 0.0 else half, clampf(piece.size.y - piece.get("top", 0.0), 0.01, piece.size.y))


static func arch_hulls(piece: Dictionary) -> Array:
	var h: Vector3 = piece.size * 0.5
	var open := arch_opening(piece)
	var sides: int = maxi(int(piece.get("sides", 12)), 2)
	var hulls := []
	for k in sides:
		var lump := PackedVector3Array()
		for t in [k, k + 1]:
			var a: float = PI * t / sides
			var x: float = cos(a) * open.x
			for z in [-h.z, h.z]:
				lump.append(Vector3(x, -h.y + sin(a) * open.y, z))
				lump.append(Vector3(x, h.y, z))
		hulls.append(lump)
	if open.x < h.x - 0.001:   # a leg either side of the opening
		for s in [-1.0, 1.0]:
			var leg := PackedVector3Array()
			for x in [s * open.x, s * h.x]:
				for y in [-h.y, h.y]:
					for z in [-h.z, h.z]:
						leg.append(Vector3(x, y, z))
			hulls.append(leg)
	return hulls


## Draws each lump's faces (its convex hull), leaving out the faces two lumps share.
static func _hulls(buf: Array, piece: Dictionary) -> void:
	var xf: Transform3D = piece.xf
	var color: Color = piece.get("tint", Color.WHITE)
	if piece.shape == "dome" and _dome_wall(piece) <= 0.0 and piece.get("arc", 360.0) >= 359.9:
		# A whole solid dome is one lump of many corners: its panels are known, no need to look for them.
		var sides: int = piece.get("sides", 12)
		var rings := dome_rings(piece)
		var foot := PackedVector3Array()
		for i in sides:
			foot.append(_dome_point(piece, sides - i, 0, 0.0))
			for j in rings:
				var a := _dome_point(piece, i, j, 0.0)
				var b := _dome_point(piece, i + 1, j, 0.0)
				var c := _dome_point(piece, i + 1, j + 1, 0.0)
				var d := _dome_point(piece, i, j + 1, 0.0)
				var n := (c - a).cross(b - a) if j + 1 == rings else (c - a).cross(b - d)
				n = n.normalized()
				if n.dot(a + c) < 0.0:
					n = -n
				_flat(_route(buf, n), xf, [a, b, c] if j + 1 == rings else [a, b, c, d], n, color)
		_flat(_route(buf, Vector3.DOWN), xf, Array(foot), Vector3.DOWN, color)
		return
	# Every face of every lump; a face two lumps share (the same place, looking opposite
	# ways) is inside the piece and is left out.
	var faces := []   # [normal, corners in order, a key for where its middle is]
	var count := {}
	for pts in draw_points(piece):
		var surface := hull_surface(pts)
		if piece.shape == "spiral":
			_one_way_up(surface)
		for face in surface:
			var mid := Vector3.ZERO
			for p in face[1]:
				mid += p
			mid /= face[1].size()
			var key := Vector3i((mid * 200.0).round())
			face.append(key)
			count[key] = count.get(key, 0) + 1
			faces.append(face)
	for face in faces:
		if count[face[2]] == 1:
			_flat(_route(buf, face[0]), xf, face[1], face[0], color)


## A piece of a spiral's curve is twisted a little (its two ends are level lines at
## different heights and angles), so its top comes out as two faces leaning slightly
## different ways, and its underside too. Drawn as they are, the shading and the floor's
## pattern break at the fold between them. This gives the faces of its top one way out
## between them (and those of its underside), so each piece reads as one sloping slab.
## Where the corners are does not change.
static func _one_way_up(surface: Array) -> void:
	for way: float in [1.0, -1.0]:
		var sum := Vector3.ZERO
		var group := []
		for face in surface:
			if (face[0] as Vector3).y * way > 0.5:
				sum += (face[0] as Vector3) * _twice_area(face[1]).length()
				group.append(face)
		if group.size() > 1 and sum.length() > 0.0:
			for face in group:
				face[0] = sum.normalized()


## One flat face with these corners (in the piece's own frame, in order round it,
## either way), facing along `n`.
static func _flat(buf: Array, xf: Transform3D, corners: Array, n: Vector3, color: Color) -> void:
	if corners.size() < 3:
		return
	var turn: Vector3 = ((corners[1] as Vector3) - corners[0]).cross((corners[2] as Vector3) - corners[0])
	if turn.dot(n) < 0.0:
		corners = corners.duplicate()
		corners.reverse()
	var out: Vector3 = xf.basis * n
	for k in range(1, corners.size() - 1):
		_tri(buf, xf * corners[0], xf * corners[k], xf * corners[k + 1], out, color)


## The flat faces of the convex lump with these corners, as the map tools work with
## them (its planes, its edges, which face is which): [[normal, corners going
## counter-clockwise seen from outside], ...]. Corners that lie in one plane make one
## face, its outline: a point inside a face, or in the middle of one of its edges, is
## not one of its corners. Points within half a millimetre of a plane count as on it,
## and faces in all but the same plane are one face, so a slanted face stays one face
## however often its corners are rounded. (For drawing, see hull_surface: on points
## that have drifted badly these faces may not quite close up.)
static func hull_faces(pts: PackedVector3Array) -> Array:
	var n := pts.size()
	var groups := []   # one per face: [normal (out), how far out its plane is, {index of a point on it: true}]
	for a in n:
		for b in range(a + 1, n):
			for c in range(b + 1, n):
				var ab := pts[b] - pts[a]
				var ac := pts[c] - pts[a]
				var normal := ab.cross(ac)
				if normal.length() < 0.001 * ab.length() * ac.length():
					continue   # (all but in a line: the plane through them could lean any way)
				normal = normal.normalized()
				var d := normal.dot(pts[a])
				var above := false
				var below := false
				var on := []
				for i in n:
					var s := normal.dot(pts[i]) - d
					if s > 0.0005:
						above = true
					elif s < -0.0005:
						below = true
					else:
						on.append(i)
					if above and below:
						break   # points on both sides: not a face
				if above and below:
					continue
				if above:
					normal = -normal
				# Other threes on the same face find it again, perhaps with a few points
				# more or less on it (when they have drifted a hair out of one plane): all
				# of them go to one face, never two all but the same (cutting with both
				# would make stray corners).
				d = normal.dot(pts[a])
				var group: Array = []
				for g in groups:
					if (g[0] as Vector3).dot(normal) > 0.9999 and absf(float(g[1]) - d) < 0.001:
						group = g
						break
				if group.is_empty():
					group = [normal, d, {}]
					groups.append(group)
				for i in on:
					group[2][i] = true
	var faces := []
	for g in groups:
		var on_points := []
		for i in (g[2] as Dictionary):
			on_points.append(pts[i])
		var corners := _outline(on_points, g[0], 0.0005)
		if corners.size() < 3:
			continue
		# The face's own way out, from all its corners, not just the three it was found
		# by; a face with next to no area is no face.
		var fit := _twice_area(corners)
		if fit.length() < 2e-6:
			continue
		fit = fit.normalized()
		faces.append([fit if fit.dot(g[0]) > 0.0 else -fit, corners])
	return faces


## The faces of the convex lump with these corners as they are drawn ([[normal,
## corners going counter-clockwise seen from outside], ...]): always a closed surface,
## with no face missing, overlapping or folded over, even for points that have drifted
## or were dragged a few millimetres apart.
##
## These are the lump's faces as they are, to within a fiftieth of a millimetre: points
## truly in one plane (a box's side) make one face, points a hair out of one plane make
## several flat ones, side by side, which look the same. Together they always cover the
## lump with no gap or overlap. (The map tools use hull_faces, where a face whose
## corners are a little out of one plane is still one face.)
static func hull_surface(pts: PackedVector3Array) -> Array:
	# On a plane means on it, to a nanometre: any looser and three points of a face a
	# hair out of one plane can call it one face where another three call it two, and the
	# surface gets a face twice in one place and none in another. The sums are done in
	# 64-bit numbers (Godot's vectors are 32-bit, and a face only millimetres wide would
	# come out leaning the wrong way); 32-bit points truly in one plane, as a box's side
	# is, still come out exactly on it.
	const EXACT := 1e-9
	var n := pts.size()
	var x := PackedFloat64Array()
	var y := PackedFloat64Array()
	var z := PackedFloat64Array()
	for p in pts:
		x.append(p.x)
		y.append(p.y)
		z.append(p.z)
	var faces := []   # [normal (out), its corners in order]
	var seen := {}
	for a in n:
		for b in range(a + 1, n):
			var ux := x[b] - x[a]
			var uy := y[b] - y[a]
			var uz := z[b] - z[a]
			for c in range(b + 1, n):
				var vx := x[c] - x[a]
				var vy := y[c] - y[a]
				var vz := z[c] - z[a]
				var nx := uy * vz - uz * vy
				var ny := uz * vx - ux * vz
				var nz := ux * vy - uy * vx
				var length := sqrt(nx * nx + ny * ny + nz * nz)
				if length < 1e-12:
					continue   # (in a line)
				var above := false
				var below := false
				var on := []
				for i in n:
					# How far in front of the plane the point is (from a point on it, so
					# that a point truly in it comes out as nothing at all).
					var s := ((x[i] - x[a]) * nx + (y[i] - y[a]) * ny + (z[i] - z[a]) * nz) / length
					if s > EXACT:
						above = true
					elif s < -EXACT:
						below = true
					else:
						on.append(i)
					if above and below:
						break   # points on both sides: not a face
				if above and below:
					continue
				var normal := Vector3(nx / length, ny / length, nz / length)
				if above:
					normal = -normal
				var key := str(on)   # (other threes on the same face find it again)
				if seen.has(key):
					continue
				seen[key] = true
				var on_points := []
				for i in on:
					on_points.append(pts[i])
				var ring := _outline(on_points, normal, 0.0)
				if ring.size() >= 3 and _twice_area(ring).length() > 1e-12:
					faces.append([normal, ring])
	if faces.size() < 4:
		return []   # all in one plane (or too few points): no solid
	return faces


## Twice a flat ring's area, facing the way its corners turn counter-clockwise
## (Newell's method).
static func _twice_area(ring: Array) -> Vector3:
	var out := Vector3.ZERO
	for k in ring.size():
		var p: Vector3 = ring[k]
		var q: Vector3 = ring[(k + 1) % ring.size()]
		out += Vector3((p.y - q.y) * (p.z + q.z), (p.z - q.z) * (p.x + q.x), (p.x - q.x) * (p.y + q.y))
	return out


## The outline of `points` (all in one plane facing along `normal`): its corners in
## order, counter-clockwise seen from the side it faces. A point inside the outline, in
## the middle of one of its sides or on top of another (within `slack` metres) is left out.
static func _outline(points: Array, normal: Vector3, slack := 0.0005) -> Array:
	var u := normal.cross(Vector3.UP if absf(normal.y) < 0.9 else Vector3.RIGHT).normalized()
	var v := normal.cross(u)   # (u, v, normal) turn the right way: counter-clockwise in u, v is seen from outside
	var flat := []
	for p: Vector3 in points:
		flat.append([Vector2(p.dot(u), p.dot(v)), p])
	flat.sort_custom(func(p: Array, q: Array) -> bool:
		return p[0].x < q[0].x or (p[0].x == q[0].x and p[0].y < q[0].y))
	# Andrew's monotone chain: the lower side left to right, then the upper side back.
	var chain := []
	for pass_ in 2:
		var start := chain.size()
		var order := flat if pass_ == 0 else flat.duplicate()
		if pass_ == 1:
			order.reverse()
		for p in order:
			while chain.size() - start >= 2 and _bends_back(chain[-2][0], chain[-1][0], p[0], slack):
				chain.pop_back()
			if chain.size() - start >= 1 and (chain[-1][0] as Vector2).distance_to(p[0]) <= slack:
				continue
			chain.append(p)
		chain.pop_back()   # (the last of each side is the first of the next)
	var out := []
	for c in chain:
		if out.is_empty() or (out[-1] as Vector3).distance_to(c[1]) > slack:
			out.append(c[1])
	if out.size() > 1 and (out[0] as Vector3).distance_to(out[-1]) <= slack:
		out.pop_back()
	return out


## Going from `o` to `a` and on to `b`, does the way turn clockwise, or run straight on
## (within `slack` metres)? Then `a` is not a corner of a counter-clockwise outline.
static func _bends_back(o: Vector2, a: Vector2, b: Vector2, slack: float) -> bool:
	var turn := (a - o).cross(b - o)
	return turn <= slack * maxf((a - o).length(), (b - o).length())


static func _tri(buf: Array, a: Vector3, b: Vector3, c: Vector3, n: Vector3, color: Color) -> void:
	var verts: PackedVector3Array = buf[0]
	var normals: PackedVector3Array = buf[1]
	var colors: PackedColorArray = buf[2]
	color = _shaded(color, n)
	for v in [a, c, b]:
		verts.append(v)
		normals.append(n)
		colors.append(color)
	_put_custom(buf, 3)


static func _shaded(color: Color, n: Vector3) -> Color:
	if _shade == Vector3.ONE:
		return color
	n = _shade_basis * n
	var flat := n.x * n.x + n.z * n.z
	var side: float = lerpf(_shade.x, _shade.y, n.z * n.z / flat) if flat > 0.0001 else 1.0
	var k: float = lerpf(side, 1.0, n.y) if n.y >= 0.0 else lerpf(side, _shade.z, -n.y)
	return Color(color.r * k, color.g * k, color.b * k, color.a)
