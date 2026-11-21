@tool
class_name MapFrame
extends Node3D
## A building that can come down (see MapCollapse): a frame of columns on a grid, with a
## floor at each level. Put one in a map with fine destruction, at the map's origin, and
## say where the frame is; the blocks under `parts` are the building. Blow out the
## columns under a bay (the square of floor between four columns) and that bay, and
## everything above it, falls.
##
## A frame can also go inside a MapMover or MapIsland (a building on a flying island):
## then the lines and heights are in the mover's own frame, and the building rides it.
##
## A building with no columns stands on its walls: tick **Held By Walls**. Then each
## crossing of the lines that has breakable wall near it counts as a column made of
## that wall, a storey at a time, and it is gone once enough of the wall is. Nothing
## of such a building is kept from breaking because something stands on it: what
## stands on or hangs from a wall or floor that breaks goes with it. Tick **To The
## Ground** as well and the ground floor can come down too, so the whole building can
## be levelled.

## The parts of the map that are the building (its floors, walls, columns and what
## stands on them): only blocks under these can fall. (Paths from this node.)
@export var parts: Array[NodePath] = []
## Only the blocks under `parts` whose middle is inside this box are this building's
## (empty: all of them). For a map with several buildings that share parts: a tower
## whose storeys are each a building of their own, one over another.
@export var claim := AABB()
## Where the lines of columns are, along x and along z (metres, in the map or the mover).
@export var lines_x := PackedFloat32Array()
@export var lines_z := PackedFloat32Array()
## The top of each floor, lowest first. The ground is not one: nothing on it falls.
@export var floor_tops := PackedFloat32Array()
## How far the floors reach out past the outermost lines of columns.
@export var overhang := 0.9
## How far below a floor's top what belongs to that floor starts (its slab, and what hangs under it).
@export var slab := 0.45
## The kind of block the columns are made of: tall blocks of it on the grid are the columns.
@export var column_kind := "concrete"
## What stands whatever happens (a lift core): a bay it stands in never falls.
@export var core := AABB()
## How much damage one storey of a column takes before it is blown out, and how hard a
## single hit has to be to do it any (small arms only mark it).
@export var column_health := 600.0
@export var column_armour := 60.0
## The building stands on its walls, not on columns: the breakable upright walls within
## Wall Reach of a crossing of the lines hold up what a column there would.
@export var held_by_walls := false
## How far along a wall from a crossing the wall that counts as its column reaches.
@export var wall_reach := 2.5
## How much of that wall (of what can break of it) has to be gone, in one storey, for
## the storey to count as blown out.
@export_range(0.1, 1.0) var wall_share := 0.6
## (Held By Walls) The storey whose wall goes comes down too, with everything on it,
## the ground floor included: all of the building can end as rubble.
@export var to_the_ground := false
## (To The Ground) How high the building's ground floor is.
@export var ground := 0.0
## (Held By Walls) A thing goes once this share of what it stands on, or hangs from,
## has broken.
@export_range(0.1, 1.0) var rests_share := 0.5

## (To The Ground) Parts that span open space at the height of the ground floor (a
## bridge over a shaft: one of `parts`): they belong to the ground storey and come down
## with it, where the ground floor itself only breaks.
@export var spans: Array[NodePath] = []
## (Held By Walls) A section of a floor (a bay's, at one level) caves in, with the walls
## under it and all there is above it in the bay, once this share of the floor itself
## has been broken, whatever holds it up: a ceiling shot half away comes down. 0: never.
@export_range(0.0, 1.0) var cave_share := 0.0


## Is a block whose middle is at `at` (in the map, or the mover) one of this building's?
func claims(at: Vector3) -> bool:
	return claim.size == Vector3.ZERO or claim.has_point(at)
