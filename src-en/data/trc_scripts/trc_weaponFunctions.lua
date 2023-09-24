mods.trc = {}

-----------------------
-- UTILITY FUNCTIONS --
-----------------------

local function userdata_table(userdata, tableName)
    if not userdata.table[tableName] then userdata.table[tableName] = {} end
    return userdata.table[tableName]
end

local function vter(cvec)
    local i = -1
    local n = cvec:size()
    return function()
        i = i + 1
        if i < n then return cvec[i] end
    end
end

-- Find ID of a room at the given location
local function get_room_at_location(shipManager, location, includeWalls)
    return Hyperspace.ShipGraph.GetShipInfo(shipManager.iShipId):GetSelectedRoom(location.x, location.y, includeWalls)
end

local function is_first_shot(weapon, afterFirstShot)
    local shots = weapon.numShots
    if weapon.weaponVisual.iChargeLevels > 0 then shots = shots*(weapon.weaponVisual.boostLevel + 1) end
    if weapon.blueprint.miniProjectiles:size() > 0 then shots = shots*weapon.blueprint.miniProjectiles:size() end
    if afterFirstShot then shots = shots - 1 end
    return shots == weapon.queuedProjectiles:size()
end

-- Returns a table where the indices are the IDs of all rooms adjacent to the given room
-- and the values are the rooms' coordinates
local function get_adjacent_rooms(shipId, roomId, diagonals)
    local shipGraph = Hyperspace.ShipGraph.GetShipInfo(shipId)
    local roomShape = shipGraph:GetRoomShape(roomId)
    local adjacentRooms = {}
    local currentRoom = nil
    local function check_for_room(x, y)
        currentRoom = shipGraph:GetSelectedRoom(x, y, false)
        if currentRoom > -1 and not adjacentRooms[currentRoom] then
            adjacentRooms[currentRoom] = Hyperspace.Pointf(x, y)
        end
    end
    for offset = 0, roomShape.w - 35, 35 do
        check_for_room(roomShape.x + offset + 17, roomShape.y - 17)
        check_for_room(roomShape.x + offset + 17, roomShape.y + roomShape.h + 17)
    end
    for offset = 0, roomShape.h - 35, 35 do
        check_for_room(roomShape.x - 17,               roomShape.y + offset + 17)
        check_for_room(roomShape.x + roomShape.w + 17, roomShape.y + offset + 17)
    end
    if diagonals then
        check_for_room(roomShape.x - 17,               roomShape.y - 17)
        check_for_room(roomShape.x + roomShape.w + 17, roomShape.y - 17)
        check_for_room(roomShape.x + roomShape.w + 17, roomShape.y + roomShape.h + 17)
        check_for_room(roomShape.x - 17,               roomShape.y + roomShape.h + 17)
    end
    return adjacentRooms
end

-- Check if a given crew member is being mind controlled by a ship system
local function under_mind_system(crewmem)
    local controlledCrew = nil
    local otherShipId = (crewmem.iShipId + 1)%2
    pcall(function() controlledCrew = Hyperspace.Global.GetInstance():GetShipManager(otherShipId).mindSystem.controlledCrew end)
    if controlledCrew then
        for crew in vter(controlledCrew) do
            if crewmem == crew then
                return true
            end
        end
    end
    return false
end

-- Check if a given crew member is resistant to mind control
local function resists_mind_control(crewmem)
    do
        local _, telepathic = crewmem.extend:CalculateStat(Hyperspace.CrewStat.IS_TELEPATHIC)
        if telepathic then return true end
    end
    do
        local _, resistMc = crewmem.extend:CalculateStat(Hyperspace.CrewStat.RESISTS_MIND_CONTROL)
        if resistMc then return true end
    end
    return false
end

-- Check if a given crew member can be mind controlled
local function can_be_mind_controlled(crewmem)
    return not (crewmem:IsDrone() or resists_mind_control(crewmem)) and not under_mind_system(crewmem)
end

-- Returns a table of all crew belonging to the given ship on the room tile at the given point
local function get_ship_crew_point(shipManager, x, y, maxCount)
    res = {}
    x = x//35
    y = y//35
    for crewmem in vter(shipManager.vCrewList) do
        if crewmem.iShipId == shipManager.iShipId and x == crewmem.x//35 and y == crewmem.y//35 then
            table.insert(res, crewmem)
            if maxCount and #res >= maxCount then
                return res
            end
        end
    end
    return res
end

local function reset_weapon_charge(weapon)
    weapon.cooldown.first = 0
    weapon.chargeLevel = 0
end

local function reduce_weapon_charge(ship, weapon)
    if weapon.cooldown.first > 0 then
        if weapon.cooldown.first >= weapon.cooldown.second then
            weapon.chargeLevel = weapon.chargeLevel - 1
        end
        local gameSpeed = Hyperspace.FPS.SpeedFactor
        local autoCooldown = 1 + ship:GetAugmentationValue("AUTO_COOLDOWN")
        weapon.cooldown.first = weapon.cooldown.first - 0.375*gameSpeed - autoCooldown*gameSpeed/16
        if weapon.cooldown.first <= 0 then
            weapon.cooldown.first = 0
            weapon.chargeLevel = 0
        end
    else
        weapon.chargeLevel = 0
    end
end

--[[
int iDamage;
int iShieldPiercing;
int fireChance;
int breachChance;
int stunChance;
int iIonDamage;
int iSystemDamage;
int iPersDamage;
bool bHullBuster;
int ownerId;
int selfId;
bool bLockdown;
bool crystalShard;
bool bFriendlyFire;
int iStun;]]--

-----------
-- LOGIC --
-----------

mods.trc.burstSpriteFixes = {}
local burstSpriteFixes = mods.trc.burstSpriteFixes
burstSpriteFixes["TRC_CASH_GUN"] = true

script.on_internal_event(Defines.InternalEvents.PROJECTILE_FIRE, function(projectile, weapon)
    local fixBurstSprite = nil
    if pcall(function() fixBurstSprite = burstSpriteFixes[weapon.blueprint.name] end) and fixBurstSprite then
        projectile:Initialize(Hyperspace.Global.GetInstance():GetBlueprints():GetWeaponBlueprint(projectile.extend.name))
    end
end)

mods.trc.burstMultiBarrel = {}
local burstMultiBarrel = mods.trc.burstMultiBarrel
burstMultiBarrel["TRC_CASH_GUN"] = {
    barrelOffset = 7,
    barrelCount = 3
}

script.on_internal_event(Defines.InternalEvents.PROJECTILE_FIRE, function(projectile, weapon)
    local burstBarrelData = nil
    if pcall(function() burstBarrelData = burstMultiBarrel[weapon.blueprint.name] end) and burstBarrelData then
        local offset = (burstBarrelData.barrelCount - weapon.queuedProjectiles:size()%burstBarrelData.barrelCount - 1)*burstBarrelData.barrelOffset
        if weapon.mount.mirror then offset = -offset end
        if weapon.mount.rotate then
            projectile.position.y = projectile.position.y + offset
        else
            projectile.position.x = projectile.position.x + offset
        end
    end
end)

mods.trc.missileDrones = {}
local missileDrones = mods.trc.missileDrones
missileDrones["TRC_COMBAT_MISSILE"] = 3

local deployedMissileDrones = {}
script.on_internal_event(Defines.InternalEvents.SHIP_LOOP, function(ship)
    for drone in vter(ship.spaceDrones) do
        local missileDeployCost = missileDrones[drone.blueprint.name]
        if missileDeployCost then
            if drone.deployed then
                if not deployedMissileDrones[drone.selfId] then
                    deployedMissileDrones[drone.selfId] = true
                    if ship:GetMissileCount() >= missileDeployCost then
                        ship:ModifyMissileCount(-missileDeployCost)
                    else
                        drone:SetDestroyed(true, false)
                        ship:ModifyDroneCount(1)
                    end
                end
            else
                deployedMissileDrones[drone.selfId] = nil
            end
        end
    end
end)

mods.trc.aoeWeapons = {}
local aoeWeapons = mods.trc.aoeWeapons
aoeWeapons["TRC_SYSTEMSHOCK"] = Hyperspace.Damage()
aoeWeapons["TRC_SYSTEMSHOCK"].iIonDamage = 1
aoeWeapons["TRC_MISSILES_SHRAPNEL"] = Hyperspace.Damage()
aoeWeapons["TRC_MISSILES_SHRAPNEL"].iSystemDamage = 1
aoeWeapons["TRC_MISSILES_SHRAPNEL_2"] = Hyperspace.Damage()
aoeWeapons["TRC_MISSILES_SHRAPNEL_2"].iSystemDamage = 2
aoeWeapons["TRC_BOMB_SHRAPNEL"] = Hyperspace.Damage()
aoeWeapons["TRC_BOMB_SHRAPNEL"].iSystemDamage = 1
aoeWeapons["TRC_VIRULENT"] = Hyperspace.Damage()
aoeWeapons["TRC_VIRULENT"].iPersDamage = 2

script.on_internal_event(Defines.InternalEvents.DAMAGE_AREA_HIT, function(shipManager, projectile, location, damage, shipFriendlyFire)
    local weaponName = nil
    pcall(function() weaponName = Hyperspace.Get_Projectile_Extend(projectile).name end)
    local aoeDamage = aoeWeapons[weaponName]
    if aoeDamage then
        Hyperspace.Get_Projectile_Extend(projectile).name = ""
        for roomId, roomPos in pairs(get_adjacent_rooms(shipManager.iShipId, get_room_at_location(shipManager, location, false), false)) do
            shipManager:DamageArea(roomPos, aoeDamage, true)
        end
        Hyperspace.Get_Projectile_Extend(projectile).name = weaponName
    end
end)

mods.trc.tileDamageWeapons = {}
local tileDamageWeapons = mods.trc.tileDamageWeapons
tileDamageWeapons["TRC_BEAM_TILE"] = {method = 2}

local farPoint = Hyperspace.Pointf(-2147483648, -2147483648)
script.on_internal_event(Defines.InternalEvents.DAMAGE_BEAM, function(shipManager, projectile, location, damage, realNewTile, beamHitType)
    if Hyperspace.ShipGraph.GetShipInfo(shipManager.iShipId):GetSelectedRoom(location.x, location.y, false) > -1 then
        local tileDamage = nil
        pcall(function() tileDamage = tileDamageWeapons[Hyperspace.Get_Projectile_Extend(projectile).name] end)
        if tileDamage and ((tileDamage.method == 0 and beamHitType ~= Defines.BeamHit.SAME_TILE) or ((tileDamage.method == 1 or tileDamage.method == 2) and beamHitType == Defines.BeamHit.NEW_TILE)) then
            local weaponName = Hyperspace.Get_Projectile_Extend(projectile).name
            Hyperspace.Get_Projectile_Extend(projectile).name = ""
            if tileDamage.method == 2 then
                shipManager:DamageBeam(location, farPoint, damage)
            else
                shipManager:DamageBeam(location, farPoint, tileDamage.damage)
            end
            Hyperspace.Get_Projectile_Extend(projectile).name = weaponName
        end
    end
    return Defines.Chain.CONTINUE, beamHitType
end)

mods.trc.statChargers = {}
local statChargers = mods.trc.statChargers
statChargers["TRC_MAGNIFIER_1"] = {{stat = "iDamage"},{stat = "breachChance"},{stat = "fireChance"}}
statChargers["TRC_MAGNIFIER_2"] = {{stat = "iDamage"},{stat = "breachChance"},{stat = "fireChance"}}
statChargers["TRC_MAGNIFIER_PIERCE"] = {{stat = "iShieldPiercing"},{stat = "breachChance"}}
statChargers["TRC_MAGNIFIER_ION"] = {{stat = "iIonDamage"},{stat = "iStun"}}
script.on_internal_event(Defines.InternalEvents.PROJECTILE_FIRE, function(projectile, weapon)
    local statBoosts = nil
    if pcall(function() statBoosts = statChargers[weapon.blueprint.name] end) and statBoosts then
        local boost = weapon.queuedProjectiles:size() -- Gets how many projectiles are charged up (doesn't include the one that was already shot)
        weapon.queuedProjectiles:clear() -- Delete all other projectiles
        for _, statBoost in ipairs(statBoosts) do -- Apply all stat boosts
            if statBoost.calc then
                projectile.damage[statBoost.stat] = statBoost.calc(boost, projectile.damage[statBoost.stat])
            else
                projectile.damage[statBoost.stat] = boost + projectile.damage[statBoost.stat]
            end
        end
    end
end)

mods.trc.cooldownChargers = {}
local cooldownChargers = mods.trc.cooldownChargers
cooldownChargers["TRC_MAGNIFIER_1"] = 1.3
cooldownChargers["TRC_MAGNIFIER_2"] = 1.5
cooldownChargers["TRC_MAGNIFIER_PIERCE"] = 1.5
cooldownChargers["TRC_MAGNIFIER_ION"] = 1.2

script.on_internal_event(Defines.InternalEvents.SHIP_LOOP, function(ship)
    local weapons = nil
    if pcall(function() weapons = ship.weaponSystem.weapons end) and weapons then
        for weapon in vter(weapons) do
            if weapon.chargeLevel ~= 0 and weapon.chargeLevel < weapon.weaponVisual.iChargeLevels then
                local cdBoost = nil
                if pcall(function() cdBoost = cooldownChargers[weapon.blueprint.name] end) and cdBoost then
                    local cdLast = userdata_table(weapon, "mods.trc.weaponStuff").cdLast
                    if cdLast and weapon.cooldown.first > cdLast then
                        -- Calculate the new charge level from number of charges and charge level from last frame
                        local chargeUpdate = weapon.cooldown.first - cdLast
                        local chargeNew = weapon.cooldown.first - chargeUpdate + cdBoost^weapon.chargeLevel*chargeUpdate
                        
                        -- Apply the new charge level
                        if chargeNew >= weapon.cooldown.second then
                            weapon.chargeLevel = weapon.chargeLevel + 1
                            if weapon.chargeLevel == weapon.weaponVisual.iChargeLevels then
                                weapon.cooldown.first = weapon.cooldown.second
                            else
                                weapon.cooldown.first = 0
                            end
                        else
                            weapon.cooldown.first = chargeNew
                        end
                    end
                    userdata_table(weapon, "mods.trc.weaponStuff").cdLast = weapon.cooldown.first
                end
            end
        end
    end
end)

mods.trc.popWeapons = {}
local popWeapons = mods.trc.popWeapons
popWeapons["DRONE_POP"] = {
    count = 1,
    countSuper = 1
}
popWeapons["DRONE_POP_2"] = {
    count = 1,
    countSuper = 1
}
script.on_internal_event(Defines.InternalEvents.SHIELD_COLLISION, function(shipManager, projectile, damage, response)
    local shieldPower = shipManager.shieldSystem.shields.power
    local popData = nil
    if pcall(function() popData = popWeapons[Hyperspace.Get_Projectile_Extend(projectile).name] end) and popData then
        if shieldPower.super.first > 0 then
            if popData.countSuper > 0 then
                shipManager.shieldSystem:CollisionReal(projectile.position.x, projectile.position.y, Hyperspace.Damage(), true)
                shieldPower.super.first = math.max(0, shieldPower.super.first - popData.countSuper)
            end
        else
            shipManager.shieldSystem:CollisionReal(projectile.position.x, projectile.position.y, Hyperspace.Damage(), true)
            shieldPower.first = math.max(0, shieldPower.first - popData.count)
        end
    end
end)

-- Valid resources are scrap, fuel, missiles, drones
mods.trc.resourceWeapons = {}
local resourceWeapons = mods.trc.resourceWeapons
resourceWeapons["TRC_CASH_GUN"] = {scrap = 3}
resourceWeapons["TRC_BOMB_DRONE"] = {drones = 1}
resourceWeapons["TRC_DRONE_GUN"] = {drones = 1}

-- Make resource weapons consume resources
script.on_internal_event(Defines.InternalEvents.PROJECTILE_FIRE, function(projectile, weapon)
    local resourceCost = resourceWeapons[weapon.blueprint.name]
    if weapon.iShipId == 0 and resourceCost and is_first_shot(weapon, true) then
        if resourceCost.scrap then
            Hyperspace.ships.player:ModifyScrapCount(-resourceCost.scrap, false)
        end
        if resourceCost.fuel then
            Hyperspace.ships.player.fuel_count = Hyperspace.ships.player.fuel_count - resourceCost.fuel
        end
        if resourceCost.missiles then
            Hyperspace.ships.player:ModifyMissileCount(-resourceCost.missiles)
        end
        if resourceCost.drones then
            Hyperspace.ships.player:ModifyDroneCount(-resourceCost.drones)
        end
    end
end)

-- Prevent resource weapons from charging if you don't have enough resources to fire
script.on_internal_event(Defines.InternalEvents.ON_TICK, function()
    local weapons = nil
    if pcall(function() weapons = Hyperspace.ships.player.weaponSystem.weapons end) and weapons then
        for weapon in vter(weapons) do
            local resourceCost = resourceWeapons[weapon.blueprint.name]
            if weapon.powered and resourceCost then
                if resourceCost.scrap and resourceCost.scrap > Hyperspace.ships.player.currentScrap then
                    reset_weapon_charge(weapon)
                    return
                end
                if resourceCost.fuel and resourceCost.fuel > Hyperspace.ships.player.fuel_count then
                    reset_weapon_charge(weapon)
                    return
                end
                if resourceCost.missiles and resourceCost.missiles > Hyperspace.ships.player:GetMissileCount() then
                    reset_weapon_charge(weapon)
                    return
                end
                if resourceCost.drones and resourceCost.drones > Hyperspace.ships.player:GetDroneCount() then
                    reset_weapon_charge(weapon)
                    return
                end
            end
        end
    end
end)

mods.trc.needSysPowerWeapons = {}
local needSysPowerWeapons = mods.trc.needSysPowerWeapons
needSysPowerWeapons["TRC_LASER_COMPACT"] = true

script.on_internal_event(Defines.InternalEvents.SHIP_LOOP, function(ship)
    if ship:HasSystem(3) and not ship.weaponSystem:Powered() then
        for weapon in vter(ship.weaponSystem.weapons) do
            if needSysPowerWeapons[weapon.blueprint.name] then
                reduce_weapon_charge(ship, weapon)
            end
        end
    end
end)

mods.trc.fireFillWeapons = {}
local fireFillWeapons = mods.trc.fireFillWeapons
fireFillWeapons["TRC_LAVA_THROWER"] = true

local function fill_room_fire(shipManager, projectile, location)
    local shipGraph = Hyperspace.ShipGraph.GetShipInfo(shipManager.iShipId)
    local room = shipGraph:GetSelectedRoom(location.x, location.y, false)
    if room > -1 then
        local weaponName = nil
        if pcall(function() weaponName = Hyperspace.Get_Projectile_Extend(projectile).name end) and weaponName and fireFillWeapons[weaponName] then
            local roomShape = shipGraph:GetRoomShape(room)
            for i = shipManager:GetFireCount(room) + 1, (roomShape.w*roomShape.h)/1225 do
                shipManager:StartFire(room)
            end
        end
    end
end
script.on_internal_event(Defines.InternalEvents.DAMAGE_BEAM, fill_room_fire)
script.on_internal_event(Defines.InternalEvents.DAMAGE_AREA_HIT, fill_room_fire)

mods.trc.crewTargetWeapons = {}
local crewTargetWeapons = mods.trc.crewTargetWeapons
crewTargetWeapons["TRC_BOMB_COLONIZER"] = "RANDOM"
crewTargetWeapons["TRC_EPISTLE"] = "MOST_CREW"

script.on_internal_event(Defines.InternalEvents.PROJECTILE_FIRE, function(projectile, weapon)
    local playerShip = Hyperspace.ships.player
    local crewTargetType = nil
    if weapon.iShipId == 1 and playerShip and pcall(function() crewTargetType = crewTargetWeapons[weapon.blueprint.name] end) and crewTargetType then
        local targetRoom = nil
        if crewTargetType == "MOST_CREW" then
            -- Find the room on the player ship with the most crew
            local mostCrew = 0
            for currentRoom = 0, Hyperspace.ShipGraph.GetShipInfo(playerShip.iShipId):RoomCount() - 1 do
                local numCrew = playerShip:CountCrewShipId(currentRoom, 0)
                if numCrew > mostCrew then
                    mostCrew = numCrew
                    targetRoom = currentRoom
                end
            end
        elseif crewTargetType == "RANDOM" then
            -- Find any room on the player ship with crew
            local validTargets = {}
            for currentRoom = 0, Hyperspace.ShipGraph.GetShipInfo(playerShip.iShipId):RoomCount() - 1 do
                if playerShip:CountCrewShipId(currentRoom, 0) > 0 then
                    table.insert(validTargets, currentRoom)
                end
            end
            if #validTargets > 0 then
                targetRoom = validTargets[math.random(#validTargets)]
            end
        end
        
        -- Retarget the bomb to the selected room
        if targetRoom then
            projectile.target = playerShip:GetRoomCenter(targetRoom)
            projectile:ComputeHeading()
        end
    end
end)

mods.trc.mcWeapons = {}
local mcWeapons = mods.trc.mcWeapons
mcWeapons["TRC_BOMB_COLONIZER"] = {
    duration = 15,
    limit = 1
}
mcWeapons["TRC_EPISTLE"] = {duration = 45}

-- Handle crew mind controlled by weapons
script.on_internal_event(Defines.InternalEvents.CREW_LOOP, function(crewmem)
    local mcTable = userdata_table(crewmem, "mods.trc.crewStuff")
    if mcTable.mcTime then
        if crewmem.bDead then
            mcTable.mcTime = nil
        else
            mcTable.mcTime = math.max(mcTable.mcTime - Hyperspace.FPS.SpeedFactor/16, 0)
            if mcTable.mcTime == 0 then
                crewmem:SetMindControl(false)
                Hyperspace.Global.GetInstance():GetSoundControl():PlaySoundMix("mindControlEnd", -1, false)
                mcTable.mcTime = nil
            end
        end
    end
end)

-- Handle mind control beams
script.on_internal_event(Defines.InternalEvents.DAMAGE_BEAM, function(shipManager, projectile, location, damage, realNewTile, beamHitType)
    local mindControl = mcWeapons[Hyperspace.Get_Projectile_Extend(projectile).name]
    if mindControl and mindControl.duration then -- Doesn't check realNewTile anymore 'cause the beam kept missing crew that were on the move
        for i, crewmem in ipairs(get_ship_crew_point(shipManager, location.x, location.y)) do
            if can_be_mind_controlled(crewmem) then
                crewmem:SetMindControl(true)
                local mcTable = userdata_table(crewmem, "mods.trc.crewStuff")
                mcTable.mcTime = math.max(mindControl.duration, mcTable.mcTime or 0)
            elseif resists_mind_control(crewmem) and realNewTile then
                crewmem.bResisted = true
            end
        end
    end
    return Defines.Chain.CONTINUE, beamHitType
end)

-- Handle other mind control weapons
script.on_internal_event(Defines.InternalEvents.DAMAGE_AREA_HIT, function(shipManager, projectile, location, damage, shipFriendlyFire)
    local mindControl = nil
    pcall(function() mindControl = mcWeapons[Hyperspace.Get_Projectile_Extend(projectile).name] end)
    if mindControl and mindControl.duration then
        local roomId = get_room_at_location(shipManager, location, true)
        local mindControlledCrew = 0
        for crewmem in vter(shipManager.vCrewList) do
            local doControl = crewmem.iRoomId == roomId and
                              crewmem.currentShipId == shipManager.iShipId and
                              crewmem.iShipId ~= projectile.ownerId
            if doControl then
                if can_be_mind_controlled(crewmem) then
                    crewmem:SetMindControl(true)
                    local mcTable = userdata_table(crewmem, "mods.trc.crewStuff")
                    mcTable.mcTime = math.max(mindControl.duration, mcTable.mcTime or 0)
                    mindControlledCrew = mindControlledCrew + 1
                    if mindControl.limit and mindControlledCrew >= mindControl.limit then break end
                elseif resists_mind_control(crewmem) then
                    crewmem.bResisted = true
                end
            end
        end
    end
end)

mods.trc.droneWeapons = {}
local droneWeapons = mods.trc.droneWeapons
droneWeapons["TRC_DRONE_GUN"] = {
    drone = "TRC_COMBAT_ASSEMBLED",
    shots = 7
}

local function spawn_temp_drone(name, ownerShip, targetShip, targetLocation, shots, position)
    local drone = ownerShip:CreateSpaceDrone(Hyperspace.Global.GetInstance():GetBlueprints():GetDroneBlueprint(name))
    drone.powerRequired = 0
    drone:SetMovementTarget(targetShip._targetable)
    drone:SetWeaponTarget(targetShip._targetable)
    drone.lifespan = shots or 2
    drone.powered = true
    drone:SetDeployed(true)
    drone.bDead = false
    if position then drone:SetCurrentLocation(position) end
    if targetLocation then drone.targetLocation = targetLocation end
    return drone
end
script.on_internal_event(Defines.InternalEvents.PROJECTILE_PRE, function(projectile)
    local droneWeaponData = droneWeapons[projectile.extend.name]
    if droneWeaponData and projectile.ownerId ~= projectile.currentSpace then
        local ship = Hyperspace.Global.GetInstance():GetShipManager(projectile.ownerId)
        local otherShip = Hyperspace.Global.GetInstance():GetShipManager((projectile.ownerId + 1)%2)
        if ship and otherShip then
            local drone = spawn_temp_drone(
                droneWeaponData.drone,
                ship,
                otherShip,
                projectile.target,
                droneWeaponData.shots,
                projectile.position)
            userdata_table(drone, "mods.trc.droneStuff").clearOnJump = true
        end
        projectile:Kill()
    end
end)
script.on_internal_event(Defines.InternalEvents.SHIP_LOOP, function(ship)
    if ship.bJumping then
        for drone in vter(ship.spaceDrones) do
            if userdata_table(drone, "mods.trc.droneStuff").clearOnJump then
                drone:SetDestroyed(true, false)
            end
        end
    end
end)
