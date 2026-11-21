-- Engine stubs for the offline tests: just enough of FS25 for scripts/NoAICollisions.lua.
-- Positions ignore rotation (every vehicle faces +z); overlap checks call back at once with the nodes the test
-- puts in world.hits[<callback name>].

world = {
    hits = {},         -- callback name -> list of nodes every overlap with that callback finds
    positions = {},    -- node -> { x, y, z }
    objects = {},      -- node -> node object (vehicle)
    masks = {},        -- node -> collision filter mask
    groups = {},       -- node -> collision filter group
    pairCalls = {},    -- { n1, n2, enabled } for every setPairCollision call
    overlaps = {},     -- { callback, target } for every overlap check
    logs = {},
}

g_currentModName = "FS25_NoAICollisions_ProEdition"
g_time = 0
g_updateLoopIndex = 0
g_server = {}
g_modIsLoaded = { FS25_NoAICollisions_ProEdition = true }

CollisionFlag = { DEFAULT = 1, STATIC_OBJECT = 2, DYNAMIC_OBJECT = 4, TREE = 8, BUILDING = 16, VEHICLE = 32,
    TRAFFIC_VEHICLE = 64 }
ClassIds = { SHAPE = 1 }

local function log(level, fmt, ...)
    table.insert(world.logs, level .. ": " .. string.format(fmt, ...))
end
Logging = {
    info = function(...) log("info", ...) end,
    warning = function(...) log("warning", ...) end,
    error = function(...) log("error", ...) end,
}

modEventListeners = {}
function addModEventListener(listener) table.insert(modEventListeners, listener) end

MathUtil = {
    vector2Length = function(x, z) return math.sqrt(x * x + z * z) end,
    vector3Length = function(x, y, z) return math.sqrt(x * x + y * y + z * z) end,
}

function entityExists(node) return world.positions[node] ~= nil end
function getWorldTranslation(node)
    local p = world.positions[node]
    return p[1], p[2], p[3]
end
function localToWorld(node, x, y, z)
    local p = world.positions[node]
    return p[1] + x, p[2] + y, p[3] + z
end
function worldToLocal(node, x, y, z)
    local p = world.positions[node]
    return x - p[1], y - p[2], z - p[3]
end
function getWorldRotation(node) return 0, 0, 0 end
function localDirectionToWorld(node, x, y, z) return x, y, z end

function getCollisionFilterMask(node) return world.masks[node] end
function setCollisionFilterMask(node, mask) world.masks[node] = mask end
function getCollisionFilterGroup(node) return world.groups[node] end
function setPairCollision(n1, n2, enabled) table.insert(world.pairCalls, { n1, n2, enabled }) end
function getHasClassId(node, classId) return true end
function getHasTrigger(node) return false end
function getNumOfChildren(node) return 0 end
function getChildAt(node, i) return nil end

local function overlap(callback, target)
    table.insert(world.overlaps, { callback = callback, target = target })
    for _, node in ipairs(world.hits[callback] or {}) do
        target[callback](target, node)
    end
end
function overlapBox(x, y, z, rx, ry, rz, ex, ey, ez, callback, target) overlap(callback, target) end
function overlapSphere(x, y, z, radius, callback, target) overlap(callback, target) end

g_currentMission = {
    vehicleSystem = { vehicles = {} },
    getNodeObject = function(self, node) return world.objects[node] end,
}

-- A one-unit vehicle with its root component at (x, 0, z), 3 m wide and 8 m long
local nextNode = 100
function makeVehicle(name, x, z)
    nextNode = nextNode + 1
    local node = nextNode
    local vehicle = { name = name, components = { { node = node } }, size = { width = 3, length = 8 } }
    vehicle.rootVehicle = vehicle
    world.positions[node] = { x, 0, z }
    world.objects[node] = vehicle
    world.masks[node] = CollisionFlag.VEHICLE + CollisionFlag.DEFAULT + CollisionFlag.TREE
    world.groups[node] = CollisionFlag.VEHICLE
    function vehicle:getChildVehicles() return { self } end
    function vehicle:getFullName() return self.name end
    function vehicle:getIsAIActive() return self.aiActive == true end
    function vehicle:getIsControlled() return false end
    function vehicle:getLastSpeed() return self.speed or 0 end
    table.insert(g_currentMission.vehicleSystem.vehicles, vehicle)
    return vehicle
end

-- AutoDrive driving it; allowDriveThrough as Overdrive publishes it (nil = the official AutoDrive)
function makeADHelper(name, x, z, allowDriveThrough)
    local vehicle = makeVehicle(name, x, z)
    vehicle.adActive = true
    vehicle.ad = {
        allowDriveThrough = allowDriveThrough,
        stateModule = { isActive = function() return vehicle.adActive end },
        specialDrivingModule = { isStoppingVehicle = function() return false end },
    }
    vehicle.ad.collisionDetectionModule = { vehicle = vehicle }
    return vehicle
end

-- AutoDrive's and Courseplay's classes, which the mod hooks. Their sensors report world.detected.
world.detected = true
ADCollisionDetectionModule = {
    hasDetectedObstable = function(module, dt)
        module.detectedObstable = world.detected
        return world.detected
    end,
}
ADSpecialDrivingModule = { driveToPoint = function() end }
ProximityController = {
    -- stopped (speed 0) while world.detected
    getDriveData = function(controller, maxSpeed, moveForwards)
        return 0, 0, nil, world.detected and 0 or maxSpeed
    end,
}

function nodeOf(vehicle) return vehicle.components[1].node end
