-- AutoDrive Overdrive's per-vehicle "Drive through obstructions (No AI Collisions)" (vehicle.ad.allowDriveThrough).
-- Every test runs in a fresh Lua runtime: tests/stubs.lua, scripts/NoAICollisions.lua, then this file.

local DT = 50

local function setup()
    NoAICollisions:loadMap("")
end

-- Runs the game for `ms`: every frame each AutoDrive helper in `helpers` asks its (hooked) collision check, then the
-- mod's update runs. Returns, per helper, what its check said on the last frame (true = stops for the obstacle).
local function run(ms, helpers)
    local last = {}
    for _ = 1, ms / DT do
        g_time = g_time + DT
        g_updateLoopIndex = g_updateLoopIndex + 1
        for _, helper in ipairs(helpers) do
            last[helper] = ADCollisionDetectionModule.hasDetectedObstable(helper.ad.collisionDetectionModule, DT)
        end
        NoAICollisions:update(DT)
    end
    return last
end

local function pairCalls(enabled)
    local n = 0
    for _, call in ipairs(world.pairCalls) do
        if call[3] == enabled then
            n = n + 1
        end
    end
    return n
end

local function overlapsOf(helper)
    local n = 0
    local state = NoAICollisions.aiStates[helper]
    for _, o in ipairs(world.overlaps) do
        if state ~= nil and o.target == state then
            n = n + 1
        end
    end
    return n
end

local function logsMatching(text)
    local n = 0
    for _, line in ipairs(world.logs) do
        if string.find(line, text, 1, true) then
            n = n + 1
        end
    end
    return n
end

local function check(condition, message)
    if not condition then
        error(message, 2)
    end
end

-- A helper on its route with a parked machine 10 m ahead that its sensors see
local function blockedHelper(allowDriveThrough)
    setup()
    local helper = makeADHelper("Helper", 0, 0, allowDriveThrough)
    local blocker = makeVehicle("Parked", 0, 10)
    world.hits.onProbeHit = { nodeOf(blocker) }
    return helper, blocker
end

local tests = {}

function tests.official_autodrive_drives_through()
    local helper = blockedHelper(nil)
    check(run(1500, { helper })[helper] == true, "stops while blocked for less than 2 s")
    check(run(1500, { helper })[helper] == false, "drives on after 2 s")
    check(pairCalls(false) > 0, "collision with the parked machine switched off")
end

function tests.overdrive_on_drives_through()
    local helper = blockedHelper(true)
    run(1500, { helper })
    check(run(1500, { helper })[helper] == false, "drives on after 2 s")
    check(pairCalls(false) > 0, "collision with the parked machine switched off")
    check(logsMatching("waits like normal AutoDrive") == 0, "nothing logged")
end

function tests.overdrive_off_waits()
    local helper = blockedHelper(false)
    for _ = 1, 10 do
        check(run(1000, { helper })[helper] == true, "keeps stopping for the obstacle")
    end
    check(#world.pairCalls == 0, "no pair collision touched")
    check(overlapsOf(helper) == 0, "no probes for this helper")
    check(world.masks[nodeOf(helper)] == CollisionFlag.VEHICLE + CollisionFlag.DEFAULT + CollisionFlag.TREE,
        "own collision mask untouched")
    check(logsMatching("Helper: AutoDrive's \"Drive through obstructions\" is off") == 1, "logged once")
end

function tests.overdrive_off_stuck_waits()
    -- Not seen by the sensors, but standing still while driving (caught on a wall): still waits
    local helper = blockedHelper(false)
    world.detected = false
    check(run(6000, { helper })[helper] == false, "the sensors' answer is passed on unchanged")
    check(#world.pairCalls == 0, "no pair collision touched")
end

function tests.overdrive_off_no_contact_pass_through()
    setup()
    local helper = makeADHelper("Helper", 0, 0, false)
    local other = makeVehicle("Harvester", 3, 0)
    helper.speed = 10
    world.detected = false
    world.hits.onContactHit = { nodeOf(other) }
    run(3000, { helper })
    check(#world.pairCalls == 0, "touching vehicle stays solid")
    check(overlapsOf(helper) == 0, "no contact probes for this helper")
end

function tests.overdrive_on_contact_pass_through()
    setup()
    local helper = makeADHelper("Helper", 0, 0, true)
    local other = makeVehicle("Harvester", 3, 0)
    helper.speed = 10
    world.detected = false
    world.hits.onContactHit = { nodeOf(other) }
    run(3000, { helper })
    check(pairCalls(false) > 0, "touching vehicle passed through")
end

function tests.overdrive_off_no_tree_pass_through()
    setup()
    local helper = makeADHelper("Helper", 0, 0, false)
    world.positions[999] = { 0, 0, 4 } -- a tree, no node object
    world.hits.onTreeContact = { 999 }
    helper.speed = 10
    world.detected = false
    run(3000, { helper })
    check(world.masks[nodeOf(helper)] == CollisionFlag.VEHICLE + CollisionFlag.DEFAULT + CollisionFlag.TREE,
        "still collides with trees")
end

function tests.overdrive_on_tree_pass_through()
    setup()
    local helper = makeADHelper("Helper", 0, 0, true)
    world.positions[999] = { 0, 0, 4 }
    world.hits.onTreeContact = { 999 }
    helper.speed = 10
    world.detected = false
    run(3000, { helper })
    check(world.masks[nodeOf(helper)] == CollisionFlag.VEHICLE, "passes through trees")
end

function tests.switched_on_again_drives_through()
    local helper = blockedHelper(false)
    check(run(5000, { helper })[helper] == true, "waits while off")
    helper.ad.allowDriveThrough = true
    check(run(1500, { helper })[helper] == true, "2 s wait starts when it is switched on")
    check(run(1500, { helper })[helper] == false, "then drives on")
end

function tests.switched_off_while_passing_restores()
    local helper, blocker = blockedHelper(true)
    check(run(3000, { helper })[helper] == false, "drives through")
    helper.ad.allowDriveThrough = false
    check(run(500, { helper })[helper] == true, "stops for obstacles again")
    -- The machine drives off: collisions come back as usual
    world.positions[nodeOf(blocker)] = { 0, 0, 100 }
    world.hits.onProbeHit = {}
    run(2000, { helper })
    check(pairCalls(true) == pairCalls(false), "every pair switched back on")
    check(NoAICollisions.aiStates[helper] == nil or next(NoAICollisions.aiStates[helper].ghostedVehicles) == nil,
        "nothing left ghosted")
end

function tests.not_driven_by_autodrive_ignores_setting()
    -- Courseplay drives a vehicle whose AutoDrive setting is off: an AutoDrive setting, so it doesn't apply
    setup()
    local vehicle = makeADHelper("CP tractor", 0, 0, false)
    vehicle.adActive = false
    vehicle.aiActive = true
    local blocker = makeVehicle("Parked", 0, 10)
    world.hits.onProbeHit = { nodeOf(blocker) }
    local controller = { vehicle = vehicle }
    local speed
    for _ = 1, 3000 / DT do
        g_time = g_time + DT
        g_updateLoopIndex = g_updateLoopIndex + 1
        local _, _, _, s = ProximityController.getDriveData(controller, 10, true)
        speed = s
        NoAICollisions:update(DT)
    end
    check(speed == 10, "Courseplay drives through after 2 s")
    check(pairCalls(false) > 0, "collision switched off")
end

function tests.head_on_other_helper_still_driven_through()
    -- Two AutoDrive helpers facing each other: the one with the setting on drives through the one with it off
    setup()
    local a = makeADHelper("A", 0, 0, true)
    local b = makeADHelper("B", 0, 10, false)
    b.getReverserDirection = function() return -1 end
    world.hits.onProbeHit = { nodeOf(a), nodeOf(b) }
    local last = run(3000, { a, b })
    check(last[a] == false, "A drives through B")
    check(last[b] == true, "B keeps waiting")
    check(overlapsOf(b) == 0, "B never probes")
end

return tests
