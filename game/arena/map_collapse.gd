class_name MapCollapse
extends Node3D
## A building that comes down when what holds it up is blown out (see MapFrame, which
## says where the building is). MapRoot makes one (`collapse`) on a map with fine
## destruction and a MapFrame.
##
## The frame is columns on a grid and a floor at each level. A "bay" is the square of
## floor between four columns; a "unit" is one bay at one level: its slab, and the walls
## and things that stand on it. Each storey of each column takes damage (explosives,
## heavy rounds, a hammer: small arms only mark it). When a bay's outer corner column,
## or any two of its columns, are gone at or below a level, that unit and every unit
## above it in the bay fall. A bay round the core (MapFrame.core) never does.
##
## What falls is simulated, not played back: after a short warning the units are cut
## into pieces (the slabs and walls along their own fine cells, so nothing looks
## different until it lets go) and every copy of the game runs them as rigid bodies.
## Two machines do not land a pile the same way on their own, so the host tells the
## others where its pieces are as they fall (the big ones ten times a second, the small
## ones five, and only those that moved), each copy pulls its own toward that, and where
## the host's pieces come to rest is final: everyone's slide to it, and the pile becomes
## part of the level.
##
## A building with no columns stands on its walls (MapFrame.held_by_walls): then each
## crossing of the frame's lines that has breakable wall near it has, for a column, that
## stretch of wall, a storey at a time, and the storey is gone once enough of the wall
## is broken. Nothing else about the rule changes.
##
## A building on something that moves (a MapFrame inside a MapIsland) has its collapse
## as a child of the mover's body (`on`), and everything here is then in the mover's own
## frame: the pieces fall, are told of and come to rest where the island is, and the
## pile rides it. An island that is mended (MapRoot.mend) gets its building back.
##
## The host decides everything: damage(), blast() and hit() are host calls, flush()
## gives what changed for it to tell everyone, and apply_columns(), start(), news() and
## rest() are what every copy does with that.

## Parts of the level went or came to rest (`boxes`: Array of AABB): what hangs on them
## (portals, grapples) lets go, and the bots' navigation is redone.
signal changed(boxes: Array)
## Host: where its pieces are, for the other copies (see news()).
signal news_out(id: int, age: float, data: PackedByteArray)
## Host: the pieces of collapse `id` have come to rest here (see rest()).
signal rest_out(id: int, data: PackedByteArray)
## A collapse has come to rest and is part of the level. `key`: what its pile is, in
## short (two copies with the same pile have the same key).
signal settled(id: int, key: String)

const WARNING := 1.5          ## seconds between the news of a collapse and the first piece letting go
const SPREAD := 16.0          ## metres a second: how fast letting go runs out along a floor from the lost column
const RISE := 9.0             ## metres a second: how fast it climbs the building (a floor lets go a little after the one under it)
const BIG := 0.5              ## cubic metres: a piece this big or bigger is "big"
const BIG_HZ := 10.0          ## host: news of a big piece this often
const SMALL_HZ := 5.0         ## ...and of a small one
const MOVED := 0.02           ## host: no news of a piece that moved less than this (metres)
const TURNED := 0.03          ## ...and turned less than this (radians)
const NEWS_BYTES := 1000      ## host: about how big one message of news is
const NEWS_RATE := 25000.0    ## host: bytes of news a second at most, for each player
const NEWS_EVERY := 4         ## host: news goes out every this many physics steps (30 times a second)
const REST_AFTER := 15.0      ## seconds after the first piece lets go: the host calls it over, unless something is still falling
const REST_LATEST := 22.0     ## ...and by now whatever is going on
const CALM_AFTER := 8.0       ## seconds after the first piece lets go: what still moves is slowed, so the pile comes to rest
const SLIDE := 0.5            ## seconds every copy takes to slide its pieces to where the host's rest
const TINY := 0.004           ## cubic metres: a loose thing smaller than this just goes
const DESTROYED := 3          ## a column storey's stages: 0 whole, 1 cracked, 2 badly cracked, 3 gone
const CRUSH_SPEED := 3.0      ## metres a second down: a big piece falling this fast kills who it lands on
const BUILD_MS := 3.0         ## milliseconds a frame spent making pieces during the warning
const LOT_BAYS := 8           ## a building held up by its walls draws its loose things in lots this many bays a side (see _lot_of)
const HISTORY := 24           ## what each copy remembers of its own pieces: this many samples...
const HISTORY_HZ := 30.0      ## ...this often
const TOPPLE := 2.0           ## metres a second: how hard a piece of a building held up by its walls is tipped outwards as it lets go
const TOPPLE_TURN := 1.2      ## ...and radians a second
const EVENTS_EACH := 100000   ## a collapse's events are numbered from its `index` times this: the number says whose it is
const BUCKET := 5.0           ## metres: the size of the buckets things and panels are found by (see _take_rests)
const SPAN_SHARE := 0.15      ## a bridge that caves in takes down the bays that this much of it is in
const CAVE_CELLS := 16        ## a floor with fewer cells than this in a bay does not cave in (MapFrame.cave_share), unless the bay has no wall of its own
const WALL_CELLS := 30        ## a stretch of wall with fewer cells that can break than this holds nothing up (a sliver beside a door)
## Square metres of slab or wall to a piece, by what it is made of.
const PIECE_AREA := {"concrete": 5.0, "masonry": 1.6, "wood": 2.2, "sheet": 2.5}
const DENSITY := {"concrete": 2400.0, "masonry": 1400.0, "wood": 600.0, "sheet": 300.0}

enum { WAITING, FALLING, SLIDING, DOWN }
enum { COLUMNS = 1, LOOSE = 2 }


## What a copy remembers of its own pieces in one collapse (see _remember).
class Memory:
	var ages := PackedFloat32Array()
	var hist := PackedFloat32Array()
	var next := 0

## What of a pile is drawn with one material (see _gather): for each vertex where it
## is, how it faces, its colour, and where it was and how it faced before the fall.
class Lot:
	var material: Material
	var shadows := GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	var at := PackedVector3Array()
	var facing := PackedVector3Array()
	var colours := PackedColorArray()
	var was_at := PackedVector3Array()
	var was_facing := PackedVector3Array()


var root: MapRoot
var breaks: MapDestruction
var frame: MapFrame
## The mover's body this building rides (it is this node's parent), or null: it stands
## on the map. With one, every place in here is in that body's frame.
var on: Node3D = null
## Its number among the map's collapses (MapRoot.collapses).
var index := 0
## Host: who is doing the damage now, and what with (who a collapse's kills go to).
var by := 0
var with := ""

## Every storey of every column: {col: Vector2i, storey, box: AABB, hp, max_hp, stage,
## fallen: bool, body: StaticBody3D, piece}. A stretch of wall that stands in for one
## (MapFrame.held_by_walls) has no body or piece, and `cells`: the wall's cells.
var segments: Array = []
## Every bay: {i, j, x0, x1, z0, z1, fixed, corner: Vector2i (-1, -1: none), cols: [Vector2i],
## from: the lowest level that has fallen or is about to (levels(): none), shown: the
## lowest that has let go (its loose things are there until then),
## loose: [pieces, by level], node}.
var bays: Array = []
## Every collapse so far: see start().
var events: Array = []

var _lines_x := PackedFloat32Array()
var _lines_z := PackedFloat32Array()
var _tops := PackedFloat32Array()
var _columns := {}        # Vector2i -> [segment index by storey, -1: none]
var _unit_cells := {}     # unit -> PackedInt32Array (breakable cells in it)
var _unit_floor := {}     # (held by walls) unit -> PackedInt32Array: the cells of its floor (the slab its walls hold up)
var _floor_of := {}       # ...and each of those cells -> its unit
var _span_units := {}     # ...and for a floor that spans open space (MapFrame.spans: a bridge), its panel -> {each unit it is in: how many of its cells}
var _weak := {}           # host: the units whose floor has lost enough of itself to cave in
var _pending := {}        # host: segment -> its new stage
var _wall_of := {}        # a wall's cell -> the segment it is part of
var _slab := 0.45         # how far below a level's top the level starts (the frame's slab; 0 to the ground)
var _shift := 0           # a column storey holds up the levels from its own number less this (1 to the ground)
var _rests_of := {}       # a cell -> the loose things that stand on it or hang from it (see _take_rests)
var _losing := {}         # the bays where some loose thing has gone, or come back (then true), since they were last built
var _gone := []           # ...and the things that went (see _hide)
var _letting_go := false  # a collapse is marking its cells fallen right now
var _restoring := false   # a collapse that began before this copy joined is being put as the host has it
var _parked := false
var _next_id := 1
var _tick := 0
var _standing: Node3D = null   # what stands, drawn (see _draw_standing): holds the lots
var _lots := {}                # a lot of loose things (see _lot_of) -> its drawing (a node: see _lot_mesh)
var _stale := {}               # the lots to draw again
var _columns_drawn: Node3D     # ...and of its column storeys
var _redraw := 0               # which of the two has lost something since (COLUMNS, LOOSE)


# ---------------------------------------------------------------------------
# Building

## Takes the building's own blocks out of `pieces` (the rest come back: the map builds
## those as ever): its columns, a storey at a time, and what stands on its floors, a bay
## at a time, so that a bay can go without the map being built again.
func setup(map: MapRoot, f: MapFrame, pieces: Array, body: Node3D = null) -> Array:
	root = map
	breaks = map.destruction
	frame = f
	on = body
	name = "Collapse"
	_next_id = index * EVENTS_EACH + 1
	_lines_x = f.lines_x
	_lines_z = f.lines_z
	_tops = f.floor_tops
	_slab = f.slab
	_shift = 0
	if f.held_by_walls and f.to_the_ground:
		# The ground floor is a level too, and a level is a storey's walls with the slab
		# they hold up (not a slab with what stands on it): the storey whose wall goes
		# comes down with everything above it, and the floor it stood on stays.
		_tops = PackedFloat32Array([f.ground])
		_tops.append_array(f.floor_tops)
		_slab = 0.0
		_shift = 1
	var nx := _lines_x.size() - 1
	var nz := _lines_z.size() - 1
	if nx < 1 or nz < 1 or _tops.is_empty():
		return pieces
	var spans := []   # the parts that span open space at the ground floor's height (MapFrame.spans)
	if _shift == 1:
		for path in f.spans:
			if f.get_node_or_null(path):
				spans.append(f.get_node(path))
	for j in nz:
		for i in nx:
			var x0 := _lines_x[i] - (f.overhang if i == 0 else 0.0)
			var x1 := _lines_x[i + 1] + (f.overhang if i == nx - 1 else 0.0)
			var z0 := _lines_z[j] - (f.overhang if j == 0 else 0.0)
			var z1 := _lines_z[j + 1] + (f.overhang if j == nz - 1 else 0.0)
			var fixed := f.core.size != Vector3.ZERO and f.core.position.x < x1 and f.core.end.x > x0 \
				and f.core.position.z < z1 and f.core.end.z > z0
			var corner := Vector2i(-1, -1)
			if (i == 0 or i == nx - 1) and (j == 0 or j == nz - 1):
				corner = Vector2i(0 if i == 0 else nx, 0 if j == 0 else nz)
			var loose := []
			for l in levels():
				loose.append([])
			bays.append({"i": i, "j": j, "x0": x0, "x1": x1, "z0": z0, "z1": z1, "fixed": fixed, "corner": corner,
				"cols": [Vector2i(i, j), Vector2i(i + 1, j), Vector2i(i, j + 1), Vector2i(i + 1, j + 1)],
				"from": levels(), "shown": levels(), "loose": loose, "node": null})
	var rest := []
	var mine := []          # the building's own loose things
	var solid_in := {}      # group -> its solid pieces
	for piece: Dictionary in pieces:
		if piece.get("frame") != frame:
			rest.append(piece)
		elif not _take_column(piece):
			mine.append(piece)
			if piece.solid and piece.has("group"):
				(solid_in.get_or_add(piece.group, []) as Array).append(piece)
	# What is only drawn, on a solid thing of its own group, goes with that thing: a
	# girder is one solid block and the flanges and web drawn on it, and it falls whole.
	var alone := []
	for piece: Dictionary in mine:
		var on: Dictionary = {}
		if not piece.solid:
			var at: Vector3 = (piece.xf as Transform3D).origin
			for other: Dictionary in solid_in.get(piece.get("group", 0), []):
				var local := (other.xf as Transform3D).affine_inverse() * at
				var reach: Vector3 = (other.size as Vector3) * 0.5 + Vector3.ONE * 0.35
				if absf(local.x) <= reach.x and absf(local.y) <= reach.y and absf(local.z) <= reach.z:
					on = other
					break
		if on.is_empty():
			alone.append(piece)
		else:
			(on.get_or_add("with", []) as Array).append(piece)
	if f.held_by_walls:
		# (Its cornices, bands and parapets run the length of the building: each bay has its stretch.)
		var cut := []
		for piece: Dictionary in alone:
			cut.append_array(_by_bay(piece))
		alone = cut
	var loose_n := 0
	for piece: Dictionary in alone:
		var xf: Transform3D = piece.xf
		var size: Vector3 = piece.size
		var at := xf.origin
		# (Something tall belongs to the floor it stands on, not the one its middle is by.)
		var up := 0.5 * (absf(xf.basis.x.y) * size.x + absf(xf.basis.y.y) * size.y + absf(xf.basis.z.y) * size.z)
		var b := bay_at(at)
		if b < 0 and f.held_by_walls:
			b = _bay_near(at)   # (a porch, an awning: it is part of the bay it stands against)
		var level := level_at(at.y - up + 0.3 if up > 1.0 else at.y)
		if level < 0 and spans.has(piece.get("part")) and at.y > _tops[0] - 1.5:
			level = 0   # (a lamp under a bridge at the height of the ground floor)
		if b < 0 or level < 0 or bays[b].fixed:
			rest.append(piece)
			rest.append_array(piece.get("with", []))
			piece.erase("with")
		else:
			piece["unit"] = unit_of(b, level)
			piece["lid"] = loose_n
			loose_n += 1
			(bays[b].loose[level] as Array).append(piece)
	for b in bays.size():
		_build_bay(b)
	_redraw = COLUMNS | LOOSE
	_draw_standing()
	if breaks:
		var by_unit := {}   # unit -> [cells]
		var floors := {}    # unit -> [cells of its floor]
		for panel: Dictionary in breaks.panels:
			if (panel.piece as Dictionary).get("frame") != frame:
				continue
			var xf: Transform3D = panel.xf
			var n: Vector3i = panel.n
			var step: Vector3 = panel.cell
			var half: Vector3 = (panel.size as Vector3) * 0.5
			var c: int = panel.first
			var span := spans.has((panel.piece as Dictionary).get("part"))
			for k in n.z:
				for j in n.y:
					for i in n.x:
						var at := xf * (-half + (Vector3(i, j, k) + Vector3(0.5, 0.5, 0.5)) * step)
						var b := bay_at(at)
						var level := level_at(at.y)
						if level < 0 and span and at.y > _tops[0] - 1.0:
							level = 0   # (a bridge at the height of the ground floor: it is the ground storey's)
						if b >= 0 and level >= 0 and not bays[b].fixed:
							var unit := unit_of(b, level)
							if not by_unit.has(unit):
								by_unit[unit] = []
							(by_unit[unit] as Array).append(c)
							if f.held_by_walls and int(panel.thin) == 1 and panel.fine:
								(floors.get_or_add(unit, []) as Array).append(c)
								_floor_of[c] = unit
								if span:
									var into: Dictionary = _span_units.get_or_add(int(breaks.cells[c].panel), {})
									into[unit] = int(into.get(unit, 0)) + 1
						c += 1
		for unit: int in by_unit:
			_unit_cells[unit] = PackedInt32Array(by_unit[unit])
			if floors.has(unit):
				_unit_floor[unit] = PackedInt32Array(floors[unit])
		if f.held_by_walls:
			_take_walls()
			_take_rests()
			breaks.cells_changed.connect(_on_cells_changed)
	return rest


## A long box that lies square to the lines, cut where it crosses them, so that each
## bay has its own stretch of it (anything else: as it is).
func _by_bay(piece: Dictionary) -> Array:
	if not (piece.get("shape", "") in ["box", "bevel"]) or piece.has("with"):
		return [piece]
	var parts := [piece]
	for world in [0, 2]:
		var lines := _lines_x if world == 0 else _lines_z
		var next := []
		for part: Dictionary in parts:
			var xf: Transform3D = part.xf
			var size: Vector3 = part.size
			var along := -1
			for a in 3:
				if absf(xf.basis[a][world]) > 0.999:
					along = a
			if along < 0:
				return [piece]   # (not square to the lines)
			var way := signf(xf.basis[along][world])
			var cuts := PackedFloat32Array()   # along it, from its middle
			for n in range(1, lines.size() - 1):
				var t := (lines[n] - xf.origin[world]) * way
				if absf(t) < size[along] * 0.5 - 0.05:
					cuts.append(t)
			if cuts.is_empty():
				next.append(part)
				continue
			cuts.sort()
			cuts.append(size[along] * 0.5)
			var from := -size[along] * 0.5
			for to in cuts:
				var stretch := part.duplicate()
				var shift := Vector3.ZERO
				shift[along] = (from + to) * 0.5
				var cut_size := size
				cut_size[along] = to - from
				stretch["size"] = cut_size
				stretch["xf"] = xf * Transform3D(Basis.IDENTITY, shift)
				next.append(stretch)
				from = to
		parts = next
	return parts


## A building held up by its walls: for each crossing of the lines, a storey at a time,
## the cells of its breakable upright walls within reach of the crossing. A stretch
## with enough of them is that crossing's column there.
func _take_walls() -> void:
	var reach := frame.wall_reach
	var found := {}   # Vector3i(crossing x, crossing z, storey) -> [cells]
	for panel: Dictionary in breaks.panels:
		if (panel.piece as Dictionary).get("frame") != frame or not panel.fine or int(panel.thin) == 1 \
				or panel.material == "glass":
			continue
		var xf: Transform3D = panel.xf
		var n: Vector3i = panel.n
		var step: Vector3 = panel.cell
		var half: Vector3 = (panel.size as Vector3) * 0.5
		var c: int = panel.first
		for k in n.z:
			for j in n.y:
				for i in n.x:
					var at := xf * (-half + (Vector3(i, j, k) + Vector3(0.5, 0.5, 0.5)) * step)
					var storey := -1
					for s in levels():
						if storey < 0 and at.y < _tops[s] - _slab:
							storey = s
					if storey >= 0 and not breaks.cells[c].protected:
						# (the nearest crossing, if it is near enough: the nearest line each way)
						var best := Vector2i(-1, -1)
						var nearest := reach
						for a in _lines_x.size():
							var d := absf(at.x - _lines_x[a])
							if d <= nearest:
								nearest = d
								best.x = a
						nearest = reach
						for b in _lines_z.size():
							var d := absf(at.z - _lines_z[b])
							if d <= nearest:
								nearest = d
								best.y = b
						if best.x >= 0 and best.y >= 0:
							(found.get_or_add(Vector3i(best.x, best.y, storey), []) as Array).append(c)
					c += 1
	var keys := found.keys()
	keys.sort()
	for key: Vector3i in keys:
		var cells: Array = found[key]
		if cells.size() < WALL_CELLS:
			continue
		var col := Vector2i(key.x, key.y)
		if not _columns.has(col):
			var none := []
			none.resize(levels())
			none.fill(-1)
			_columns[col] = none
		if int(_columns[col][key.z]) >= 0:
			continue   # (a real column stands there)
		var box := AABB()
		for n in cells.size():
			var cell_box := _cell_box(cells[n])
			box = cell_box if n == 0 else box.merge(cell_box)
			_wall_of[cells[n]] = segments.size()
		_columns[col][key.z] = segments.size()
		segments.append({"col": col, "storey": key.z, "box": box, "hp": 1.0, "max_hp": 1.0, "stage": 0, "fallen": false,
			"body": null, "piece": {}, "cells": PackedInt32Array(cells)})


## A building held up by its walls keeps none of its walls and floors from breaking
## (see MapDestruction._protect): instead each loose thing in it knows the cells it
## stands on, or failing that the cells it hangs from or is set in (`rests`), and goes
## when enough of them have (see _on_cells_changed). What stands on the ground has
## none; what stands on another thing goes with that.
func _take_rests() -> void:
	_rests_of = {}
	# (In buckets: a tier of a tower has hundreds of panels and thousands of things.)
	var mine := []   # the panels a thing here can rest on: [panel, its box here]
	var panel_buckets := {}
	for panel: Dictionary in breaks.panels:
		var piece: Dictionary = panel.piece
		# (This building's, and any other's that it touches: a lamp hangs from the floor of the building above.)
		if piece.get("frame") == frame or (piece.get("unguarded", false) and panel.get("frame") == on):
			var reach := (panel.xf as Transform3D) * AABB(-(panel.size as Vector3) * 0.5, panel.size)
			_bucket(panel_buckets, reach.grow(0.1), mine.size())
			mine.append([panel, reach])
	var all := []   # [piece, its box]
	var thing_buckets := {}
	for bay: Dictionary in bays:
		for level: Array in bay.loose:
			for piece: Dictionary in level:
				var box := (piece.xf as Transform3D) * AABB(-(piece.size as Vector3) * 0.5, piece.size)
				_bucket(thing_buckets, box.grow(0.15), all.size())
				all.append([piece, box])
	for n in all.size():
		all[n][0]["rid"] = n
	for entry: Array in all:
		var piece: Dictionary = entry[0]
		var box: AABB = entry[1]
		var stands := []
		var hangs := []
		var reach := box.grow(0.08)
		for m: int in _bucketed(panel_buckets, reach):
			var pair: Array = mine[m]
			if not (pair[1] as AABB).intersects(reach):
				continue
			var panel: Dictionary = pair[0]
			var span := breaks._cells_in(panel, (panel.xf as Transform3D).affine_inverse() * reach)
			if span.is_empty():
				continue
			var n: Vector3i = panel.n
			for k in range(span[0].z, span[1].z + 1):
				for j in range(span[0].y, span[1].y + 1):
					for i in range(span[0].x, span[1].x + 1):
						var c := int(panel.first) + i + n.x * (j + n.y * k)
						var cell := _cell_box(c)
						if not cell.grow(0.08).intersects(box):
							continue
						var over := cell.grow(0.08).intersection(box)
						if int(panel.thin) == 1 and absf(box.position.y - cell.end.y) <= 0.1 and over.size.x > 0.05 and over.size.z > 0.05:
							stands.append(c)
						else:
							hangs.append(c)
		if not stands.is_empty():
			piece["rests"] = PackedInt32Array(stands)
		elif box.position.y > _tops[0] + 0.5 or _shift == 0:   # (else it stands on the ground)
			piece["rests"] = PackedInt32Array(hangs)
		else:
			piece["rests"] = PackedInt32Array()
	# What stands on another thing (a pot on a shelf, a tree in its planter).
	for turn in 2:
		for entry: Array in all:
			var piece: Dictionary = entry[0]
			var box: AABB = entry[1]
			if not (piece.rests as PackedInt32Array).is_empty() or (_shift == 1 and box.position.y <= _tops[0] + 0.5):
				continue
			for o: int in _bucketed(thing_buckets, box):
				var other: Array = all[o]
				var under: AABB = other[1]
				if other[0] == piece or (other[0].rests as PackedInt32Array).is_empty():
					continue
				if absf(box.position.y - under.end.y) <= 0.12 and under.grow(0.05).intersects(box):
					piece["rests"] = other[0].rests
					break
	for entry: Array in all:
		for c: int in (entry[0].rests as PackedInt32Array):
			(_rests_of.get_or_add(c, []) as Array).append(entry[0])


## Puts `index` in every bucket of `buckets` that `box` reaches, and gives the indices in
## the buckets a box reaches, lowest first.
static func _bucket(buckets: Dictionary, box: AABB, index: int) -> void:
	var lo := Vector3i((box.position / BUCKET).floor())
	var hi := Vector3i((box.end / BUCKET).floor())
	for x in range(lo.x, hi.x + 1):
		for y in range(lo.y, hi.y + 1):
			for z in range(lo.z, hi.z + 1):
				(buckets.get_or_add(Vector3i(x, y, z), []) as Array).append(index)


static func _bucketed(buckets: Dictionary, box: AABB) -> Array:
	var lo := Vector3i((box.position / BUCKET).floor())
	var hi := Vector3i((box.end / BUCKET).floor())
	if lo == hi:
		return buckets.get(lo, [])   # (in the order they went in: lowest first)
	var found := {}
	for x in range(lo.x, hi.x + 1):
		for y in range(lo.y, hi.y + 1):
			for z in range(lo.z, hi.z + 1):
				for i: int in buckets.get(Vector3i(x, y, z), []):
					found[i] = true
	var near := found.keys()
	near.sort()
	return near


## A cell's box in this collapse's frame (the map's, or the mover's).
func _cell_box(c: int) -> AABB:
	var panel: Dictionary = breaks.panels[breaks.cells[c].panel]
	return (panel.xf as Transform3D) * breaks._local_box(panel, breaks.cells[c].ijk)


## Host: walls broke. A stretch of wall that holds the building up (see _take_walls) is
## gone once enough of it is. (Every copy counts, but only the host's count is used:
## see flush().)
func _on_cells_changed(cells: PackedInt32Array, stages: PackedByteArray) -> void:
	var touched := {}
	var things := {}   # the loose things that stand on, or hang from, what changed (by their id)
	for n in mini(cells.size(), stages.size()):
		if int(stages[n]) == MapDestruction.BROKEN and _wall_of.has(cells[n]):
			touched[_wall_of[cells[n]]] = true
		for piece: Dictionary in _rests_of.get(cells[n], []):
			things[int(piece.rid)] = piece
	# A thing goes when enough of what holds it has (and is back when that is: a
	# killcam shows a wall as it was, a mended island has its walls again).
	for id in things:
		var piece: Dictionary = things[id]
		var rests: PackedInt32Array = piece.rests
		var gone := 0
		for c in rests:
			if int(breaks.cells[c].stage) >= MapDestruction.BROKEN:
				gone += 1
		var lost := gone >= ceili(rests.size() * frame.rests_share)
		if lost == bool(piece.get("lost", false)):
			continue
		piece["lost"] = lost
		_losing[int(piece.unit) / 16] = bool(_losing.get(int(piece.unit) / 16, false)) or not lost
		if lost:
			_gone.append(piece)
		# (In bits, unless it is coming down with its floor anyway.)
		if lost and root.debris and not _parked and not _letting_go and int(bays[int(piece.unit) / 16].shown) > int(piece.unit) % 16 \
				and not piece.get("hidden", false):
			var box: AABB = (piece.xf as Transform3D) * AABB(-(piece.size as Vector3) * 0.5, piece.size)
			root.debris.burst(_box_out(box), piece.kind, BlockMaterials.for_kind(piece.kind, root.palette))
	# A floor that has lost enough of itself caves in (MapFrame.cave_share).
	if frame.cave_share > 0.0 and not _letting_go and not _restoring:
		var floors := {}
		var bridges := {}
		for n in mini(cells.size(), stages.size()):
			if int(stages[n]) == MapDestruction.BROKEN and _floor_of.has(cells[n]):
				floors[int(_floor_of[cells[n]])] = true
				if _span_units.has(int(breaks.cells[cells[n]].panel)):
					bridges[int(breaks.cells[cells[n]].panel)] = true
		# (A bridge is one thing, whatever bays it crosses: enough of it gone and all of it goes.)
		for index: int in bridges:
			var panel: Dictionary = breaks.panels[index]
			var count := int(panel.n.x) * int(panel.n.y) * int(panel.n.z)
			var gone := 0
			for c in range(int(panel.first), int(panel.first) + count):
				if int(breaks.cells[c].stage) >= MapDestruction.BROKEN:
					gone += 1
			if gone >= ceili(count * frame.cave_share):
				for unit: int in _span_units[index]:
					# (Not the bays its ends only just reach into: their floors stand.)
					if int(_span_units[index][unit]) >= count * SPAN_SHARE and int(bays[unit / 16].from) > unit % 16:
						_weak[unit] = true
		for unit: int in floors:
			var bay: Dictionary = bays[unit / 16]
			var of: PackedInt32Array = _unit_floor[unit]
			if int(bay.from) <= unit % 16 or _weak.has(unit):
				continue
			# (A sliver of floor at the foot of a wall brings nothing down: a real stretch of it, or a span that stands on no wall of its own.)
			if of.size() < CAVE_CELLS and not _bare(bay):
				continue
			var gone := 0
			for c in of:
				if int(breaks.cells[c].stage) >= MapDestruction.BROKEN:
					gone += 1
			if gone >= ceili(of.size() * frame.cave_share):
				_weak[unit] = true
	for i: int in touched:
		var seg: Dictionary = segments[i]
		if int(seg.stage) >= DESTROYED or seg.fallen:
			continue
		var gone := 0   # (broken, or down with the bay beside this one: a wall that has lost its neighbour is weaker)
		for c: int in (seg.cells as PackedInt32Array):
			if int(breaks.cells[c].stage) >= MapDestruction.BROKEN:
				gone += 1
		if gone >= ceili((seg.cells as PackedInt32Array).size() * frame.wall_share):
			_pending[i] = DESTROYED


## A body for part of the building that stands still in its frame: on a mover, one that
## is moved with it a step at a time, like the mover's own.
func _fixed_body() -> PhysicsBody3D:
	if on == null:
		return StaticBody3D.new()
	var moving := AnimatableBody3D.new()
	moving.sync_to_physics = false
	return moving


## A place in this collapse's frame, in the map's (and back).
func _out(at: Vector3) -> Vector3:
	return on.transform * at if on else at


func _in(at: Vector3) -> Vector3:
	return on.transform.affine_inverse() * at if on else at


func _box_out(box: AABB) -> AABB:
	return on.transform * box if on else box


## How many floors there are.
func levels() -> int:
	return _tops.size()


func unit_of(bay: int, level: int) -> int:
	return bay * 16 + level


## The bay over (or under) a point, or -1.
func bay_at(at: Vector3) -> int:
	var nx := _lines_x.size() - 1
	var nz := _lines_z.size() - 1
	if nx < 1 or nz < 1:
		return -1
	var over := frame.overhang
	if at.x < _lines_x[0] - over or at.x >= _lines_x[nx] + over or at.z < _lines_z[0] - over or at.z >= _lines_z[nz] + over:
		return -1
	var i := 0
	while i < nx - 1 and at.x >= _lines_x[i + 1]:
		i += 1
	var j := 0
	while j < nz - 1 and at.z >= _lines_z[j + 1]:
		j += 1
	return j * nx + i


## The bay nearest a place outside all of them.
func _bay_near(at: Vector3) -> int:
	var best := -1
	var nearest := INF
	for b in bays.size():
		var bay: Dictionary = bays[b]
		var d := Vector2(at.x - clampf(at.x, bay.x0, bay.x1), at.z - clampf(at.z, bay.z0, bay.z1)).length()
		if d < nearest:
			nearest = d
			best = b
	return best


## The level a height belongs to (its slab, and what stands on it), or -1: the ground's.
func level_at(y: float) -> int:
	var level := -1
	for l in _tops.size():
		if y >= _tops[l] - _slab:
			level = l
	return level


## The space a unit takes up.
func unit_box(unit: int) -> AABB:
	var bay: Dictionary = bays[unit / 16]
	var level := unit % 16
	var y0 := _tops[level] - _slab
	var y1 := _tops[level + 1] - _slab if level + 1 < _tops.size() else _tops[level] + 8.0
	return AABB(Vector3(bay.x0, y0, bay.z0), Vector3(bay.x1 - bay.x0, y1 - y0, bay.z1 - bay.z0))


## Is there a column on crossing `column` of the frame's lines (x, z) with a storey
## `storey` (0: the ground's)?
func has_column(column: Vector2i, storey: int) -> bool:
	var by_storey: Array = _columns.get(column, [])
	return storey >= 0 and storey < by_storey.size() and int(by_storey[storey]) >= 0


## The space that storey of that column takes up.
func column_box(column: Vector2i, storey: int) -> AABB:
	return segments[_columns[column][storey]].box if has_column(column, storey) else AABB()


## Host (tests, see Match.dev_blow_column): blows out that storey of that column the
## way a player would: a column takes three rockets' worth, a stretch of wall loses as
## much of itself as it takes. False if there is no such column to blow out now.
func dev_blow(column: Vector2i, storey: int) -> bool:
	if _parked or not has_column(column, storey):
		return false
	var seg: Dictionary = segments[_columns[column][storey]]
	if int(seg.stage) >= DESTROYED or seg.fallen:
		return false
	if seg.has("cells"):
		var cells: PackedInt32Array = seg.cells
		for n in ceili(cells.size() * frame.wall_share):
			breaks.damage(cells[n], 100000.0)
	else:
		for n in 3:
			blast(_out((seg.box as AABB).get_center()), 1.0, 262.0)
	return true


## Is this place (a spawn point) in or under a bay that has come down?
func blocked(at: Vector3) -> bool:
	if not frame.claims(_in(at)):
		return false   # (another building's: a tier of a tower over or under this one)
	var b := bay_at(_in(at))
	return b >= 0 and int(bays[b].from) < levels()


## A column: a tall upright block of the frame's column kind on a crossing of its lines.
## It is taken a storey at a time.
func _take_column(piece: Dictionary) -> bool:
	var size: Vector3 = piece.size
	var xf: Transform3D = piece.xf
	if piece.kind != frame.column_kind or piece.shape != "box" or not piece.solid or size.y < 2.5 * maxf(size.x, size.z) \
			or not xf.basis.is_equal_approx(Basis()):
		return false
	var col := Vector2i(-1, -1)
	for i in _lines_x.size():
		if absf(xf.origin.x - _lines_x[i]) < 0.3:
			col.x = i
	for j in _lines_z.size():
		if absf(xf.origin.z - _lines_z[j]) < 0.3:
			col.y = j
	if col.x < 0 or col.y < 0:
		return false
	var bottom := xf.origin.y - size.y * 0.5
	var top := xf.origin.y + size.y * 0.5
	var by_storey := []
	for s in levels():
		var y0 := bottom if s == 0 else maxf(bottom, _tops[s - 1])
		var y1 := top if s == levels() - 1 else minf(top, _tops[s])
		if y1 - y0 < 0.3:
			by_storey.append(-1)
			continue
		var part := piece.duplicate()
		part.xf = Transform3D(Basis(), Vector3(xf.origin.x, (y0 + y1) * 0.5, xf.origin.z))
		part.size = Vector3(size.x, y1 - y0, size.z)
		var body := _fixed_body()
		body.name = "Column_%d_%d_%d" % [col.x, col.y, s]
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = part.size
		shape.shape = box
		shape.transform = part.xf
		body.add_child(shape)
		add_child(body)
		by_storey.append(segments.size())
		segments.append({"col": col, "storey": s, "box": AABB((part.xf as Transform3D).origin - (part.size as Vector3) * 0.5, part.size),
			"hp": frame.column_health, "max_hp": frame.column_health, "stage": 0, "fallen": false, "body": body, "piece": part})
	_columns[col] = by_storey
	return true


## Map pieces drawn as the map draws them. `moves`: they are part of something that
## will (its pattern is laid out from where it stands now, and goes with it).
func _piece_mesh(pieces: Array, moves: bool) -> Node3D:
	var holder := Node3D.new()
	var meshes := MapMesher.build(pieces, root.face_shade)
	for kind in meshes:
		var mi := MeshInstance3D.new()
		mi.mesh = MapMesher.riding(meshes[kind]) if moves or on else meshes[kind]
		mi.material_override = _material(kind)
		var base := mi.material_override as BaseMaterial3D
		if base and base.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		holder.add_child(mi)
	return holder


## A bay's loose things (what stands on the floors that have not fallen): one body. They
## are drawn with the rest of what stands (_draw_standing).
func _build_bay(b: int, redraw: bool = true) -> void:
	var bay: Dictionary = bays[b]
	if bay.node:
		(bay.node as Node).queue_free()
		bay.node = null
	if redraw:
		_redraw |= LOOSE
		_stale[_lot_of(b)] = true
	var body := _fixed_body()
	body.name = "Bay_%d_%d" % [bay.i, bay.j]
	if _parked:
		body.collision_layer = 0
	for level in mini(int(bay.shown), levels()):
		for piece: Dictionary in bay.loose[level]:
			if not piece.solid or piece.get("lost", false):
				continue
			for lump in root.collision_shapes(piece):
				var shape := CollisionShape3D.new()
				shape.shape = lump
				shape.transform = piece.xf
				body.add_child(shape)
	if body.get_child_count() == 0:
		body.free()
		return
	add_child(body)
	bay.node = body


## Draws what of the building stands and is not a wall or floor that breaks: its
## column storeys as one lot ("Columns") and the loose things as others ("Standing"),
## each one mesh for each kind, like the rest of the map. Whichever is stale is made
## again: the columns are few and quick, and a rocket that takes one out must not hold
## the game up. The loose things are many and slow (a furnished room is tens of
## milliseconds: the mesher is GDScript), so they are drawn when the map is made and
## when it is mended and at no other time: a thing that goes is blanked where it is in
## its lot's mesh (_hide), and so is everything in a bay that comes down.
func _draw_standing() -> void:
	var what := _redraw
	_redraw = 0
	if not root.has_meshes:
		_stale.clear()
		return
	if what & COLUMNS:
		if _columns_drawn:
			remove_child(_columns_drawn)
			_columns_drawn.queue_free()
		var solid := []
		for seg: Dictionary in segments:
			if seg.body != null:
				solid.append(seg.piece)
		_columns_drawn = _standing_mesh(solid, [])
		_columns_drawn.name = "Columns"
		add_child(_columns_drawn)
	if what & LOOSE:
		for lot: int in _stale:
			_show_lot(lot, _lot_mesh(lot))
	_stale.clear()


## Which lot of loose things bay `b`'s are drawn in. A building with columns is one
## lot. One held up by its walls can be big (a tier of Empyrean Tower is 60 m across,
## with 1,500 things in it), so it is cut into squares of LOT_BAYS bays: what is out
## of sight is then not drawn, at a few meshes for each square.
func _lot_of(b: int) -> int:
	if not frame.held_by_walls:
		return 0
	return (int(bays[b].j) / LOT_BAYS) * 64 + int(bays[b].i) / LOT_BAYS


## The loose things of a lot on the floors that are shown, drawn: a node with a mesh
## for each kind, which also knows where in those meshes each thing is ("ranges": a
## thing's number -> [[mesh, its first corner, how many]...]), for _hide.
func _lot_mesh(lot: int) -> Node3D:
	var drawn := [{}, {}]   # solid, decor: kind -> buffer (see MapMesher.add_to)
	var sizes := [{}, {}]   # ...and how many corners each had after the last thing
	var spans := []         # [thing, 0 solid / 1 decor, kind, first corner, how many]
	for b in bays.size():
		if _lot_of(b) != lot:
			continue
		var bay: Dictionary = bays[b]
		for level in mini(int(bay.shown), levels()):
			for piece: Dictionary in bay.loose[level]:
				if piece.get("lost", false):
					continue
				var sets := [[], []]
				if not piece.get("hidden", false):
					(sets[0 if piece.solid else 1] as Array).append(piece)
				for part: Dictionary in piece.get("with", []):
					if not part.get("hidden", false):
						(sets[1] as Array).append(part)
				for n in 2:
					if (sets[n] as Array).is_empty():
						continue
					var by_kind: Dictionary = drawn[n]
					MapMesher.add_to(by_kind, sets[n], root.face_shade)
					for kind: String in by_kind:
						var now := (by_kind[kind][0] as PackedVector3Array).size()
						var was := int(sizes[n].get(kind, 0))
						if now > was:
							spans.append([int(piece.lid), n, kind, was, now - was])
							sizes[n][kind] = now
	var holder := _holder(MapMesher.meshes(drawn[0]), MapMesher.meshes(drawn[1]))
	var meshes := {}
	for mi: MeshInstance3D in holder.get_children():
		meshes[String(mi.name)] = mi.mesh
	var ranges := {}
	for span: Array in spans:
		var mesh: ArrayMesh = meshes.get(("Mesh_%s" if span[1] == 0 else "Mesh_%s_decor") % span[2])
		if mesh:
			(ranges.get_or_add(span[0], []) as Array).append([mesh, span[3], span[4]])
	holder.set_meta("ranges", ranges)
	return holder


## A loose thing has gone (with what it stood on, or with its bay): it is blanked in
## its lot's drawing, the corners of its faces all put in one place, which costs
## nothing to speak of where drawing the lot again would hold the game up. False if
## it cannot be (the lot is not drawn): the lot is then to be drawn again.
func _hide(piece: Dictionary) -> bool:
	if not root.has_meshes:
		return true
	var lot := _lot_of(int(piece.unit) / 16)
	if _stale.has(lot):
		return true   # (about to be drawn again, without it)
	var node := _lots.get(lot) as Node3D
	if node == null:
		return false
	for at: Array in (node.get_meta("ranges") as Dictionary).get(int(piece.lid), []):
		MapMesher.blank(at[0], at[1], at[2])
	return true


## Puts a lot's new drawing (see _lot_mesh) in place of its old one.
func _show_lot(lot: int, node: Node3D) -> void:
	if _standing == null:
		_standing = Node3D.new()
		_standing.name = "Standing"
		add_child(_standing)
	var old := _lots.get(lot) as Node3D
	if old:
		_standing.remove_child(old)
		old.queue_free()
	_lots[lot] = node
	_standing.add_child(node)


func _standing_mesh(solid: Array, decor: Array) -> Node3D:
	return _holder(MapMesher.build(solid, root.face_shade), MapMesher.build(decor, root.face_shade))


## A node with a mesh for each kind of `solid` and of `decor` (kind -> mesh).
func _holder(solid: Dictionary, decor: Dictionary) -> Node3D:
	var holder := Node3D.new()
	for lot in 2:
		var meshes: Dictionary = [solid, decor][lot]
		for kind in meshes:
			var mi := MeshInstance3D.new()
			mi.name = ("Mesh_%s" if lot == 0 else "Mesh_%s_decor") % kind
			mi.mesh = MapMesher.riding(meshes[kind]) if on else meshes[kind]   # (on a mover, its pattern is the mover's)
			mi.material_override = _material(kind)
			var base := mi.material_override as BaseMaterial3D
			if (lot == 1 and not root.decor_shadows) or (base and base.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED):
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			if lot == 1 and root.detail_range > 0.0:
				mi.visibility_range_end = root.detail_range
				mi.visibility_range_end_margin = root.detail_range * 0.1
			holder.add_child(mi)
	return holder


# ---------------------------------------------------------------------------
# Damage (host)

## Host: a round or a blow of `amount` landed on the level at `point`.
func hit(point: Vector3, amount: float) -> void:
	point = _in(point)
	for i in segments.size():
		var seg: Dictionary = segments[i]
		if seg.body != null and int(seg.stage) < DESTROYED and not seg.fallen and (seg.box as AABB).grow(0.12).has_point(point):
			_damage(i, amount)
			return


## Host: a blast at `at`: every column storey within `radius` takes `amount`, less the further off.
func blast(at: Vector3, radius: float, amount: float) -> void:
	if radius <= 0.0:
		return
	at = _in(at)
	for i in segments.size():
		var seg: Dictionary = segments[i]
		if seg.body == null or int(seg.stage) >= DESTROYED or seg.fallen:
			continue   # (a stretch of wall is damaged as wall: see _on_cells_changed)
		var box: AABB = seg.box
		var d := at.clamp(box.position, box.end).distance_to(at)
		if d < radius:
			_damage(i, amount * (1.0 - d / radius))


func _damage(i: int, amount: float) -> void:
	if amount < frame.column_armour:
		return
	var seg: Dictionary = segments[i]
	seg.hp = maxf(float(seg.hp) - amount, 0.0)
	var left: float = float(seg.hp) / float(seg.max_hp)
	var stage := DESTROYED if seg.hp <= 0.0 else (0 if left > 0.66 else (1 if left > 0.33 else 2))
	if stage != int(seg.stage):
		_pending[i] = stage


## Host: what changed since the last flush, for everyone: {} if nothing, else
## {columns: [segments, stages], events: [a start() for each new collapse]}.
func flush() -> Dictionary:
	if _pending.is_empty() and _weak.is_empty():
		return {}
	var ids := PackedInt32Array()
	var stages := PackedByteArray()
	var lost: Array = []
	for i in _pending:
		ids.append(i)
		stages.append(int(_pending[i]))
		if int(_pending[i]) >= DESTROYED:
			lost.append(i)
	_pending.clear()
	var result := {"columns": [ids, stages], "events": []}
	if lost.is_empty() and _weak.is_empty():
		return result
	# Which units that leaves with nothing under them.
	var gone := {}   # segment -> true: gone now, or about to be
	for i in segments.size():
		if int(segments[i].stage) >= DESTROYED:
			gone[i] = true
	for i in lost:
		gone[i] = true
	var units := PackedInt32Array()
	var caved := Vector3.INF   # where a floor caved in (the middle of the first one)
	var weak := _weak.keys()
	weak.sort()
	_weak.clear()
	for unit: int in weak:
		var bay: Dictionary = bays[unit / 16]
		if bay.fixed or int(bay.from) <= unit % 16:
			continue
		if caved == Vector3.INF:
			caved = unit_box(unit).get_center()
			caved.y = _tops[unit % 16 + 1] if unit % 16 + 1 < _tops.size() else caved.y
		for up in range(unit % 16, int(bay.from)):
			units.append(unit_of(unit / 16, up))
		bay.from = unit % 16
	for b in bays.size():
		var bay: Dictionary = bays[b]
		if bay.fixed:
			continue
		for level in int(bay.from):
			var without := 0
			var standing := 0
			var corner_gone := false
			for col: Vector2i in bay.cols:
				if _lost(col, level, gone):
					without += 1
					corner_gone = corner_gone or col == bay.corner
				elif _holds(col, level):
					standing += 1
			# (Two of its columns, or the only one it has: a bay of a round tower can have a single crossing with wall by it.)
			if corner_gone or without >= 2 or (without == 1 and standing == 0):
				for up in range(level, int(bay.from)):
					units.append(unit_of(b, up))
				bay.from = level   # (the host's own: nothing claims these units twice)
				break
	# A floor with no column of its own under it (the middle of a wide room's ceiling) is
	# held up by the floors beside it: it goes, with all above it, once two of those have
	# at that level, or the only one there was.
	var nx := _lines_x.size() - 1
	var spreading := not units.is_empty() and frame.held_by_walls
	while spreading:
		spreading = false
		for b in bays.size():
			var bay: Dictionary = bays[b]
			if bay.fixed or int(bay.from) == 0:
				continue
			for level in int(bay.from):
				var held := false
				for col: Vector2i in bay.cols:
					held = held or _holds(col, level) or _lost(col, level, gone)
				if held or not _unit_floor.has(unit_of(b, level)):
					continue   # (it has columns of its own, or there is no floor of it at this level)
				var beside := 0
				var down := 0
				for step: Vector2i in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
					var i := int(bay.i) + step.x
					var j := int(bay.j) + step.y
					if i < 0 or i >= nx or j < 0 or j >= _lines_z.size() - 1:
						continue
					var o := j * nx + i
					if not _unit_floor.has(unit_of(o, level)):
						continue
					beside += 1
					if int(bays[o].from) <= level:
						down += 1
				if beside > 0 and down >= mini(2, beside):
					for up in range(level, int(bay.from)):
						units.append(unit_of(b, up))
					bay.from = level
					spreading = true
					break
	if not units.is_empty():
		var at: Vector3 = caved if lost.is_empty() else (segments[lost[0]].box as AABB).get_center()
		(result.events as Array).append({"id": _next_id, "units": units, "seed": randi() & 0x7fffffff,
			"at": at, "by": by, "with": with})
		_next_id += 1
	return result


## Has this bay no column of its own on any storey (the middle of a wide room, a bridge)?
func _bare(bay: Dictionary) -> bool:
	for col: Vector2i in bay.cols:
		if _holds(col, levels()):
			return false
	return true


## Has crossing `col` a column at or below `level` (any storey of one up to there)?
func _holds(col: Vector2i, level: int) -> bool:
	var by_storey: Array = _columns.get(col, [])
	for s in mini(level + 1 + _shift, by_storey.size()):
		if int(by_storey[s]) >= 0:
			return true
	return false


## Is column `col` gone at or below `level` (one of its storeys up to there blown out)?
func _lost(col: Vector2i, level: int, gone: Dictionary) -> bool:
	var by_storey: Array = _columns.get(col, [])
	for s in mini(level + 1 + _shift, by_storey.size()):
		if int(by_storey[s]) >= 0 and gone.has(int(by_storey[s])):
			return true
	return false


## Everyone: column storeys cracked or were blown out.
func apply_columns(ids: PackedInt32Array, stages: PackedByteArray) -> void:
	for n in mini(ids.size(), stages.size()):
		var i := ids[n]
		if i < 0 or i >= segments.size():
			continue
		var seg: Dictionary = segments[i]
		var stage := int(stages[n])
		if stage == int(seg.stage):
			continue
		seg.stage = stage
		if stage >= DESTROYED:
			seg.hp = 0.0
			_pending.erase(i)   # (a copy that is not the host counted its walls too)
			_segment_gone(i, true)
		elif root.marks and not seg.has("cells") and on == null:
			root.marks.cracks_on(i, seg.box, stage)
	if _redraw:
		_draw_standing()


## A column storey's own body and marks go. `burst`: blown out (rubble and a crash).
func _segment_gone(i: int, burst: bool) -> void:
	var seg: Dictionary = segments[i]
	if seg.has("cells"):
		return   # (a stretch of wall: what is left of it stands until its bay goes)
	if seg.body:
		(seg.body as Node).queue_free()
		seg.body = null
		_redraw |= COLUMNS
	var box: AABB = seg.box
	if root.marks and on == null:
		root.marks.cracks_on(i, box, 0)
		root.marks.clear_in(box.grow(0.05))
	if burst:
		if root.debris and on == null:
			root.debris.burst(box, frame.column_kind, "concrete")
		var sound := get_node_or_null("/root/Sound")
		if sound:
			var p = sound.play_at("break_concrete", _out(box.get_center()), "fire", 3.0, 0.05)
			if p:
				p.pitch_scale *= 0.7
	changed.emit([_box_out(box.grow(0.15))])


# ---------------------------------------------------------------------------
# A collapse

## Everyone: collapse `event` begins ({id, units, seed, at: where the frame was cut, by,
## with}): after the warning its units let go. `restore`: for a copy that joined after
## it, {age, done, poses}: the pieces are put where the host has them.
func start(event: Dictionary, restore: Dictionary = {}) -> void:
	for other: Dictionary in events:
		if int(other.id) == int(event.id):
			return   # (told twice: a copy that joined as it began)
	for other: Dictionary in events:
		_plan(other, 0.0)   # (how one is cut depends on what stands beside it: settled before this one changes that)
	var e := event.duplicate()
	e["state"] = WAITING
	e["age"] = -WARNING
	e["pieces"] = []     # {body, c: its middle (in its own frame), big, at: when it lets go, box: AABB, ...}
	e["specs"] = []      # the pieces to make (see _plan)
	e["planned"] = 0     # how many of its units are in that list so far
	e["made"] = 0
	e["boxes"] = []
	e["hosting"] = false
	_next_id = maxi(_next_id, int(e.id) + 1)
	var touched := {}
	for unit: int in (e.units as PackedInt32Array):
		var bay: Dictionary = bays[unit / 16]
		bay.from = mini(int(bay.from), unit % 16)
		touched[unit / 16] = true
		(e.boxes as Array).append(unit_box(unit))
		_weak.erase(unit)
	e["bays"] = touched.keys()
	var falling := {}
	for unit: int in (e.units as PackedInt32Array):
		falling[unit] = true
	e["falling"] = falling
	e["tail"] = _stranded_columns()
	events.append(e)
	if not restore.is_empty():
		if restore.get("dropped", false):
			_drop(e)   # (it came down on an island that has since gone below the map: no pile)
			return
		# (Every piece is made, whatever has happened to what it stood on since: the
		# host's poses say which of them it has.)
		_restoring = true
		_let_go(e, true)
		_restoring = false
		_put(e, restore.poses)
		if restore.done:
			_solidify(e)
		else:
			e.state = FALLING   # (frozen where the host had them; its news and its rest move them on)
			e.age = float(restore.age)
			for p: Dictionary in e.pieces:
				p.at = 0.0
		return
	var sound := get_node_or_null("/root/Sound")
	if sound:
		var p = sound.play_at("break_concrete", _out(e.at), "fire", 6.0)
		if p:
			p.pitch_scale *= 0.45   # the frame groans


## Works out what collapse `e` is made of, in an order every copy agrees on: a list of
## pieces to make ({kind: "cells" / "loose" / "column", ...}), a unit at a time for up to
## `budget` milliseconds (0: all of it now). Cutting a tower up is too much for the one
## frame in which its column goes, so it is spread over the start of the warning. True
## once the list is whole.
func _plan(e: Dictionary, budget: float) -> bool:
	var units: PackedInt32Array = e.units
	if int(e.planned) > units.size():
		return true
	var started := Time.get_ticks_usec()
	var specs: Array = e.specs
	var falling: Dictionary = e.falling
	var rng := RandomNumberGenerator.new()
	while int(e.planned) < units.size():
		var unit := units[int(e.planned)]
		rng.seed = int(e.seed) + unit * 7919
		# Slabs and walls: each panel's cells in this unit, cut into pieces.
		var by_panel := {}
		for c: int in _unit_cells.get(unit, PackedInt32Array()):
			var p: int = breaks.cells[c].panel
			if not by_panel.has(p):
				by_panel[p] = []
			(by_panel[p] as Array).append(c)
		var order := by_panel.keys()
		order.sort()
		for p: int in order:
			if breaks.panels[p].whole:
				# (A block that breaks all at once, a dome say: it comes down as it is.)
				specs.append({"kind": "loose", "piece": breaks.panels[p].piece, "cell": int(breaks.panels[p].first)})
			else:
				specs.append_array(_cut(p, by_panel[p], rng, unit, falling))
		# What stands on the floor.
		for piece: Dictionary in bays[unit / 16].loose[unit % 16]:
			var s: Vector3 = piece.size
			if piece.solid and s.x * s.y * s.z >= TINY:
				specs.append({"kind": "loose", "piece": piece})
		e.planned = int(e.planned) + 1
		if budget > 0.0 and (Time.get_ticks_usec() - started) / 1000.0 > budget:
			return false
	specs.append_array(e.tail)
	e.planned = units.size() + 1
	# When each lets go. It crumbles from where the frame was cut: outward along the
	# floor, and up the building a floor at a time, each letting go as the one under it
	# drops away.
	var low := INF   # the bottom of the lowest floor that falls
	for unit: int in units:
		low = minf(low, unit_box(unit).position.y)
	var from: Vector3 = e.at
	for spec: Dictionary in specs:
		var at: Vector3 = spec.get("middle", Vector3.ZERO)
		if spec.kind == "loose":
			at = (spec.piece.xf as Transform3D).origin
		elif spec.kind == "column":
			at = (segments[spec.segment].box as AABB).get_center()
		spec["at"] = Vector2(at.x - from.x, at.z - from.z).length() / SPREAD + maxf(at.y - low, 0.0) / RISE
	return true


## The column storeys with nothing left round them, as pieces to make: they go with the
## collapse that has just begun.
func _stranded_columns() -> Array:
	var specs := []
	var cols := _columns.keys()
	cols.sort()
	for col: Vector2i in cols:
		var by_storey: Array = _columns[col]
		for s in range(1, by_storey.size()):
			var i: int = by_storey[s]
			if i < 0 or segments[i].fallen or segments[i].has("cells"):
				continue   # (a stretch of wall is cells of its bays: it goes as those do)
			var held := false
			var beside := 0
			for b in bays.size():
				if (bays[b].cols as Array).has(col):
					beside += 1
					if int(bays[b].from) > s - 1:
						held = true
			if beside > 0 and not held:
				segments[i].fallen = true
				specs.append({"kind": "column", "segment": i})
	return specs


## Cuts the cells of panel `p` that are in one unit into pieces: about one to every
## PIECE_AREA of it, each the cells nearest one of a scatter of points. Each piece
## collides as the flat-sided lump round its point, a touch small, so that neighbours
## start out clear of each other.
func _cut(p: int, cells: Array, rng: RandomNumberGenerator, unit: int, falling: Dictionary) -> Array:
	var panel: Dictionary = breaks.panels[p]
	var u: int = panel.u
	var v: int = panel.v
	var thin: int = panel.thin
	var step: Vector3 = panel.cell
	var half: Vector3 = (panel.size as Vector3) * 0.5
	var lo := Vector2i(1 << 30, 1 << 30)
	var hi := Vector2i(-1, -1)
	var where := {}   # cell -> Vector2i (its place on the panel)
	for c: int in cells:
		var ijk: Vector3i = breaks.cells[c].ijk
		var at := Vector2i(ijk[u], ijk[v])
		where[c] = at
		lo = lo.min(at)
		hi = hi.max(at)
	var w: float = (hi.x - lo.x + 1) * step[u]
	var h: float = (hi.y - lo.y + 1) * step[v]
	var style: String = panel.style if PIECE_AREA.has(panel.style) else "sheet"
	# (Metal does not break up: a rail or a sheet of it comes away in one piece.)
	var count := 1 if String(panel.get("material", "")) == "metal" else maxi(1, roundi(w * h / float(PIECE_AREA[style])))
	var seeds: Array = []
	for n in count:
		seeds.append(Vector2(rng.randf_range(0.15, 0.85) * w, rng.randf_range(0.15, 0.85) * h))
	# (Which cells go to which piece is worked out when the first of them is made: it is
	# the slow part, and the pieces are made a few a frame. See _share.)
	var job := {"panel": p, "cells": cells, "seeds": seeds, "lo": lo, "shares": []}
	# (in the panel's frame: where the patch of cells starts)
	var origin := -half
	origin[u] += lo.x * step[u]
	origin[v] += lo.y * step[v]
	var specs := []
	var polys := _voronoi(w, h, seeds)
	# A slab piece on the edge of a bay that still stands hangs on by its bars.
	var bay: Dictionary = bays[unit / 16]
	for n in count:
		var poly: PackedVector2Array = polys[n]
		if poly.size() < 3:
			specs.append({"kind": "none"})
			continue
		var tight := _inset(poly, 0.02)
		var solid := PackedVector3Array()
		var mid := Vector3.ZERO
		for q in tight:
			for side in 2:
				var point := origin
				point[u] += q.x
				point[v] += q.y
				point[thin] = (-half[thin] + 0.01) if side == 0 else (half[thin] - 0.01)
				solid.append((panel.xf as Transform3D) * point)
		for point in solid:
			mid += point
		mid /= solid.size()
		var spec := {"kind": "cells", "panel": p, "job": job, "n": n, "solid": solid, "middle": mid,
			"density": DENSITY[style], "pins": []}
		if thin == 1 and style == "concrete" and rng.randf() < 0.75:
			var ties: Array = []
			for q in poly:
				var point := origin
				point[u] += q.x
				point[v] += q.y
				var at := (panel.xf as Transform3D) * point
				for side: Array in [[at.x - bay.x0 < 0.02, Vector3.LEFT], [bay.x1 - at.x < 0.02, Vector3.RIGHT],
						[at.z - bay.z0 < 0.02, Vector3.FORWARD], [bay.z1 - at.z < 0.02, Vector3.BACK]]:
					if side[0] and _stands_beside(unit, side[1], falling):
						ties.append(at)
						break
			if ties.size() >= 2:
				spec.pins = [(ties[0] as Vector3).lerp(ties[1], 0.15), (ties[1] as Vector3).lerp(ties[0], 0.15)]
		specs.append(spec)
	return specs


## The cells of one piece of a cut panel (see _cut): each cell goes to the nearest point.
func _share(job: Dictionary, n: int) -> Array:
	var shares: Array = job.shares
	if shares.is_empty():
		var panel: Dictionary = breaks.panels[job.panel]
		var u: int = panel.u
		var v: int = panel.v
		var su: float = (panel.cell as Vector3)[u]
		var sv: float = (panel.cell as Vector3)[v]
		var lo: Vector2i = job.lo
		var seeds: Array = job.seeds
		for k in seeds.size():
			shares.append([])
		for c: int in job.cells:
			var ijk: Vector3i = breaks.cells[c].ijk
			var mid := Vector2((ijk[u] - lo.x + 0.5) * su, (ijk[v] - lo.y + 0.5) * sv)
			var best := 0
			var nearest := INF
			for k in seeds.size():
				var d := mid.distance_squared_to(seeds[k])
				if d < nearest:
					nearest = d
					best = k
			(shares[best] as Array).append(c)
	return shares[n]


## Is there a unit beside `unit` on that side, at its level, that is not coming down?
func _stands_beside(unit: int, side: Vector3, falling: Dictionary) -> bool:
	var bay: Dictionary = bays[unit / 16]
	var i: int = int(bay.i) + int(side.x)
	var j: int = int(bay.j) + int(side.z)
	var nx := _lines_x.size() - 1
	if i < 0 or j < 0 or i >= nx or j >= _lines_z.size() - 1:
		return false
	var other := j * nx + i
	return int(bays[other].from) > unit % 16 and not falling.has(unit_of(other, unit % 16))


func _physics_process(delta: float) -> void:
	_tick += 1
	if not _losing.is_empty():
		# Loose things went with what they stood on (or are back): those bays, made again.
		for b: int in _losing:
			_build_bay(b, bool(_losing[b]))
		_losing.clear()
		for piece: Dictionary in _gone:
			if piece.get("lost", false) and not _hide(piece):
				_redraw |= LOOSE
				_stale[_lot_of(int(piece.unit) / 16)] = true
		_gone.clear()
		if _redraw:
			_draw_standing()
	for e: Dictionary in events:
		match int(e.state):
			WAITING:
				e.age = float(e.age) + delta
				if _plan(e, BUILD_MS) and int(e.made) < (e.specs as Array).size():
					_make_some(e, BUILD_MS)
				_warn(e)
				if float(e.age) >= 0.0:
					_let_go(e, false)
			FALLING:
				e.age = float(e.age) + delta
				_fall(e, delta)
			SLIDING:
				e.age = float(e.age) + delta
				_slide(e)


## The warning: dust shaken out from under what is about to go, and a shake.
func _warn(e: Dictionary) -> void:
	if _tick % 14 != 0 or root.debris == null or DisplayServer.get_name() == "headless":
		return
	var boxes: Array = e.boxes
	var box: AABB = boxes[randi() % boxes.size()]
	root.debris.dust(_out(Vector3(randf_range(box.position.x, box.end.x), box.position.y - 0.1, randf_range(box.position.z, box.end.z))),
		"concrete", Vector3.DOWN * 2.0)
	_shake(e, 0.25)


func _shake(e: Dictionary, amount: float) -> void:
	var arena := get_node_or_null("/root/Net")
	var local = arena.get("arena").get("local_player") if arena and arena.get("arena") else null
	if local and is_instance_valid(local) and local.has_method("shake"):
		var d: float = (local as Node3D).global_position.distance_to(_out(e.at))
		local.shake(amount * clampf(1.4 - d / 40.0, 0.0, 1.0))


## Makes pieces of `e` for up to `budget` milliseconds (hidden and out of the way until
## they are wanted: see _let_go).
func _make_some(e: Dictionary, budget: float) -> void:
	var specs: Array = e.specs
	var started := Time.get_ticks_usec()
	while int(e.made) < specs.size():
		(e.pieces as Array).append(_make(specs[e.made]))
		e.made = int(e.made) + 1
		if budget > 0.0 and (Time.get_ticks_usec() - started) / 1000.0 > budget:
			return


## One piece from its spec: a body where the thing stands, frozen, hidden and touching
## nothing. {body: null} for a piece with nothing in it.
func _make(spec: Dictionary) -> Dictionary:
	var none := {"body": null, "at": 0.0, "big": false, "c": Vector3.ZERO, "box": AABB(), "out": false, "due": false}
	var body: RigidBody3D = null
	var solid := PackedVector3Array()
	var density := 2400.0
	var drawn: Node3D = null
	match String(spec.kind):
		"cells":
			var panel: Dictionary = breaks.panels[spec.panel]
			var there: Array = []
			for c: int in _share(spec.job, spec.n):
				var stage := int(breaks.cells[c].stage)
				if stage < MapDestruction.BROKEN or stage == MapDestruction.FALLEN:
					there.append(c)
			if there.is_empty():
				return none
			solid = spec.solid
			density = spec.density
			if root.has_meshes:
				drawn = _cells_mesh(panel, there)
		"loose":
			var piece: Dictionary = spec.piece
			if piece.get("lost", false) and not _restoring:
				return none   # (it went with what it stood on, before this)
			if spec.has("cell") and int(breaks.cells[spec.cell].stage) == MapDestruction.BROKEN and not _restoring:
				return none   # (a block that was shot to bits before this)
			density = 500.0
			body = _new_body()
			for lump in root.collision_shapes(piece):
				var shape := CollisionShape3D.new()
				shape.shape = lump
				shape.transform = piece.xf
				body.add_child(shape)
			var half: Vector3 = (piece.size as Vector3) * 0.5
			for corner in 8:
				solid.append((piece.xf as Transform3D) * Vector3(-half.x if corner & 1 == 0 else half.x, -half.y if corner & 2 == 0 else half.y,
					-half.z if corner & 4 == 0 else half.z))
			if root.has_meshes:
				var seen := []
				for part: Dictionary in [piece] + (piece.get("with", []) as Array):
					if not part.get("hidden", false):
						seen.append(part)
				if not seen.is_empty():
					drawn = _piece_mesh(seen, true)
		"column":
			var seg: Dictionary = segments[spec.segment]
			if int(seg.stage) >= DESTROYED:
				return none
			var box: AABB = seg.box
			for corner in 8:
				solid.append(box.get_center() + (box.size * 0.5 - Vector3.ONE * 0.015) * Vector3(-1.0 if corner & 1 == 0 else 1.0,
					-1.0 if corner & 2 == 0 else 1.0, -1.0 if corner & 4 == 0 else 1.0))
			if root.has_meshes:
				drawn = _piece_mesh([seg.piece], true)
		_:
			return none
	if body == null:
		body = _new_body()
		var shape := CollisionShape3D.new()
		var hull := ConvexPolygonShape3D.new()
		hull.points = solid
		shape.shape = hull
		body.add_child(shape)
	var lo := solid[0]
	var hi := solid[0]
	for point in solid:
		lo = lo.min(point)
		hi = hi.max(point)
	var size := hi - lo
	body.mass = clampf(size.x * size.y * size.z * 0.7 * density, 15.0, 30000.0)
	if drawn:
		body.add_child(drawn)
	body.visible = false
	add_child(body)
	return {"body": body, "at": float(spec.at), "big": size.x * size.y * size.z >= BIG, "c": (lo + hi) * 0.5, "box": AABB(lo, size),
		"out": false, "pins": spec.get("pins", []), "last": Vector3.ZERO, "sent": false, "sent_xf": Transform3D(), "rest_sent": false, "due": false,
		"segment": int(spec.get("segment", -1)), "target": null}


func _new_body() -> RigidBody3D:
	var body := RigidBody3D.new()
	var material := PhysicsMaterial.new()
	material.friction = 0.9
	material.bounce = 0.02
	body.physics_material_override = material
	body.angular_damp = 0.3
	body.collision_layer = 0
	body.collision_mask = 0
	body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	body.freeze = true
	return body


## The cells of a panel that are there, drawn as the panel draws them (whole boxes,
## its own kind and tint), as a mesh that goes with a body.
func _cells_mesh(panel: Dictionary, cells: Array) -> Node3D:
	var u: int = panel.u
	var v: int = panel.v
	var lo := Vector2i(1 << 30, 1 << 30)
	var hi := Vector2i(-1, -1)
	for c: int in cells:
		var ijk: Vector3i = breaks.cells[c].ijk
		lo = lo.min(Vector2i(ijk[u], ijk[v]))
		hi = hi.max(Vector2i(ijk[u], ijk[v]))
	var nu := hi.x - lo.x + 1
	var nv := hi.y - lo.y + 1
	var keys := PackedByteArray()
	keys.resize(nu * nv)
	for c: int in cells:
		var ijk: Vector3i = breaks.cells[c].ijk
		keys[(ijk[u] - lo.x) + nu * (ijk[v] - lo.y)] = 1
	var pieces := []
	for box: Array in MapDestruction._merge_flat(nu, nv, keys, 1):
		# (a box is its first and last cell each way, counted from the corner of these cells)
		var local: AABB = breaks._flat_extent(panel, [lo.x + int(box[0]), lo.y + int(box[1]), lo.x + int(box[2]), lo.y + int(box[3])])
		pieces.append(MapDestruction.painted(panel, {"xf": (panel.xf as Transform3D) * Transform3D(Basis(), local.get_center()), "size": local.size,
			"kind": panel.kind, "solid": true, "shape": "box", "tint": panel.tint}))
		# What is on its face (a lamp strip, the frosting on glass) goes with it.
		for skin: Dictionary in panel.skins:
			var clipped: AABB = breaks._clip_skin(panel, skin.box, local)
			if clipped.has_volume():
				pieces.append({"xf": (panel.xf as Transform3D) * Transform3D(Basis(), clipped.get_center()), "size": clipped.size,
					"kind": skin.kind, "solid": true, "shape": "box", "tint": skin.tint})
	var holder := Node3D.new()
	var meshes := MapMesher.build(pieces, root.face_shade)
	for kind in meshes:
		var mi := MeshInstance3D.new()
		mi.mesh = MapMesher.riding(meshes[kind])
		mi.material_override = _material(kind)
		holder.add_child(mi)
	return holder


## What a kind is drawn with here: on a mover, what the mover's own blocks are.
func _material(kind: String) -> Material:
	return root.riding_material_for(kind) if on else root.material_for(kind)


## The warning is over: the units of `e` stop being part of the level (their cells
## fall, their loose things and column storeys go) and its pieces stand in their place,
## each to let go when its turn comes. `quiet`: for a copy that joined later (no dust).
func _let_go(e: Dictionary, quiet: bool) -> void:
	_plan(e, 0.0)
	_make_some(e, 0.0)
	e.state = FALLING
	e.age = 0.0
	# The cells, marked fallen: gone from their panels with no rubble of their own.
	if breaks:
		var ids := PackedInt32Array()
		for unit: int in (e.units as PackedInt32Array):
			for c: int in _unit_cells.get(unit, PackedInt32Array()):
				if int(breaks.cells[c].stage) < MapDestruction.BROKEN:
					ids.append(c)
		if not ids.is_empty():
			var stages := PackedByteArray()
			stages.resize(ids.size())
			stages.fill(MapDestruction.FALLEN)
			_letting_go = true
			breaks.apply(ids, stages)
			_letting_go = false
	# What stood in those bays goes with them: blanked where it is drawn (see _hide).
	var shown := {}
	for b: int in e.bays:
		shown[b] = mini(int(bays[b].shown), levels())
	for unit: int in (e.units as PackedInt32Array):
		bays[unit / 16].shown = mini(int(bays[unit / 16].shown), unit % 16)
	for b: int in e.bays:
		var all_hidden := true
		for level in range(int(bays[b].shown), int(shown[b])):
			for piece: Dictionary in bays[b].loose[level]:
				if not _hide(piece):
					all_hidden = false
		_build_bay(b, not all_hidden)
	for p: Dictionary in e.pieces:
		if p.body == null:
			continue
		if int(p.segment) >= 0:
			_segment_gone(p.segment, false)
		var body: RigidBody3D = p.body
		body.visible = true
		body.collision_layer = 1   # part of the level: you stand on it, and it stops a shot
		body.collision_mask = 1    # ...and nobody pushes it about (the same fall for everyone)
	if _redraw:
		_draw_standing()
	if root.marks and on == null:   # (on a mover the marks are on its cells, and go with them)
		for box: AABB in e.boxes:
			root.marks.clear_in(box)
	changed.emit((e.boxes as Array).map(_box_out))
	if not quiet:
		_shake(e, 1.0)
		var sound := get_node_or_null("/root/Sound")
		if sound:
			sound.play_at("explosion_far", _out(e.at), "far", 4.0)
			var p = sound.play_at("break_concrete", _out(e.at), "fire", 8.0)
			if p:
				p.pitch_scale *= 0.55


## A piece of a building that stood on its walls, as it lets go: tipped outwards from
## the middle of its bay. (A wall cut loose over the wall it stood on would otherwise
## stay there, a stack of loose blocks that looks like a wall.) The same on every copy:
## `n` says how hard, between a little and a lot.
func _topple(p: Dictionary, n: int) -> void:
	var body: RigidBody3D = p.body
	var c: Vector3 = p.c
	var b := bay_at(c)
	var middle := Vector3((_lines_x[0] + _lines_x[-1]) * 0.5, 0.0, (_lines_z[0] + _lines_z[-1]) * 0.5)
	if b >= 0:
		middle = Vector3((float(bays[b].x0) + float(bays[b].x1)) * 0.5, 0.0, (float(bays[b].z0) + float(bays[b].z1)) * 0.5)
	var away := Vector3(c.x - middle.x, 0.0, c.z - middle.z)
	var far := away.length()
	if far < 0.5:
		return   # (a floor: it has nothing under it anyway)
	away /= far
	var hard := (0.6 + 0.8 * float((n * 2654435761) % 1000) / 1000.0) * minf(1.0, far / 2.0)
	var turn := global_transform.basis.orthonormalized()
	body.linear_velocity = turn * (away * TOPPLE * hard)
	body.angular_velocity = turn * (Vector3.UP.cross(away) * TOPPLE_TURN * hard)   # (its top goes first)


## One step of a fall: pieces let go in turn, dust where they tear free and where the
## heavy ones land; the host sends its news and says when it is over.
func _fall(e: Dictionary, delta: float) -> void:
	var age: float = e.age
	var pieces: Array = e.pieces
	var awake := 0   # pieces still to let go, or still moving (one that hangs by its bars never quite sleeps)
	var fast := 0    # ...and those still falling
	var calm: bool = age >= CALM_AFTER and age - delta < CALM_AFTER
	var dusty: bool = root.debris != null and DisplayServer.get_name() != "headless"
	for p: Dictionary in pieces:
		if p.body == null:
			continue
		var body: RigidBody3D = p.body
		if not p.out:
			awake += 1
			if age >= float(p.at):
				p.out = true
				if p.target == null:   # (a piece the host already has at rest stays put)
					body.freeze = false
					if frame.held_by_walls:
						_topple(p, pieces.find(p) + int(e.seed))
				if not (p.pins as Array).is_empty():
					body.linear_damp = 0.5    # (it swings on its bars, and soon hangs still)
					body.angular_damp = 1.5
				for at: Vector3 in p.pins:
					var pin := PinJoint3D.new()
					add_child(pin)
					pin.global_position = to_global(at)
					pin.node_a = pin.get_path_to(body)
					(e.get_or_add("joints", []) as Array).append(pin)
				if dusty and p.big and randf() < 0.4:
					root.debris.dust(_out(body.transform * (p.c as Vector3)), "concrete", Vector3.DOWN)
			continue
		if not body.sleeping and not body.freeze:
			var where := _out(body.transform * (p.c as Vector3))
			if where.y < root.kill_height - 4.0:
				# (Off the edge of an island, or out of a tower, and away below the map: it is gone. See _solidify.)
				body.freeze = true
				body.visible = false
				continue
			if not WorldGravity.zones.is_empty():
				body.gravity_scale = WorldGravity.zone_at(where)   # (out of a hole in a tower in orbit, it drifts)
			var v := body.linear_velocity
			if v.length_squared() > 0.01 or body.angular_velocity.length_squared() > 0.04:
				awake += 1
				if v.length_squared() > 2.25:
					fast += 1
			if calm:
				body.linear_damp = maxf(body.linear_damp, 0.4)
				body.angular_damp = maxf(body.angular_damp, 1.2)
			var last: Vector3 = p.last
			if dusty and last.y < -3.5 and v.y > last.y * 0.5 and body.mass > 100.0:
				root.debris.dust(_out(body.transform * (p.c as Vector3)) + Vector3(randf_range(-1, 1), 0.3, randf_range(-1, 1)), "concrete", Vector3.UP * 3.0)
				if p.big and randf() < 0.3:
					_shake(e, 0.35)
			p.last = v
	if e.hosting:
		_send_news(e)
		e["quiet"] = float(e.get("quiet", 0.0)) + delta if awake == 0 else 0.0
		if (age > 2.0 and float(e.quiet) > 0.75) or (age > REST_AFTER and fast == 0) or age > REST_LATEST:
			var data := poses(e)
			rest_out.emit(int(e.id), data)
			rest(int(e.id), data)
	else:
		_remember(e)


# ---------------------------------------------------------------------------
# Between players

## Host: collapse `id` is this copy's to referee (it sends the news and calls the end).
func host(id: int) -> void:
	for e: Dictionary in events:
		if int(e.id) == id:
			e.hosting = true


## Is anything coming down right now?
func falling() -> bool:
	for e: Dictionary in events:
		if int(e.state) == FALLING:
			return true
	return false


## Host: where its pieces are, for the others: those that moved since it last said, the
## big ones more often. One piece: which (2 bytes), moving or at rest (1), where (12),
## how it is turned (8), and if moving how fast (6) and its spin (6).
func _send_news(e: Dictionary) -> void:
	var ticks: float = Engine.physics_ticks_per_second
	var every_big := maxi(1, roundi(ticks / BIG_HZ))
	var every_small := maxi(1, roundi(ticks / SMALL_HZ))
	var pieces: Array = e.pieces
	var n := pieces.size()
	for i in n:
		var p: Dictionary = pieces[i]
		if p.out and (_tick + i) % (every_big if p.big else every_small) == 0:
			p.due = true
	# No more than NEWS_RATE bytes a second: when everything moves at once the big pieces
	# go first and the rest wait their turn (each sweep starts where the last one stopped).
	var budget := minf(float(e.get("budget", NEWS_RATE * 0.1)) + NEWS_RATE / ticks, NEWS_RATE * 0.1)
	e["budget"] = budget
	if _tick % NEWS_EVERY != 0:
		return
	var out := StreamPeerBuffer.new()
	for small in 2:
		var turn := "turn_small" if small else "turn_big"
		var first := int(e.get(turn, 0))
		for k in n:
			var i := (first + k) % n
			var p: Dictionary = pieces[i]
			if p.body == null or not p.due or p.big == (small == 1):
				continue
			var body: RigidBody3D = p.body
			var xf := body.transform
			if body.sleeping:
				if p.rest_sent:
					p.due = false
					continue
				if budget < 23.0:
					e[turn] = i
					break
				budget -= 23.0
				p.rest_sent = true
				_write(out, i, 2, xf, p.c, Vector3.ZERO, Vector3.ZERO)
			else:
				p.rest_sent = false
				var was: Transform3D = p.sent_xf
				if p.sent and (was * (p.c as Vector3)).distance_to(xf * (p.c as Vector3)) < MOVED \
						and was.basis.get_rotation_quaternion().angle_to(xf.basis.get_rotation_quaternion()) < TURNED:
					p.due = false
					continue
				if budget < 35.0:
					e[turn] = i
					break
				budget -= 35.0
				p.sent = true
				p.sent_xf = xf
				_write(out, i, 1, xf, p.c, body.linear_velocity, body.angular_velocity)
			p.due = false
			if out.get_size() >= NEWS_BYTES:
				news_out.emit(int(e.id), float(e.age), out.data_array)
				out = StreamPeerBuffer.new()
	e["budget"] = budget
	if out.get_size() > 0:
		news_out.emit(int(e.id), float(e.age), out.data_array)


static func _write(out: StreamPeerBuffer, i: int, state: int, xf: Transform3D, c: Vector3, lin: Vector3, ang: Vector3) -> void:
	out.put_u16(i)
	out.put_u8(state)
	var at := xf * c
	out.put_float(at.x)
	out.put_float(at.y)
	out.put_float(at.z)
	var q := xf.basis.get_rotation_quaternion()
	for part: float in [q.x, q.y, q.z, q.w]:
		out.put_16(clampi(roundi(part * 32767.0), -32767, 32767))
	if state == 1:
		for part: float in [lin.x, lin.y, lin.z]:
			out.put_16(clampi(roundi(part * 100.0), -32767, 32767))
		for part: float in [ang.x, ang.y, ang.z]:
			out.put_16(clampi(roundi(part * 1000.0), -32767, 32767))


## Everyone but the host: the host's news of collapse `id`, made when its fall was
## `age` seconds old. Each piece in it is pulled to where the host had it: what is
## compared is where this copy had the piece at that same age (it runs the same fall a
## little later), and the difference is taken out of where the piece is now.
func news(id: int, age: float, data: PackedByteArray) -> void:
	for e: Dictionary in events:
		if int(e.id) != id or int(e.state) != FALLING or e.hosting:
			continue
		var pieces: Array = e.pieces
		var buf := StreamPeerBuffer.new()
		buf.data_array = data
		while buf.get_available_bytes() >= 23:
			var i := buf.get_u16()
			var state := buf.get_u8()
			var at := Vector3(buf.get_float(), buf.get_float(), buf.get_float())
			var q := Quaternion(buf.get_16() / 32767.0, buf.get_16() / 32767.0, buf.get_16() / 32767.0, buf.get_16() / 32767.0).normalized()
			var lin := Vector3.ZERO
			var ang := Vector3.ZERO
			if state == 1:
				if buf.get_available_bytes() < 12:
					return
				lin = Vector3(buf.get_16(), buf.get_16(), buf.get_16()) / 100.0
				ang = Vector3(buf.get_16(), buf.get_16(), buf.get_16()) / 1000.0
			if i >= pieces.size() or pieces[i].body == null:
				continue
			var p: Dictionary = pieces[i]
			if state == 2:
				p.target = [at, q]
				_settle(p)
			else:
				p.target = null
				_correct(e, i, at, q, lin, ang, age)


## A piece the host has at rest goes to exactly there and stops.
func _settle(p: Dictionary) -> void:
	var body: RigidBody3D = p.body
	var at: Vector3 = p.target[0]
	var basis := Basis(p.target[1] as Quaternion)
	body.freeze = true
	body.transform = Transform3D(basis, at - basis * (p.c as Vector3))
	p.out = true


## What this copy's pieces were doing, every so often, for news() to compare with:
## for each sample its age, and for each piece where (3), how turned (4), how fast (3)
## and its spin (3).
func _remember(e: Dictionary) -> void:
	var every := maxi(1, roundi(Engine.physics_ticks_per_second / HISTORY_HZ))
	if _tick % every != 0:
		return
	var pieces: Array = e.pieces
	if not e.has("memory"):
		var made := Memory.new()
		made.hist.resize(HISTORY * pieces.size() * 13)
		made.ages.resize(HISTORY)
		made.ages.fill(-1.0)
		e["memory"] = made
	var m: Memory = e.memory
	var slot := m.next
	m.next = (slot + 1) % HISTORY
	m.ages[slot] = float(e.age)
	var hist := m.hist   # (written through `m.hist` below: a packed array in a variable is its own copy once changed)
	var o := slot * pieces.size() * 13
	for p: Dictionary in pieces:
		if p.body != null:
			var body: RigidBody3D = p.body
			var xf := body.transform
			var at := xf * (p.c as Vector3)
			var q := xf.basis.get_rotation_quaternion()
			var lin := body.linear_velocity
			var ang := body.angular_velocity
			hist[o] = at.x; hist[o + 1] = at.y; hist[o + 2] = at.z
			hist[o + 3] = q.x; hist[o + 4] = q.y; hist[o + 5] = q.z; hist[o + 6] = q.w
			hist[o + 7] = lin.x; hist[o + 8] = lin.y; hist[o + 9] = lin.z
			hist[o + 10] = ang.x; hist[o + 11] = ang.y; hist[o + 12] = ang.z
		o += 13
	m.hist = hist


func _correct(e: Dictionary, i: int, at: Vector3, q: Quaternion, lin: Vector3, ang: Vector3, age: float) -> void:
	var p: Dictionary = e.pieces[i]
	var body: RigidBody3D = p.body
	if not p.out:
		# (the host's has let go and this one has not yet: it does now)
		p.out = true
		p.at = 0.0
	body.freeze = false
	var c: Vector3 = p.c
	var cur := body.transform
	# Where this copy had the piece when its own fall was that old: the nearest sample.
	var mine_at := cur * c
	var mine_q := cur.basis.get_rotation_quaternion()
	var mine_lin := body.linear_velocity
	var mine_ang := body.angular_velocity
	var n: int = (e.pieces as Array).size()
	var since: Array = []   # the samples made after that one: they move by the same amount
	var m: Memory = e.get("memory")
	if m:
		var ages := m.ages
		var hist := m.hist
		var best := -1
		for s in HISTORY:
			if ages[s] >= 0.0 and (best < 0 or absf(ages[s] - age) < absf(ages[best] - age)):
				best = s
		if best >= 0 and absf(ages[best] - age) < absf(float(e.age) - age):
			var o := (best * n + i) * 13
			mine_at = Vector3(hist[o], hist[o + 1], hist[o + 2])
			mine_q = Quaternion(hist[o + 3], hist[o + 4], hist[o + 5], hist[o + 6])
			mine_lin = Vector3(hist[o + 7], hist[o + 8], hist[o + 9])
			mine_ang = Vector3(hist[o + 10], hist[o + 11], hist[o + 12])
			for s in HISTORY:
				if ages[s] > ages[best]:
					since.append(s)
	var off := at - mine_at
	var turn := (q * mine_q.inverse()).normalized()
	var dlin := (lin - mine_lin) * 0.8
	var dang := (ang - mine_ang) * 0.8
	if off.length() < 0.015 and absf(turn.get_angle()) < 0.02 and dlin.length() < 0.08 and dang.length() < 0.15:
		return
	var basis := (Basis(turn) * cur.basis).orthonormalized()
	var centre := cur * c + off
	PhysicsServer3D.body_set_state(body.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(basis, centre - basis * c))
	body.linear_velocity += dlin
	body.angular_velocity += dang
	body.sleeping = false
	for s: int in since:   # (in place, in the Memory: no copy of it all for one piece)
		var o := (s * n + i) * 13
		m.hist[o] += off.x; m.hist[o + 1] += off.y; m.hist[o + 2] += off.z
		var was := Quaternion(m.hist[o + 3], m.hist[o + 4], m.hist[o + 5], m.hist[o + 6])
		var now := (turn * was).normalized()
		m.hist[o + 3] = now.x; m.hist[o + 4] = now.y; m.hist[o + 5] = now.z; m.hist[o + 6] = now.w
		m.hist[o + 7] += dlin.x; m.hist[o + 8] += dlin.y; m.hist[o + 9] += dlin.z
		m.hist[o + 10] += dang.x; m.hist[o + 11] += dang.y; m.hist[o + 12] += dang.z


## Where every piece of a collapse is: for each, 7 numbers (its middle, how it is
## turned); a piece that is not there counts too (zeros), so the list lines up.
func poses(e: Dictionary) -> PackedByteArray:
	var out := PackedFloat32Array()
	var pieces: Array = e.pieces
	out.resize(pieces.size() * 7)
	for i in pieces.size():
		var p: Dictionary = pieces[i]
		if p.body == null:
			continue
		var xf: Transform3D = (p.body as Node3D).transform
		var at := xf * (p.c as Vector3)
		var q := xf.basis.get_rotation_quaternion()
		var o := i * 7
		out[o] = at.x; out[o + 1] = at.y; out[o + 2] = at.z
		out[o + 3] = q.x; out[o + 4] = q.y; out[o + 5] = q.z; out[o + 6] = q.w
	return out.to_byte_array()


## Does a poses() say the host has no piece at `o`? (Nothing was written there: no turn
## at all, which no piece has.)
static func _absent(list: PackedFloat32Array, o: int) -> bool:
	return o + 6 < list.size() and list[o + 3] == 0.0 and list[o + 4] == 0.0 and list[o + 5] == 0.0 and list[o + 6] == 0.0


## Puts every piece of `e` where `data` (a poses()) has it, at once, frozen.
func _put(e: Dictionary, data: PackedByteArray) -> void:
	var list := data.to_float32_array()
	var pieces: Array = e.pieces
	for i in mini(pieces.size(), list.size() / 7):
		var p: Dictionary = pieces[i]
		if p.body == null:
			continue
		var o := i * 7
		var body: RigidBody3D = p.body
		if _absent(list, o):
			body.queue_free()   # (the host has no such piece)
			p.body = null
			continue
		var basis := Basis(Quaternion(list[o + 3], list[o + 4], list[o + 5], list[o + 6]).normalized())
		body.freeze = true
		body.transform = Transform3D(basis, Vector3(list[o], list[o + 1], list[o + 2]) - basis * (p.c as Vector3))
		p.out = true
		p.target = [Vector3(list[o], list[o + 1], list[o + 2]), Quaternion(list[o + 3], list[o + 4], list[o + 5], list[o + 6]).normalized()]


## Everyone: the pieces of collapse `id` have come to rest on the host, at `data` (a
## poses()). That is final: this copy's stop and slide there, and become the level.
func rest(id: int, data: PackedByteArray) -> void:
	for e: Dictionary in events:
		if int(e.id) != id or int(e.state) >= SLIDING:
			continue
		if int(e.state) == WAITING:
			_let_go(e, true)   # (it was over on the host before it began here)
		var list := data.to_float32_array()
		var pieces: Array = e.pieces
		for i in pieces.size():
			var p: Dictionary = pieces[i]
			if p.body == null:
				continue
			var body: RigidBody3D = p.body
			var o := i * 7
			if _absent(list, o):
				body.queue_free()   # (the host has no such piece: it went with what it stood on there, before the fall)
				p.body = null
				continue
			body.freeze = true
			p["from"] = body.transform
			if o + 6 < list.size():
				p.target = [Vector3(list[o], list[o + 1], list[o + 2]), Quaternion(list[o + 3], list[o + 4], list[o + 5], list[o + 6]).normalized()]
			else:
				p.target = [body.transform * (p.c as Vector3), body.transform.basis.get_rotation_quaternion()]
		e.state = SLIDING
		e.age = 0.0
		e["final"] = data


func _slide(e: Dictionary) -> void:
	var a := smoothstep(0.0, 1.0, clampf(float(e.age) / SLIDE, 0.0, 1.0))
	for p: Dictionary in e.pieces:
		if p.body == null:
			continue
		var from: Transform3D = p.from
		var c: Vector3 = p.c
		# (At the end exactly where the host has it, not a rounding away: from different
		# starts the last step of a blend lands a millionth of a metre apart, and the
		# heaps are compared to the millimetre.)
		var basis := Basis(p.target[1] as Quaternion) if a >= 1.0 else Basis(from.basis.get_rotation_quaternion().slerp(p.target[1], a))
		var at: Vector3 = p.target[0] if a >= 1.0 else (from * c).lerp(p.target[0], a)
		(p.body as RigidBody3D).transform = Transform3D(basis, at - basis * c)
	if float(e.age) >= SLIDE:
		_solidify(e)


## The pile is part of the level from here on: one body that does not move (the bots'
## navigation is laid over it like the rest of the level).
func _solidify(e: Dictionary) -> void:
	e.state = DOWN
	for joint: Node in e.get("joints", []):
		joint.queue_free()
	var lots := {}   # what the pieces are drawn with -> what is drawn with it (see _gather)
	var heap := Node3D.new()
	heap.name = "Heap_%d" % int(e.id)
	var body := _fixed_body()
	body.name = "Collision"
	var boxes: Array = []
	for p: Dictionary in e.pieces:
		if p.body == null:
			continue
		var from: RigidBody3D = p.body
		var xf := from.transform
		if _out(xf * (p.c as Vector3)).y < root.kill_height:
			from.queue_free()   # (it fell off the island, or out of the tower: no part of the pile)
			p.body = null
			continue
		for child in from.get_children():
			if child is CollisionShape3D:
				from.remove_child(child)
				(child as Node3D).transform = xf * (child as Node3D).transform
				body.add_child(child)
			else:
				for mi: MeshInstance3D in child.find_children("*", "MeshInstance3D", true, false):
					_gather(lots, mi, xf * (child as Node3D).transform * mi.transform)
		boxes.append((xf * (p.box as AABB)).grow(0.3))
		from.queue_free()
		p.body = null
	e.pieces = []
	e.erase("memory")
	for lot: Lot in lots.values():
		heap.add_child(_gathered(lot))
	heap.add_child(body)
	add_child(heap)
	e["heap"] = heap
	if _parked:
		body.collision_layer = 0
	changed.emit(boxes.map(_box_out))
	var places := PackedInt32Array()   # where each shape of the pile is, to the millimetre
	for shape: Node3D in body.get_children():
		var at := shape.transform.origin
		places.append_array([roundi(at.x * 1000.0), roundi(at.y * 1000.0), roundi(at.z * 1000.0)])
	settled.emit(int(e.id), "%d %08x" % [body.get_child_count(), hash(places)])


## One small piece of each kind of thing the building is made of, drawn the two ways a
## collapse draws them (falling, and lying in a pile), under `stage`: see FxWarmup.
func warm(stage: Node3D) -> void:
	if not root.has_meshes:
		return
	var kinds := {}   # kind -> a piece of it
	if breaks:
		for panel: Dictionary in breaks.panels:
			if (panel.piece as Dictionary).get("framed", false) and not kinds.has(panel.kind):
				kinds[panel.kind] = panel.piece
	for seg: Dictionary in segments:
		if not seg.has("cells") and not kinds.has(seg.piece.kind):
			kinds[seg.piece.kind] = seg.piece
	for bay: Dictionary in bays:
		for level: Array in bay.loose:
			for piece: Dictionary in level:
				for part: Dictionary in [piece] + (piece.get("with", []) as Array):
					if not kinds.has(part.kind) and not part.get("hidden", false):
						kinds[part.kind] = part
	var small := []
	for kind: String in kinds:
		var piece: Dictionary = (kinds[kind] as Dictionary).duplicate()
		piece.xf = Transform3D.IDENTITY
		piece.size = Vector3.ONE * 0.2
		piece.shape = "box"
		piece.erase("with")
		small.append(piece)
	if small.is_empty():
		return
	var falling := _piece_mesh(small, true)
	stage.add_child(falling)
	var lots := {}
	for mi: MeshInstance3D in falling.find_children("*", "MeshInstance3D", true, false):
		_gather(lots, mi, Transform3D.IDENTITY)
	for lot: Lot in lots.values():
		stage.add_child(_gathered(lot))


## One of a fallen piece's meshes, for the pile's: the pieces of a pile do not move
## again, so everything in it drawn the same way becomes one mesh (a pile of two
## hundred pieces is drawn as a handful). `lots`: material -> Lot.
func _gather(lots: Dictionary, mi: MeshInstance3D, xf: Transform3D) -> void:
	if mi.mesh == null or mi.mesh.get_surface_count() == 0:
		return
	var arrays := mi.mesh.surface_get_arrays(0)
	var at: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var facing: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	if at.is_empty():
		return   # (nothing is drawn: a server with no screen)
	var lot: Lot = lots.get(mi.material_override)
	if lot == null:
		lot = Lot.new()
		lot.material = mi.material_override
		lot.shadows = mi.cast_shadow
		lots[mi.material_override] = lot
	lot.at.append_array(xf * at)
	lot.facing.append_array(Transform3D(xf.basis.orthonormalized(), Vector3.ZERO) * facing)
	lot.colours.append_array(arrays[Mesh.ARRAY_COLOR])
	# A face whose pattern was moved (MapBlock.face_patterns) tells the shader so in
	# CUSTOM0, which the pile's mesh uses for where its corners were: the pattern is
	# worked into where they were here, so it stays where it was.
	var pattern: Variant = arrays[Mesh.ARRAY_CUSTOM0]
	if pattern is PackedFloat32Array and (pattern as PackedFloat32Array).size() == at.size() * 4:
		var settings: PackedFloat32Array = pattern
		var was := at.duplicate()
		for i in at.size():
			var custom := Vector4(settings[i * 4], settings[i * 4 + 1], settings[i * 4 + 2], settings[i * 4 + 3])
			if custom != Vector4.ZERO:
				was[i] = MapMesher.pattern_place(at[i], facing[i], custom)
		lot.was_at.append_array(was)
	else:
		lot.was_at.append_array(at)
	lot.was_facing.append_array(facing)


## The one mesh of a lot. Each vertex carries where it was, and how it faced, while its
## piece was whole and in its place: the surface's pattern is still measured from there
## (map_surface.gdshader), so nothing about a piece changes as the pile sets.
func _gathered(lot: Lot) -> MeshInstance3D:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = lot.at
	arrays[Mesh.ARRAY_NORMAL] = lot.facing
	arrays[Mesh.ARRAY_COLOR] = lot.colours
	var mark := PackedVector2Array()
	mark.resize(lot.at.size())
	mark.fill(Vector2(2, 0))
	arrays[Mesh.ARRAY_TEX_UV2] = mark
	arrays[Mesh.ARRAY_CUSTOM0] = lot.was_at.to_byte_array().to_float32_array()
	arrays[Mesh.ARRAY_CUSTOM1] = lot.was_facing.to_byte_array().to_float32_array()
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
		(Mesh.ARRAY_CUSTOM_RGB_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) | (Mesh.ARRAY_CUSTOM_RGB_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT))
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = lot.material
	mi.cast_shadow = lot.shadows
	return mi


## Host: is someone standing here (feet, height) under a big piece coming down fast?
## {by, with}: whose collapse it is, or {}.
func crushes(feet: Vector3, height: float) -> Dictionary:
	feet = _in(feet)
	var middle := feet + Vector3(0, height * 0.5, 0)
	for e: Dictionary in events:
		if int(e.state) != FALLING:
			continue
		for p: Dictionary in e.pieces:
			if p.body == null or not p.big or not p.out:
				continue
			var body: RigidBody3D = p.body
			if body.freeze or body.sleeping or body.linear_velocity.y > -CRUSH_SPEED:
				continue
			var local := body.transform.affine_inverse() * middle
			var box: AABB = p.box
			# (under it, or in it: not standing on top of it)
			if box.grow(0.25).has_point(local) and (body.transform * (p.c as Vector3)).y > feet.y + height * 0.4:
				return {"by": int(e.by), "with": String(e.with)}
	return {}


## Host: everything a copy that has just joined needs: {columns: [segments, stages],
## events: [[the start(), {age, done, poses}]...]}.
func state() -> Dictionary:
	var ids := PackedInt32Array()
	var stages := PackedByteArray()
	for i in segments.size():
		if int(segments[i].stage) != 0:
			ids.append(i)
			stages.append(int(segments[i].stage))
	var list := []
	for e: Dictionary in events:
		var first := {"id": e.id, "units": e.units, "seed": e.seed, "at": e.at, "by": e.by, "with": e.with}
		if int(e.state) == WAITING:
			list.append([first, {}])
		elif int(e.state) == DOWN:
			list.append([first, {"age": 0.0, "done": true, "poses": e.get("final", PackedByteArray()), "dropped": e.get("dropped", false)}])
		else:
			list.append([first, {"age": e.age, "done": false, "poses": poses(e)}])
	return {"columns": [ids, stages], "events": list}


## A copy that has just joined: what state() said. (After what is broken: see
## MatchState.request_breaks.)
func restore(s: Dictionary) -> void:
	var columns: Array = s.get("columns", [])
	if columns.size() >= 2:
		apply_columns(columns[0], columns[1])
	for pair: Array in s.get("events", []):
		start(pair[0], pair[1])


# ---------------------------------------------------------------------------
# A building on an island that goes below the map and comes back

## The mover this rides was parked below the map, or brought back (MapIsland.set_parked).
## Nobody sees or reaches it down there: whatever was still coming down is gone, and
## nothing of the building is there to hit.
func set_parked(parked: bool) -> void:
	_parked = parked
	if parked:
		for e: Dictionary in events:
			if int(e.state) != DOWN:
				_drop(e)
	for node: Node in find_children("*", "CollisionObject3D", true, false):
		if not node is RigidBody3D:
			(node as CollisionObject3D).collision_layer = 0 if parked else 1


## Collapse `e` is over with nothing left of it: its units are gone, and so are its
## pieces. (For a copy that joins later it is told as down, with no pile.)
func _drop(e: Dictionary) -> void:
	if int(e.state) == WAITING:
		_let_go(e, true)
	for joint: Node in e.get("joints", []):
		joint.queue_free()
	e.erase("joints")
	for p: Dictionary in e.pieces:
		if p.body:
			(p.body as Node).queue_free()
	e.pieces = []
	e.erase("memory")
	e.state = DOWN
	e["dropped"] = true


## Everyone: the building is as it was built (its island came back up mended: see
## MapRoot.mend, which then makes its walls and floors whole).
func mend() -> void:
	for e: Dictionary in events:
		if int(e.state) != DOWN:
			_drop(e)
		if e.has("heap"):
			(e.heap as Node).queue_free()
	var had := not events.is_empty() or not _losing.is_empty()
	events.clear()
	_pending.clear()
	_weak.clear()
	_losing.clear()
	_gone.clear()
	for seg: Dictionary in segments:
		if seg.has("cells"):   # (a column of its own that was blown out is not put back)
			seg.stage = 0
			seg.fallen = false
	for bay: Dictionary in bays:
		for level: Array in bay.loose:
			for piece: Dictionary in level:
				if piece.get("lost", false):
					piece["lost"] = false
					had = true
	if not had:
		return
	for b in bays.size():
		bays[b].from = levels()
		bays[b].shown = levels()
		_build_bay(b)
	_redraw |= LOOSE
	_draw_standing()


# ---------------------------------------------------------------------------
# Shapes

## The plan of a rectangle `w` by `h` shared out between `seeds`: for each, the corners
## of the part nearer it than any other (empty if it has none).
static func _voronoi(w: float, h: float, seeds: Array) -> Array:
	var polys := []
	for i in seeds.size():
		var poly := PackedVector2Array([Vector2(0, 0), Vector2(w, 0), Vector2(w, h), Vector2(0, h)])
		for j in seeds.size():
			if i == j or poly.size() < 3:
				continue
			var mid: Vector2 = ((seeds[i] as Vector2) + (seeds[j] as Vector2)) * 0.5
			var normal: Vector2 = ((seeds[j] as Vector2) - (seeds[i] as Vector2)).normalized()
			var cut := PackedVector2Array()
			for k in poly.size():
				var a := poly[k]
				var b := poly[(k + 1) % poly.size()]
				var da := (a - mid).dot(normal)
				var db := (b - mid).dot(normal)
				if da <= 0.0:
					cut.append(a)
				if (da < 0.0) != (db < 0.0) and absf(da - db) > 1e-9:
					cut.append(a.lerp(b, da / (da - db)))
			poly = cut
		polys.append(poly)
	return polys


## A polygon shrunk toward its middle by `gap` metres.
static func _inset(poly: PackedVector2Array, gap: float) -> PackedVector2Array:
	var mid := Vector2.ZERO
	for p in poly:
		mid += p
	mid /= poly.size()
	var out := PackedVector2Array()
	for p in poly:
		var d := p - mid
		out.append(mid + d * maxf(0.0, 1.0 - gap / maxf(d.length(), 0.001)))
	return out
