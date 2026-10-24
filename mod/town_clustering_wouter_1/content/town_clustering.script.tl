--- Town Clustering - redistribute generated towns into clusters.
---
--- The engine places towns uniformly during map generation and there is no way
--- to influence that from the new game dialog (see NOTES.md - no mod code runs
--- in the menu, and a terrain generator can only shape terrain). So instead we
--- let generation finish untouched and rearrange towns afterwards, on the first
--- tick of a new game.
---
--- Towns are *relocated*, not deleted: the town count the player chose with the
--- Town Density setting is preserved exactly. Each town either keeps the
--- position the generator gave it, or is destroyed and re-created next to a
--- cluster centre. Terrain, rivers and industries are never touched.
---
--- The rebuild uses the same calls the Map Editor uses for its own town import
--- (gui/map_editor/map_editor.tl, makeTowns):
---
---   api.engine.terrain.makeMapFromGame  ->  the current towns, with names,
---                                           size factors and cargo needs
---   api.engine.mapgen.createTowns       ->  { toRemove, toAdd }
---   makeTownDestroyCmd / makeTownCreateCmd
---
--- A town that is listed with its `existing` entity is left alone; one listed
--- without it is created fresh, and any town in the world that the list no
--- longer mentions is returned in `toRemove`.
---
--- The mod only needs to be active when the game starts; afterwards it does
--- nothing and can safely be removed from the savegame.

local entity_util = ug_require "::/scripts/entity_util.tl" as EntityUtil

local LOG <const> = "[town-clustering] "
local MOD_ID <const> = "town_clustering_wouter_1"

--- Slider index (1-based) to value. Index 0 or missing falls back to DEFAULT.
--- Confirmed 1-based against the stock climate generators, which default to
--- index 3 of five values and mean "Medium" by it.
local CLUSTER_COUNTS <const> = { 2, 3, 4, 5, 6, 8 }
local KEEP_FRACTIONS <const> = { 0.30, 0.45, 0.60, 0.75, 1.00 }
local ISOLATED_SHARES <const> = { 0.0, 0.05, 0.10, 0.20 }

--- Cluster sizes follow a geometric series; these are the bounds the ratio is
--- drawn from, per slider position. A ratio of 1.0 makes every cluster the same
--- size; the lower the ratio, the more one conurbation dominates. The range is
--- a range rather than one number so that the same settings give a different
--- shape on a different map.
local VARIATION_RATIO_MIN <const> = { 1.00, 0.78, 0.55, 0.38 }
local VARIATION_RATIO_MAX <const> = { 1.00, 0.92, 0.80, 0.55 }

--- Isolated towns are scaled to this share of their generated size. They are
--- meant to read as hamlets left behind by the clustering, not as peers of the
--- towns in the conurbations.
local ISOLATED_SIZE_SCALE <const> = 0.45

--- Isolated towns come in small groups instead of alone: a lone town in an empty
--- stretch claims all of it, which is a poor fit for TF3's town regions, noise
--- and pollution. Each group is an anchor - a town far from every cluster - plus
--- up to two of its nearest generated neighbours within ISOLATED_GROUP_REACH,
--- all kept where the generator put them and scaled down. Anchors stay
--- ISOLATED_GROUP_GAP apart, so the groups do not line up along the one empty
--- strip the clusters left behind.
local ISOLATED_GROUP_REACH <const> = 3000.0
local ISOLATED_GROUP_GAP <const> = 4500.0

--- Only rearrange a genuinely fresh game. Adding this mod to an established
--- save and silently rebuilding half its towns would be catastrophic, so bail
--- out if any meaningful time has passed.
local MAX_START_GAME_TIME <const> = 60 * 60 * 24 * 10

--- Placement rules for a relocated town, all in metres.
---
--- MIN_TOWN_SPACING is deliberately far below the generator's own roughly one
--- town per 5 km2 - about 1400 m between neighbours - because packing towns
--- tighter than the engine ever would is the entire point. It still has to be
--- wide enough that two town centres do not try to grow through each other,
--- and 600 m is the tightest that has been tried in game.
---
--- Note that a cluster centre is itself a town, so it occupies the middle
--- before any mover is placed: the innermost ring that can actually be used is
--- the first one wider than this spacing, not the first ring.
local MIN_TOWN_SPACING <const> = 600.0

--- Base spacing between town centres in a cluster, per Cluster Density slider
--- position (Packed .. Scattered). MIN_TOWN_SPACING stays the hard floor under
--- all of them.
---
--- These are the *required* spacing at the core, not the distance towns end up
--- at. Picking at random among the valid spots on a ring, plus the growth
--- towards the fringe, leaves the nearest neighbour about 1.3x further out. The
--- values are calibrated (flat-terrain simulation of findSpot) so the median
--- nearest-neighbour distance lands at roughly 720 / 820 / 920 / 1020 / 1150 /
--- 1350 / 1600 / 1900 m. Packed sits below the floor on purpose: the floor then
--- decides most of it, which keeps Packed close to the original fixed 600 m.
local DENSITY_SPACINGS <const> = { 530.0, 610.0, 700.0, 770.0, 870.0, 1020.0, 1210.0, 1440.0 }
local DEFAULT_SPACING <const> = 770.0

--- Spacing grows from the core of a cluster to its outskirts: from the base
--- spacing one spacing out from the core (the first spot a town can actually
--- take, since the core town occupies the middle) to (1 + SPACING_GROWTH)
--- times it at the cluster's expected radius. Dense middle, looser fringe.
local SPACING_GROWTH <const> = 0.5

--- Each cluster draws its own multiplier on the base spacing, so one cluster
--- comes out compact and another loose under the same settings.
local CLUSTER_SPACING_MIN <const> = 0.80
local CLUSTER_SPACING_MAX <const> = 1.25

--- Ring geometry as a share of the cluster's own spacing. 0.7 and 0.4 are the
--- original 420 m and 240 m at 600 m spacing, so Packed rings match the old ones.
local FIRST_RING_SHARE <const> = 0.7
local RING_STEP_SHARE <const> = 0.4
local MAX_RINGS <const> = 18

--- Half-width of the probe that measures the map, in metres. Generous: the
--- probe binary-searches inside it, so a larger value costs a few calls only.
local MAP_PROBE_LIMIT <const> = 200000.0

--- Cluster shapes. Every cluster is laid out along one of these rather than in
--- rings around a single town, chosen per cluster by the Cluster Shapes slider:
--- Round only, Mixed (MIXED_WEIGHTS, in SHAPE_KINDS order) or Varied (equal).
local SHAPE_KINDS <const> = { "round", "elongated", "chain", "polycentric", "satellite" }
local MIXED_WEIGHTS <const> = { 0.40, 0.15, 0.15, 0.15, 0.15 }
local DEFAULT_SHAPE_MODE <const> = 3

--- A cluster expected to hold fewer towns than this is too small to read as
--- several cores or as a core with outliers, so it draws from the first three
--- kinds only.
local MIN_TOWNS_MULTI_CORE <const> = 5

--- Elongated: stretched along a random direction by this much (the area stays
--- the same, so the cross direction shrinks by the same factor).
local ELONGATED_ASPECT_MIN <const> = 1.8
local ELONGATED_ASPECT_MAX <const> = 3.0

--- Chain: a gently bending line through the cluster's centre, this many
--- spacings long per town, each segment turning up to CHAIN_MAX_TURN radians
--- from the one before. Towns fill a band along it, widening only if needed.
local CHAIN_LENGTH_PER_TOWN_MIN <const> = 0.8
local CHAIN_LENGTH_PER_TOWN_MAX <const> = 1.2
local CHAIN_MAX_TURN <const> = 0.6

--- Polycentric: the extra cores sit this far from the first. Satellite: the
--- outlying towns sit this far beyond the edge of the core - measured from the
--- edge rather than the centre, because a large core already reaches 2 km or
--- more and swallowed satellites placed a fixed distance from its centre. Both
--- are metres at Normal density and scale up with looser settings, so the parts
--- stay distinct.
local POLY_GAP_MIN <const> = 1500.0
local POLY_GAP_MAX <const> = 3000.0
local SATELLITE_GAP_MIN <const> = 1500.0
local SATELLITE_GAP_MAX <const> = 2500.0
local SATELLITE_SHARE <const> = 0.35
local SHAPE_REFERENCE_SPACING <const> = 770.0

--- The map border is avoided, not forbidden.
---
--- Cluster centres: a candidate within EDGE_MARGIN_SHARE of the map's shorter
--- side from the border has its claim (its distance to the centres already
--- chosen) scaled down, to EDGE_CENTRE_MIN_FACTOR right at the edge, and each
--- next centre is drawn from the CENTRE_PICK_FROM best claims rather than
--- always the single best - so corners stop being the automatic answer.
local EDGE_MARGIN_SHARE <const> = 0.15
local EDGE_CENTRE_MIN_FACTOR <const> = 0.35
local CENTRE_PICK_FROM <const> = 3

--- Town spots: within EDGE_SPOT_SOFT metres of the border a candidate is picked
--- less often, down to EDGE_SPOT_MIN_WEIGHT of the usual chance at the edge.
local EDGE_SPOT_SOFT <const> = 1500.0
local EDGE_SPOT_MIN_WEIGHT <const> = 0.25

--- Shapes: a direction (chain, elongated) or an extra point (polycentric core,
--- satellite) is drawn up to ORIENT_TRIES times until it stays EDGE_SPOT_SOFT
--- clear of the border; failing that, the draw that stays clearest is used.
local ORIENT_TRIES <const> = 4

--- Cluster sizes go to centres by room (see redistribute); each centre's room
--- is jittered by up to this share so the largest cluster is usually, not
--- always, the one with the most space.
local ROOM_JITTER <const> = 0.3
local ANGLES_PER_RING <const> = 12

--- How far a town may wander off its ring, as a share of that ring's radius.
--- Because it scales with the radius, the middle of a cluster stays tight while
--- the outskirts scatter - which is the shape real town groups have, and the
--- shape a fixed spacing cannot produce.
local JITTER_SHARE <const> = 0.18

--- No cluster drops below this share of the largest one's weight. Without a
--- floor, eight clusters at the low end of the ratio range leaves the last few
--- holding a single town each, which reads as a stray rather than as a group.
local SIZE_MIN_WEIGHT <const> = 0.18

--- A candidate is rejected if the ground rises or falls more than
--- MAX_SLOPE_DROP across a probe of SLOPE_PROBE metres either side of it, or if
--- any probe lands in water. Towns need buildable ground, and the generator's
--- own placer applies a similar test.
---
--- The ground is sampled in PROBE_DIRECTIONS directions at each of two radii,
--- so the whole disc around a candidate has to be reasonably flat and dry - not
--- just the point it sits on.
---
--- Both radii matter. 24 m alone missed a river or a bank just beyond it and
--- left the centre looking fine while the town had nowhere to build; 48 m alone
--- steps straight over a ditch or a ridge at 24 m. Eight directions rather than
--- four because at 48 m a feature lying diagonally between the axes slips
--- through a four-point test entirely.
---
--- Note that MAX_SLOPE_DROP applies across every sample, so widening the reach
--- also tightens the gradient a candidate may sit on - 14 m across 48 m is 29%,
--- where 14 m across 24 m was 58%. That is the intended direction, but it is
--- the knob to turn if clusters come out sparse or the log reports stranded
--- towns.
local SLOPE_PROBE <const> = 48.0
local SLOPE_PROBE_INNER <const> = 24.0
local PROBE_DIRECTIONS <const> = 8
local MAX_SLOPE_DROP <const> = 14.0

--- Creating towns is asynchronous. Stop waiting for the world to settle after
--- this many ticks and connect whatever is actually there.
local MAX_SETTLE_TICKS <const> = 240

--- A town is created empty and grows its first houses over the ticks that
--- follow, so a population of zero means nothing straight away. Wait until the
--- number of empty towns has stopped falling for this many consecutive checks
--- before concluding that whatever is left is a dud - usually a centre with no
--- room to build, hemmed in by a river or a slope.
local POPULATION_STABLE_TICKS <const> = 90
local MAX_POPULATION_TICKS <const> = 1200

local record Candidate
	--- the town as the generator left it
	source : GameMap.Town
	x : number
	y : number
	--- distance to the nearest chosen cluster centre
	dist : number
	--- index of that nearest centre
	centre : integer
	--- which of the three fates this town met
	kind : string
end

--- A town position that later placements must keep clear of. Two towns must
--- be at least the larger of their two spacings apart, so a town on the loose
--- fringe of a cluster keeps its neighbours at the fringe's distance.
local record Placed
	x : number
	y : number
	spacing : number
end

--- One part of a cluster's shape that towns are placed around: the core, an
--- extra core of a polycentric cluster, or one outlying point of a satellite
--- cluster.
local record Anchor
	x : number
	y : number
	--- movers meant to land here, and how many have
	quota : integer
	placed : integer
	--- the radius this part is expected to fill; spacing grows towards it
	radius : number
end

local record Shape
	kind : string
	--- anchors[1] is always the cluster's centre
	anchors : {Anchor}
	--- elongated: stretch factor and direction (radians)
	aspect : number
	angle : number
	--- chain: the bending line, as points, and its length
	pathX : {number}
	pathY : {number}
	pathLength : number
end

--- The playable map, as probed by mapBounds.
local record Bounds
	minX : number
	maxX : number
	minY : number
	maxY : number
end

--- Distance from a point to the nearest map border; negative outside the map.
local function edgeDistance(b : Bounds, x : number, y : number) : number
	return math.min(x - b.minX, b.maxX - x, y - b.minY, b.maxY - y)
end

local record State
	--- 0/nil = not started
	--- 1 = towns rebuilt, waiting for the world to show them all
	--- 2 = roads laid, waiting to see which towns stay empty
	--- 3 = empty towns destroyed, one tick before relaying the roads
	--- 4 = finished
	--- Each road pass has to wait a tick: the destroy and create commands must
	--- land before the engine is asked to lay out a network.
	phase : integer
	--- how many towns we expect once the rebuild lands
	expected : integer
	--- ticks spent waiting in the current phase
	waited : integer
	--- how many towns had no inhabitants at the last check
	zeroes : integer
	--- consecutive checks in which that count did not fall
	stable : integer
	done : boolean
end

--- Small deterministic RNG. We avoid math.random so that the result depends
--- only on the generated map, not on whatever else has consumed randomness.
local record Rng
	seed : integer
end

local function nextRandom(rng : Rng) : number
	rng.seed = (rng.seed * 1103515245 + 12345) % 2147483648
	return rng.seed / 2147483648
end

--- Split `amount` between buckets in proportion to `weights`, by largest
--- remainder, so the parts add up to exactly `amount` rather than to whatever
--- rounding each one individually happens to give.
local function share(amount : integer, weights : {number}) : {integer}
	local parts : {integer} = {}
	local remainder : {number} = {}
	local total = 0.0
	for __, weight in ipairs(weights) do total = total + weight end

	local handedOut = 0
	for i, weight in ipairs(weights) do
		local exact = 0.0
		if total > 0 then exact = amount * weight / total end
		parts[i] = math.floor(exact)
		remainder[i] = exact - parts[i]
		handedOut = handedOut + parts[i]
	end

	while handedOut < amount do
		local best, bestRemainder = 0, -1.0
		for i = 1, #weights do
			if remainder[i] > bestRemainder then
				bestRemainder = remainder[i]
				best = i
			end
		end
		if best == 0 then break end
		parts[best] = parts[best] + 1
		remainder[best] = -1.0
		handedOut = handedOut + 1
	end
	return parts
end

local function pick(list : {number}, index : integer, fallback : number) : number
	if index ~= nil and index >= 1 and index <= #list then
		return list[index]
	end
	return fallback
end

--- clusterCount, keepFraction, isolatedShare, ratioLow, ratioHigh, baseSpacing,
--- shapeMode (1 = Round only, 2 = Mixed, 3 = Varied)
local function readParams() : integer, number, number, number, number, number, integer
	local all = api.engine.config.getModParams()
	local own = all ~= nil and all[MOD_ID] as {string : integer} or nil
	if own == nil then
		log.message(LOG .. "no mod params found; using defaults")
		return 4, 0.45, 0.10, 0.55, 0.80, DEFAULT_SPACING, DEFAULT_SHAPE_MODE
	end
	local variation = own["cluster.variation"]
	local shapeMode = own["cluster.shapes"]
	if shapeMode == nil or shapeMode < 1 or shapeMode > 3 then
		shapeMode = DEFAULT_SHAPE_MODE
	end
	return math.floor(pick(CLUSTER_COUNTS as {number}, own["cluster.count"], 4)),
		pick(KEEP_FRACTIONS, own["cluster.keep"], 0.45),
		pick(ISOLATED_SHARES, own["cluster.isolated"], 0.10),
		pick(VARIATION_RATIO_MIN, variation, 0.55),
		pick(VARIATION_RATIO_MAX, variation, 0.80),
		pick(DENSITY_SPACINGS, own["cluster.density"], DEFAULT_SPACING),
		shapeMode
end

--- How far the playable map reaches from `origin` along one direction, found
--- by binary search on isValidCoordinate. Only needs the map to be one convex
--- block around the origin, which every TF3 map is.
local function probeExtent(ox : number, oy : number, dx : number, dy : number) : number
	local lo, hi = 0.0, MAP_PROBE_LIMIT
	for __ = 1, 40 do
		if hi - lo < 1.0 then break end
		local mid = (lo + hi) / 2
		if api.engine.terrain.isValidCoordinate(api.type.Vec2f.new(ox + dx * mid, oy + dy * mid)) then
			lo = mid
		else
			hi = mid
		end
	end
	return lo
end

--- minX, maxX, minY, maxY of the playable map. Probed from the centre of the
--- towns rather than from 0,0, so it still works if a map is not centred on
--- the origin.
local function mapBounds(towns : {Candidate}) : number, number, number, number
	local sx, sy = 0.0, 0.0
	for __, town in ipairs(towns) do
		sx = sx + town.x
		sy = sy + town.y
	end
	local ox, oy = sx / #towns, sy / #towns
	return ox - probeExtent(ox, oy, -1, 0), ox + probeExtent(ox, oy, 1, 0),
		oy - probeExtent(ox, oy, 0, -1), oy + probeExtent(ox, oy, 0, 1)
end

local function countTowns() : integer
	local n = 0
	api.engine.forEachEntityWithComponent(function(_entity : Engine.Entity)
		n = n + 1
	end, api.type.ComponentType.TOWN)
	return n
end

--- A town's population, as the game itself counts it: the residential person
--- capacity of its buildings (game_mechanics/towns/town_util.tl, which reads
--- `getTownCapacityUsages(entity).residential.capacity` for the number shown in
--- the town window).
local function townPopulation(entity : Engine.Entity) : integer
	local capacities = api.engine.system.townBuildingSystem.getLandUsePersonCapacities(entity)
	if capacities == nil then
		return 0
	end
	local residential = capacities[api.type["enum"].LandUseType.RESIDENTIAL as integer + 1]
	if residential == nil then
		return 0
	end
	return residential
end

--- Towns with nobody living in them. A town the engine could not build on - the
--- centre is on land, but the ground around it is river or cliff - is created
--- happily and then just sits there empty.
local function emptyTowns() : {Engine.Entity}
	local empty : {Engine.Entity} = {}
	api.engine.forEachEntityWithComponent(function(entity : Engine.Entity)
		if townPopulation(entity) <= 0 then
			empty[#empty + 1] = entity
		end
	end, api.type.ComponentType.TOWN)
	return empty
end

local function distance2(ax : number, ay : number, bx : number, by : number) : number
	local dx, dy = ax - bx, ay - by
	return dx * dx + dy * dy
end

--- Farthest-point sampling, softened: start at a random town away from the
--- border, then repeatedly take one of the towns furthest from everything
--- chosen so far. Spreads the centres across the map without needing a
--- map-size constant.
---
--- Pure farthest-point sampling on a rectangular map picks the corners first,
--- every time - test runs had four of eight centres in the four corners. So a
--- town's claim is scaled down near the border, and the next centre is drawn
--- from the few best claims instead of always the single best.
local function chooseCentres(towns : {Candidate}, count : integer, bounds : Bounds,
		rng : Rng) : {Candidate}
	local margin = EDGE_MARGIN_SHARE * math.min(bounds.maxX - bounds.minX, bounds.maxY - bounds.minY)
	local function edgeFactor(town : Candidate) : number
		local t = math.min(1.0, math.max(0.0, edgeDistance(bounds, town.x, town.y) / margin))
		return EDGE_CENTRE_MIN_FACTOR + (1 - EDGE_CENTRE_MIN_FACTOR) * t
	end

	local inland : {Candidate} = {}
	for __, town in ipairs(towns) do
		if edgeDistance(bounds, town.x, town.y) >= margin then
			inland[#inland + 1] = town
		end
	end
	local pool = towns
	if #inland > 0 then pool = inland end

	local first = pool[1 + math.floor(nextRandom(rng) * #pool)]
	local centres : {Candidate} = { first }
	local chosen : {Candidate : boolean} = { [first] = true }

	while #centres < count and #centres < #towns do
		local ranked : {Candidate} = {}
		local claim : {Candidate : number} = {}
		for __, town in ipairs(towns) do
			if not chosen[town] then
				local nearest = math.huge
				for __, centre in ipairs(centres) do
					local d = distance2(town.x, town.y, centre.x, centre.y)
					if d < nearest then nearest = d end
				end
				claim[town] = math.sqrt(nearest) * edgeFactor(town)
				ranked[#ranked + 1] = town
			end
		end
		if #ranked == 0 then break end
		table.sort(ranked, function(a : Candidate, b : Candidate) : boolean
			return claim[a] > claim[b]
		end)
		local nextCentre = ranked[1 + math.floor(nextRandom(rng) * math.min(CENTRE_PICK_FROM, #ranked))]
		centres[#centres + 1] = nextCentre
		chosen[nextCentre] = true
	end
	return centres
end

--- Is this somewhere a town could plausibly stand? The engine will happily
--- create a town in a lake or up a cliff if we ask it to, so we ask carefully.
local function isBuildable(x : number, y : number) : boolean
	local pos = api.type.Vec2f.new(x, y)
	if not api.engine.terrain.isValidCoordinate(pos) then
		return false
	end
	if api.engine.terrain.isOnWater(pos) then
		return false
	end

	local centre = api.engine.terrain.getHeightAt(pos)
	local lo, hi = centre, centre

	for __, radius in ipairs({ SLOPE_PROBE_INNER, SLOPE_PROBE }) do
		for direction = 0, PROBE_DIRECTIONS - 1 do
			local angle = direction * math.pi * 2 / PROBE_DIRECTIONS
			local probe = api.type.Vec2f.new(
				x + math.cos(angle) * radius,
				y + math.sin(angle) * radius)

			if not api.engine.terrain.isValidCoordinate(probe) then
				return false
			end
			if api.engine.terrain.isOnWater(probe) then
				return false
			end

			local h = api.engine.terrain.getHeightAt(probe)
			if h < lo then lo = h end
			if h > hi then hi = h end
		end
	end

	return (hi - lo) <= MAX_SLOPE_DROP
end

--- The spacing a town needs at distance `reach` from the middle of its part of
--- a cluster. `spacing` is the cluster's base spacing (density slider times the
--- cluster's own multiplier) and `clusterRadius` the radius the part is
--- expected to fill; the requirement grows from `spacing` to
--- (1 + SPACING_GROWTH) times it at that radius.
local function spacingAt(spacing : number, clusterRadius : number, reach : number) : number
	-- Measured from one spacing out: nothing can stand closer to the core, so
	-- measuring from the centre put even the innermost towns half-way up the
	-- growth and small clusters at the maximum straight away.
	local t = 0.0
	if clusterRadius > spacing then
		t = math.min(1.0, math.max(0.0, (reach - spacing) / (clusterRadius - spacing)))
	end
	return math.max(MIN_TOWN_SPACING, spacing * (1 + SPACING_GROWTH * t))
end

local function between(lo : number, hi : number, rng : Rng) : number
	return lo + nextRandom(rng) * (hi - lo)
end

--- Which shape a cluster gets, for the Cluster Shapes setting and the number
--- of towns the cluster is expected to hold.
local function pickKind(mode : integer, expected : integer, rng : Rng) : string
	if mode == 1 then
		return "round"
	end
	local count = #SHAPE_KINDS
	if expected < MIN_TOWNS_MULTI_CORE then
		count = 3
	end
	local r = nextRandom(rng)
	if mode == 2 then
		local sum = 0.0
		for i = 1, count do sum = sum + MIXED_WEIGHTS[i] end
		local acc = 0.0
		for i = 1, count do
			acc = acc + MIXED_WEIGHTS[i] / sum
			if r < acc then return SHAPE_KINDS[i] end
		end
		return SHAPE_KINDS[count]
	end
	return SHAPE_KINDS[1 + math.floor(r * count)]
end

--- The point `u` metres along a chain, and the unit normal to the chain there.
local function pathPoint(shape : Shape, u : number) : number, number, number, number
	local px, py = shape.pathX, shape.pathY
	local remaining = u
	for i = 1, #px - 1 do
		local dx, dy = px[i + 1] - px[i], py[i + 1] - py[i]
		local len = math.sqrt(dx * dx + dy * dy)
		if remaining <= len or i == #px - 1 then
			local t, nx, ny = 0.0, 0.0, 0.0
			if len > 0 then
				t = math.min(1.0, math.max(0.0, remaining / len))
				nx, ny = -dy / len, dx / len
			end
			return px[i] + dx * t, py[i] + dy * t, nx, ny
		end
		remaining = remaining - len
	end
	return px[1], py[1], 0.0, 0.0
end

local function distanceToPath(shape : Shape, x : number, y : number) : number
	local px, py = shape.pathX, shape.pathY
	local best = math.huge
	for i = 1, #px - 1 do
		local dx, dy = px[i + 1] - px[i], py[i + 1] - py[i]
		local len2 = dx * dx + dy * dy
		local t = 0.0
		if len2 > 0 then
			t = math.min(1.0, math.max(0.0, ((x - px[i]) * dx + (y - py[i]) * dy) / len2))
		end
		local d = distance2(x, y, px[i] + dx * t, py[i] + dy * t)
		if d < best then best = d end
	end
	return math.sqrt(best)
end

--- How far a point is from a cluster's shape, in metres (for an elongated
--- cluster, measured with the stretch taken out). Decides which cluster a
--- generated town belongs to and which towns stay where they are.
local function shapeDistance(shape : Shape, x : number, y : number) : number
	local core = shape.anchors[1]
	if shape.kind == "elongated" then
		local dx, dy = x - core.x, y - core.y
		local c, sn = math.cos(shape.angle), math.sin(shape.angle)
		local stretch = math.sqrt(shape.aspect)
		local u = (dx * c + dy * sn) / stretch
		local v = (-dx * sn + dy * c) * stretch
		return math.sqrt(u * u + v * v)
	elseif shape.kind == "chain" then
		return distanceToPath(shape, x, y)
	elseif shape.kind == "polycentric" then
		local best = math.huge
		for __, a in ipairs(shape.anchors) do
			local d = distance2(x, y, a.x, a.y)
			if d < best then best = d end
		end
		return math.sqrt(best)
	end
	return math.sqrt(distance2(x, y, core.x, core.y))
end

--- Lay out a cluster's shape around its centre. Quotas and radii are filled in
--- later by assignQuotas, once the number of movers is known.
local function buildShape(kind : string, cx : number, cy : number, spacing : number,
		expected : integer, bounds : Bounds, rng : Rng) : Shape
	local shape : Shape = {
		kind = kind,
		anchors = { { x = cx, y = cy, quota = 0, placed = 0, radius = 2 * spacing } },
		aspect = 1.0, angle = 0.0, pathX = {}, pathY = {}, pathLength = 0.0,
	}
	local scale = math.max(1.0, spacing / SHAPE_REFERENCE_SPACING)

	if kind == "elongated" then
		shape.aspect = between(ELONGATED_ASPECT_MIN, ELONGATED_ASPECT_MAX, rng)
		-- Point the long axis away from the border if the first draw runs into
		-- it: judged by the ends of the axis at the reach the cluster is
		-- expected to fill.
		local reach = math.max(2 * spacing, 0.75 * spacing * math.sqrt(expected)) * math.sqrt(shape.aspect)
		local bestClear = -math.huge
		for __ = 1, ORIENT_TRIES do
			local angle = nextRandom(rng) * math.pi
			local dx, dy = math.cos(angle) * reach, math.sin(angle) * reach
			local clear = math.min(edgeDistance(bounds, cx + dx, cy + dy), edgeDistance(bounds, cx - dx, cy - dy))
			if clear > bestClear then
				bestClear = clear
				shape.angle = angle
			end
			if clear >= EDGE_SPOT_SOFT then break end
		end

	elseif kind == "chain" then
		local length = math.max(3 * spacing,
			spacing * expected * between(CHAIN_LENGTH_PER_TOWN_MIN, CHAIN_LENGTH_PER_TOWN_MAX, rng))
		local segments = 2
		if expected >= 8 then segments = 3 end
		-- Draw the line until it stays clear of the border (judged at its
		-- bends and ends), keeping the clearest draw if none does.
		local bestClear = -math.huge
		local bestX : {number} = {}
		local bestY : {number} = {}
		for __ = 1, ORIENT_TRIES do
			local heading = nextRandom(rng) * math.pi * 2
			local px : {number} = { 0.0 }
			local py : {number} = { 0.0 }
			for i = 1, segments do
				if i > 1 then
					heading = heading + (nextRandom(rng) - 0.5) * 2 * CHAIN_MAX_TURN
				end
				px[i + 1] = px[i] + math.cos(heading) * length / segments
				py[i + 1] = py[i] + math.sin(heading) * length / segments
			end
			shape.pathX, shape.pathY, shape.pathLength = px, py, length
			-- Centre the line on the cluster's centre, by length rather than by
			-- its end points, so the centre town sits in the middle of the chain.
			local mx, my = pathPoint(shape, length / 2)
			local clear = math.huge
			for i = 1, #px do
				px[i] = px[i] + cx - mx
				py[i] = py[i] + cy - my
				clear = math.min(clear, edgeDistance(bounds, px[i], py[i]))
			end
			if clear > bestClear then
				bestClear = clear
				bestX, bestY = px, py
			end
			if clear >= EDGE_SPOT_SOFT then break end
		end
		shape.pathX, shape.pathY = bestX, bestY

	elseif kind == "polycentric" then
		local extra = 1
		if expected >= 9 then extra = 2 end
		local heading = nextRandom(rng) * math.pi * 2
		for i = 1, extra do
			if i > 1 then
				heading = heading + math.pi * between(0.6, 1.4, rng)
			end
			local gap = scale * between(POLY_GAP_MIN, POLY_GAP_MAX, rng)
			local ax, ay = cx + math.cos(heading) * gap, cy + math.sin(heading) * gap
			local clear = edgeDistance(bounds, ax, ay)
			for __ = 2, ORIENT_TRIES do
				if clear >= EDGE_SPOT_SOFT then break end
				local h = nextRandom(rng) * math.pi * 2
				local tx, ty = cx + math.cos(h) * gap, cy + math.sin(h) * gap
				local c = edgeDistance(bounds, tx, ty)
				if c > clear then
					ax, ay, clear, heading = tx, ty, c, h
				end
			end
			shape.anchors[#shape.anchors + 1] = {
				x = ax, y = ay, quota = 0, placed = 0, radius = 2 * spacing,
			}
		end

	elseif kind == "satellite" then
		local count = math.min(5, math.max(3, math.floor(expected * SATELLITE_SHARE + 0.5)))
		count = math.max(1, math.min(count, expected - 2))
		-- The reach the core is expected to fill, by the same rule as
		-- assignQuotas uses once the exact numbers are known.
		local coreReach = math.max(2 * spacing, 0.75 * spacing * math.sqrt(expected - count))
		local heading = nextRandom(rng) * math.pi * 2
		local arc = math.pi * 2 / count
		for i = 1, count do
			local a = heading + (i - 1) * arc + (nextRandom(rng) - 0.5) * arc * 0.5
			local gap = scale * between(SATELLITE_GAP_MIN, SATELLITE_GAP_MAX, rng)
			local d = coreReach + gap
			local ax, ay = cx + math.cos(a) * d, cy + math.sin(a) * d
			-- A satellite off the map or against the border moves round the
			-- core, then closer in (never into the core), keeping the clearest
			-- of a few tries.
			local clear = edgeDistance(bounds, ax, ay)
			for try = 2, ORIENT_TRIES do
				if clear >= EDGE_SPOT_SOFT then break end
				local ta = a + (nextRandom(rng) - 0.5) * arc
				local td = coreReach + gap * (1 - 0.2 * (try - 1))
				local tx, ty = cx + math.cos(ta) * td, cy + math.sin(ta) * td
				local c = edgeDistance(bounds, tx, ty)
				if c > clear then
					ax, ay, clear = tx, ty, c
				end
			end
			shape.anchors[#shape.anchors + 1] = {
				x = ax, y = ay, quota = 0, placed = 0, radius = 2 * spacing,
			}
		end
	end
	return shape
end

--- Share a cluster's movers between the parts of its shape, and work out how
--- far each part is expected to reach. `stays` are the towns already standing
--- in the cluster; they count towards the core's size.
local function assignQuotas(shape : Shape, movers : integer, stays : integer, spacing : number, rng : Rng)
	local anchors = shape.anchors
	if shape.kind == "satellite" and #anchors > 1 then
		-- one town per outlying point while the movers last; the rest go to
		-- the core
		local outer = math.min(#anchors - 1, movers)
		for i = 2, #anchors do
			if i - 1 <= outer then anchors[i].quota = 1 else anchors[i].quota = 0 end
		end
		anchors[1].quota = movers - outer
	elseif shape.kind == "polycentric" and #anchors > 1 then
		local weights : {number} = { 1.0 }
		for i = 2, #anchors do weights[i] = between(0.5, 0.9, rng) end
		local parts = share(movers, weights)
		for i, a in ipairs(anchors) do a.quota = parts[i] end
	else
		anchors[1].quota = movers
	end

	for i, a in ipairs(anchors) do
		local n = a.quota
		if i == 1 then n = n + stays end
		if shape.kind == "chain" or (shape.kind == "satellite" and i > 1) then
			-- a chain grows along its line, not outwards; a satellite is one town
			a.radius = 2 * spacing
		else
			a.radius = math.max(2 * spacing, 0.75 * spacing * math.sqrt(n))
		end
	end
end

--- Find a spot for one relocated town around part `a` of a cluster's shape:
--- work outwards ring by ring and take one of the spots on the first ring that
--- has any that are buildable and far enough from every town already placed.
--- Returns false if the neighbourhood is full, in which case the caller tries
--- elsewhere. The flag is a separate return rather than a nil position, so the
--- signature stays honest to Teal - the game type-checks this file at load.
---
--- Round parts use plain rings. An elongated core uses rings stretched along
--- the shape's direction. A chain samples along its line, with a band around
--- it that widens ring by ring. A candidate's required spacing grows from
--- `spacing` towards (1 + SPACING_GROWTH) times it at the part's radius; the
--- spacing the chosen spot demands is returned for later placements.
local function findSpot(shape : Shape, a : integer, spacing : number,
		placed : {Placed}, bounds : Bounds, rng : Rng) : boolean, number, number, number
	local anchor = shape.anchors[a]
	local onChain = shape.kind == "chain" and a == 1
	local stretched = shape.kind == "elongated" and a == 1
	local stretch = math.sqrt(shape.aspect)
	local cosA, sinA = math.cos(shape.angle), math.sin(shape.angle)

	local slots = ANGLES_PER_RING
	if onChain then
		-- a long line needs more samples per pass to cover its length
		slots = ANGLES_PER_RING * math.max(1, math.ceil(shape.pathLength / (4 * spacing)))
	end
	local step = math.pi * 2 / slots
	local firstRing = spacing * FIRST_RING_SHARE
	local ringStep = spacing * RING_STEP_SHARE

	for ring = 1, MAX_RINGS do
		local radius = firstRing + (ring - 1) * ringStep
		local phase = nextRandom(rng) * math.pi * 2
		local wobble = radius * JITTER_SHARE

		-- Gather every spot on this ring that would work, then take one of them
		-- at random.
		--
		-- Taking the first that fits - which is what this used to do - walks the
		-- slots in order and stops, so every town lands at the smallest radius
		-- that will have it and the cluster packs into an even lattice sitting
		-- 3% above MIN_TOWN_SPACING. Measured, the median gap between
		-- neighbours was 822 m against a floor of 800. That reads as machined.
		--
		-- The candidates are wobbled off the ring before they are tested, not
		-- after, so the spacing floor still holds exactly.
		local spotsX : {number} = {}
		local spotsY : {number} = {}
		local spotsS : {number} = {}
		local spotsW : {number} = {}
		local weightSum = 0.0
		for slot = 0, slots - 1 do
			local reach = radius + (nextRandom(rng) - 0.5) * 2 * wobble
			local x, y = 0.0, 0.0
			if onChain then
				local u = nextRandom(rng) * shape.pathLength
				local offset = (nextRandom(rng) - 0.5) * 2 * reach
				local px, py, nx, ny = pathPoint(shape, u)
				x = px + nx * offset
				y = py + ny * offset
			else
				local angle = phase + slot * step + (nextRandom(rng) - 0.5) * step * 0.8
				local lx, ly = math.cos(angle) * reach, math.sin(angle) * reach
				if stretched then
					lx, ly = lx * stretch, ly / stretch
					lx, ly = lx * cosA - ly * sinA, lx * sinA + ly * cosA
				end
				x = anchor.x + lx
				y = anchor.y + ly
			end
			local need = spacingAt(spacing, anchor.radius, reach)

			local clear = true
			for __, p in ipairs(placed) do
				local gap = math.max(need, p.spacing)
				if distance2(x, y, p.x, p.y) < gap * gap then
					clear = false
					break
				end
			end
			if clear and isBuildable(x, y) then
				-- near the border a spot is picked less often, not never
				local t = math.min(1.0, math.max(0.0, edgeDistance(bounds, x, y) / EDGE_SPOT_SOFT))
				local weight = EDGE_SPOT_MIN_WEIGHT + (1 - EDGE_SPOT_MIN_WEIGHT) * t
				spotsX[#spotsX + 1] = x
				spotsY[#spotsY + 1] = y
				spotsS[#spotsS + 1] = need
				spotsW[#spotsW + 1] = weight
				weightSum = weightSum + weight
			end
		end

		if #spotsX > 0 then
			local target = nextRandom(rng) * weightSum
			local choice = #spotsX
			for i = 1, #spotsW do
				target = target - spotsW[i]
				if target <= 0 then
					choice = i
					break
				end
			end
			return true, spotsX[choice], spotsY[choice], spotsS[choice]
		end
	end
	return false, 0, 0, 0
end

--- Place one mover in a cluster: the part of its shape with the most of its
--- share outstanding first, then any other part, so a full or unbuildable
--- part does not strand the town.
local function placeInShape(shape : Shape, spacing : number, placed : {Placed},
		bounds : Bounds, rng : Rng) : boolean, number, number, number
	local order : {integer} = {}
	for i = 1, #shape.anchors do order[i] = i end
	table.sort(order, function(a : integer, b : integer) : boolean
		local ra = shape.anchors[a].quota - shape.anchors[a].placed
		local rb = shape.anchors[b].quota - shape.anchors[b].placed
		if ra ~= rb then return ra > rb end
		return a < b
	end)
	for __, i in ipairs(order) do
		local ok, x, y, need = findSpot(shape, i, spacing, placed, bounds, rng)
		if ok then
			shape.anchors[i].placed = shape.anchors[i].placed + 1
			return true, x, y, need
		end
	end
	return false, 0, 0, 0
end

--- One log line per cluster shape, for tools/plot_run.py.
local function logShape(k : integer, shape : Shape)
	local anchors = ""
	for i, a in ipairs(shape.anchors) do
		if i > 1 then anchors = anchors .. "|" end
		anchors = anchors .. string.format("%.0f:%.0f:%.0f:%d", a.x, a.y, a.radius, a.quota)
	end
	local path = "-"
	if #shape.pathX > 0 then
		path = ""
		for i = 1, #shape.pathX do
			if i > 1 then path = path .. "|" end
			path = path .. string.format("%.0f:%.0f", shape.pathX[i], shape.pathY[i])
		end
	end
	log.message(LOG .. string.format("SHAPE %d kind=%s aspect=%.2f angle=%.3f anchors=%s path=%s",
		k, shape.kind, shape.aspect, shape.angle, anchors, path))
end

--- Rebuild the town layout. Returns the number of towns the world should end up
--- with, or 0 if there was nothing worth doing.
local function redistribute() : integer
	local map = api.engine.terrain.makeMapFromGame(false, true, false, false)
	if map == nil or map.towns == nil or #map.towns < 2 then
		log.message(LOG .. "no towns to work with")
		return 0
	end

	local towns : {Candidate} = {}
	for __, source in ipairs(map.towns) do
		towns[#towns + 1] = {
			source = source, x = source.pos.x, y = source.pos.y,
			dist = 0, centre = 1, kind = "move",
		}
	end
	local total = #towns

	local clusterCount, keepFraction, isolatedShare, ratioLow, ratioHigh, baseSpacing, shapeMode = readParams()
	local stayCount = math.max(1, math.floor(total * keepFraction + 0.5))
	if stayCount >= total then
		log.message(LOG .. "every town stays put; nothing to do")
		return 0
	end

	-- Seed from the map itself so the same map always clusters the same way.
	local seed = total * 7919
	for __, town in ipairs(towns) do
		seed = (seed + math.floor(town.x) * 31 + math.floor(town.y) * 17) % 2147483648
	end
	local rng : Rng = { seed = math.abs(seed) + 1 }

	local minX, maxX, minY, maxY = mapBounds(towns)
	local bounds : Bounds = { minX = minX, maxX = maxX, minY = minY, maxY = maxY }

	local centres = chooseCentres(towns, clusterCount, bounds, rng)

	-- A centre is a reference into `towns`, so if the centre town itself is
	-- moved its x/y change with it. Placement works from these fixed copies.
	local centreX : {number} = {}
	local centreY : {number} = {}
	for i, centre in ipairs(centres) do
		centreX[i] = centre.x
		centreY[i] = centre.y
	end

	-- Each cluster's own spacing: the density slider times a per-cluster draw.
	local clusterSpacing : {number} = {}
	for i = 1, #centres do
		clusterSpacing[i] = baseSpacing
			* (CLUSTER_SPACING_MIN + nextRandom(rng) * (CLUSTER_SPACING_MAX - CLUSTER_SPACING_MIN))
	end

	-- Debug output for plotting a run outside the game (tools/plot_run.py).
	log.message(LOG .. string.format(
		"PARAMS count=%d keep=%.2f isolated=%.2f ratio=%.2f..%.2f spacing=%.0f shapes=%d",
		clusterCount, keepFraction, isolatedShare, ratioLow, ratioHigh, baseSpacing, shapeMode))
	log.message(LOG .. string.format("BOUNDS x=%.0f..%.0f y=%.0f..%.0f", minX, maxX, minY, maxY))
	for i = 1, #centres do
		log.message(LOG .. string.format("CENTRE %d x=%.0f y=%.0f", i, centreX[i], centreY[i]))
	end

	local movers = total - stayCount
	local isolatedCount = math.floor(movers * isolatedShare + 0.5)

	-- How big should each cluster be?
	--
	-- Sharing the towns out evenly makes the clusters come out the same size,
	-- which reads as generated. Each centre instead gets a weight from a
	-- geometric series - one conurbation dominates, a couple are middling, one
	-- is a modest group - and every later share follows those weights.
	--
	-- The ratio varies per map, and which centre draws which weight follows how
	-- much room each centre has (below), so the big one is not simply whichever
	-- centre the sampling happened to pick first.
	local ratio = ratioLow + nextRandom(rng) * (ratioHigh - ratioLow)
	local weights : {number} = {}
	local w = 1.0
	for i = 1, #centres do
		if w < SIZE_MIN_WEIGHT then
			weights[i] = SIZE_MIN_WEIGHT
		else
			weights[i] = w
		end
		w = w * ratio
	end
	-- The largest clusters go preferably to the centres with the most room
	-- around them. A big cluster spreads furthest, and given to a centre near
	-- the border it spilled up to it: in a test run the two largest clusters
	-- sat 2 and 2.5 km from the edge. Room is the distance to the border and
	-- to the nearest other centre, whichever is less, jittered so the order is
	-- a tendency rather than a rule.
	local room : {number} = {}
	for i = 1, #centres do
		local r = edgeDistance(bounds, centreX[i], centreY[i])
		for j = 1, #centres do
			if j ~= i then
				r = math.min(r, 0.5 * math.sqrt(distance2(centreX[i], centreY[i], centreX[j], centreY[j])))
			end
		end
		room[i] = r * between(1 - ROOM_JITTER, 1 + ROOM_JITTER, rng)
	end
	local byRoom : {integer} = {}
	for i = 1, #centres do byRoom[i] = i end
	table.sort(byRoom, function(a : integer, b : integer) : boolean
		if room[a] ~= room[b] then return room[a] > room[b] end
		return a < b
	end)
	-- weights were built largest first
	local ordered : {number} = {}
	for i = 1, #weights do ordered[i] = weights[i] end
	for rank, i in ipairs(byRoom) do
		weights[i] = ordered[rank]
	end

	-- Each cluster's shape, laid out around its centre. A shape needs to know
	-- roughly how many towns it will hold (a chain's length, how many
	-- satellites), so give it the share of the non-isolated towns its weight
	-- implies; the exact quotas follow once the stayers are known.
	local expected = share(total - isolatedCount, weights)
	local shapes : {Shape} = {}
	for i = 1, #centres do
		local kind = pickKind(shapeMode, expected[i], rng)
		shapes[i] = buildShape(kind, centreX[i], centreY[i], clusterSpacing[i], expected[i], bounds, rng)
	end

	-- Every generated town belongs to the cluster whose shape it is nearest to.
	for __, town in ipairs(towns) do
		local nearest = math.huge
		local nearestIndex = 1
		for i, shape in ipairs(shapes) do
			local d = shapeDistance(shape, town.x, town.y)
			if d < nearest then
				nearest = d
				nearestIndex = i
			end
		end
		town.dist = nearest
		town.centre = nearestIndex
	end

	-- Nearest to a shape keep the position the generator gave them; they are
	-- already where we want towns to be.
	table.sort(towns, function(a : Candidate, b : Candidate) : boolean
		return a.dist < b.dist
	end)

	-- Towns that keep their position have to follow the weights too. Capping
	-- only the movers leaves the clusters barely more than a fifth apart,
	-- because the towns that stay are spread evenly by geography and dilute
	-- everything the weights do.
	local stayQuota = share(stayCount, weights)

	local stays : {integer} = {}
	for i = 1, #centres do stays[i] = 0 end
	local staysTotal = 0
	for __, town in ipairs(towns) do
		-- towns are in ascending distance order, so a cluster fills its places
		-- with the towns already closest to it
		local k = town.centre
		if stays[k] < stayQuota[k] then
			town.kind = "stay"
			stays[k] = stays[k] + 1
			staysTotal = staysTotal + 1
		else
			town.kind = "move"
		end
	end

	-- Spare some of the movers as isolated towns: they stay out in the country
	-- where they were generated and are scaled down, so they read as outlying
	-- hamlets rather than as peers of the towns in the conurbations.
	--
	-- They come in groups of two or three: an anchor far from every cluster,
	-- plus its nearest movers within reach. Anchors are taken from the far end,
	-- kept apart from each other and, where possible, off the border; each pass
	-- below relaxes one of those if the first could not place them all.
	local isolated : {Candidate} = {}
	local groupSizes : {integer} = {}
	local anchors : {Candidate} = {}
	local remaining = isolatedCount
	local passes : {{number}} = {
		{ EDGE_SPOT_SOFT, ISOLATED_GROUP_GAP },
		{ 0, ISOLATED_GROUP_GAP },
		{ 0, 0.6 * ISOLATED_GROUP_GAP },
		{ 0, 0 },
	}
	for passIndex, pass in ipairs(passes) do
		local edgeNeed, gap = pass[1], pass[2]
		for index = total, 1, -1 do
			if remaining <= 0 then break end
			local town = towns[index]
			local ok = town.kind == "move" and edgeDistance(bounds, town.x, town.y) >= edgeNeed
			if ok then
				for __, a in ipairs(anchors) do
					if distance2(town.x, town.y, a.x, a.y) < gap * gap then
						ok = false
						break
					end
				end
			end

			-- The movers within reach, nearest first: the candidate companions.
			-- Only the last pass accepts an anchor without any, since a lone
			-- isolated town is what the grouping is meant to avoid.
			local near : {Candidate} = {}
			if ok then
				for __, other in ipairs(towns) do
					if other ~= town and other.kind == "move"
						and distance2(town.x, town.y, other.x, other.y) <= ISOLATED_GROUP_REACH * ISOLATED_GROUP_REACH then
						near[#near + 1] = other
					end
				end
				if #near == 0 and passIndex < #passes then
					ok = false
				end
			end

			if ok then
				town.kind = "isolated"
				isolated[#isolated + 1] = town
				anchors[#anchors + 1] = town
				remaining = remaining - 1

				-- one or two companions, never leaving a single isolated town over
				local want = 1
				if remaining >= 2 and nextRandom(rng) < 0.5 then want = 2 end
				if remaining == 2 then
					want = 2 -- a pair would leave one alone; take both
				elseif remaining == 3 then
					want = 1 -- leaves two, which make the next pair
				end
				table.sort(near, function(a : Candidate, b : Candidate) : boolean
					return distance2(town.x, town.y, a.x, a.y) < distance2(town.x, town.y, b.x, b.y)
				end)
				local size = 1
				for i = 1, math.min(want, #near, remaining) do
					near[i].kind = "isolated"
					isolated[#isolated + 1] = near[i]
					remaining = remaining - 1
					size = size + 1
				end
				groupSizes[#groupSizes + 1] = size
			end
		end
	end

	-- Everything that is not moving occupies its spot already. Those towns ask
	-- only for the hard floor; a mover placed near them brings its own, larger
	-- spacing, and the pair rule takes the larger of the two.
	local placed : {Placed} = {}
	for __, town in ipairs(towns) do
		if town.kind ~= "move" then
			placed[#placed + 1] = { x = town.x, y = town.y, spacing = MIN_TOWN_SPACING }
		end
	end

	local moverCount = 0
	for __, town in ipairs(towns) do
		if town.kind == "move" then
			moverCount = moverCount + 1
		end
	end

	local quota = share(moverCount, weights)

	-- A cluster with nothing in it is just a gap. Borrow from the largest.
	for i = 1, #centres do
		if stays[i] + quota[i] == 0 then
			local big = 1
			for k = 2, #centres do
				if quota[k] > quota[big] then big = k end
			end
			if quota[big] > 1 then
				quota[big] = quota[big] - 1
				quota[i] = 1
			end
		end
	end

	local placedIn : {integer} = {}
	for i = 1, #centres do placedIn[i] = 0 end

	-- Share each cluster's movers between the parts of its shape. A part's
	-- radius is how far it is expected to reach: n towns in a roughly
	-- hexagonal packing cover a disc of about 0.53 * spacing * sqrt(n); with the
	-- spacing averaging ~1.25x the base across the growth, and room for the
	-- jitter, that is 0.75 * base * sqrt(n), and at least two spacings, so even
	-- a three-town part has a core and a fringe.
	for i, shape in ipairs(shapes) do
		assignQuotas(shape, quota[i], stays[i], clusterSpacing[i], rng)
		log.message(LOG .. string.format("CLUSTER %d spacing=%.0f radius=%.0f towns=%d",
			i, clusterSpacing[i], shape.anchors[1].radius, stays[i] + quota[i]))
		logShape(i, shape)
	end

	local moved, stranded = 0, 0
	for __, town in ipairs(towns) do
		if town.kind == "move" then
			-- Try the cluster with the most of its quota outstanding first, and
			-- fall through to the others if it turns out to be full - better a
			-- slightly off-quota cluster than a stranded town.
			local order : {integer} = {}
			for i = 1, #centres do order[i] = i end
			table.sort(order, function(a : integer, b : integer) : boolean
				local ra, rb = quota[a] - placedIn[a], quota[b] - placedIn[b]
				if ra ~= rb then return ra > rb end
				return a < b
			end)

			local settled = false
			for __, k in ipairs(order) do
				if quota[k] - placedIn[k] > 0 then
					local ok, x, y, need = placeInShape(shapes[k], clusterSpacing[k], placed, bounds, rng)
					if ok then
						town.x = x
						town.y = y
						town.centre = k
						placedIn[k] = placedIn[k] + 1
						moved = moved + 1
						placed[#placed + 1] = { x = x, y = y, spacing = need }
						settled = true
						break
					end
				end
			end
			if not settled then
				-- Nowhere to put it: leave the town alone rather than destroy
				-- it. A quieter result than losing a town.
				town.kind = "stay"
				stranded = stranded + 1
				placed[#placed + 1] = { x = town.x, y = town.y, spacing = MIN_TOWN_SPACING }
			end
		end
	end

	if moved == 0 then
		log.message(LOG .. "found nowhere to move any town to; leaving the map alone")
		return 0
	end

	-- The desired layout. A town listed with its `existing` entity is left
	-- untouched; one listed without is built fresh at the new position.
	local desired : {GameMap.Town} = {}
	for __, town in ipairs(towns) do
		local entry = api.type.Map.Town.new()
		entry.pos = api.type.Vec2f.new(town.x, town.y)
		entry.name = town.source.name or ""
		entry.sizeFactors = town.source.sizeFactors
		entry.landUse2CargoNeeds = town.source.landUse2CargoNeeds
		if town.kind ~= "move" then
			entry.existing = town.source.existing
		end
		desired[#desired + 1] = entry
	end

	local result = api.engine.mapgen.createTowns(tostring(rng.seed), desired)
	for __, entity in ipairs(result.toRemove) do
		api.cmd.sendCommand(api.cmd.makeTownDestroyCmd(entity))
	end
	if #result.toAdd > 0 then
		api.cmd.sendCommand(api.cmd.makeTownCreateCmd(result.toAdd))
	end

	-- Isolated towns keep their entity, so they can simply be scaled down.
	for __, town in ipairs(isolated) do
		if town.source.existing ~= nil and town.source.sizeFactors ~= nil then
			local scaled : {number} = {}
			for i, factor in ipairs(town.source.sizeFactors) do
				scaled[i] = factor * ISOLATED_SIZE_SCALE
			end
			api.cmd.sendCommand(
				api.cmd.makeTownUpdateSizeCmd(town.source.existing, scaled, true))
		end
	end

	-- Debug output: every town's final position and fate, then the distance
	-- from each town to its nearest neighbour - the number behind "towns in a
	-- cluster are too close together".
	local nearestDist : {number} = {}
	local nearestMoved : {number} = {}
	for i, town in ipairs(towns) do
		log.message(LOG .. string.format("TOWN %s c=%d x=%.0f y=%.0f",
			town.kind, town.centre, town.x, town.y))
		local best = math.huge
		for j, other in ipairs(towns) do
			if i ~= j then
				local d = distance2(town.x, town.y, other.x, other.y)
				if d < best then best = d end
			end
		end
		nearestDist[#nearestDist + 1] = math.sqrt(best)
		if town.kind == "move" then
			nearestMoved[#nearestMoved + 1] = math.sqrt(best)
		end
	end

	local function logSpacing(label : string, list : {number})
		if #list == 0 then return end
		table.sort(list)
		local n = #list
		log.message(LOG .. string.format(
			"SPACING %s: min=%.0f p10=%.0f median=%.0f p90=%.0f max=%.0f", label,
			list[1], list[math.max(1, math.floor(n * 0.1 + 0.5))],
			list[math.max(1, math.floor(n * 0.5 + 0.5))],
			list[math.max(1, math.floor(n * 0.9 + 0.5))], list[n]))
	end
	logSpacing("nearest neighbour", nearestDist)
	logSpacing("moved towns", nearestMoved)

	-- How much the border still attracts: centres inside the margin, and moved
	-- towns within EDGE_SPOT_SOFT of the edge.
	local margin = EDGE_MARGIN_SHARE * math.min(maxX - minX, maxY - minY)
	local edgeCentres, edgeMoved, movedTotal = 0, 0, 0
	for i = 1, #centres do
		if edgeDistance(bounds, centreX[i], centreY[i]) < margin then edgeCentres = edgeCentres + 1 end
	end
	for __, town in ipairs(towns) do
		if town.kind == "move" then
			movedTotal = movedTotal + 1
			if edgeDistance(bounds, town.x, town.y) < EDGE_SPOT_SOFT then edgeMoved = edgeMoved + 1 end
		end
	end
	log.message(LOG .. string.format(
		"EDGE %d of %d centres within %.0f m of the border; %d of %d moved towns within %.0f m",
		edgeCentres, #centres, margin, edgeMoved, movedTotal, EDGE_SPOT_SOFT))

	-- Isolated groups, and how alone the loneliest isolated town still is.
	local sizesText = ""
	for i, n in ipairs(groupSizes) do
		if i > 1 then sizesText = sizesText .. "/" end
		sizesText = sizesText .. tostring(n)
	end
	local loneliest = 0.0
	for __, town in ipairs(isolated) do
		local best = math.huge
		for __, other in ipairs(towns) do
			if other ~= town then
				local d = distance2(town.x, town.y, other.x, other.y)
				if d < best then best = d end
			end
		end
		loneliest = math.max(loneliest, math.sqrt(best))
	end
	log.message(LOG .. string.format(
		"ISOLATED %d towns in %d groups sized %s; loneliest is %.0f m from its nearest neighbour",
		#isolated, #groupSizes, sizesText, loneliest))

	local sizes = ""
	for i = 1, #centres do
		if i > 1 then sizes = sizes .. "/" end
		sizes = sizes .. tostring(stays[i] + placedIn[i])
	end

	log.message(LOG .. string.format(
		"%d towns -> %d clusters sized %s (ratio %.2f): %d moved, %d left in place, "
		.. "%d isolated, %d stranded (%d destroyed, %d created)",
		total, #centres, sizes, ratio, moved, staysTotal, #isolated, stranded,
		#result.toRemove, #result.toAdd))
	return total
end

--- Rebuild the inter-town road network.
---
--- getDefaultTownConnections is a *proposal*, not a finished network - the Map
--- Editor merges it into whatever connections already exist rather than
--- treating it as complete (map_editor.tl, "Propose Default Connections"). On a
--- clustered map it reliably leaves each cluster an island, so we stitch the
--- components together ourselves before handing the lot to the engine.
---
--- Some links will still fail to build: the engine reports "Too Much Incline"
--- or "Collision" and leaves that pair unconnected. That happens to the stock
--- generator's own connections too, on hilly maps, so a connected proposal is
--- the most we can guarantee from here.
local function connectAll()
	local entities : {Engine.Entity} = {}
	local xs : {number} = {}
	local ys : {number} = {}
	local mapTowns : {GameMap.Town} = {}

	api.engine.forEachEntityWithComponent(function(entity : Engine.Entity)
		local pos = entity_util.getPosition(entity)
		if pos ~= nil then
			local i = #entities + 1
			entities[i] = entity
			xs[i] = pos.x
			ys[i] = pos.y
			local mapTown = api.type.Map.Town.new()
			mapTown.pos = api.type.Vec2f.new(pos.x, pos.y)
			mapTown.name = entity_util.getEntityName(entity) or ""
			mapTown.existing = entity
			mapTowns[i] = mapTown
		end
	end, api.type.ComponentType.TOWN)

	local count = #entities
	if count < 2 then
		return
	end

	local connections = api.engine.mapgen.getDefaultTownConnections(mapTowns)

	-- Which end is index zero?
	--
	-- The engine documents these as "indices into the vector townEntities". That
	-- vector is C++, so they are 0-based, while every list on this side of the
	-- boundary is 1-based. Appending a 1-based index to the list crashed the
	-- simulation thread twice on an out-of-range read - the second time reading
	-- 0xFFFFFFFFFFFFFFFF, which is what running off the end of that vector looks
	-- like. The crash landed at the very end of the layout, exactly where our own
	-- appended links sit.
	--
	-- Rather than trust either reading, work the base out from the data: a zero
	-- anywhere proves 0-based, and a value equal to the town count proves
	-- 1-based, because neither is legal in the other scheme.
	local lowest, highest = math.huge, -math.huge
	for __, conn in ipairs(connections) do
		for k = 1, 2 do
			local v = conn[k]
			if v < lowest then lowest = v end
			if v > highest then highest = v end
		end
	end

	local base = -1
	if #connections == 0 then
		base = -1
	elseif lowest <= 0 then
		base = 0
	elseif highest >= count then
		base = 1
	end

	-- base == -1 means the sample proved nothing: every index landed in the range
	-- the two schemes share. Guessing would risk either linking the wrong towns
	-- or crashing the game, so leave the engine's own proposal alone instead.
	local canAppend = base >= 0

	-- Union-find over the proposed connections.
	local parent : {integer} = {}
	for i = 1, count do parent[i] = i end

	local function find(i : integer) : integer
		while parent[i] ~= i do
			parent[i] = parent[parent[i]]
			i = parent[i]
		end
		return i
	end

	local components = count
	local function union(a : integer, b : integer) : boolean
		local ra, rb = find(a), find(b)
		if ra == rb then return false end
		parent[ra] = rb
		components = components - 1
		return true
	end

	-- Engine index -> our 1-based index. Anything out of range is skipped rather
	-- than silently folded into the wrong town, which is what the old 1-based
	-- guard did to every connection that touched index 0.
	local skipped = 0
	if canAppend then
		for __, conn in ipairs(connections) do
			local a = conn[1] - base + 1
			local b = conn[2] - base + 1
			if a >= 1 and a <= count and b >= 1 and b <= count then
				union(a, b)
			else
				skipped = skipped + 1
			end
		end
	end

	-- Join whatever is still separate by the shortest link available, which for
	-- clustered towns is the pair of towns facing each other across the gap.
	local added = 0
	while canAppend and components > 1 do
		local bestA, bestB, bestD = 0, 0, math.huge
		for i = 1, count do
			for j = i + 1, count do
				if find(i) ~= find(j) then
					local d = distance2(xs[i], ys[i], xs[j], ys[j])
					if d < bestD then
						bestD = d
						bestA = i
						bestB = j
					end
				end
			end
		end
		if bestA == 0 then break end
		union(bestA, bestB)
		-- Back into the engine's own index base, and never outside the range it
		-- gave us: a bad index here is an access violation, not an error.
		local ea = bestA - 1 + base
		local eb = bestB - 1 + base
		if ea >= base and ea <= count - 1 + base and eb >= base and eb <= count - 1 + base then
			connections[#connections + 1] = { ea, eb }
			added = added + 1
		end
	end

	-- keep = true: add the links that are missing, leaving the existing street
	-- network alone.
	--
	-- keep = false means "remove the streets first", and that crashed the game:
	-- an access violation on the Simulation Thread (TransportFever3.exe+0xA4BD7,
	-- reading a freed pointer) a few seconds after this command was sent. By the
	-- time we get here the world has been simulating for minutes - towns have
	-- buildings, industries exist, people are moving - and tearing the whole
	-- street network out from under that leaves the engine holding stale
	-- references. The Map Editor can afford keep = false because nothing is
	-- running there; a game script cannot.
	--
	-- The cost is cosmetic: a destroyed town takes its own streets with it (see
	-- makeTownDestroyCmd), but an inter-town road that used to lead to it can be
	-- left as a stub.
	api.cmd.sendCommand(
		api.cmd.makeTownConnectWithIndustriesCmd(entities, connections, true))
	log.message(LOG .. string.format(
		"connected %d towns with %d links: engine proposed %d indexed %d..%d "
		.. "(read as %d-based), %d skipped, %d added to join separate clusters",
		count, #connections, #connections - added,
		lowest == math.huge and 0 or lowest, highest == -math.huge and 0 or highest,
		base, skipped, added))
end

local mod = {}

mod.update = function(_userParams : table, state : GameScriptState<State>, _dt : number)
	local current = state:get()
	if current ~= nil and current.done then
		return
	end

	if current ~= nil and current.phase == 1 then
		-- Town creation is asynchronous. Wait for the world to show the town
		-- count we expect before laying out roads, but do not wait forever.
		local waited = (current.waited or 0) + 1
		if countTowns() < current.expected and waited < MAX_SETTLE_TICKS then
			state:set({ phase = 1, expected = current.expected, waited = waited,
				zeroes = 0, stable = 0, done = false })
			return
		end
		if countTowns() < current.expected then
			log.message(LOG .. string.format(
				"gave up waiting: %d of %d towns present", countTowns(), current.expected))
		end
		connectAll()
		state:set({ phase = 2, expected = current.expected, waited = 0,
			zeroes = countTowns(), stable = 0, done = false })
		return
	end

	if current ~= nil and current.phase == 2 then
		-- Every town starts empty and fills over the following ticks, so the
		-- only honest signal is that the number of empty ones has stopped
		-- falling. Whatever is still empty after that could not build at all.
		local waited = (current.waited or 0) + 1
		local empty = emptyTowns()
		local zeroes = #empty

		local stable = (current.stable or 0) + 1
		if zeroes < (current.zeroes or 0) then
			stable = 0
		end

		if zeroes > 0 and stable < POPULATION_STABLE_TICKS and waited < MAX_POPULATION_TICKS then
			state:set({ phase = 2, expected = current.expected, waited = waited,
				zeroes = zeroes, stable = stable, done = false })
			return
		end

		if zeroes > 0 then
			for __, entity in ipairs(empty) do
				api.cmd.sendCommand(api.cmd.makeTownDestroyCmd(entity))
			end
			log.message(LOG .. string.format(
				"removed %d town(s) with no inhabitants after %d ticks; %d left",
				zeroes, waited, countTowns() - zeroes))
			-- Their roads went with them, but the links that led to them can be
			-- left dangling, so lay the network out once more. Rare enough that
			-- the extra pass costs nothing in practice.
			state:set({ phase = 3, expected = current.expected, waited = 0,
				zeroes = 0, stable = 0, done = false })
		else
			log.message(LOG .. string.format(
				"every town is inhabited after %d ticks", waited))
			state:set({ phase = 3, expected = current.expected, waited = 0,
				zeroes = 0, stable = 0, done = true })
		end
		return
	end

	if current ~= nil and current.phase == 3 then
		-- One tick on, so the destroy commands have landed.
		connectAll()
		state:set({ phase = 4, expected = current.expected, waited = 0,
			zeroes = 0, stable = 0, done = true })
		return
	end

	local gameTimeComponent = api.engine.getComponent(
		api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME) as Engine.Component.GameTime
	if gameTimeComponent ~= nil and gameTimeComponent.gameTime > MAX_START_GAME_TIME then
		-- Not a fresh game: almost certainly the mod was added to an existing
		-- save. Do nothing, ever, rather than rearrange someone's towns.
		log.message(LOG .. "not a new game; clustering skipped")
		state:set({ phase = 4, expected = 0, waited = 0, zeroes = 0, stable = 0, done = true })
		return
	end

	-- Towns may not exist on the very first tick; wait for generation.
	if countTowns() < 2 then
		return
	end

	local expected = redistribute()
	if expected > 0 then
		state:set({ phase = 1, expected = expected, waited = 0,
			zeroes = 0, stable = 0, done = false })
	else
		state:set({ phase = 4, expected = 0, waited = 0, zeroes = 0, stable = 0, done = true })
	end
end

return mod
