--
-- No AI Collisions
-- Author: PropaineX
--
-- AI road traffic behaves normally (it stops for you, and you bump into moving
-- cars), but any traffic car that sits still near one of your vehicles becomes
-- pass-through, so a stopped car can never jam you up.
--
-- How it works:
--   * Two shapes only collide when each one's group matches the other's mask.
--   * Around every active player vehicle we look for shapes in the
--     TRAFFIC_VEHICLE group and track how far they move.
--   * Once a traffic shape has been stationary for STOP_TIME, VEHICLE is removed
--     from its collision mask, so player vehicles pass through it.
--   * When it moves again and no player vehicle is close enough to overlap it,
--     the original mask is restored. Restoring while overlapping would make the
--     physics engine shove the vehicles apart violently.
--
-- Helpers that are stopped:
--   * AutoDrive (forwards and reversing), Courseplay and the base game helper
--     are hooked where they decide to stop for an obstacle.
--   * If a helper has been stopped for BLOCK_TIME and a box probe finds a car
--     or vehicle in its path, it ignores the stop and drives on along its
--     course. Collisions are switched off between the helper and whatever is
--     in its path:
--       - traffic cars become pass-through (same as above),
--       - game vehicles (parked machines, your own vehicle...) get pair
--         collision disabled with the helper only, so they stay solid for
--         everything else. Pair collision only covers the bodies, so the
--         helper's wheels also stop touching vehicles meanwhile; otherwise
--         they climb onto the other vehicle and drag it along.
--   * Another helper in the path is only driven through when it is stopped by
--     this helper as well (a deadlock) or the two are touching (they bumped,
--     and often only one of them sees the other while the other is pinned).
--     A helper waiting its turn, like an AutoDrive or Courseplay truck
--     queueing at an unload point with a gap, is left alone. Only a helper
--     facing the way this one drives and in the same lane counts as a queue:
--     one facing it or crossing its path (an unloader waiting in the field
--     for its combine) or in the next lane (side by side leaving a two-lane
--     silo) is driven through after BLOCK_TIME.
--       - world objects (trees, buildings, walls, static and dynamic objects
--         such as bales) get their flags taken out of the collision mask of
--         every shape and wheel of the helper, so it passes through all of
--         them until it is clear. Triggers are left alone.
--   * An AutoDrive helper that is trying to drive but hasn't moved for
--     STUCK_TIME (a trailer caught on a wall in a corner, which its sensors
--     don't see) counts as stopped too, so it drives through what it is
--     pressed against.
--   * Nothing physical found in the path (an AutoDrive route yield) means the
--     helper waits as it normally would.
--   * Collisions are switched back on once the helper and the obstruction are
--     clear of each other.
--
-- Multiplayer: collision filters are local engine state, so every peer (server
-- and clients) runs the same traffic logic on its own copy of the traffic. No
-- network events are needed. Helpers only drive on the server, so the helper
-- hooks only ever fire there.
--

NoAICollisions = {}
NoAICollisions.MOD_NAME = g_currentModName

NoAICollisions.SCAN_INTERVAL = 500   -- ms between checks
NoAICollisions.STOP_TIME = 2000      -- ms a traffic car must stand still before it becomes pass-through
NoAICollisions.STOP_DISTANCE = 0.1   -- m moved per scan that still counts as standing still
NoAICollisions.SCAN_RADIUS = 20      -- m around each active vehicle (plus half its size)
NoAICollisions.CLEAR_DISTANCE = 8    -- m extra gap required before a car becomes solid again

NoAICollisions.BLOCK_TIME = 2000     -- ms a helper stays stopped before it drives through the obstruction
NoAICollisions.PROBE_INTERVAL = 250  -- ms between checks of a stopped helper's path
NoAICollisions.PROBE_LENGTH = 15     -- m checked in front of (or behind, when reversing) each unit of the helper
NoAICollisions.SEEN_TIMEOUT = 1000   -- ms a probe hit stays valid
NoAICollisions.PAIR_CLEAR_GAP = 2    -- m extra gap required before a helper and a game vehicle collide again
NoAICollisions.CONTACT_MARGIN = 0.3  -- m around a helper's body that counts as touching (AutoDrive queues at 2 m or more)
NoAICollisions.QUEUE_ANGLE_COS = math.cos(math.rad(45)) -- a helper ahead counts as a queue only when it faces within 45 deg of our driving direction
NoAICollisions.WORLD_PROBE_LIFT = 0.5 -- m above each unit's root where the world object checks start, so the ground under it doesn't count
NoAICollisions.STUCK_TIME = 2000     -- ms an AutoDrive helper that wants to drive may stand still before it counts as stopped
NoAICollisions.STUCK_SPEED = 0.5     -- km/h below which it counts as standing still

NoAICollisions.tracked = {}          -- traffic shape node -> { x, y, z, stoppedTime, lastSeen }
NoAICollisions.ghosted = {}          -- traffic shape node -> original collision mask
NoAICollisions.pairGhosts = {}       -- "node1_node2" -> number of helpers that disabled this pair
NoAICollisions.aiStates = {}         -- helper root vehicle -> AIState
NoAICollisions.scanTimer = 0
NoAICollisions.isReady = false

local function hasFlag(value, flag)
    return math.floor(value / flag) % 2 == 1
end

-- Clears every bit of `flags` that is set in `mask`
local function removeFlags(mask, flags)
    local bit = 1
    while bit <= flags do
        if hasFlag(flags, bit) and hasFlag(mask, bit) then
            mask = mask - bit
        end
        bit = bit * 2
    end
    return mask
end

function NoAICollisions:loadMap(filename)
    if CollisionFlag == nil or CollisionFlag.TRAFFIC_VEHICLE == nil or CollisionFlag.VEHICLE == nil then
        Logging.error("[%s] Required collision flags not found, mod disabled.", self.MOD_NAME)
        return
    end

    self.trafficFlag = CollisionFlag.TRAFFIC_VEHICLE
    self.vehicleFlag = CollisionFlag.VEHICLE
    self.probeMask = self.trafficFlag + self.vehicleFlag

    -- World objects a helper drives through: what AutoDrive's and Courseplay's
    -- sensors stop for, apart from vehicles. Wheels keep DEFAULT so they still
    -- stand on map ground meshes.
    self.worldFlags, self.wheelWorldFlags = 0, 0
    for _, name in ipairs({ "DEFAULT", "STATIC_OBJECT", "DYNAMIC_OBJECT", "TREE", "BUILDING" }) do
        local flag = CollisionFlag[name]
        if flag ~= nil then
            self.worldFlags = self.worldFlags + flag
            if name ~= "DEFAULT" then
                self.wheelWorldFlags = self.wheelWorldFlags + flag
            end
        end
    end
    self.canIgnoreWorld = self.worldFlags > 0 and getHasClassId ~= nil and ClassIds ~= nil and getHasTrigger ~= nil
    self.canDisablePairs = setPairCollision ~= nil
    if not self.canDisablePairs then
        Logging.warning("[%s] setPairCollision not available, helpers will only drive through traffic cars.", self.MOD_NAME)
    end
    self.isReady = true
    self.canIgnoreWheels = self:installWheelHook()
    self:installHelperHooks()
    Logging.info("[%s] Loaded - stopped AI traffic will become pass-through.", self.MOD_NAME)
end

function NoAICollisions:deleteMap()
    self.tracked = {}
    self.ghosted = {}
    self.pairGhosts = {}
    self.aiStates = {}
    self.isReady = false
end

function NoAICollisions:getVehicles()
    if g_currentMission.vehicleSystem ~= nil and g_currentMission.vehicleSystem.vehicles ~= nil then
        return g_currentMission.vehicleSystem.vehicles
    end
    return g_currentMission.vehicles or {}
end

local function getVehicleRadius(vehicle)
    local size = vehicle.size
    if size ~= nil and size.length ~= nil and size.width ~= nil then
        return math.max(size.length, size.width) * 0.5
    end
    return 5
end

local function getVehiclePosition(vehicle)
    if vehicle.isDeleted or vehicle.components == nil or vehicle.components[1] == nil then
        return nil
    end
    local node = vehicle.components[1].node
    if node == nil or not entityExists(node) then
        return nil
    end
    return getWorldTranslation(node)
end

-- Center of the vehicle's bounding box, which is not always where its root component sits
local function getVehicleCenter(vehicle)
    if vehicle.isDeleted or vehicle.components == nil or vehicle.components[1] == nil then
        return nil
    end
    local node = vehicle.components[1].node
    if node == nil or not entityExists(node) then
        return nil
    end
    local size = vehicle.size or {}
    return localToWorld(node, size.widthOffset or 0, 0, size.lengthOffset or 0)
end

-- Driven by the base game helper, Courseplay (runs as an AI job) or AutoDrive
local function isHelperActive(rootVehicle)
    if rootVehicle.getIsAIActive ~= nil and rootVehicle:getIsAIActive() then
        return true
    end
    if rootVehicle.ad ~= nil and rootVehicle.ad.stateModule ~= nil and rootVehicle.ad.stateModule:isActive() then
        return true
    end
    return false
end

-- A vehicle is "active" when someone is driving it, a helper is driving it, or
-- it is attached to such a vehicle. Parked vehicles don't need scanning.
local function isVehicleActive(vehicle)
    local rootVehicle = vehicle.rootVehicle or vehicle
    if rootVehicle.getIsControlled ~= nil and rootVehicle:getIsControlled() then
        return true
    end
    return isHelperActive(rootVehicle)
end

local function getChildVehicles(rootVehicle)
    if rootVehicle.getChildVehicles ~= nil then
        return rootVehicle:getChildVehicles()
    end
    return { rootVehicle }
end

function NoAICollisions:update(dt)
    if not self.isReady or g_currentMission == nil then
        return
    end

    self.scanTimer = self.scanTimer - dt
    if self.scanTimer > 0 then
        return
    end
    self.scanTimer = self.SCAN_INTERVAL

    -- Overlap results arrive asynchronously, so each scan processes the
    -- results gathered since the previous one.
    self:updateTrackedShapes()
    self:updateHelpers()

    for _, vehicle in pairs(self:getVehicles()) do
        if isVehicleActive(vehicle) then
            local x, y, z = getVehiclePosition(vehicle)
            if x ~= nil then
                local radius = self.SCAN_RADIUS + getVehicleRadius(vehicle)
                overlapSphere(x, y, z, radius, "onTrafficOverlap", self, self.trafficFlag, true, true, true, true)
            end
        end
    end
end

function NoAICollisions:onTrafficOverlap(node)
    if node == nil or node == 0 or not entityExists(node) then
        return true
    end

    -- Ignore anything that belongs to a regular game vehicle
    local object = g_currentMission:getNodeObject(node)
    if object ~= nil and object.rootVehicle ~= nil then
        return true
    end

    local entry = self.tracked[node]
    if entry == nil then
        local x, y, z = getWorldTranslation(node)
        self.tracked[node] = { x = x, y = y, z = z, stoppedTime = 0, lastSeen = g_time }
    else
        entry.lastSeen = g_time
    end

    return true
end

function NoAICollisions:updateTrackedShapes()
    for node, entry in pairs(self.tracked) do
        if not entityExists(node) then
            self.tracked[node] = nil
            self.ghosted[node] = nil
        else
            local x, y, z = getWorldTranslation(node)
            local moved = MathUtil.vector3Length(x - entry.x, y - entry.y, z - entry.z)
            entry.x, entry.y, entry.z = x, y, z

            if moved <= self.STOP_DISTANCE then
                entry.stoppedTime = entry.stoppedTime + self.SCAN_INTERVAL
            else
                entry.stoppedTime = 0
            end

            local isNearby = g_time - entry.lastSeen <= self.SCAN_INTERVAL * 2

            if self.ghosted[node] == nil then
                if isNearby and entry.stoppedTime >= self.STOP_TIME then
                    self:setGhosted(node, true)
                elseif not isNearby then
                    self.tracked[node] = nil
                end
            elseif (entry.stoppedTime == 0 or not isNearby) and not self:isOverlappingPlayerVehicle(node) then
                self:setGhosted(node, false)
                if not isNearby then
                    self.tracked[node] = nil
                end
            end
        end
    end
end

function NoAICollisions:setGhosted(node, ghosted)
    if ghosted then
        local mask = getCollisionFilterMask(node)
        if mask ~= nil and hasFlag(mask, self.vehicleFlag) then
            self.ghosted[node] = mask
            setCollisionFilterMask(node, mask - self.vehicleFlag)
        end
    else
        local mask = self.ghosted[node]
        if mask ~= nil then
            setCollisionFilterMask(node, mask)
            self.ghosted[node] = nil
        end
    end
end

-- Conservative distance check against every player vehicle, parked ones
-- included, so a car never turns solid inside a trailer or tractor.
function NoAICollisions:isOverlappingPlayerVehicle(node)
    local tx, _, tz = getWorldTranslation(node)
    for _, vehicle in pairs(self:getVehicles()) do
        local x, _, z = getVehiclePosition(vehicle)
        if x ~= nil then
            local distance = MathUtil.vector2Length(tx - x, tz - z)
            if distance < getVehicleRadius(vehicle) + self.CLEAR_DISTANCE then
                return true
            end
        end
    end
    return false
end

--
-- Pair collision between a helper and a game vehicle
--

local function getPairKey(node1, node2)
    if node1 > node2 then
        node1, node2 = node2, node1
    end
    return string.format("%d_%d", node1, node2)
end

-- Disables collision between every component of the helper and every
-- component of the other vehicle. Returns the node pairs so they can be
-- restored later, even if implements get attached or detached meanwhile.
function NoAICollisions:disablePairCollision(rootA, rootB)
    local nodePairs = {}
    for _, a in ipairs(getChildVehicles(rootA)) do
        for _, b in ipairs(getChildVehicles(rootB)) do
            if a.components ~= nil and b.components ~= nil then
                for _, ca in ipairs(a.components) do
                    for _, cb in ipairs(b.components) do
                        local n1, n2 = ca.node, cb.node
                        if n1 ~= nil and n2 ~= nil and entityExists(n1) and entityExists(n2) then
                            local key = getPairKey(n1, n2)
                            local count = self.pairGhosts[key] or 0
                            if count == 0 then
                                setPairCollision(n1, n2, false)
                            end
                            self.pairGhosts[key] = count + 1
                            table.insert(nodePairs, { n1, n2, key })
                        end
                    end
                end
            end
        end
    end
    return nodePairs
end

function NoAICollisions:restorePairCollision(nodePairs)
    for _, pair in ipairs(nodePairs) do
        local n1, n2, key = pair[1], pair[2], pair[3]
        local count = (self.pairGhosts[key] or 1) - 1
        if count <= 0 then
            self.pairGhosts[key] = nil
            if entityExists(n1) and entityExists(n2) then
                setPairCollision(n1, n2, true)
            end
        else
            self.pairGhosts[key] = count
        end
    end
end

--
-- Wheels of a helper that drives through game vehicles
--

-- Wheels find what they stand on with their own collision mask, which pair
-- collision doesn't touch. The game applies that mask in WheelPhysics:updateBase,
-- so VEHICLE (and the world objects, see below) is left out there while a
-- helper drives through.
function NoAICollisions:installWheelHook()
    if WheelPhysics == nil or WheelPhysics.updateBase == nil or bit32 == nil then
        Logging.warning("[%s] WheelPhysics not available, helper wheels may still catch on vehicles they drive through.", self.MOD_NAME)
        return false
    end
    if WheelPhysics.noAICollisionsHooked then
        return true
    end
    WheelPhysics.noAICollisionsHooked = true

    local loggedMask = false
    local updateBase = WheelPhysics.updateBase
    WheelPhysics.updateBase = function(physics, ...)
        local flags = 0
        if (physics.noAICollisionsVehicleCount or 0) > 0 then
            flags = flags + NoAICollisions.vehicleFlag
        end
        if (physics.noAICollisionsWorldCount or 0) > 0 then
            flags = flags + NoAICollisions.wheelWorldFlags
        end
        if flags == 0 then
            return updateBase(physics, ...)
        end
        local collisionMask = physics.collisionMask
        local mask = collisionMask or physics.configCollisionMask or WheelPhysics.COLLISION_MASK
        if mask ~= nil then
            if not loggedMask then
                loggedMask = true
                Logging.info("[%s] Helper wheel mask %s (vehicles %s), left out while driving through.",
                    NoAICollisions.MOD_NAME, tostring(mask), hasFlag(mask, NoAICollisions.vehicleFlag) and "included" or "not included")
            end
            physics.collisionMask = removeFlags(mask, flags)
        end
        updateBase(physics, ...)
        physics.collisionMask = collisionMask
    end
    return true
end

-- Counts up `counter` on every wheel of the helper. Returns the wheels it
-- changed so they can be restored later, even if implements get attached or
-- detached meanwhile.
function NoAICollisions:disableWheelCollision(rootVehicle, counter)
    local wheels = {}
    for _, vehicle in ipairs(getChildVehicles(rootVehicle)) do
        local spec = vehicle.spec_wheels
        if spec ~= nil and spec.wheels ~= nil then
            for _, wheel in ipairs(spec.wheels) do
                local physics = wheel.physics
                if physics ~= nil then
                    physics[counter] = (physics[counter] or 0) + 1
                    -- The game rebuilds the wheel shape in its post update
                    physics.isPositionDirty = true
                    table.insert(wheels, physics)
                end
            end
        end
    end
    return wheels
end

function NoAICollisions:restoreWheelCollision(wheels, counter)
    for _, physics in ipairs(wheels) do
        physics[counter] = math.max((physics[counter] or 1) - 1, 0)
        physics.isPositionDirty = true
    end
end

--
-- Collision between a helper and world objects (trees, buildings, static
-- and dynamic objects)
--

-- Takes the world flags out of every collision shape of the helper and its
-- implements. Triggers are left alone so unload and fill triggers still work.
-- Returns shape node -> original mask.
function NoAICollisions:disableWorldCollision(rootVehicle)
    local shapes = {}
    local function walk(node)
        if shapes[node] ~= nil then
            return
        end
        if getHasClassId(node, ClassIds.SHAPE) and not getHasTrigger(node) then
            local mask = getCollisionFilterMask(node)
            if mask ~= nil then
                local newMask = removeFlags(mask, self.worldFlags)
                if newMask ~= mask then
                    setCollisionFilterMask(node, newMask)
                    shapes[node] = mask
                end
            end
        end
        for i = 0, getNumOfChildren(node) - 1 do
            walk(getChildAt(node, i))
        end
    end
    for _, vehicle in ipairs(getChildVehicles(rootVehicle)) do
        if vehicle.components ~= nil then
            for _, component in ipairs(vehicle.components) do
                if component.node ~= nil and entityExists(component.node) then
                    walk(component.node)
                end
            end
        end
    end
    return shapes
end

function NoAICollisions:restoreWorldCollision(shapes)
    for node, mask in pairs(shapes) do
        if entityExists(node) then
            setCollisionFilterMask(node, mask)
        end
    end
end

-- Conservative check using bounding circles of every unit of both vehicles
function NoAICollisions:areVehiclesOverlapping(rootA, rootB)
    for _, a in ipairs(getChildVehicles(rootA)) do
        local ax, _, az = getVehicleCenter(a)
        if ax ~= nil then
            for _, b in ipairs(getChildVehicles(rootB)) do
                local bx, _, bz = getVehicleCenter(b)
                if bx ~= nil then
                    local gap = getVehicleRadius(a) + getVehicleRadius(b) + self.PAIR_CLEAR_GAP
                    if MathUtil.vector2Length(ax - bx, az - bz) < gap then
                        return true
                    end
                end
            end
        end
    end
    return false
end

--
-- Helpers that are stopped
--

-- Per-helper state. It is also the target of the overlap callbacks, so every
-- probe result lands on the helper that asked for it.
local AIState = {}
AIState.__index = AIState

function AIState.new(rootVehicle)
    local state = setmetatable({}, AIState)
    state.rootVehicle = rootVehicle
    state.blockedSince = nil
    state.isPushing = false
    state.lastCall = 0
    state.lastBlocked = nil
    state.lastProbe = -math.huge
    state.traffic = {}         -- traffic shape node -> last time it was in the helper's path
    state.vehicles = {}        -- game root vehicle -> last time it was in the helper's path
    state.contacts = {}        -- game root vehicle -> last time it was touching the helper
    state.ghostedVehicles = {} -- game root vehicle -> node pairs with collision disabled
    state.ghostedWheels = nil  -- helper wheels not touching vehicles, while any vehicle is ghosted
    state.world = nil          -- last time a world object was in the helper's path
    state.worldContact = nil   -- last time a world object was touching the helper
    state.worldChecks = 0      -- contact checks sent since the world was ghosted
    state.ghostedWorld = nil   -- helper shape node -> original mask, while driving through world objects
    state.ghostedWorldWheels = nil
    return state
end

-- World objects: trees, buildings, static and dynamic objects. Parts of game
-- vehicles (pallets, for example) go to the vehicle handling instead.
function AIState:onWorldHit(node)
    if node == nil or node == 0 or not entityExists(node) or getHasTrigger(node) then
        return true
    end
    local object = g_currentMission:getNodeObject(node)
    if object ~= nil and object.rootVehicle ~= nil then
        local rootVehicle = object.rootVehicle
        if rootVehicle ~= self.rootVehicle and not rootVehicle.isDeleted then
            self.vehicles[rootVehicle] = g_time
        end
        return true
    end
    self.world = g_time
    return true
end

function AIState:onWorldContact(node)
    if node == nil or node == 0 or not entityExists(node) or getHasTrigger(node) then
        return true
    end
    local object = g_currentMission:getNodeObject(node)
    if object ~= nil and object.rootVehicle ~= nil then
        return true
    end
    self.worldContact = g_time
    return true
end

function AIState:onContactHit(node)
    if node == nil or node == 0 or not entityExists(node) then
        return true
    end
    local object = g_currentMission:getNodeObject(node)
    local rootVehicle = object ~= nil and object.rootVehicle or nil
    if rootVehicle ~= nil and rootVehicle ~= self.rootVehicle and not rootVehicle.isDeleted then
        self.contacts[rootVehicle] = g_time
    end
    return true
end

function AIState:onProbeHit(node)
    if node == nil or node == 0 or not entityExists(node) then
        return true
    end

    -- Game vehicles have a node object with a root vehicle; traffic cars don't
    local object = g_currentMission:getNodeObject(node)
    if object ~= nil and object.rootVehicle ~= nil then
        local rootVehicle = object.rootVehicle
        if rootVehicle ~= self.rootVehicle and not rootVehicle.isDeleted then
            self.vehicles[rootVehicle] = g_time
        end
        return true
    end

    if getCollisionFilterGroup ~= nil then
        local group = getCollisionFilterGroup(node)
        if group == nil or not hasFlag(group, NoAICollisions.trafficFlag) then
            return true
        end
    end

    self.traffic[node] = g_time
    return true
end

-- Box covering every unit of the helper plus PROBE_LENGTH in its driving
-- direction, so something it has already partly driven into still counts.
function NoAICollisions:probeHelperPath(state, moveForwards)
    local direction = moveForwards and 1 or -1
    for _, vehicle in ipairs(getChildVehicles(state.rootVehicle)) do
        local node = vehicle.components ~= nil and vehicle.components[1] ~= nil and vehicle.components[1].node or nil
        if node ~= nil and entityExists(node) and vehicle.size ~= nil then
            local size = vehicle.size
            local halfLength = (size.length or 4) * 0.5 + self.PROBE_LENGTH * 0.5
            local z = (size.lengthOffset or 0) + direction * self.PROBE_LENGTH * 0.5
            local x, y, wz = localToWorld(node, size.widthOffset or 0, 1.5, z)
            local rx, ry, rz = getWorldRotation(node)
            overlapBox(x, y, wz, rx, ry, rz, (size.width or 3) * 0.5 + 0.3, 1.5, halfLength,
                "onProbeHit", state, self.probeMask, true, true, true, true)

            -- Same box for world objects, starting a bit above the ground
            if self.canIgnoreWorld then
                local lift = self.WORLD_PROBE_LIFT
                local lx, ly, lz = localToWorld(node, size.widthOffset or 0, 1.5 + lift * 0.5, z)
                overlapBox(lx, ly, lz, rx, ry, rz, (size.width or 3) * 0.5 + 0.3, 1.5 - lift * 0.5, halfLength,
                    "onWorldHit", state, self.worldFlags, true, true, true, true)
            end

            -- Tight box around the unit itself: anything in it is touching
            local cx, cy, cz = localToWorld(node, size.widthOffset or 0, 1.5, size.lengthOffset or 0)
            overlapBox(cx, cy, cz, rx, ry, rz, (size.width or 3) * 0.5 + self.CONTACT_MARGIN, 1.5,
                (size.length or 4) * 0.5 + self.CONTACT_MARGIN,
                "onContactHit", state, self.vehicleFlag, true, true, true, true)
        end
    end
end

-- Box around each unit of the helper (above the ground): anything in it is a
-- world object the helper is still inside
function NoAICollisions:probeWorldContact(state)
    local lift = self.WORLD_PROBE_LIFT
    for _, vehicle in ipairs(getChildVehicles(state.rootVehicle)) do
        local node = vehicle.components ~= nil and vehicle.components[1] ~= nil and vehicle.components[1].node or nil
        if node ~= nil and entityExists(node) and vehicle.size ~= nil then
            local size = vehicle.size
            local x, y, z = localToWorld(node, size.widthOffset or 0, 1.5 + lift * 0.5, size.lengthOffset or 0)
            local rx, ry, rz = getWorldRotation(node)
            overlapBox(x, y, z, rx, ry, rz, (size.width or 3) * 0.5 + self.CONTACT_MARGIN, 1.5 - lift * 0.5,
                (size.length or 4) * 0.5 + self.CONTACT_MARGIN,
                "onWorldContact", state, self.worldFlags, true, true, true, true)
        end
    end
    state.worldChecks = state.worldChecks + 1
end

-- Flat forward direction of a vehicle, following its reverser (cab turned around)
local function getVehicleForward(vehicle)
    local node = vehicle.components ~= nil and vehicle.components[1] ~= nil and vehicle.components[1].node or nil
    if node == nil or not entityExists(node) then
        return nil
    end
    local dx, _, dz = localDirectionToWorld(node, 0, 0, 1)
    if vehicle.getReverserDirection ~= nil then
        local reverser = vehicle:getReverserDirection()
        dx, dz = dx * reverser, dz * reverser
    end
    local length = MathUtil.vector2Length(dx, dz)
    if length < 0.001 then
        return nil
    end
    return dx / length, dz / length
end

-- Same lane: this helper's center lies within the wider of the two widths,
-- measured across the direction a unit of the other helper is facing. One in
-- the next lane over (two helpers leaving a two-lane silo side by side) is not
-- in line with it, even when this one turns towards it.
function NoAICollisions:isInSameLane(rootVehicle, otherVehicle)
    local x, y, z = getVehicleCenter(rootVehicle)
    if x == nil then
        return true -- can't tell: leave it alone as before
    end
    local ownWidth = rootVehicle.size ~= nil and rootVehicle.size.width or 3
    for _, unit in ipairs(getChildVehicles(otherVehicle)) do
        local node = unit.components ~= nil and unit.components[1] ~= nil and unit.components[1].node or nil
        if node ~= nil and entityExists(node) then
            local size = unit.size or {}
            local lx = worldToLocal(node, x, y, z) - (size.widthOffset or 0)
            if math.abs(lx) < math.max(ownWidth, size.width or 3) * 0.5 then
                return true
            end
        end
    end
    return false
end

-- A queue (trucks waiting at an unload point) means the helper ahead faces the
-- way this helper is driving and is in the same lane. One that faces it or
-- crosses its path is not waiting in line with it, e.g. an unloader standing
-- in the field for its combine, and neither is one in the next lane.
function NoAICollisions:isQueuedBehind(state, otherVehicle)
    local ax, az = getVehicleForward(state.rootVehicle)
    local bx, bz = getVehicleForward(otherVehicle)
    if ax == nil or bx == nil then
        return true -- can't tell: leave it alone as before
    end
    if state.moveForwards == false then
        ax, az = -ax, -az
    end
    if ax * bx + az * bz < self.QUEUE_ANGLE_COS then
        return false
    end
    return self:isInSameLane(state.rootVehicle, otherVehicle)
end

-- Another helper is only driven through when it is stopped by us too. One that
-- is waiting for something else (its turn at an unload point, a route yield,
-- a different obstacle) must not be pushed into.
function NoAICollisions:isWaitingHelper(state, otherVehicle)
    if not isHelperActive(otherVehicle) then
        return false
    end
    -- Touching means they bumped: whatever the other one is doing, it can't
    -- get free on its own
    local touched = state.contacts[otherVehicle]
    if touched ~= nil and g_time - touched <= self.SEEN_TIMEOUT then
        return false
    end
    -- Facing it or crossing its path: not a queue, so it would wait forever
    if not self:isQueuedBehind(state, otherVehicle) then
        return false
    end
    local other = self.aiStates[otherVehicle]
    if other == nil or g_time - other.lastCall > self.SEEN_TIMEOUT then
        return true
    end
    if other.blockedSince == nil and not other.isPushing then
        return true
    end
    local seen = other.vehicles[state.rootVehicle]
    return seen == nil or g_time - seen > self.SEEN_TIMEOUT
end

-- Returns whether anything is in the helper's path, whether all of it
-- already has collisions with the helper switched off, and whether any of it
-- is a helper waiting its turn.
function NoAICollisions:getPathStatus(state)
    local hasObstacle, allGhosted, hasWaitingHelper = false, true, false
    for rootVehicle, lastSeen in pairs(state.contacts) do
        if rootVehicle.isDeleted or g_time - lastSeen > self.SEEN_TIMEOUT then
            state.contacts[rootVehicle] = nil
        end
    end
    for node, lastSeen in pairs(state.traffic) do
        if not entityExists(node) or g_time - lastSeen > self.SEEN_TIMEOUT then
            state.traffic[node] = nil
        else
            hasObstacle = true
            if self.ghosted[node] == nil then
                allGhosted = false
            end
        end
    end
    for rootVehicle, lastSeen in pairs(state.vehicles) do
        if rootVehicle.isDeleted or g_time - lastSeen > self.SEEN_TIMEOUT then
            state.vehicles[rootVehicle] = nil
        else
            hasObstacle = true
            if state.ghostedVehicles[rootVehicle] == nil then
                allGhosted = false
                if self:isWaitingHelper(state, rootVehicle) then
                    hasWaitingHelper = true
                end
            end
        end
    end
    if state.world ~= nil then
        if g_time - state.world > self.SEEN_TIMEOUT then
            state.world = nil
        else
            hasObstacle = true
            if state.ghostedWorld == nil then
                allGhosted = false
            end
        end
    end
    return hasObstacle, allGhosted, hasWaitingHelper
end

-- Switches off collisions between the helper and everything in its path.
-- Traffic cars are turned solid again by the regular traffic logic, game
-- vehicles by updateHelpers once they are clear of the helper.
function NoAICollisions:ghostPath(state)
    for node, lastSeen in pairs(state.traffic) do
        if g_time - lastSeen <= self.SEEN_TIMEOUT and entityExists(node) then
            if self.tracked[node] == nil then
                local x, y, z = getWorldTranslation(node)
                self.tracked[node] = { x = x, y = y, z = z, stoppedTime = self.STOP_TIME, lastSeen = g_time }
            end
            if self.ghosted[node] == nil then
                self:setGhosted(node, true)
            end
        end
    end

    if self.canDisablePairs then
        for rootVehicle, lastSeen in pairs(state.vehicles) do
            if g_time - lastSeen <= self.SEEN_TIMEOUT and not rootVehicle.isDeleted
                and state.ghostedVehicles[rootVehicle] == nil then
                state.ghostedVehicles[rootVehicle] = self:disablePairCollision(state.rootVehicle, rootVehicle)
            end
        end
        if self.canIgnoreWheels and state.ghostedWheels == nil and next(state.ghostedVehicles) ~= nil then
            state.ghostedWheels = self:disableWheelCollision(state.rootVehicle, "noAICollisionsVehicleCount")
        end
    end

    if self.canIgnoreWorld and state.ghostedWorld == nil and state.world ~= nil
        and g_time - state.world <= self.SEEN_TIMEOUT then
        state.ghostedWorld = self:disableWorldCollision(state.rootVehicle)
        state.worldContact = nil
        state.worldChecks = 0
        if self.canIgnoreWheels then
            state.ghostedWorldWheels = self:disableWheelCollision(state.rootVehicle, "noAICollisionsWorldCount")
        end
    end
end

function NoAICollisions:getAIState(vehicle)
    local rootVehicle = vehicle.rootVehicle or vehicle
    local state = self.aiStates[rootVehicle]
    if state == nil then
        state = AIState.new(rootVehicle)
        self.aiStates[rootVehicle] = state
    end
    return state
end

-- Called by the helper hooks every time the helper decides whether to stop.
-- Returns true while the helper should ignore the stop and drive on.
function NoAICollisions:shouldDriveOn(vehicle, isBlocked, moveForwards)
    if not self.isReady or vehicle == nil or vehicle.isDeleted then
        return false
    end
    local state = self:getAIState(vehicle)

    -- A gap in calls means the helper was off or doing something else
    if g_time - state.lastCall > self.SEEN_TIMEOUT then
        state.blockedSince = nil
        state.isPushing = false
    end
    state.lastCall = g_time
    state.moveForwards = moveForwards ~= false

    if not isBlocked then
        -- AutoDrive may run more than one check per frame; a block reported
        -- by another check this frame still stands.
        if state.lastBlocked ~= g_time then
            state.blockedSince = nil
            state.isPushing = false
        end
        return false
    end
    state.lastBlocked = g_time

    if g_time - state.lastProbe >= self.PROBE_INTERVAL then
        state.lastProbe = g_time
        self:probeHelperPath(state, moveForwards ~= false)
    end

    local hasObstacle, allGhosted, hasWaitingHelper = self:getPathStatus(state)

    if state.isPushing then
        if not hasWaitingHelper then
            self:ghostPath(state)
            return true
        end
        -- Caught up with a helper that is waiting its turn: queue behind it
        state.isPushing = false
        state.blockedSince = g_time
        return false
    end

    -- Still passing through something it already drove into
    if hasObstacle and allGhosted then
        return true
    end

    if state.blockedSince == nil then
        state.blockedSince = g_time
    end

    if hasObstacle and not hasWaitingHelper and g_time - state.blockedSince >= self.BLOCK_TIME then
        state.blockedSince = nil
        state.isPushing = true
        self:ghostPath(state)
        return true
    end
    return false
end

-- AutoDrive is driving (not holding on purpose) but the vehicle has stood
-- still for STUCK_TIME: it is pressed against something its sensors don't see
function NoAICollisions:isStuck(vehicle)
    if not self.isReady or vehicle == nil or vehicle.isDeleted then
        return false
    end
    local state = self:getAIState(vehicle)
    local ad = vehicle.ad
    local isHolding = ad ~= nil and ad.specialDrivingModule ~= nil and ad.specialDrivingModule:isStoppingVehicle()
    local speed = vehicle.getLastSpeed ~= nil and vehicle:getLastSpeed() or 0
    local hadGap = state.lastStuckCheck == nil or g_time - state.lastStuckCheck > self.SEEN_TIMEOUT
    state.lastStuckCheck = g_time

    if isHolding or hadGap or speed > self.STUCK_SPEED then
        state.stuckSince = nil
    elseif state.stuckSince == nil then
        state.stuckSince = g_time
    end
    return state.stuckSince ~= nil and g_time - state.stuckSince >= self.STUCK_TIME
end

-- Turns collisions between helpers and game vehicles back on once they are clear
function NoAICollisions:restoreClearedVehicles(state)
    for otherVehicle, nodePairs in pairs(state.ghostedVehicles) do
        local release = state.rootVehicle.isDeleted or otherVehicle.isDeleted
        if not release then
            local lastSeen = state.vehicles[otherVehicle]
            local isInPath = lastSeen ~= nil and g_time - lastSeen <= self.SEEN_TIMEOUT
            release = not isInPath and not self:areVehiclesOverlapping(state.rootVehicle, otherVehicle)
        end
        if release then
            self:restorePairCollision(nodePairs)
            state.ghostedVehicles[otherVehicle] = nil
        end
    end
    if state.ghostedWheels ~= nil and next(state.ghostedVehicles) == nil then
        self:restoreWheelCollision(state.ghostedWheels, "noAICollisionsVehicleCount")
        state.ghostedWheels = nil
    end
end

-- Turns world collisions of a helper back on once nothing is in its path or
-- inside it. Contact results arrive asynchronously, so at least one full
-- check must have come back since the world was ghosted.
function NoAICollisions:restoreClearedWorld(state)
    if state.ghostedWorld == nil then
        return
    end
    local release = state.rootVehicle.isDeleted
    if not release then
        local isInPath = state.world ~= nil and g_time - state.world <= self.SEEN_TIMEOUT
        local isTouching = state.worldContact ~= nil and g_time - state.worldContact <= self.SEEN_TIMEOUT
        release = not isInPath and not isTouching and state.worldChecks >= 2
    end
    if release then
        self:restoreWorldCollision(state.ghostedWorld)
        state.ghostedWorld = nil
        if state.ghostedWorldWheels ~= nil then
            self:restoreWheelCollision(state.ghostedWorldWheels, "noAICollisionsWorldCount")
            state.ghostedWorldWheels = nil
        end
    elseif not state.rootVehicle.isDeleted then
        self:probeWorldContact(state)
    end
end

function NoAICollisions:updateHelpers()
    for rootVehicle, state in pairs(self.aiStates) do
        self:restoreClearedVehicles(state)
        self:restoreClearedWorld(state)
        if (rootVehicle.isDeleted or g_time - state.lastCall > 10000) and next(state.ghostedVehicles) == nil
            and state.ghostedWorld == nil then
            self.aiStates[rootVehicle] = nil
        end
    end
end

-- Every mod runs in its own environment, reachable as a global named after
-- the mod (FS25_AutoDrive.ADCollisionDetectionModule), so classes from
-- AutoDrive or Courseplay are not visible here as plain globals.
local function findClass(name)
    local class = _G[name]
    if type(class) == "table" then
        return class
    end
    if g_modIsLoaded ~= nil then
        for modName, isLoaded in pairs(g_modIsLoaded) do
            local env = isLoaded and _G[modName] or nil
            if type(env) == "table" and type(env[name]) == "table" then
                return env[name]
            end
        end
    end
    return nil
end

-- Switches the base game helper's view of the obstruction off or on again.
-- Its blocked callback only fires on changes, so the change is reported here.
function NoAICollisions:setBaseGameDriveOn(handler, driveOn)
    if handler.noAICollisionsDriveOn == driveOn then
        return
    end
    handler.noAICollisionsDriveOn = driveOn
    if handler.noAICollisionsBlockedCallback ~= nil then
        handler.noAICollisionsBlockedCallback(handler.isBlocked == true and not driveOn)
    end
end

function NoAICollisions:installHelperHooks()
    local hooked = 0

    -- AutoDrive: a single check decides whether it stops on its route
    local ADCollisionDetectionModule = findClass("ADCollisionDetectionModule")
    if ADCollisionDetectionModule ~= nil and ADCollisionDetectionModule.hasDetectedObstable ~= nil
        and not ADCollisionDetectionModule.noAICollisionsHooked then
        ADCollisionDetectionModule.noAICollisionsHooked = true
        local hasDetectedObstable = ADCollisionDetectionModule.hasDetectedObstable
        ADCollisionDetectionModule.hasDetectedObstable = function(module, ...)
            -- Already decided this frame together with the follow sensor (driveToPoint below)
            if module.noAICollisionsFrame == g_updateLoopIndex then
                return module.noAICollisionsResult
            end
            local detected = hasDetectedObstable(module, ...)
            -- Stuck against something the sensors don't see counts as stopped too
            local stuck = not detected and NoAICollisions:isStuck(module.vehicle)
            if NoAICollisions:shouldDriveOn(module.vehicle, detected or stuck, true) then
                module.detectedObstable = false
                return false
            end
            return detected
        end
        -- Reversing uses its own rear sensor check
        if ADCollisionDetectionModule.checkReverseCollision ~= nil then
            local checkReverseCollision = ADCollisionDetectionModule.checkReverseCollision
            ADCollisionDetectionModule.checkReverseCollision = function(module, ...)
                local detected = checkReverseCollision(module, ...)
                if NoAICollisions:shouldDriveOn(module.vehicle, detected == true, false) then
                    return false
                end
                return detected
            end
        end
        -- Following a combine or chasing a point also stops for the plain front
        -- sensor, outside the check above. Both are decided together here and
        -- the collision check is switched off while it drives through.
        local ADSpecialDrivingModule = findClass("ADSpecialDrivingModule")
        if ADSpecialDrivingModule ~= nil and ADSpecialDrivingModule.driveToPoint ~= nil then
            local driveToPoint = ADSpecialDrivingModule.driveToPoint
            ADSpecialDrivingModule.driveToPoint = function(module, dt, point, maxFollowSpeed, checkDynamicCollision, ...)
                local vehicle = module.vehicle
                local ad = vehicle ~= nil and vehicle.ad or nil
                if checkDynamicCollision and ad ~= nil and ad.collisionDetectionModule ~= nil then
                    local cdm = ad.collisionDetectionModule
                    local detected = hasDetectedObstable(cdm, dt)
                        or (ad.sensors ~= nil and ad.sensors.frontSensor ~= nil and ad.sensors.frontSensor:pollInfo())
                    if NoAICollisions:shouldDriveOn(vehicle, detected == true, true) then
                        cdm.detectedObstable = false
                        return driveToPoint(module, dt, point, maxFollowSpeed, false, ...)
                    end
                    cdm.noAICollisionsFrame = g_updateLoopIndex
                    cdm.noAICollisionsResult = detected == true
                end
                return driveToPoint(module, dt, point, maxFollowSpeed, checkDynamicCollision, ...)
            end
        end
        hooked = hooked + 1
        Logging.info("[%s] AutoDrive helpers will drive through obstructions after 2 seconds.", self.MOD_NAME)
    end

    -- Courseplay: the proximity controller stops or slows the helper for anything in front of it
    local ProximityController = findClass("ProximityController")
    if ProximityController ~= nil and ProximityController.getDriveData ~= nil
        and not ProximityController.noAICollisionsHooked then
        ProximityController.noAICollisionsHooked = true
        local getDriveData = ProximityController.getDriveData
        ProximityController.getDriveData = function(controller, maxSpeed, moveForwards, ...)
            local gx, gz, direction, speed = getDriveData(controller, maxSpeed, moveForwards, ...)
            local isBlocked = speed ~= nil and speed <= 0 and maxSpeed ~= nil and maxSpeed > 0
            if NoAICollisions:shouldDriveOn(controller.vehicle, isBlocked, moveForwards) then
                if controller.states ~= nil and controller.setState ~= nil then
                    controller:setState(controller.states.NO_OBSTACLE, "NoAICollisions: driving through obstruction")
                end
                -- Keep Courseplay's own "blocked for a while" recovery and the
                -- blocked message from kicking in while it drives through
                for _, timer in ipairs({ controller.blockingVehicle, controller.blockingObject, controller.showBlockedByObjectMessageTimer }) do
                    if type(timer) == "table" and timer.reset ~= nil then
                        timer:reset()
                    end
                end
                if controller.vehicle.resetCpActiveInfoText ~= nil and InfoTextManager ~= nil
                    and InfoTextManager.BLOCKED_BY_OBJECT ~= nil then
                    controller.vehicle:resetCpActiveInfoText(InfoTextManager.BLOCKED_BY_OBJECT)
                end
                return gx, gz, direction, maxSpeed
            end
            return gx, gz, direction, speed
        end
        hooked = hooked + 1
        Logging.info("[%s] Courseplay helpers will drive through obstructions after 2 seconds.", self.MOD_NAME)
    end

    -- Base game helper: the collision trigger handler tells the drive
    -- strategy when it is blocked (vehicles, players) and how far the nearest
    -- hit is. While driving through, both are reported as clear.
    local AICollisionTriggerHandler = findClass("AICollisionTriggerHandler")
    if AICollisionTriggerHandler ~= nil and AICollisionTriggerHandler.update ~= nil
        and AICollisionTriggerHandler.setIsBlockedCallback ~= nil
        and not AICollisionTriggerHandler.noAICollisionsHooked then
        AICollisionTriggerHandler.noAICollisionsHooked = true

        local setIsBlockedCallback = AICollisionTriggerHandler.setIsBlockedCallback
        AICollisionTriggerHandler.setIsBlockedCallback = function(handler, callback, ...)
            handler.noAICollisionsBlockedCallback = callback
            if callback ~= nil then
                local wrapped = function(isBlocked, ...)
                    return callback(isBlocked and not handler.noAICollisionsDriveOn, ...)
                end
                return setIsBlockedCallback(handler, wrapped, ...)
            end
            return setIsBlockedCallback(handler, callback, ...)
        end

        if AICollisionTriggerHandler.setCollisionDistanceCallback ~= nil then
            local setCollisionDistanceCallback = AICollisionTriggerHandler.setCollisionDistanceCallback
            AICollisionTriggerHandler.setCollisionDistanceCallback = function(handler, callback, ...)
                if callback ~= nil then
                    local wrapped = function(distance, ...)
                        if handler.noAICollisionsDriveOn then
                            distance = math.huge
                        end
                        return callback(distance, ...)
                    end
                    return setCollisionDistanceCallback(handler, wrapped, ...)
                end
                return setCollisionDistanceCallback(handler, callback, ...)
            end
        end

        local update = AICollisionTriggerHandler.update
        AICollisionTriggerHandler.update = function(handler, dt, movingDirection, ...)
            if handler.vehicle ~= nil then
                local forwards = movingDirection == nil or movingDirection >= 0
                local driveOn = NoAICollisions:shouldDriveOn(handler.vehicle, handler.isBlocked == true, forwards)
                NoAICollisions:setBaseGameDriveOn(handler, driveOn)
            end
            return update(handler, dt, movingDirection, ...)
        end
        hooked = hooked + 1
        Logging.info("[%s] Base game helpers will drive through obstructions after 2 seconds.", self.MOD_NAME)
    end

    if hooked == 0 then
        Logging.warning("[%s] No helper (base game, AutoDrive, Courseplay) could be hooked, helpers will not drive through obstructions.", self.MOD_NAME)
    end
end

addModEventListener(NoAICollisions)
