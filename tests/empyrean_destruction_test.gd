extends SceneTree
## Empyrean Tower comes apart: its walls, floors and outer wall break small, and each of
## its six tiers is a building of its own that comes down a section at a time.
## Run: godot --headless --fixed-fps 60 --path . --script tests/empyrean_destruction_test.gd
##
##  - the tower's stone and floors break, nothing of it is kept from breaking, and the
##    metre of outer wall breaks under a rocket but not under small arms;
##  - each tier has a collapse of its own, held up by its walls, claiming what lies
##    between its floor and the next;
##  - enough of a stretch of wall gone brings down the section over it in that tier
##    only: the tier above stands, and nobody spawns under what fell, but they do a
##    tier up;
##  - a bridge over the shaft caves in once enough of it is shot away, and takes none
##    of the rooms beside it;
##  - what falls outside the wall falls in the low gravity there;
##  - someone who joins afterwards is told what is broken and what fell, tier by tier,
##    and has the very same heaps and the same walls and floors gone.

const TIER := 30.5
const ROCKET := [1.575, 262.0]   # how far a rocket breaks things, and how hard

var failures := 0
var map: MapRoot
var heaps := {}   # the host's heaps: a collapse's number -> what MapCollapse.settled says of it


func _init() -> void:
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	if ok:
		print("  ok   ", what)
	else:
		print("  FAIL ", what)
		failures += 1


func _apply(d: MapDestruction) -> int:
	var change := d.flush()
	if change.is_empty():
		return 0
	return d.apply(change[0], change[1]).size()


## Everything the collapses make of the damage so far: the events that started.
func _flush_all() -> Array:
	var started := []
	for c in map.collapses:
		var out := c.flush()
		if out.is_empty():
			continue
		c.apply_columns(out.columns[0], out.columns[1])
		for ev: Dictionary in out.events:
			c.start(ev)
			c.host(int(ev.id))
			started.append(ev)
	return started


func _run() -> void:
	await process_frame
	map = Maps.make("empyrean")
	map.destructible = true
	root.add_child(map)
	map.build()
	for i in 4:
		await physics_frame
	var d := map.destruction
	for other in map.collapses:
		other.settled.connect(func(id: int, key: String): heaps[id] = key)

	print("  what breaks")
	var kinds := {}
	var guarded := 0
	var shell: Dictionary = {}
	for panel: Dictionary in d.panels:
		kinds[panel.kind] = true
		var n: Vector3i = panel.n
		for cell in range(int(panel.first), int(panel.first) + n.x * n.y * n.z):
			if d.cells[cell].protected:
				guarded += 1
		if shell.is_empty() and panel.kind == "stone" and float(panel.armour) >= MapDestruction.THICK_ARMOUR and n.x * n.y * n.z > 20:
			shell = panel
	for kind in ["stone", "stone_dark", "stone_floor", "floor_engine", "brass", "glass_stained"]:
		_check(kinds.has(kind), "%s breaks" % kind)
	_check(d.cells.size() > 80000, "the tower is made of pieces that break (%d)" % d.cells.size())
	_check(guarded == 0, "none of it is kept from breaking (%d pieces are)" % guarded)
	_check(not shell.is_empty(), "the outer wall breaks, in big pieces with armour")
	if not shell.is_empty():
		var first := int(shell.first)
		d.damage(first, 55.0)
		_check(_apply(d) == 0 and int(d.cells[first].stage) == 0, "small arms do nothing to it")
		var at := d.cell_center(first + 3)
		d.damage_area(at, ROCKET[0], ROCKET[1])
		var broke := _apply(d)
		_check(broke >= 1, "a rocket takes a piece out of it (%d)" % broke)
		for n in 3:
			d.damage_area(at, ROCKET[0], ROCKET[1])
			broke += _apply(d)
		_check(broke >= 3, "and a few make a breach (%d pieces)" % broke)
	_check(_flush_all().is_empty(), "a breach in the outer wall brings nothing down")

	print("  the tiers")
	var bays := [64, 64, 49, 49, 36, 36]
	_check(map.collapses.size() == 6, "each of the six tiers can come down (%d)" % map.collapses.size())
	if map.collapses.size() != 6:
		quit(1)
		return
	for i in 6:
		var c: MapCollapse = map.collapses[i]
		var walls := c.segments.filter(func(seg): return seg.has("cells"))
		_check(c.index == i and c.bays.size() == bays[i] and walls.size() == c.segments.size() and walls.size() >= 10
			and c.frame.claims(Vector3(0, TIER * i + 5.0, 0)) and not c.frame.claims(Vector3(0, TIER * i - 5.0, 0)),
			"tier %d: %d bays on %d stretches of wall, claiming its own height" % [i + 1, c.bays.size(), walls.size()])

	print("  a section comes down")
	var c: MapCollapse = map.collapses[0]
	var corner := Vector2i(2, 2)
	_check(c.has_column(corner, 1), "the Engine has a stretch of wall at a crossing of its ground storey")
	if not c.has_column(corner, 1):
		quit(1)
		return
	var seg: Dictionary = c.segments[c._columns[corner][1]]
	var cells: PackedInt32Array = seg.cells
	var need := ceili(cells.size() * c.frame.wall_share)
	for n in need - 1:
		d.damage(cells[n], 10000.0)
	_apply(d)
	_check(_flush_all().is_empty(), "with %d of its %d pieces gone the wall still holds" % [need - 1, cells.size()])
	d.damage(cells[need - 1], 10000.0)
	_apply(d)
	var started := _flush_all()
	_check(started.size() == 1 and map.collapse_of(int(started[0].id)) == c, "one more and a section of the Engine is coming down, and nothing of another tier")
	if started.size() != 1:
		quit(1)
		return
	var ev: Dictionary = started[0]
	var units: PackedInt32Array = ev.units
	var fell := {}
	for unit in units:
		fell[unit / 16] = true
	_check(units.size() >= 3 and units[0] % 16 == 0, "from the ground storey up (%d bays, %d floors of them)" % [fell.size(), units.size()])
	var e: Dictionary = c.events[0]
	for n in 400:
		await physics_frame
		if int(e.state) == MapCollapse.FALLING:
			break
	_check(int(e.state) == MapCollapse.FALLING and (e.pieces as Array).size() > 10, "after the warning it lets go (%d pieces)" % (e.pieces as Array).size())
	var fallen := 0
	var above := 0
	for unit in units:
		for cell: int in c._unit_cells.get(unit, PackedInt32Array()):
			if int(d.cells[cell].stage) == MapDestruction.FALLEN:
				fallen += 1
				if d.cell_center(cell).y > TIER - 1.0:
					above += 1
	_check(fallen > 100, "its walls and floors are no longer part of the tower (%d pieces of them)" % fallen)
	_check(above == 0, "none of them the next tier's floor")
	var bay: Dictionary = c.bays[fell.keys()[0]]
	var under := Vector3((c.frame.lines_x[bay.i] + c.frame.lines_x[int(bay.i) + 1]) * 0.5, 0.3, (c.frame.lines_z[bay.j] + c.frame.lines_z[int(bay.j) + 1]) * 0.5)
	_check(c.blocked(under) and map.under_rubble(under), "nobody is put under the section that fell")
	_check(not map.under_rubble(under + Vector3(0, TIER, 0)), "but they are a tier up, over the same spot")
	for n in 240:
		await physics_frame
	var inside := 0
	var heavy := 0
	for p: Dictionary in e.pieces:
		if p.body and is_instance_valid(p.body) and (p.body as Node3D).visible:
			inside += 1
			if is_equal_approx((p.body as RigidBody3D).gravity_scale, WorldGravity.zone_at((p.body as Node3D).global_transform * (p.c as Vector3))):
				heavy += 1
	_check(inside > 10 and heavy == inside, "each piece falls as hard as things do where it is (%d of %d)" % [heavy, inside])

	print("  a bridge over the shaft")
	var library: MapCollapse = map.collapses[1]
	var bridge := -1
	for p: int in library._span_units:
		if bridge < 0:
			bridge = p
	_check(bridge >= 0, "the Library has a bridge that can cave in")
	if bridge >= 0:
		var panel: Dictionary = d.panels[bridge]
		var n: Vector3i = panel.n
		var count := n.x * n.y * n.z
		# (shot away evenly along it: one end shot away alone lets go of that end)
		var order := []
		for k in count:
			order.append(int(panel.first) + k * 37 % count)
		var gone := ceili(count * library.frame.cave_share)
		for k in count / 4:
			d.damage(order[k], 10000.0)
		_apply(d)
		_check(_flush_all().is_empty(), "with a quarter of its %d pieces shot away it holds" % count)
		for k in range(count / 4, gone):
			d.damage(order[k], 10000.0)
		_apply(d)
		started = _flush_all()
		_check(started.size() == 1 and map.collapse_of(int(started[0].id)) == library, "with %d gone it is coming down" % gone)
		if started.size() == 1:
			var span: PackedInt32Array = started[0].units
			var mine := 0
			for unit in span:
				if (library._span_units[bridge] as Dictionary).has(unit):
					mine += 1
			_check(mine >= 1 and span.size() <= 12, "the bridge and what stands on it, not the rooms beside it (%d sections)" % span.size())

	print("  someone who joins afterwards")
	for n in 3600:   # (120 steps a second: a fall is called over 22 s after it began at the latest)
		if map.collapses.all(func(o): return o.events.all(func(ev): return int(ev.state) == MapCollapse.DOWN)):
			break
		await physics_frame
	_check(heaps.size() == 2, "both falls come to rest on the host (%d)" % heaps.size())
	var view := SubViewport.new()   # (a world of its own)
	view.own_world_3d = true
	view.size = Vector2i(16, 16)
	root.add_child(view)
	var late: MapRoot = Maps.make("empyrean")
	late.destructible = true
	view.add_child(late)
	late.build()
	var theirs := {}
	for other in late.collapses:
		other.settled.connect(func(id: int, key: String): theirs[id] = key)
	# (As MatchState does it: what is broken, then each collapse's state.)
	var all := d.snapshot()
	late.destruction.apply(all[0], all[1])
	for other in map.collapses:
		late.collapses[other.index].restore(other.state())
	for n in 120:
		await physics_frame
	_check(late.destruction.state_key() == d.state_key(), "they have the same walls and floors gone (%s)" % late.destruction.state_key())
	_check(theirs == heaps and not theirs.is_empty(), "and the very same heaps, each in its own tier (%s)" % [theirs])

	print("  falling outside")
	_check(is_equal_approx(WorldGravity.zone_at(Vector3(0, 5, 0)), 1.0) and WorldGravity.zone_at(Vector3(45, 40, 0)) < 0.5,
		"things weigh less outside the wall than inside")
	print("empyrean destruction: %s" % ("FAILED (%d)" % failures if failures else "ok"))
	quit(1 if failures else 0)
