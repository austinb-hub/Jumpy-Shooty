class_name MapDestruction
extends Node3D
## Walls and floors you can shoot or smash through (arena maps only, never races).
##
## Which pieces break: solid, drawn blocks whose Breakable is ticked. Health is the
## block's own Break Health, else its Break Settings' health, else its kind's toughness
## in the palette's `breakable` list. Two ways to break:
##  - Per cell (the usual): only a thin wall or floor (a box, one side at most
##    MAX_THICKNESS, the face at least MIN_AREA square metres). Each such "panel" is
##    cut into cells of about CELL metres (glass and other weak kinds break as one
##    pane), each with that health.
##  - Whole block: any block, one "panel" of one cell that has all the health and
##    goes at once. What rests on it stays where it is.
## A cell takes damage,
## cracks (darkens) at two thirds and one third left, then breaks: its collision and
## drawing go, rubble falls and a crash plays. It stays broken until the match ends.
##
## Some cells never break, so the map stays playable:
##  - near a spawn point (the floor under it and the walls round it);
##  - anything else rests on, hangs from or goes through: the floor under a desk, a
##    wall or a stair, a slab a column passes through, a wall with a beam on top.
## Thin drawn-only pieces lying flat on a panel (a ceiling under a floor, a rug on it,
## a lamp strip, the frosting on a glass wall) are its "skins": they are cut and break
## with the cells they cover.
##
## The host decides every hit (see Match) and tells everyone which cells changed and
## how damaged they are; each copy then rebuilds that panel's collision and mesh. A
## panel's collision is the fewest boxes that cover what is left, so walking over an
## intact floor feels exactly like before.

## Fine fracture (`fine`, set by the map: MapRoot.fine_destruction). The same panels are
## cut much smaller (FINE_STYLES: about half a metre, blockwork along its courses), so a
## hole is the size of what made it:
##  - a cell's health is FINE_HEALTH of its kind's toughness, and a hit weaker than the
##    material's `armour` does nothing at all (small arms only mark concrete);
##  - a blast or a heavy blow damages every cell within reach (damage_area), less the
##    further out;
##  - the edge of a hole is drawn ragged: the corners of the cells round it are pushed
##    about by a number worked out from the panel and the corner, so every copy of the
##    game draws the same edge without being told it;
##  - cracks are not darkened cells but marks (see BulletMarks), so only a break redraws
##    the panel.
## Collision stays boxes: the cells that are left, merged.

signal cells_changed(cells: PackedInt32Array, stages: PackedByteArray)

const CELL := 2.0            ## metres: about how big a piece breaks off
const MAX_THICKNESS := 0.6   ## a wall or floor this thin or thinner can break
const MIN_AREA := 7.0        ## ...and at least this big (small landings and steps stay)
const SMALL_AREA := 0.4      ## ...or this big, in a building held up by its walls (MapFrame): every bit of wall breaks there
const THICK_CELL := 1.5      ## fine: a wall or floor thicker than MAX_THICKNESS (MapRoot.break_thickness lets one break) breaks in pieces this much bigger...
const THICK_ARMOUR := 60.0   ## ...and a hit weaker than this does nothing to it (small arms only mark it), whatever it is made of
const ONE_PIECE_BELOW := 50.0  ## kinds weaker than this (glass) shatter as one pane
const SPAWN_GUARD := 3.0     ## metres round a spawn point nothing breaks
const BROKEN := 3            ## stages: 0 whole, 1 cracked, 2 badly cracked, 3 broken
const FALLEN := 4            ## ...4 gone with what held it up (a collapse): no rubble or crash of its own
const FINE_HEALTH := 0.3     ## fine: a cell's health, as a share of its kind's toughness
## fine: how each sort of material breaks. cell: metres across a piece (along the panel,
## up it); jitter: how far a corner on the edge of a hole strays, as a share of a cell
## (along, up); armour: a hit weaker than this does nothing; stop: a round weaker than
## this stops in it, a stronger one goes through (see pierce()); keep: the share of its
## damage a round still has on the far side; wear: the share of a round's damage the
## wall takes when the round goes through (one that stops in it does all of it).
const FINE_STYLES := {
	"concrete": {"name": "concrete", "cell": Vector2(0.5, 0.5), "jitter": Vector2(0.3, 0.3), "armour": 60.0, "stop": 90.0, "keep": 0.4, "wear": 0.6},
	"masonry": {"name": "masonry", "cell": Vector2(0.4, 0.4), "jitter": Vector2(0.1, 0.0), "armour": 0.0, "stop": 50.0, "keep": 0.5, "wear": 0.3},
	"wood": {"name": "wood", "cell": Vector2(0.5, 0.5), "jitter": Vector2(0.38, 0.12), "armour": 0.0, "stop": 8.0, "keep": 0.7, "wear": 0.5},
	"sheet": {"name": "sheet", "cell": Vector2(0.5, 0.5), "jitter": Vector2(0.26, 0.26), "armour": 0.0, "stop": 5.0, "keep": 0.85, "wear": 0.5},
}
const GLASS_KEEP := 0.9       ## fine: ...and through a pane of glass (any round goes through one)
const MAX_PIERCE := 2         ## fine: how many walls one round can go through
const ARMOURED_FROM := 200.0  ## fine: a concrete kind at least this tough has concrete's armour
const BLAST_REACH := 0.35     ## fine: a blast breaks walls out to this share of its splash radius
const BLOW_REACH := 0.8       ## fine: metres round a melee blow that it damages
const SLAM_REACH := 1.1       ## fine: metres round a ground slam that go through
const HEALTH_SPREAD := 0.5    ## fine: one cell is up to this much tougher than the next (a ragged hole, not a round one)
const CUT_SHADE := 0.7       ## fine: how dark the broken edge of a panel is drawn
const CRACK_SHADE := [1.0, 0.8, 0.62]
const LOT := 32.0             ## metres: fine panels that stand whole are drawn together, in lots this big (see _draw_lots)
const MAX_DEBRIS := 140
const PANEL_BUCKET := 6.0     ## metres: the size of the buckets pieces are matched to panels in

## Every panel: {xf, size, kind, tint, n: Vector3i, cell: Vector3, first: int (first
## cell index), body: StaticBody3D, meshes: Node3D, skins: [{kind, tint, box: AABB}], thin: int,
## frame: Node3D or null}. A panel that rides a mover (an island's glass walls) has that
## mover's body as its frame: its xf is in that frame, and its body and meshes are the
## frame's children, so they go where it goes.
var panels: Array = []
## Every cell: {panel, ijk: Vector3i, hp, max_hp, stage, protected}
var cells: Array = []
var root: MapRoot
## Fine fracture (see the top): set before setup().
var fine := false

var _damaged := {}   # cell -> stage, for every cell that is not whole
var _dirty := {}     # fine: panels whose meshes are redrawn at the end of this frame
var _pending := {}   # host: cell -> new stage, sent by flush()
var _debris := 0
# Killcams (see MapReplay): what a replay draws in place of the live damage.
var _revision := 0          # goes up whenever a cell changes stage
var _captured_rev := -1
var _captured: Array = []
var _replaying := false
var _replay := {}           # cell -> the stage a replay draws it at (cells not in it: whole)
var _replay_of: Variant = null   # ...from this replay_capture() (the same one again: nothing to do)


## Takes the pieces that will break out of `pieces` (they are built here instead)
## and returns the rest, for MapRoot to build as usual.
func setup(map: MapRoot, pieces: Array, spawn_points: Array) -> Array:
	root = map
	name = "Breakables"
	var rest := _take(pieces, spawn_points, null)
	if not panels.is_empty():
		add_to_group(MapReplay.GROUP)
	return rest


## The same for the blocks of a mover (MapRoot calls it for each): `pieces` and
## `spawn_points` are in the mover's own frame, and `frame` is its moving body.
func add_riding(frame: Node3D, pieces: Array, spawn_points: Array) -> Array:
	var rest := _take(pieces, spawn_points, frame)
	if not panels.is_empty():
		add_to_group(MapReplay.GROUP)
	return rest


func _take(pieces: Array, spawn_points: Array, frame: Node3D) -> Array:
	var map := root
	var first_panel := panels.size()
	var first_cell := cells.size()
	var table: Dictionary = map.palette.breakable if map.palette else {}
	var keep := []
	var panel_pieces := []
	var whole_pieces := []
	var seen := {}
	for piece in pieces:
		if _can_break(piece, table):
			var key := "%s|%s" % [piece.xf, piece.size]
			if seen.has(key):
				continue   # the same block twice: break it once
			seen[key] = true
			panel_pieces.append(piece)
		else:
			keep.append(piece)
	if panel_pieces.is_empty():
		return pieces
	# Thin drawn-only pieces lying flat on a panel go with it (cut cell by cell).
	var skin_of := {}   # index in keep -> panel index
	for piece in panel_pieces:
		var whole: bool = piece.get("break_mode", "cell") == "whole"
		_add_panel(piece, health_of(piece, table), whole, frame)
		if whole:
			whole_pieces.append(piece)
	# (Where the new panels are, in buckets: a big map has thousands of them, and tens of
	# thousands of pieces that might lie on one.)
	var buckets := {}
	for i in range(first_panel, panels.size()):
		var reach: AABB = ((panels[i].xf as Transform3D) * AABB(-(panels[i].size as Vector3) * 0.5, panels[i].size)).grow(0.2)
		var lo := Vector3i((reach.position / PANEL_BUCKET).floor())
		var hi := Vector3i((reach.end / PANEL_BUCKET).floor())
		for x in range(lo.x, hi.x + 1):
			for y in range(lo.y, hi.y + 1):
				for z in range(lo.z, hi.z + 1):
					(buckets.get_or_add(Vector3i(x, y, z), []) as Array).append(i)
	var near_of := {}   # index in keep -> the panels it might lie on, lowest first
	for k in keep.size():
		var p: Dictionary = keep[k]
		if p.solid or p.get("hidden", false) or p.shape != "box":
			continue
		var near := _panels_near(buckets, (p.xf as Transform3D) * AABB(-(p.size as Vector3) * 0.5, p.size))
		near_of[k] = near
		for i: int in near:
			if panels[i].whole:
				continue
			var box := _skin_box(panels[i], p)
			if box.has_volume():
				panels[i].skins.append({"kind": p.kind, "tint": p.get("tint", Color.WHITE), "box": box})
				skin_of[k] = i
				break
	var rest := []
	for k in keep.size():
		if skin_of.has(k):
			continue
		var p: Dictionary = keep[k]
		if p.solid or p.get("hidden", false) or p.shape != "box":
			rest.append(p)
		else:
			rest.append_array(_share_band(p, near_of[k]))
	# Whole blocks count as things resting on a floor: a floor under a crate holds.
	_protect(rest + whole_pieces, spawn_points, first_cell, first_panel)
	for i in range(first_panel, panels.size()):
		if panels[i].fine and panels[i].frame == null:
			panels[i]["lot"] = []   # (drawn with the panels round it while it is whole: see _draw_lots)
		_rebuild_panel(i)
	_draw_lots(first_panel)
	return rest


## Draws the fine panels from `first_panel` on that stand still, whole: all those in
## each cube of LOT metres as one mesh for each kind, like the rest of the map, in
## place of a mesh or two for every panel (a map can have thousands: Empyrean Tower's
## 1,900 were five thousand draw calls a frame). Each panel knows where in those
## meshes it is ("lot": [[mesh, its first corner, how many]...]); the first time it is
## drawn with a hole in it, it is blanked there and drawn on its own from then on
## (_rebuild_meshes). Panels that ride a mover are drawn on their own from the start.
func _draw_lots(first_panel: int) -> void:
	if DisplayServer.get_name() == "headless" and not root.has_meshes:
		return
	var lots := {}   # which cube -> {"drawn": kind -> buffer, "sizes": kind -> corners so far, "spans": [[panel, kind, first corner, how many]]}
	for index in range(first_panel, panels.size()):
		var panel: Dictionary = panels[index]
		if not panel.has("lot"):
			continue
		var keys := PackedByteArray()
		keys.resize(int(panel.nu) * int(panel.nv))
		keys.fill(1)
		var lot: Dictionary = lots.get_or_add(Vector3i(((panel.xf as Transform3D).origin / LOT).floor()), {"drawn": {}, "sizes": {}, "spans": []})
		var drawn: Dictionary = lot.drawn
		MapMesher.add_to(drawn, _flat_pieces(panel, keys), root.face_shade)
		for kind: String in drawn:
			var now := (drawn[kind][0] as PackedVector3Array).size()
			var was := int(lot.sizes.get(kind, 0))
			if now > was:
				(lot.spans as Array).append([index, kind, was, now - was])
				lot.sizes[kind] = now
	for at: Vector3i in lots:
		var holder := Node3D.new()
		holder.name = "Lot_%d_%d_%d" % [at.x, at.y, at.z]
		add_child(holder)
		var meshes := MapMesher.meshes(lots[at].drawn)
		for kind: String in meshes:
			var node := MeshInstance3D.new()
			node.name = "Mesh_%s" % kind
			node.mesh = meshes[kind]
			node.material_override = root.material_for(kind)
			holder.add_child(node)
		for span: Array in lots[at].spans:
			(panels[span[0]].lot as Array).append([meshes[span[1]], span[2], span[3]])


func _can_break(piece: Dictionary, table: Dictionary) -> bool:
	if not piece.solid or piece.get("hidden", false):
		return false
	if not piece.get("breakable", false):
		return false
	if piece.get("break_mode", "cell") == "whole":
		return true
	var small: bool = piece.get("unguarded", false)
	if fine and root.break_small_walls and not small:
		var up: Vector3 = (piece.xf as Transform3D).basis.y.abs()
		var s: Vector3 = piece.size
		small = s.y > minf(s.x, s.z) and up.y > 0.99   # (a wall: thin sideways, not a floor)
	return thin_enough_piece(piece, SMALL_AREA if small else MIN_AREA, maxf(root.break_thickness, MAX_THICKNESS) if fine else MAX_THICKNESS)


static func thin_enough_piece(piece: Dictionary, area: float = MIN_AREA, thickness: float = MAX_THICKNESS) -> bool:
	return piece.shape == "box" and _thin(piece.size, area, thickness)


## Can a block of this shape and size break per cell? (MapBlock's warning asks.)
static func thin_enough(shape: int, size: Vector3) -> bool:
	return shape == MapBlock.Shape.BOX and _thin(size)


static func _thin(s: Vector3, area: float = MIN_AREA, thickness: float = MAX_THICKNESS) -> bool:
	var dims := [s.x, s.y, s.z]
	dims.sort()
	# (A size is held in single precision, where 0.6 is a hair over 0.6.)
	return dims[0] <= thickness + 0.001 and dims[1] * dims[2] >= area


## How much damage a cell of this piece takes: its own health, else its kind's
## toughness from the palette, else BlockBreakable.DEFAULT_HEALTH.
static func health_of(piece: Dictionary, table: Dictionary) -> float:
	var own: float = piece.get("health", 0.0)
	if own > 0.0:
		return own
	var kind_health: float = float(table.get(piece.kind, 0.0))
	return kind_health if kind_health > 0.0 else BlockBreakable.DEFAULT_HEALTH


## fine: how a kind of this material breaks (a row of FINE_STYLES). Blockwork and
## brickwork (kinds drawn as courses) break along their courses: a cell is half a block
## wide and one course high.
static func fine_style(kind: String, material: String, palette: MapPalette, toughness: float = 1000.0) -> Dictionary:
	var surface: String = palette.surface.get(kind, "") if palette else ""
	var drawn: Dictionary = MapScenery.SURFACES.get(surface, {})
	if int(drawn.get("style", -1)) in [8, 9, 19]:   # bricks, blocks, masonry
		var style: Dictionary = (FINE_STYLES.masonry as Dictionary).duplicate()
		var course: Vector2 = drawn.get("wall_cell", Vector2(0.8, 0.4))
		while course.y < 0.3:
			course *= 2.0   # (thin bricks: two or four courses to a piece)
		style.cell = Vector2(course.x * 0.5, course.y)
		return style
	if material == "wood":
		return FINE_STYLES.wood
	# (Only what is as tough as concrete shrugs off small arms: a plastic barrier is "concrete" by default.)
	if material in ["concrete", "dirt"] and toughness >= ARMOURED_FROM:
		return FINE_STYLES.concrete
	return FINE_STYLES.sheet


func _add_panel(piece: Dictionary, toughness: float, whole: bool = false, frame: Node3D = null) -> void:
	var s: Vector3 = piece.size
	var thin := 0
	for a in 3:
		if s[a] < s[thin]:
			thin = a
	var mat: String = piece.get("material", "")
	if not BlockMaterials.TABLE.has(mat):
		mat = BlockMaterials.for_kind(piece.kind, root.palette)
	var n := Vector3i.ONE
	var cut := toughness >= ONE_PIECE_BELOW and not whole   # (else one pane, or one block)
	var style: Dictionary = fine_style(piece.kind, mat, root.palette, toughness) if fine and cut else {}
	if not style.is_empty():
		# Bigger pieces: where the map's palette says so for this kind, and in anything
		# thicker than usually breaks (which small arms only mark, and no round goes through).
		var bigger: float = root.palette.break_scale.get(piece.kind, 1.0) if root.palette else 1.0
		var thick := s[thin] > MAX_THICKNESS + 0.001
		if thick or bigger != 1.0:
			style = style.duplicate()
			style.cell = (style.cell as Vector2) * bigger * (THICK_CELL if thick else 1.0)
			if thick:
				style.armour = maxf(float(style.armour), THICK_ARMOUR)
				style.stop = INF
	if cut:
		for a in 3:
			if a != thin:
				# (a wall's cells are measured along it and up it; a floor's, the first both ways)
				var across: float = CELL if style.is_empty() else (style.cell.y if a == 1 else style.cell.x)
				n[a] = maxi(1, roundi(s[a] / across))
	if not style.is_empty():
		toughness *= FINE_HEALTH
	var panel := {"xf": piece.xf, "size": s, "kind": piece.kind, "tint": piece.get("tint", Color.WHITE),
		"n": n, "cell": Vector3(s.x / n.x, s.y / n.y, s.z / n.z), "first": cells.size(), "thin": thin,
		"skins": [], "body": null, "meshes": null, "whole": whole, "piece": piece, "material": mat, "frame": frame,
		"fine": not style.is_empty(), "armour": style.get("armour", 0.0), "jitter": style.get("jitter", Vector2.ZERO),
		"stop": style.get("stop", 0.0 if fine and mat == "glass" else INF),
		"keep": style.get("keep", GLASS_KEEP), "wear": style.get("wear", 1.0), "style": style.get("name", "")}
	# The two axes across its face, how many cells along each, and how far apart their
	# numbers are in `cells`.
	var u := (thin + 1) % 3
	var v := (thin + 2) % 3
	var strides := [1, n.x, n.x * n.y]
	panel["u"] = u
	panel["v"] = v
	panel["nu"] = n[u]
	panel["nv"] = n[v]
	panel["su"] = strides[u]
	panel["sv"] = strides[v]
	var stray: Vector2 = panel.jitter
	if thin == 1:   # a floor: more along its longer side (boards splinter along their length)
		panel["jitter"] = stray if s[u] >= s[v] else Vector2(stray.y, stray.x)
	else:           # a wall: `y` is up it
		panel["jitter"] = Vector2(stray.y if u == 1 else stray.x, stray.y if v == 1 else stray.x)
	var index := panels.size()
	panels.append(panel)
	for k in n.z:
		for j in n.y:
			for i in n.x:
				var hp := toughness
				if panel.fine:   # (the host's own business, but the same every match: it keeps tests steady)
					hp *= 1.0 - HEALTH_SPREAD * 0.5 + HEALTH_SPREAD * (hash(Vector2i(index, cells.size())) % 1000) / 999.0
				cells.append({"panel": index, "ijk": Vector3i(i, j, k), "hp": hp, "max_hp": hp,
					"stage": 0, "protected": false})
	var body: StaticBody3D
	if frame:
		var moving := AnimatableBody3D.new()   # it moves with its frame, a step at a time like it
		moving.sync_to_physics = false
		body = moving
	else:
		body = StaticBody3D.new()
	body.name = "Panel_%d" % index
	body.collision_layer = 1
	body.collision_mask = 0
	body.transform = piece.xf
	body.set_meta("panel", index)
	(frame if frame else self).add_child(body)
	panel.body = body
	var meshes := Node3D.new()
	meshes.name = "Mesh_%d" % index
	(frame if frame else self).add_child(meshes)
	panel.meshes = meshes


## The panels in `buckets` (see _take) that a box reaches the neighbourhood of, lowest
## number first.
func _panels_near(buckets: Dictionary, box: AABB) -> Array:
	var lo := Vector3i((box.position / PANEL_BUCKET).floor())
	var hi := Vector3i((box.end / PANEL_BUCKET).floor())
	var found := {}
	for x in range(lo.x, hi.x + 1):
		for y in range(lo.y, hi.y + 1):
			for z in range(lo.z, hi.z + 1):
				for i: int in buckets.get(Vector3i(x, y, z), []):
					found[i] = true
	var near := found.keys()
	near.sort()
	return near


## `piece` as a box in the panel's frame, if it is a skin of that panel: thin, lying
## flat against one of its big faces, square to it, and within its outline.
func _skin_box(panel: Dictionary, piece: Dictionary) -> AABB:
	var to_local: Transform3D = (panel.xf as Transform3D).affine_inverse() * (piece.xf as Transform3D)
	for a in 3:   # square to the panel (any quarter turn)
		var col: Vector3 = to_local.basis[a].abs()
		if maxf(col.x, maxf(col.y, col.z)) < 0.999:
			return AABB()
	var box: AABB = to_local * AABB(-(piece.size as Vector3) * 0.5, piece.size)
	var half: Vector3 = panel.size * 0.5
	var thin: int = panel.thin
	if box.size[thin] > 0.15:
		return AABB()
	for a in 3:
		if a != thin and (box.position[a] < -half[a] - 0.05 or box.end[a] > half[a] + 0.05):
			return AABB()
	var gap_above: float = box.position[thin] - half[thin]
	var gap_below: float = -half[thin] - box.end[thin]
	if absf(gap_above) > 0.05 and absf(gap_below) > 0.05:
		return AABB()   # not touching either face
	return box


## A long thin drawn-only piece that runs along the faces of several panels (a band of
## colour round a building, across the stretches of wall between its windows): each
## panel takes the length of it that lies on it as a skin, and what is left over (past
## a corner, across an opening) comes back as pieces of its own, to be drawn as before.
## A piece that is no such band comes back whole.
func _share_band(piece: Dictionary, near: Array) -> Array:
	var size: Vector3 = piece.size
	var along := 0   # its long axis, in its own frame
	for a in 3:
		if size[a] > size[along]:
			along = a
	if size[along] < 2.0 or minf(size[(along + 1) % 3], size[(along + 2) % 3]) > 0.15:
		return [piece]
	var pxf: Transform3D = piece.xf
	var spans: Array = []   # [from, to (along it, from its middle), panel, the skin's box]
	for i: int in near:
		var panel: Dictionary = panels[i]
		if panel.whole or not panel.fine:
			continue
		var to_local: Transform3D = (panel.xf as Transform3D).affine_inverse() * pxf
		var square := true
		for a in 3:
			var col: Vector3 = to_local.basis[a].abs()
			if maxf(col.x, maxf(col.y, col.z)) < 0.999:
				square = false
		if not square:
			continue
		var box: AABB = to_local * AABB(-size * 0.5, size)
		var half: Vector3 = panel.size * 0.5
		var thin: int = panel.thin
		if box.size[thin] > 0.15 or (absf(box.position[thin] - half[thin]) > 0.05 and absf(-half[thin] - box.end[thin]) > 0.05):
			continue   # not flat on either face
		var run := 0   # the panel's axis it runs along
		for a in 3:
			if to_local.basis[along].abs()[a] > 0.5:
				run = a
		var across := 3 - thin - run
		if run == thin or box.position[across] < -half[across] - 0.05 or box.end[across] > half[across] + 0.05:
			continue
		var from := maxf(box.position[run], -half[run])
		var to := minf(box.end[run], half[run])
		if to - from < 0.1:
			continue
		var skin := box
		skin.position[run] = from
		skin.size[run] = to - from
		# (where that is along the piece: its axis may run the other way)
		var a_end: float = (to_local.affine_inverse() * skin.position)[along]
		var b_end: float = (to_local.affine_inverse() * skin.end)[along]
		spans.append([minf(a_end, b_end), maxf(a_end, b_end), i, skin])
	if spans.is_empty():
		return [piece]
	spans.sort_custom(func(a, b): return a[0] < b[0])
	var left: Array = []
	var at := -size[along] * 0.5
	for span in spans:
		if span[0] < at - 0.01:
			continue   # (two panels over the same stretch: the first has it)
		if span[0] - at > 0.01:
			left.append(_band_part(piece, along, at, span[0]))
		panels[span[2]].skins.append({"kind": piece.kind, "tint": piece.get("tint", Color.WHITE), "box": span[3]})
		at = span[1]
	if size[along] * 0.5 - at > 0.01:
		left.append(_band_part(piece, along, at, size[along] * 0.5))
	return left


## The stretch of `piece` from `from` to `to` along its axis `along` (measured from its
## middle), as a piece.
func _band_part(piece: Dictionary, along: int, from: float, to: float) -> Dictionary:
	var part := piece.duplicate()
	var size: Vector3 = piece.size
	size[along] = to - from
	var shift := Vector3.ZERO
	shift[along] = (from + to) * 0.5
	part["size"] = size
	part["xf"] = (piece.xf as Transform3D) * Transform3D(Basis.IDENTITY, shift)
	return part


## Marks the cells that must not break: near spawns, and under or round other things.
## (Panel by panel, and for each thing only the cells it reaches: a map cut fine has
## thousands of cells.)
func _protect(others: Array, spawn_points: Array, first_cell: int = 0, first_panel: int = 0) -> void:
	# A coarse grid of the other pieces' boxes, so each panel only checks its neighbours.
	var bucket := 4.0
	var grid := {}
	var boxes := []
	for p in others:
		if p.get("hidden", false) and not p.solid:
			continue
		var box: AABB = (p.xf as Transform3D) * AABB(-(p.size as Vector3) * 0.5, p.size)
		if box.size.y < 0.15 and not p.solid:
			continue   # paint and decals hold nothing up
		var lo := Vector3i((box.position / bucket).floor())
		var hi := Vector3i((box.end / bucket).floor())
		if Vector3(hi - lo).length() > 40.0:
			continue   # the ground, the sky box: too big to be resting on a panel
		var id := boxes.size()
		boxes.append(box)
		for x in range(lo.x, hi.x + 1):
			for y in range(lo.y, hi.y + 1):
				for z in range(lo.z, hi.z + 1):
					var key := Vector3i(x, y, z)
					if not grid.has(key):
						grid[key] = []
					grid[key].append(id)
	for index in range(first_panel, panels.size()):
		var panel: Dictionary = panels[index]
		if (panel.piece as Dictionary).get("unguarded", false):
			continue   # (a building held up by its walls: all of it breaks, and what stands on it goes with it)
		var pxf: Transform3D = panel.xf
		var inv := pxf.affine_inverse()
		var pbox: AABB = pxf * AABB(-(panel.size as Vector3) * 0.5, panel.size)
		var first: int = panel.first
		var n: Vector3i = panel.n
		for s in spawn_points:
			var at: Vector3 = s[0]
			var near := AABB(Vector3(at.x - SPAWN_GUARD, at.y - 1.5, at.z - SPAWN_GUARD), Vector3(SPAWN_GUARD * 2.0, 4.5, SPAWN_GUARD * 2.0))
			if not near.intersects(pbox):
				continue
			var reach := _cells_in(panel, inv * near)
			if reach.is_empty():
				continue
			for k in range(reach[0].z, reach[1].z + 1):
				for j in range(reach[0].y, reach[1].y + 1):
					for i in range(reach[0].x, reach[1].x + 1):
						var c := first + i + n.x * (j + n.y * k)
						var box := _frame_box(c)
						var flat := Vector2(clampf(at.x, box.position.x, box.end.x) - at.x, clampf(at.z, box.position.z, box.end.z) - at.z)
						if flat.length() < SPAWN_GUARD and box.end.y > at.y - 1.5 and box.position.y < at.y + 3.0:
							cells[c].protected = true
		if panel.whole:
			continue   # (a whole block breaks even with things on it: they stay put)
		var floor_panel: bool = panel.thin == 1
		var grown := pbox.grow(0.06)
		var lo := Vector3i((grown.position / bucket).floor())
		var hi := Vector3i((grown.end / bucket).floor())
		var checked := {}
		for x in range(lo.x, hi.x + 1):
			for y in range(lo.y, hi.y + 1):
				for z in range(lo.z, hi.z + 1):
					for id: int in grid.get(Vector3i(x, y, z), []):
						if checked.has(id):
							continue
						checked[id] = true
						var other: AABB = boxes[id]
						if not grown.intersects(other):
							continue
						var reach := _cells_in(panel, inv * other.grow(0.06))
						if reach.is_empty():
							continue
						for k in range(reach[0].z, reach[1].z + 1):
							for j in range(reach[0].y, reach[1].y + 1):
								for i in range(reach[0].x, reach[1].x + 1):
									var c := first + i + n.x * (j + n.y * k)
									if c >= first_cell and not cells[c].protected and _holds(_frame_box(c), other, floor_panel):
										cells[c].protected = true


## The cells of a panel that a box (in the panel's own frame) reaches: [first ijk, last
## ijk], or [] if it misses the panel.
func _cells_in(panel: Dictionary, box: AABB) -> Array:
	var half: Vector3 = panel.size * 0.5
	if not AABB(-half, panel.size).intersects(box) and not AABB(-half, panel.size).grow(0.001).intersects(box):
		return []
	var step: Vector3 = panel.cell
	var top: Vector3i = (panel.n as Vector3i) - Vector3i.ONE
	var lo := Vector3i(((box.position + half) / step).floor()).clamp(Vector3i.ZERO, top)
	var hi := Vector3i(((box.end + half) / step).floor()).clamp(Vector3i.ZERO, top)
	return [lo, hi]


## Does `other` rest on this cell, hang from it, or go through it? (What a wall
## stands on does not count: the wall rests on that, not the other way round.)
static func _holds(cell: AABB, other: AABB, floor_panel: bool) -> bool:
	var eps := 0.05
	var grown := cell.grow(eps)
	if not grown.intersects(other):
		return false
	var overlap := grown.intersection(other)
	# Resting on top or hanging underneath (with some real footprint on it).
	var footprint := overlap.size.x > 0.1 and overlap.size.z > 0.1
	if footprint and absf(other.position.y - cell.end.y) <= eps:
		return true
	if floor_panel and footprint and absf(other.end.y - cell.position.y) <= eps:
		return true
	# Through it: the two really overlap (not just touching side by side).
	var inside := cell.intersection(other)
	return inside.size.x > eps and inside.size.y > eps and inside.size.z > eps


## Is the floor that someone at `at` would stand on gone: a floor that breaks, right
## under there, with its piece at that spot broken or fallen? (A spawn point on an upper
## floor is no use once that is so.)
func floor_gone(at: Vector3) -> bool:
	for panel: Dictionary in panels:
		if int(panel.thin) != 1 or panel.whole:
			continue
		var half: Vector3 = (panel.size as Vector3) * 0.5
		var local: Vector3 = _panel_xf(panel).affine_inverse() * at
		if absf(local.x) > half.x or absf(local.z) > half.z or local.y < half.y - 0.2 or local.y > half.y + 1.0:
			continue
		var n: Vector3i = panel.n
		var step: Vector3 = panel.cell
		var i := clampi(int((local.x + half.x) / step.x), 0, n.x - 1)
		var k := clampi(int((local.z + half.z) / step.z), 0, n.z - 1)
		if int(cells[int(panel.first) + i + n.x * n.y * k].stage) >= BROKEN:
			return true
	return false


## A cell's box in the map's frame (around its panel's box: rough for a turned panel),
## where it is right now if it rides a mover.
func cell_box(c: int) -> AABB:
	var cell: Dictionary = cells[c]
	var panel: Dictionary = panels[cell.panel]
	return _panel_xf(panel) * _local_box(panel, cell.ijk)


## The same in its panel's frame: the map's, or its mover's.
func _frame_box(c: int) -> AABB:
	var cell: Dictionary = cells[c]
	var panel: Dictionary = panels[cell.panel]
	return (panel.xf as Transform3D) * _local_box(panel, cell.ijk)


## Where a panel is in the map right now.
func _panel_xf(panel: Dictionary) -> Transform3D:
	var frame := panel.get("frame") as Node3D
	if frame and is_instance_valid(frame):
		return frame.transform * (panel.xf as Transform3D)
	return panel.xf


func cell_center(c: int) -> Vector3:
	return cell_box(c).get_center()


func _local_box(panel: Dictionary, ijk: Vector3i) -> AABB:
	var half: Vector3 = panel.size * 0.5
	var step: Vector3 = panel.cell
	return AABB(-half + Vector3(ijk) * step, step)


## The cell a shot or a blow landed on: `body` is the collider it hit.
func cell_at(body: Object, point: Vector3, normal: Vector3) -> int:
	if body == null or not body.has_meta("panel"):
		return -1
	var panel: Dictionary = panels[int(body.get_meta("panel"))]
	var local: Vector3 = _panel_xf(panel).affine_inverse() * (point - normal * 0.03)
	var ijk: Vector3 = ((local + panel.size * 0.5) / panel.cell).floor()
	var n: Vector3i = panel.n
	var i := Vector3i(clampi(int(ijk.x), 0, n.x - 1), clampi(int(ijk.y), 0, n.y - 1), clampi(int(ijk.z), 0, n.z - 1))
	return panel.first + i.x + n.x * (i.y + n.y * i.z)


## What a cell is made of, for sounds and rubble (a BlockMaterials name).
func material_of(c: int) -> String:
	return panels[cells[c].panel].material


## The cell of the breakable wall or floor whose face is at `point` (a mark's place on
## a surface facing `normal`), or -1.
func cell_near(point: Vector3, normal: Vector3) -> int:
	var at := point - normal * 0.05
	for panel: Dictionary in panels:
		var local: Vector3 = _panel_xf(panel).affine_inverse() * at
		var half: Vector3 = panel.size * 0.5
		if absf(local.x) > half.x or absf(local.y) > half.y or absf(local.z) > half.z:
			continue
		var n: Vector3i = panel.n
		var ijk := Vector3i(((local + half) / (panel.cell as Vector3)).floor()).clamp(Vector3i.ZERO, n - Vector3i.ONE)
		return int(panel.first) + ijk.x + n.x * (ijk.y + n.y * ijk.z)
	return -1


## fine: a shot's path carried on through the walls it is strong enough to go through.
## `legs` is the path so far (Portals.shot_path: [{a, b, dir, hit}], the last one ending
## where it hit the level); legs are added past each wall the round goes through (at
## most MAX_PIERCE), found the same way with `portals`, `mask` and `exclude`. Every leg
## gets `keep` (the share of the round's damage it still has along that leg), `cell`
## (the breakable cell it ended on, or -1) and `wear` (the share of the round's damage
## that cell takes: all of it, or less if the round went on through), and a leg that
## starts on the far side of a wall gets `through`. Nothing is damaged here: the host and a shooter's own copy both
## work the path out this way, and only the host acts on it.
func pierce(space: PhysicsDirectSpaceState3D, legs: Array, weapon: WeaponData, portals: Object = null,
		mask: int = 1, exclude: Array[RID] = []) -> void:   # (portals: the arena's Portals, or null)
	var keep := 1.0
	var gone := 0.0
	var holes := 0
	var i := 0
	while i < legs.size():
		var leg: Dictionary = legs[i]
		i += 1
		leg["keep"] = keep
		leg["cell"] = -1
		leg["wear"] = 1.0
		gone += (leg.a as Vector3).distance_to(leg.b)
		var hit: Dictionary = leg.hit
		if hit.is_empty():
			continue
		var c := cell_at(hit.collider, hit.position, hit.normal)
		leg["cell"] = c
		if c < 0 or not fine or holes >= MAX_PIERCE or i < legs.size():
			continue
		var panel: Dictionary = panels[cells[c].panel]
		if weapon.damage_at(gone) * weapon.structure_damage * keep < float(panel.stop):
			continue
		var dir: Vector3 = leg.dir
		var face: Vector3 = _panel_xf(panel).basis[panel.thin].normalized()
		var thick: float = (panel.size as Vector3)[panel.thin] / maxf(absf(dir.dot(face)), 0.2)
		var left := weapon.max_range - gone - thick
		if left < 0.1:
			continue
		var from: Vector3 = (hit.position as Vector3) + dir * (thick + 0.02)
		leg["wear"] = float(panel.wear)
		keep *= float(panel.keep)
		holes += 1
		gone += thick
		var more: Array
		if portals:
			more = portals.call("shot_path", space, from, dir, left, mask, exclude)
		else:
			var ray := PhysicsRayQueryParameters3D.create(from, from + dir * left, mask, exclude)
			var next := space.intersect_ray(ray)
			more = [{"a": from, "b": from + dir * left if next.is_empty() else next.position, "dir": dir, "hit": next}]
		more[0]["through"] = true
		legs.append_array(more)


# ---------------------------------------------------------------------------
# Damage (host)

## Host: `amount` of damage on cell `c`. Changes go out with the next flush().
func damage(c: int, amount: float) -> void:
	if c < 0 or c >= cells.size():
		return
	var cell: Dictionary = cells[c]
	if cell.protected or cell.stage >= BROKEN:
		return
	if amount < float(panels[cell.panel].armour):
		return   # too weak a hit for this material: a mark at most
	cell.hp = maxf(cell.hp - amount, 0.0)
	var stage := _stage_for(cell)
	if stage != cell.stage:
		_pending[c] = stage


## Host: an explosion at `at` with this weapon's splash: fine, it breaks everything
## near (see BLAST_REACH); else just the piece it landed on (`body`, `normal`: what it hit).
func blast(at: Vector3, weapon: WeaponData, body: Object, normal: Vector3) -> void:
	var amount := weapon.damage * weapon.structure_damage
	if fine and weapon.explosive:
		damage_area(at, weapon.splash_radius * BLAST_REACH, amount)
		for c in root.collapses:
			c.blast(at, weapon.splash_radius * BLAST_REACH, amount)   # (the columns of a building that can come down)
	elif body:
		damage(cell_at(body, at - normal * 0.05, normal), amount)


## Host: a melee blow of `amount` that landed on `body` at `at`: fine, it also damages
## the cells within `reach` metres; else just the piece it landed on.
func blow(body: Object, at: Vector3, normal: Vector3, amount: float, reach: float = BLOW_REACH) -> void:
	var c := cell_at(body, at, normal)
	if c < 0:
		struck(at, minf(amount, 400.0))   # (a column takes a blow as a blow, however hard: a slam that goes through any floor is still one swing)
	if c >= 0 and panels[cells[c].panel].fine and reach > 0.0:
		damage_area(at - normal * 0.03, reach, amount)
	else:
		damage(c, amount)


## Host: a round or a blow of `amount` landed at `point` on something that is not a
## breakable wall: a column of a building that can come down takes it (see MapCollapse).
func struck(point: Vector3, amount: float) -> void:
	for c in root.collapses:
		c.hit(point, amount)


## Host: who is doing the damage that follows, and what with (a collapse's kills are theirs).
func cause(who: int, weapon_id: String) -> void:
	for c in root.collapses:
		c.by = who
		c.with = weapon_id


## Host: a blast or a heavy blow at `at`: every cell within `radius` metres takes
## `amount`, less the further out (nothing at the rim). Changes go out with the next
## flush(), like damage()'s.
func damage_area(at: Vector3, radius: float, amount: float) -> void:
	if radius <= 0.0 or amount <= 0.0:
		return
	for panel: Dictionary in panels:
		var xf := _panel_xf(panel)
		var local: Vector3 = xf.affine_inverse() * at
		var half: Vector3 = panel.size * 0.5
		var nearest := local.clamp(-half, half)
		if nearest.distance_to(local) >= radius:
			continue
		var step: Vector3 = panel.cell
		var n: Vector3i = panel.n
		var lo := Vector3i(((local - Vector3.ONE * radius + half) / step).floor()).clamp(Vector3i.ZERO, n - Vector3i.ONE)
		var hi := Vector3i(((local + Vector3.ONE * radius + half) / step).floor()).clamp(Vector3i.ZERO, n - Vector3i.ONE)
		for k in range(lo.z, hi.z + 1):
			for j in range(lo.y, hi.y + 1):
				for i in range(lo.x, hi.x + 1):
					var from := -half + Vector3(i, j, k) * step
					var d := local.clamp(from, from + step).distance_to(local)
					if d < radius:
						damage(int(panel.first) + i + n.x * (j + n.y * k), amount * (1.0 - d / radius))


static func _stage_for(cell: Dictionary) -> int:
	if cell.hp <= 0.0:
		return BROKEN
	var left: float = cell.hp / cell.max_hp
	return 0 if left > 0.66 else (1 if left > 0.33 else 2)


## Host: the cells that changed since the last flush, as [cells, stages] (empty if none).
func flush() -> Array:
	if _pending.is_empty():
		return []
	var ids := PackedInt32Array()
	var stages := PackedByteArray()
	for c in _pending:
		ids.append(c)
		stages.append(_pending[c])
	_pending.clear()
	return [ids, stages]


## Host: every cell that is not whole, as [cells, stages] (for someone joining late).
func snapshot() -> Array:
	var ids := PackedInt32Array(_damaged.keys())
	ids.sort()   # (the same list on every copy, whatever order the damage arrived in)
	var stages := PackedByteArray()
	stages.resize(ids.size())
	for i in ids.size():
		stages[i] = _damaged[ids[i]]
	return [ids, stages]


# ---------------------------------------------------------------------------
# Every copy: show what the host decided

## Sets cells to the given stages and rebuilds their panels. Returns the cells that
## broke just now (for rubble and sounds).
func apply(ids: PackedInt32Array, stages: PackedByteArray) -> PackedInt32Array:
	var broke := PackedInt32Array()
	var touched := {}
	for i in mini(ids.size(), stages.size()):
		var c := ids[i]
		if c < 0 or c >= cells.size():
			continue
		var cell: Dictionary = cells[c]
		var stage := int(stages[i])
		if stage == cell.stage:
			continue
		var was_gone: bool = cell.stage >= BROKEN
		if stage == BROKEN and not was_gone:
			broke.append(c)
		if stage >= BROKEN:
			cell.hp = 0.0
		elif stage == 0:
			cell.hp = cell.max_hp   # (made whole again: see repair())
		cell.stage = stage
		if stage == 0:
			_damaged.erase(c)
		else:
			_damaged[c] = stage
		# (a fine panel draws its cracks as marks: only a break changes it)
		if not panels[cell.panel].fine or was_gone != (stage >= BROKEN):
			touched[cell.panel] = true
	for p in touched:
		_rebuild_panel(p)
	if not touched.is_empty():
		_revision += 1
	if not ids.is_empty():
		cells_changed.emit(ids, stages)
	if not broke.is_empty() and not _replaying:   # (a killcam playing shows the wall as it was: no rubble from it)
		_break_effects(broke)
	return broke


## Every copy: everything that rides `frame` (a mover's body) is whole again: an island
## that went below the clouds comes back up mended. Nothing is sent: every copy does it
## at the same point of the island's journey. Returns how many cells it mended.
func repair(frame: Node3D) -> int:
	var ids := PackedInt32Array()
	for panel: Dictionary in panels:
		if panel.get("frame") != frame:
			continue
		for c in range(int(panel.first), int(panel.first) + int(panel.n.x * panel.n.y * panel.n.z)):
			var cell: Dictionary = cells[c]
			cell.hp = cell.max_hp   # (host: also what was hit and does not show it yet)
			_pending.erase(c)       # (host: damage done to it on its way down, not yet sent)
			if cell.stage != 0:
				ids.append(c)
	if ids.is_empty():
		return 0
	var stages := PackedByteArray()
	stages.resize(ids.size())   # (all 0: whole)
	apply(ids, stages)
	return ids.size()


## "cracked/broken checksum": the same on every copy that shows the same damage (tests).
func state_key() -> String:
	var snap := snapshot()
	var broken := 0
	for st in (snap[1] as PackedByteArray):
		if st >= BROKEN:
			broken += 1
	return "%d/%d %08x" % [(snap[0] as PackedInt32Array).size() - broken, broken, hash([snap[0], snap[1]])]


func is_broken(c: int) -> bool:
	return cells[c].stage >= BROKEN


func broken_count() -> int:
	var count := 0
	for cell in cells:
		if cell.stage >= BROKEN:
			count += 1
	return count


func breakable_count() -> int:
	var count := 0
	for cell in cells:
		if not cell.protected:
			count += 1
	return count


## Rebuilds one panel's collision (the fewest boxes covering what is left) and its
## meshes (cracked cells darker, skins cut to match).
func _rebuild_panel(index: int) -> void:
	var panel: Dictionary = panels[index]
	var body: StaticBody3D = panel.body
	for child in body.get_children():
		body.remove_child(child)
		child.free()
	var first: int = panel.first
	if panel.whole:
		_rebuild_whole(panel)
		return
	if panel.fine:
		var gone := _fine_gone(panel, false)
		for box in _merge_flat(panel.nu, panel.nv, gone, 0):
			var shape := CollisionShape3D.new()
			var bs := BoxShape3D.new()
			var local := _flat_extent(panel, box)
			bs.size = local.size
			shape.shape = bs
			shape.position = local.get_center()
			body.add_child(shape)
		# The drawing waits for the end of the frame: a burst of breaks redraws it once.
		if is_inside_tree() and not _replaying:
			_dirty[index] = true
			set_process(true)
		else:
			_rebuild_meshes(index)
		return
	var solid := func(c: int) -> int: return 0 if cells[first + c].stage >= BROKEN else 1
	for box in _merge(panel.n, solid):
		var shape := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		var local := _boxes_extent(panel, box)
		bs.size = local.size
		shape.shape = bs
		shape.position = local.get_center()
		body.add_child(shape)
	_rebuild_meshes(index)


## The stage cell `c` is drawn at: its own, or what a killcam playing says it was.
func _shown(c: int) -> int:
	return int(_replay.get(c, 0)) if _replaying else int(cells[c].stage)


## Rebuilds one panel's meshes from the stages its cells are drawn at (see _shown).
func _rebuild_meshes(index: int) -> void:
	var panel: Dictionary = panels[index]
	if panel.whole:
		_rebuild_whole_meshes(panel)
		return
	var first: int = panel.first
	var holder: Node3D = panel.meshes
	for child in holder.get_children():
		holder.remove_child(child)
		child.free()
	_dirty.erase(index)
	if DisplayServer.get_name() == "headless" and not root.has_meshes:
		return
	if panel.has("lot"):
		if not _fine_gone(panel, true).has(1):
			return   # (whole, as it is drawn in its lot: see _draw_lots)
		for at: Array in panel.lot:
			MapMesher.blank(at[0], at[1], at[2])
		panel.erase("lot")
	if panel.fine:
		_fine_meshes(panel)
		return
	var by_stage := func(c: int) -> int: return 0 if _shown(first + c) >= BROKEN else _shown(first + c) + 1
	var pieces := []
	for box in _merge(panel.n, by_stage):
		var local := _boxes_extent(panel, box)
		var shade: float = CRACK_SHADE[box[2] - 1]
		var tint: Color = panel.tint
		pieces.append(painted(panel, {"xf": (panel.xf as Transform3D) * Transform3D(Basis(), local.get_center()), "size": local.size,
			"kind": panel.kind, "shape": "box", "tint": Color(tint.r * shade, tint.g * shade, tint.b * shade, tint.a)}))
		for skin in panel.skins:
			var clipped := _clip_skin(panel, skin.box, local)
			if clipped.has_volume():
				pieces.append({"xf": (panel.xf as Transform3D) * Transform3D(Basis(), clipped.get_center()), "size": clipped.size,
					"kind": skin.kind, "shape": "box", "tint": skin.tint})
	var meshes := MapMesher.build(pieces, root.face_shade)
	for kind in meshes:
		holder.add_child(_drawn(panel, kind, meshes[kind]))


## A whole-block panel: its own shape while it stands (darker as it cracks), nothing
## once broken. (Its children were cleared by _rebuild_panel.)
func _rebuild_whole(panel: Dictionary) -> void:
	var cell: Dictionary = cells[panel.first]
	if cell.stage < BROKEN:
		var piece: Dictionary = (panel.piece as Dictionary).duplicate()
		piece.xf = Transform3D.IDENTITY   # the body sits where the block does
		for lump in root.collision_shapes(piece):
			var shape := CollisionShape3D.new()
			shape.shape = lump
			(panel.body as StaticBody3D).add_child(shape)
	_rebuild_whole_meshes(panel)


func _rebuild_whole_meshes(panel: Dictionary) -> void:
	var holder: Node3D = panel.meshes
	for child in holder.get_children():
		holder.remove_child(child)
		child.free()
	var stage := _shown(panel.first)
	if stage >= BROKEN:
		return
	if DisplayServer.get_name() == "headless" and not root.has_meshes:
		return
	var piece: Dictionary = (panel.piece as Dictionary).duplicate()
	var shade: float = CRACK_SHADE[stage]
	var tint: Color = panel.tint
	piece.xf = panel.xf
	piece.tint = Color(tint.r * shade, tint.g * shade, tint.b * shade, tint.a)
	var meshes := MapMesher.build([piece], root.face_shade)
	for kind in meshes:
		holder.add_child(_drawn(panel, kind, meshes[kind]))


## The cells of a fine panel marked 1 in `keys` (one for each cell across its face), as
## the few boxes they make, with the skins over them cut to match: pieces to draw.
func _flat_pieces(panel: Dictionary, keys: PackedByteArray) -> Array:
	var pieces := []
	var xf: Transform3D = panel.xf
	for box in _merge_flat(panel.nu, panel.nv, keys, 1):
		var local := _flat_extent(panel, box)
		pieces.append(painted(panel, {"xf": xf * Transform3D(Basis(), local.get_center()), "size": local.size,
			"kind": panel.kind, "shape": "box", "tint": panel.tint}))
		for skin in panel.skins:
			var clipped := _clip_skin(panel, skin.box, local)
			if clipped.has_volume():
				pieces.append({"xf": xf * Transform3D(Basis(), clipped.get_center()), "size": clipped.size,
					"kind": skin.kind, "shape": "box", "tint": skin.tint})
	return pieces


## One of a panel's meshes, ready to draw. On a panel that rides a mover the kind's
## pattern is laid out from the mover, like the rest of what rides it (see
## MapRoot._build_mover): measured from the map it would stand still while the wall
## moved through it, and would not meet the pattern on the wall beside it.
func _drawn(panel: Dictionary, kind: String, mesh: ArrayMesh) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	if panel.get("frame") != null:
		node.mesh = MapMesher.riding(mesh)
		node.material_override = root.riding_material_for(kind)
	else:
		node.mesh = mesh
		node.material_override = root.material_for(kind)
	return node


## `piece`, a box of a panel's own kind that is part of how the panel is drawn, with the
## panel's block's painted faces (MapBlock.face_kinds, face_patterns): its faces look the
## way the block's do, so they are painted as the block's are.
static func painted(panel: Dictionary, piece: Dictionary) -> Dictionary:
	var own: Dictionary = panel.piece
	for key in ["face_kinds", "face_patterns", "scale"]:
		if own.has(key):
			piece[key] = own[key]
	return piece


## The part of a skin over these cells: cut along the panel's face, whole across it.
func _clip_skin(panel: Dictionary, skin: AABB, cells_box: AABB) -> AABB:
	var lo := skin.position
	var hi := skin.end
	var half: Vector3 = panel.size * 0.5
	for a in 3:
		if a == panel.thin:
			continue
		# A skin edge on the panel's own edge stays where it is; inside, it follows the cells.
		var c_lo: float = cells_box.position[a] if cells_box.position[a] > -half[a] + 0.001 else -INF
		var c_hi: float = cells_box.end[a] if cells_box.end[a] < half[a] - 0.001 else INF
		lo[a] = maxf(lo[a], c_lo)
		hi[a] = minf(hi[a], c_hi)
		if hi[a] <= lo[a]:
			return AABB()
	return AABB(lo, hi - lo)


func _boxes_extent(panel: Dictionary, box: Array) -> AABB:
	var a: Vector3i = box[0]
	var b: Vector3i = box[1]
	var from := _local_box(panel, a)
	var to := _local_box(panel, b)
	return from.merge(to)


## Greedy merge of a grid of cells into boxes of cells with the same non-zero key:
## [first ijk, last ijk, key] for each box.
static func _merge(n: Vector3i, key_of: Callable) -> Array:
	var count := n.x * n.y * n.z
	var keys := PackedInt32Array()
	keys.resize(count)
	for c in count:
		keys[c] = key_of.call(c)
	var used := PackedByteArray()
	used.resize(count)
	var at := func(i: int, j: int, k: int) -> int: return i + n.x * (j + n.y * k)
	var boxes := []
	for k in n.z:
		for j in n.y:
			for i in n.x:
				var c: int = at.call(i, j, k)
				var key := keys[c]
				if key == 0 or used[c] == 1:
					continue
				var i2 := i
				while i2 + 1 < n.x and keys[at.call(i2 + 1, j, k)] == key and used[at.call(i2 + 1, j, k)] == 0:
					i2 += 1
				var j2 := j
				while j2 + 1 < n.y:
					var ok := true
					for x in range(i, i2 + 1):
						var cc: int = at.call(x, j2 + 1, k)
						if keys[cc] != key or used[cc] == 1:
							ok = false
							break
					if not ok:
						break
					j2 += 1
				var k2 := k
				while k2 + 1 < n.z:
					var ok := true
					for y in range(j, j2 + 1):
						for x in range(i, i2 + 1):
							var cc: int = at.call(x, y, k2 + 1)
							if keys[cc] != key or used[cc] == 1:
								ok = false
								break
						if not ok:
							break
					if not ok:
						break
					k2 += 1
				for z in range(k, k2 + 1):
					for y in range(j, j2 + 1):
						for x in range(i, i2 + 1):
							used[at.call(x, y, z)] = 1
				boxes.append([Vector3i(i, j, k), Vector3i(i2, j2, k2), key])
	return boxes


# ---------------------------------------------------------------------------
# Fine fracture: a panel as cells across its face (nu x nv of them, numbered u first)

func _process(_delta: float) -> void:
	for index in _dirty.keys():
		_rebuild_meshes(index)
	_dirty.clear()
	set_process(false)


## For each cell across a fine panel's face, 1 if it is gone: as the game has it, or
## (`drawn`) as it is drawn (a killcam draws the past).
func _fine_gone(panel: Dictionary, drawn: bool) -> PackedByteArray:
	var nu: int = panel.nu
	var nv: int = panel.nv
	var su: int = panel.su
	var sv: int = panel.sv
	var first: int = panel.first
	var gone := PackedByteArray()
	gone.resize(nu * nv)
	var stages: Dictionary = _replay if drawn and _replaying else _damaged
	if stages.is_empty():
		return gone
	for iv in nv:
		var row := first + iv * sv
		for iu in nu:
			if int(stages.get(row + iu * su, 0)) >= BROKEN:
				gone[iu + nu * iv] = 1
	return gone


## The cells whose key is `want`, merged into as few rectangles as a greedy pass finds:
## [first u, first v, last u, last v] each.
static func _merge_flat(nu: int, nv: int, keys: PackedByteArray, want: int) -> Array:
	var used := PackedByteArray()
	used.resize(nu * nv)
	var boxes := []
	for iv in nv:
		var iu := 0
		while iu < nu:
			var c := iu + nu * iv
			if keys[c] != want or used[c] == 1:
				iu += 1
				continue
			var i2 := iu
			while i2 + 1 < nu and keys[c + i2 + 1 - iu] == want and used[c + i2 + 1 - iu] == 0:
				i2 += 1
			var j2 := iv
			while j2 + 1 < nv:
				var row := nu * (j2 + 1)
				var ok := true
				for x in range(iu, i2 + 1):
					if keys[row + x] != want or used[row + x] == 1:
						ok = false
						break
				if not ok:
					break
				j2 += 1
			for y in range(iv, j2 + 1):
				for x in range(iu, i2 + 1):
					used[x + nu * y] = 1
			boxes.append([iu, iv, i2, j2])
			iu = i2 + 1
	return boxes


## A rectangle of cells (see _merge_flat) as a box in the panel's frame.
func _flat_extent(panel: Dictionary, box: Array) -> AABB:
	var half: Vector3 = panel.size * 0.5
	var step: Vector3 = panel.cell
	var u: int = panel.u
	var v: int = panel.v
	var lo := -half
	var size: Vector3 = panel.size
	lo[u] += box[0] * step[u]
	lo[v] += box[1] * step[v]
	size[u] = (box[2] - box[0] + 1) * step[u]
	size[v] = (box[3] - box[1] + 1) * step[v]
	return AABB(lo, size)


## -1..1 each way, the same on every copy of the game: how far the corner (ju, jv) of
## the panel whose first cell is `first` strays when it is on the edge of a hole.
static func _stray(first: int, ju: int, jv: int) -> Vector2:
	var h := hash(Vector3i(first, ju, jv))
	return Vector2((h & 0xffff) / 32767.5 - 1.0, ((h >> 16) & 0xffff) / 32767.5 - 1.0)


## Draws a fine panel: what is left of it as plain boxes, except the cells round a
## hole, which are drawn one by one with their corners on the hole pushed about, so
## its edge is ragged. (The panel's holder is empty when this is called.)
func _fine_meshes(panel: Dictionary) -> void:
	var gone := _fine_gone(panel, true)
	var nu: int = panel.nu
	var nv: int = panel.nv
	var u: int = panel.u
	var v: int = panel.v
	var t: int = panel.thin
	var xf: Transform3D = panel.xf
	var half: Vector3 = panel.size * 0.5
	var step: Vector3 = panel.cell
	var tint: Color = panel.tint
	var keys := PackedByteArray()   # 0 gone, 1 plain, 2 on the edge of a hole
	keys.resize(nu * nv)
	keys.fill(1)
	var w := nu + 1
	var rag := PackedByteArray()    # corners with a hole on one side and panel on another
	var lo_u := nu
	var hi_u := -1
	var lo_v := nv
	var hi_v := -1
	for iv in nv:
		for iu in nu:
			if gone[iu + nu * iv] == 1:
				keys[iu + nu * iv] = 0
				lo_u = mini(lo_u, iu)
				hi_u = maxi(hi_u, iu)
				lo_v = mini(lo_v, iv)
				hi_v = maxi(hi_v, iv)
	var pieces := []
	var extra := {}   # kind -> [corners, normals, colours] of the ragged cells
	MapMesher._shade = root.face_shade
	MapMesher._shade_basis = Basis()
	if hi_u >= 0:
		rag.resize(w * (nv + 1))
		for jv in range(lo_v, hi_v + 2):
			for ju in range(lo_u, hi_u + 2):
				var some_gone := false
				var some_left := false
				for dv in 2:
					var cv := jv - dv
					if cv < 0 or cv >= nv:
						continue
					for du in 2:
						var cu := ju - du
						if cu < 0 or cu >= nu:
							continue
						if gone[cu + nu * cv] == 1:
							some_gone = true
						else:
							some_left = true
				if some_gone and some_left:
					rag[ju + w * jv] = 1
		var stray: Vector2 = panel.jitter
		var first: int = panel.first
		for iv in range(maxi(lo_v - 1, 0), mini(hi_v + 2, nv)):
			for iu in range(maxi(lo_u - 1, 0), mini(hi_u + 2, nu)):
				var c := iu + nu * iv
				if keys[c] == 0:
					continue
				if rag[iu + w * iv] == 0 and rag[iu + 1 + w * iv] == 0 and rag[iu + w * (iv + 1)] == 0 and rag[iu + 1 + w * (iv + 1)] == 0:
					continue
				keys[c] = 2
				# Its four corners across the face, going round, strayed where they are on a hole.
				var flat := PackedVector2Array()
				for k in 4:
					var ju: int = iu + (1 if k == 1 or k == 2 else 0)
					var jv: int = iv + (1 if k >= 2 else 0)
					var at := Vector2(-half[u] + ju * step[u], -half[v] + jv * step[v])
					if rag[ju + w * jv] == 1:
						var by := _stray(first, ju, jv)
						if ju > 0 and ju < nu:
							at.x += by.x * stray.x * step[u]
						if jv > 0 and jv < nv:
							at.y += by.y * stray.y * step[v]
					flat.append(at)
				# The panel itself, and any skin that covers this whole cell, as layers through it.
				var layers := [[panel.kind, tint, -half[t], half[t]]]
				var cell_lo := Vector2(-half[u] + iu * step[u], -half[v] + iv * step[v])
				for skin in panel.skins:
					var sb: AABB = skin.box
					if sb.end[u] <= cell_lo.x or sb.position[u] >= cell_lo.x + step[u] or sb.end[v] <= cell_lo.y or sb.position[v] >= cell_lo.y + step[v]:
						continue
					if sb.position[u] <= cell_lo.x + 0.01 and sb.end[u] >= cell_lo.x + step[u] - 0.01 \
							and sb.position[v] <= cell_lo.y + 0.01 and sb.end[v] >= cell_lo.y + step[v] - 0.01:
						layers.append([skin.kind, skin.tint, sb.position[t], sb.end[t]])
					else:   # only part of the cell: that part, square
						var cell_box := AABB(-half, panel.size)
						cell_box.position[u] = cell_lo.x
						cell_box.position[v] = cell_lo.y
						cell_box.size[u] = step[u]
						cell_box.size[v] = step[v]
						cell_box.position[t] = sb.position[t]
						cell_box.size[t] = sb.size[t]
						var part := cell_box.intersection(sb)
						if part.has_volume():
							pieces.append({"xf": xf * Transform3D(Basis(), part.get_center()), "size": part.size,
								"kind": skin.kind, "shape": "box", "tint": skin.tint})
				# Which of its four sides are open: on a hole (drawn dark, as a broken edge) or on the panel's rim.
				var open := [0, 0, 0, 0]
				var beside := [[iu, iv - 1], [iu + 1, iv], [iu, iv + 1], [iu - 1, iv]]
				for k in 4:
					var bu: int = beside[k][0]
					var bv: int = beside[k][1]
					if bu < 0 or bv < 0 or bu >= nu or bv >= nv:
						open[k] = 1
					elif gone[bu + nu * bv] == 1:
						open[k] = 2
				for li in layers.size():
					var layer: Array = layers[li]
					# (The panel's own layer has its block's painted faces: a face goes in its
					# painted kind's buffer, with its pattern. A skin's, none.)
					var own: Dictionary = panel.piece if li == 0 else {}
					var colour: Color = layer[1]
					var near := []
					var far := []
					for k in 4:
						var a := Vector3.ZERO
						a[u] = flat[k].x
						a[v] = flat[k].y
						a[t] = layer[3]
						near.append(a)
						a[t] = layer[2]
						far.append(a)
					var out := Vector3.ZERO
					out[t] = 1.0
					MapMesher._flat(MapMesher.face_buffer(extra, own, layer[0], out), xf, near, out, colour)
					MapMesher._flat(MapMesher.face_buffer(extra, own, layer[0], -out), xf, far, -out, colour)
					for k in 4:
						if open[k] == 0:
							continue
						var k2 := (k + 1) % 4
						var along: Vector2 = flat[k2] - flat[k]
						var side := Vector3.ZERO   # square to the edge, away from the cell
						side[u] = along.y
						side[v] = -along.x
						var mid: Vector2 = (flat[0] + flat[1] + flat[2] + flat[3]) * 0.25
						if Vector2(side[u], side[v]).dot((flat[k] + flat[k2]) * 0.5 - mid) < 0.0:
							side = -side
						var shade := CUT_SHADE if open[k] == 2 else 1.0
						MapMesher._flat(MapMesher.face_buffer(extra, own, layer[0], side.normalized()), xf, [far[k], far[k2], near[k2], near[k]],
							side.normalized(), Color(colour.r * shade, colour.g * shade, colour.b * shade, colour.a))
	pieces.append_array(_flat_pieces(panel, keys))
	var holder: Node3D = panel.meshes
	var meshes := MapMesher.build(pieces, root.face_shade)
	for kind in extra:
		var arrays := MapMesher.surface_arrays(extra[kind])
		var ragged := ArrayMesh.new()
		ragged.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, MapMesher.surface_flags(arrays))
		meshes[kind + " "] = ragged   # (its own mesh beside the kind's boxes)
	for key: String in meshes:
		holder.add_child(_drawn(panel, key.strip_edges(), meshes[key]))


# ---------------------------------------------------------------------------
# Killcams (see MapReplay): the walls as they were. Only what is drawn changes: the
# collision stays the live one (the match goes on round a death killcam).

## Every cell that is not whole, as [cells, stages]: the same array until one changes.
func replay_capture() -> Variant:
	if _captured_rev != _revision:
		_captured = snapshot()
		_captured_rev = _revision
	return _captured


## Draws the cells as `state` (a replay_capture()) has them. A cell that breaks as the
## replay plays on crashes and drops its rubble, as it did in the match.
func replay_show(state: Variant, _next: Variant, _u: float, _holder: Node3D) -> void:
	if not state is Array or (state as Array).size() < 2 or (_replaying and is_same(state, _replay_of)):
		return
	_replay_of = state
	var want := {}
	var ids: PackedInt32Array = state[0]
	var stages: PackedByteArray = state[1]
	for i in mini(ids.size(), stages.size()):
		if ids[i] >= 0 and ids[i] < cells.size():
			want[ids[i]] = int(stages[i])
	for c in _damaged:
		if int(_damaged[c]) == FALLEN:
			want[c] = FALLEN   # (what came down with a building stays down: its pieces are not replayed)
	var before := _replay if _replaying else _live_damage()
	var touched := {}
	var broke := PackedInt32Array()
	for c in want:
		var was := int(before.get(c, 0))
		if int(want[c]) != was:
			if not panels[cells[c].panel].fine or (int(want[c]) >= BROKEN) != (was >= BROKEN):
				touched[cells[c].panel] = true
			if _replaying and int(want[c]) == BROKEN and was < BROKEN:
				broke.append(c)
	for c in before:
		if not want.has(c) and (not panels[cells[c].panel].fine or int(before[c]) >= BROKEN):
			touched[cells[c].panel] = true
	if _replaying and touched.is_empty():
		return
	_replaying = true
	_replay = want
	for p in touched:
		_rebuild_meshes(p)
	if not broke.is_empty():
		_break_effects(broke)


## Back to drawing the live damage.
func replay_clear() -> void:
	if not _replaying:
		return
	var shown := _replay
	_replaying = false
	_replay = {}
	_replay_of = null
	var touched := {}
	for c in shown:
		if int(shown[c]) != int(cells[c].stage) and _redraws(c, int(shown[c]), int(cells[c].stage)):
			touched[cells[c].panel] = true
	for c in _live_damage():
		if int(shown.get(c, 0)) != int(cells[c].stage) and _redraws(c, int(shown.get(c, 0)), int(cells[c].stage)):
			touched[cells[c].panel] = true
	for p in touched:
		_rebuild_meshes(p)


func _live_damage() -> Dictionary:
	return _damaged.duplicate()


## Does cell `c` look different at stage `a` and at stage `b`? (A fine panel only when
## the cell is there in one and gone in the other.)
func _redraws(c: int, a: int, b: int) -> bool:
	return not panels[cells[c].panel].fine or (a >= BROKEN) != (b >= BROKEN)


# ---------------------------------------------------------------------------
# Rubble and sound

func _break_effects(broke: PackedInt32Array) -> void:
	var flying := PackedInt32Array()   # fine cells: their rubble is MapDebris's
	for c in broke:
		if root.debris and panels[cells[c].panel].fine:
			flying.append(c)
			continue
		var at := cell_center(c)
		var mat := material_of(c)
		var sound := get_node_or_null("/root/Sound")   # (not there in map-only tests)
		var info := BlockMaterials.info(mat)
		if sound:
			var p = sound.play_at(info.break, at, "body", 0.0, 0.08)
			if p:
				p.pitch_scale *= info.break_pitch
		if DisplayServer.get_name() == "headless":
			continue
		_rubble(c, mat)
	if not flying.is_empty():
		root.debris.broke(flying)


func _rubble(c: int, mat: String) -> void:
	var panel: Dictionary = panels[cells[c].panel]
	var box := cell_box(c)
	var info := BlockMaterials.info(mat)
	var shards: bool = info.shards
	# A whole block can be much bigger than a cell: more bits, up to three times.
	var count := int(info.debris * clampf(box.get_volume() / (CELL * CELL * 0.3), 1.0, 3.0))
	var material := root.material_for(panel.kind)
	for i in count:
		if _debris >= MAX_DEBRIS:
			return
		var bit := RigidBody3D.new()
		bit.collision_layer = 0
		bit.collision_mask = 1   # lands on the level, never on players
		var mesh := MeshInstance3D.new()
		var shape := BoxMesh.new()
		var thick: float = (panel.size as Vector3)[panel.thin]
		var s := randf_range(0.07, 0.2) * CELL
		shape.size = Vector3(s, s, s) * Vector3(randf_range(0.5, 1.0), randf_range(0.5, 1.0), randf_range(0.5, 1.0))
		if shards:
			shape.size.y = maxf(thick, 0.03)   # flat shards
		else:
			shape.size = shape.size.min(Vector3.ONE * maxf(thick, 0.1) * 1.5)
		mesh.mesh = shape
		mesh.material_override = material
		bit.add_child(mesh)
		var col := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = shape.size
		col.shape = bs
		bit.add_child(col)
		add_child(bit)
		bit.global_position = Vector3(randf_range(box.position.x, box.end.x), randf_range(box.position.y, box.end.y), randf_range(box.position.z, box.end.z))
		bit.rotation = Vector3(randf() * TAU, randf() * TAU, randf() * TAU)
		bit.linear_velocity = Vector3(randf_range(-2.5, 2.5), randf_range(0.5, 3.5), randf_range(-2.5, 2.5))
		bit.angular_velocity = Vector3(randf_range(-6, 6), randf_range(-6, 6), randf_range(-6, 6))
		_debris += 1
		var tween := bit.create_tween()
		tween.tween_interval(randf_range(2.0, 3.0))
		tween.tween_property(mesh, "scale", Vector3.ONE * 0.01, 0.4)
		tween.tween_callback(func():
			_debris -= 1
			bit.queue_free())
	_dust(box.get_center(), mat)


func _dust(at: Vector3, mat: String) -> void:
	var puff := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = CELL * 0.3
	sphere.height = CELL * 0.6
	sphere.radial_segments = 10
	sphere.rings = 5
	puff.mesh = sphere
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = BlockMaterials.info(mat).dust
	puff.material_override = m
	puff.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(puff)
	puff.global_position = at
	var tween := puff.create_tween().set_parallel()
	tween.tween_property(puff, "scale", Vector3.ONE * 1.8, 0.9)
	tween.tween_property(puff, "transparency", 1.0, 0.9)
	tween.chain().tween_callback(puff.queue_free)
