-- name: \\#00FF7F\\Simple SavePoints v1.57\\#00FF7F\\
-- description: Four persistent, multiplayer-safe savepoints per player.\n\nAny D-pad direction: save to that direction's slot.\nL Trigger + the same D-pad direction: load that slot.\n\nEach slot stays on this computer and sends no SavePoint data to the host or\nother players.\n\nMade by \\#674ea7\\Toxikskull\\#674ea7\\ \\#ffffff\\&\\#ffffff\\ \\#f8c62d\\GazzyGaz\\#f8c62d\\.
 
---------------------------------------------------------------------------------------------------
-- Controls and load state
---------------------------------------------------------------------------------------------------

-- Save up to four places with the D-pad, then hold L and press the same direction to return. Each
-- slot remembers more than a position: it also keeps your view, inventory and supported movement
-- or held object. Saves stay on this computer; loading must not reset another player's game.

-- Load preferences last for this session. maxHP also accommodates mods with extra health.
local keepCoins, fullHP = true, false
-- Subpages use the same side panel as the player picker, leaving native pause controls intact.
local menuPages = {page = nil, index = 0, mouseDown = true}
-- Only the host changes this session-wide restriction. Checkpoints remain entirely local.
if network_is_server() then gGlobalSyncTable.spSaveLoadOnly = false end
local function travelRestricted()
    if not gGlobalSyncTable.spSaveLoadOnly then return false end
    djui_popup_create("Feature currently unavailable, save/load only mode is enabled", 3)
    return true
end

-- Time limits and short setup delays are in game frames.
local DEFAULT_HP, LOAD_TIMEOUT, BOWSER_READY_TIMEOUT = 2176, 180, 300
local LOAD_SETTLE_FRAMES, CAMERA_RESTORE_FRAMES = 3, 4
local IW_OFFSET, IW_RECENT = 160, 2

-- A load is idle, waiting for level setup, or waiting for Bowser to appear.
local LOAD_NONE, LOAD_LEVEL, LOAD_BOWSER = 0, 1, 2

-- beforeMario() completes the load; updatePendingLoad() times it out if setup stalls.
-- Some internal areas have no entrance, so loadEntryArea records the entrance used to reach them.
local loadMode, timer, loadSettle = LOAD_NONE, 0, 0
local lastLevel, lastArea, loadEntryArea, maxHP = nil, nil, nil, DEFAULT_HP
local loadUsedLevelWarp = false

-- Rapid loads keep only the latest request until the current level change finishes.
local queuedLoadSlot

-- Leaving water needs the normal water-exit action to clear its low camera angle.
local loadSourceWasWater = false

-- Recent instant-warp direction chooses a safe side of the boundary. The guard holds
-- Mario at the corrected point briefly while the destination's collision is set up.
local recentIWAge, recentDX, recentDY, recentDZ = 99, 0, 0, 0
local guardFrames, guardX, guardY, guardZ = 0, 0, 0, 0

-- This player's clock, not the shared Koopa race. PSS finish logic and the HUD both
-- need it, but only updateRaceTimer() advances it.
local raceTimerOverride, raceTimerRunning, raceTimerValue, raceTimerHold = false, false, 0, 0
local raceTimerLevel, raceTimerArea = -1, -1

-- Keep the saved view for a few camera updates while water/warp setup finishes.
local cameraRestoreFrames = 0

-- Level selection waits for the pause menu to close, then requests the course's act screen once.
local queuedLevel, chosenActSelectLevel = nil, nil

-- Current pickup history and the loaded slot's hidden pickups are separate sets.
-- hiddenObjects keeps the original render flags so we can show those objects again.
local ownedGone, ownedGoneLocation, hiddenObjects = {}, nil, {}
local collectedByArea, worldScanTicker = {}, 0

-- Our current replacement item and the original it stands in for. Cleanup must not
-- delete a different object just because the engine reused an old pointer.
local restoredObject
local restoredObjectSourceKey, restoredObjectSourceBehavior, restoredObjectLocation = nil, nil, nil

-- Custom fields survive SET_HOME but reset when the object slot is reused. Keep these
-- names/types stable: they identify copies saved again or loaded after a restart.
define_custom_obj_fields({oSimpleSavePointsSerial = 'u32', oSimpleSavePointsSource = 'u32'})
local restoredObjectSerial, nextRestoredObjectSerial = 0, 0
-- A shell's network slot can appear a few frames after spawning.
local restoredObjectSyncFrames = 0
-- Wait for the old shell's deletion before creating its replacement.
local shellRestoreFrames, shellRestoreAttempts = 0, 0
local penguinRestoreFrames = 0
local function penguinBehavior(behavior)
    return behavior == id_bhvSmallPenguin or behavior == id_bhvPenguinBaby
end
-- Restored shells can disappear on other players' screens. Packet 91 lets those players
-- draw a non-interactive fallback under the rider if the real shell is missing.
local shellVisual = {
    packet = 91, serial = 0, lost = 0, active = false, level = -1, area = -1,
    playerCount = 1, resend = 0, pending = 0, states = {}, visuals = {}
}

-- Bowser may finish spawning after Mario arrives. These retries have separate limits
-- for a tail hold and a free-moving boss.
local interactionRetryFrames, bowserWorldRetryFrames = 0, 0

-- Saved object modes and the engine states used when restoring them.
local OBJ_NONE, OBJ_HELD, OBJ_SHELL, OBJ_BOWSER = 0, 1, 2, 3
local FREE, HELD, DEACTIVATED = HELD_FREE or 0, HELD_HELD or 1, ACTIVE_FLAG_DEACTIVATED or 0

-- Restoring a spin must pass through the game's pickup and holding stages first.
local bowserRestoreObject, bowserRestoreFrames, bowserRestoreLocation = nil, 0, nil
local bowserRestorePhase, bowserRestoreSettle = 0, 0
local BOWSER_RESTORE_GRAB, BOWSER_RESTORE_HELD, BOWSER_RESTORE_SETTLE = 1, 2, 3

-- While held, Bowser is drawn through Mario rather than as a second level model.
local heldBowserRoot, heldBowserLocation = nil, nil
local BOWSER_RENDER_ACTIVE = GRAPH_RENDER_ACTIVE or 1

-- Bowser's attack setup can overwrite the saved animation frame on its first update.
local bowserWorldAnimObject, bowserWorldAnimLocation, bowserWorldAnimFrame = nil, nil, 0

-- A shifted platform moves the saved camera by the same amount as Mario.
-- The arena checks and platform helpers are defined in the Bowser section.
local bossArena = {cameraX = 0, cameraY = 0, cameraZ = 0}

-- UI and player travel are defined in their own function scopes near the end of the
-- file to stay within Lua's local-variable limit. Neither exports a public Lua API.
local savesHud = {enabled = false, rows = {}}
-- Visits use spVisit request/reply messages 3/4, not checkpoint files.
local playerTravel = {popup = false, busy = false, tick = 0, serial = 0, stable = 0, limits = {}}

-- First byte of each checkpoint file.
local CHECKPOINT_FORMAT = 4

-- Slot order also decides which button wins if several are pressed together.
-- Down's existing filename differs from the others; keep it to preserve saved slots.
local SAVE_SLOTS = {
    {button = U_JPAD, name = "Up", file = "checkpoint-up.sav"},
    {button = L_JPAD, name = "Left", file = "checkpoint-left.sav"},
    {button = D_JPAD, name = "Down", file = "checkpoint.sav"},
    {button = R_JPAD, name = "Right", file = "checkpoint-right.sav"},
}
-- Start with Down selected. Skip input work on frames with no D-pad press.
local DEFAULT_SLOT = 3
local SAVE_BUTTON_MASK = U_JPAD | L_JPAD | D_JPAD | R_JPAD

---------------------------------------------------------------------------------------------------
-- Save files
---------------------------------------------------------------------------------------------------

-- Each direction has its own file. Saving replaces that slot; loading uses the copy already in
-- memory, so it does not wait for disk access or ask the host for data. Files are read once when
-- the mod starts. The field order below is part of the file format and must not change without a
-- format update.

-- addFields() fills this ordered array during script initialization. blankCheckpoint(), packCheckpoint(), and
-- unpackCheckpoint() are its only consumers; reordering entries would change the binary file layout.
local CHECKPOINT_FIELDS = {}

-- Field guide (all numeric unless noted):
--   spLevel/spArea/spAct, spX/Y/Z, spAngle*, inventory, caps, swim/air and spIW/spD* describe Mario and location.
--   spObj* describes a held/ridden object's root; spBobomb* preserves its behavior-specific remaining fuse.
--   spBowserHeld* plus spInt* preserve Mario's tail-hold pose/momentum; spBowserWorld* describes a free boss root.
--   spTimer owns a private timer; spTimerOn is 0=absent, 1=running, or 2=finished/frozen. spSharedRace marks that
--   the live lobby race must remain authoritative.
--   spSwim/spAir describe the saved environment. spAir is 0=ground, 1=ordinary air, 2=flying, or 3=bubbled;
--   flight/bubble motion reuses the spInt* motion block because neither state can also hold or ride an object.
--   spCam* stores the rendered view and smoothing state; spGone (stored separately as text) lists local pickups.
--   spBoss* records irreversible fight progress, the Bowser 2 floor, and Mario's position relative to a supported
--   arena platform. Shared fights use that relative point without rewinding the arena for everybody else.
-- Every populated slot contains every schema field, so gameplay code can read values directly without nil/default
-- branches. blankCheckpoint() supplies the defaults and unpackCheckpoint() must decode the complete schema.

-- Adds saved fields in file order. Keep existing fields in place so older saves still decode
-- correctly.
local function addFields(default, spec)
    for name in spec:gmatch("%w+") do CHECKPOINT_FIELDS[#CHECKPOINT_FIELDS + 1] = {name, default} end
end

addFields(0, [[
spLevel spAct spX spY spZ spAngleX spAngleY spAngleZ
spRedCoins spCoins spSecrets spKeys spCapFlags spCapTimer
spShell spShellWater spShellAction
spObjMode spObjBhv spObjModel spObjKey spObjBehParams spObjBehParams2
spObjX spObjY spObjZ spObjHomeX spObjHomeY spObjHomeZ
spObjVelX spObjVelY spObjVelZ spObjForwardVel
spObjMovePitch spObjMoveYaw spObjMoveRoll spObjFacePitch spObjFaceYaw spObjFaceRoll
spObjAngleVelPitch spObjAngleVelYaw spObjAngleVelRoll
spObjAction spObjPrevAction spObjSubAction spObjTimer spObjBhvTimer
spObjAnimState spObjAnimFrame spObjFlags spObjInteractType
spObjInteractSubtype spObjInteractStatus spObjIntangibleTimer spObjHealth
spObjMoveFlags spObjGravity spObjFriction spObjBuoyancy
spObjBounciness spObjGraphYOffset spObjRoom spObjAreaTimer
spObjAreaTimerDuration spObjAreaTimerType
spBobombBlinkTimer spBobombFuseLit spBobombFuseTimer
spBowserF4 spBowserHeldPitch spBowserHeldVelYaw spBowserHeldStage
spBowserWorld spBowserWorldKey spBowserWorldX spBowserWorldY spBowserWorldZ
spBowserWorldHomeX spBowserWorldHomeY spBowserWorldHomeZ
spBowserWorldVelX spBowserWorldVelY spBowserWorldVelZ spBowserWorldForwardVel
spBowserWorldMovePitch spBowserWorldMoveYaw spBowserWorldMoveRoll
spBowserWorldFacePitch spBowserWorldFaceYaw spBowserWorldFaceRoll
spBowserWorldAngleVelPitch spBowserWorldAngleVelYaw spBowserWorldAngleVelRoll
spBowserWorldAction spBowserWorldPrevAction spBowserWorldSubAction
spBowserWorldTimer spBowserWorldDelayTimer spBowserWorldAnimState
spBowserWorldAnimFrame spBowserWorldHealth spBowserWorldMoveFlags
spBowserWorldIntangible spBowserWorldUnk88 spBowserWorldF4
spBowserWorldF8 spBowserWorldDist spBowserWorldUnk106
spBowserWorldUnk108 spBowserWorldUnk110 spBowserWorldAngleToCentre
spBowserWorldUnk1AC spBowserWorldUnk1AE spBowserWorldEyesShut spBowserWorldUnk1B2
spIntAction spIntPrevAction spIntActionState spIntActionTimer spIntActionArg
spIntVelX spIntVelY spIntVelZ spIntForwardVel spIntSlideX spIntSlideZ
spIntAngleVelX spIntAngleVelY spIntAngleVelZ spIntTwirlYaw spIntGrabPos
spIntAnimFrame spIntMarioObjPitch spTimer spTimerOn spSharedRace
spSwim spAir spIW spDX spDY spDZ
]])
addFields(1, "spArea spObjScaleX spObjScaleY spObjScaleZ")
addFields(4, "spLives")
addFields(255, "spObjOpacity spBowserWorldOpacity")
addFields(-1, "spBowserAnim spBowserWorldAnim")
addFields(DEFAULT_HP, "spHP")
addFields(0, [[
spCamValid spCamPosX spCamPosY spCamPosZ
spCamFocusX spCamFocusY spCamFocusZ spCamYaw spCamNextYaw
spCamOldPitch spCamOldYaw spCamFocusDistance
spCamFocHSpeed spCamFocVSpeed spCamPosHSpeed spCamPosVSpeed
]])

-- Supported format-2 files end here. Keep their prefix length independent of runtime boss/UI state;
-- unpackCheckpoint() fills later fields from defaults and the next save writes the current format.
local checkpointFieldCounts = {[2] = #CHECKPOINT_FIELDS}
addFields(-1, "spBossMines")
addFields(0, [[
spBossSupport spBossSupportKey spBossSupportParam
spBossLocalX spBossLocalY spBossLocalZ spBossSupportClearance
spBossTilt spBossTiltFacePitch spBossTiltFaceYaw spBossTiltFaceRoll
spBossTiltVelPitch spBossTiltVelYaw spBossTiltVelRoll
]])
-- Record the date in the checkpoint itself, once per save. Older files keep zero date fields rather than
-- inventing a creation time; the HUD labels those dates unavailable until the player saves again.
checkpointFieldCounts[3] = #CHECKPOINT_FIELDS
addFields(0, "spSavedYear spSavedMonth spSavedDay spSavedHour spSavedMinute")

-- Creates a fresh slot with all defaults filled in, including fields absent from older supported
-- saves.
local function blankCheckpoint()
    local s = {spGone = ""}
    for _, f in ipairs(CHECKPOINT_FIELDS) do s[f[1]] = f[2] end
    return s
end

-- localCheckpoints is indexed exactly like SAVE_SLOTS and stores decoded/fresh tables only for populated slots.
-- activeSlot names popup/camera work; localCheckpoint is the table consumed by apply() and delayed callbacks.
-- A nil entry means that direction has never been saved; save() always creates a fresh table.
-- Player effect: each D-pad direction remains independent, and an unused direction reports that it is empty.
local localCheckpoints, activeSlot, localCheckpoint = {}, DEFAULT_SLOT, nil

-- Packs one slot for writing to disk. Pickups follow the fixed numeric fields as a list of IDs.
local function packCheckpoint(s)
    local out, gone = {string.pack("<B", CHECKPOINT_FORMAT)}, {}
    for _, f in ipairs(CHECKPOINT_FIELDS) do out[#out + 1] = string.pack("<d", tonumber(s[f[1]]) or f[2]) end
    for key in s.spGone:gmatch("[^,]+") do
        local value = tonumber(key)
        if value ~= nil and value >= 0 and value <= 0x7fffffff then gone[#gone + 1] = value end
    end
    out[#out + 1] = string.pack("<I2", #gone)
    for _, value in ipairs(gone) do out[#out + 1] = string.pack("<I4", value) end
    return table.concat(out)
end

-- Reads a saved slot. A damaged or unsupported file leaves this slot empty without breaking the
-- other three.
local function unpackCheckpoint(blob)
    local ok, result = pcall(function()
        local offset, version, s = 1, nil, blankCheckpoint()
        version, offset = string.unpack("<B", blob, offset)
        if version ~= CHECKPOINT_FORMAT and version ~= 3 and version ~= 2 then error("unsupported checkpoint format") end
        local fieldCount = checkpointFieldCounts[version] or #CHECKPOINT_FIELDS
        for i = 1, fieldCount do
            local f = CHECKPOINT_FIELDS[i]
            s[f[1]], offset = string.unpack("<d", blob, offset)
        end
        local count
        count, offset = string.unpack("<I2", blob, offset)
        local gone = {}
        for i = 1, count do
            local value
            value, offset = string.unpack("<I4", blob, offset)
            gone[i] = tostring(value)
        end
        if offset ~= #blob + 1 then error("trailing checkpoint data") end
        s.spGone = table.concat(gone, ",")
        return s
    end)
    return ok and result or nil
end

-- Replaces one slot's file. The second rewind is required after erasing the old contents. A write
-- failure leaves the new save usable in memory.
local function writeCheckpoint(slot, blob)
    if mod_fs_get == nil or mod_fs_create == nil then return false end
    local ok, saved = pcall(function()
        local fs = mod_fs_get() or mod_fs_create()
        if fs == nil then return false end
        local fileName = SAVE_SLOTS[slot].file
        local file = fs:get_file(fileName) or fs:create_file(fileName, false)
        if file == nil or not file:rewind() then return false end
        if file.size > 0 and not file:erase(file.size) then return false end
        if not file:rewind() or not file:write_bytes(blob) then return false end
        return fs:save()
    end)
    return ok and saved == true
end

-- Reads all four slots once at startup. Loading during play uses these tables, not the filesystem.
local function loadPersistentSlots()
    if mod_fs_get == nil then return end
    local ok, fs = pcall(mod_fs_get)
    if not ok or fs == nil then return end
    for i, slot in ipairs(SAVE_SLOTS) do
        local valid, s = pcall(function()
            local file = fs:get_file(slot.file)
            if file == nil or file.size <= 0 or not file:rewind() then return nil end
            return unpackCheckpoint(file:read_bytes(file.size))
        end)
        if valid and s ~= nil then localCheckpoints[i] = s end
    end
end

-- Startup call: runs before hook registration, then points delayed work at Down if that slot exists.
loadPersistentSlots()
localCheckpoint = localCheckpoints[activeSlot]
 
---------------------------------------------------------------------------------------------------
-- Locations and object identity
---------------------------------------------------------------------------------------------------

-- These helpers distinguish areas within a level and recognize saved objects after a restart. An
-- engine object pointer is not a lasting identity: another object can reuse it after the original
-- disappears.

-- Produces the saved object ID. Keep this hash unchanged or existing saves will no longer
-- recognize objects.
local function stableHash(s)
    local h = 5381
    s = tostring(s or "object")
    for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end
    return tostring(h)
end

-- Checks whether Mario is touching an instant-warp surface, such as the Wet-Dry World tunnel
-- boundary.
local function iwSurface(s)
    if s == nil then return false end
    local t = s.type
    return t == SURFACE_INSTANT_WARP_1B or t == SURFACE_INSTANT_WARP_1C
        or t == SURFACE_INSTANT_WARP_1D or t == SURFACE_INSTANT_WARP_1E
end
 
-- Only the direction of a warp matters when choosing which side of its boundary to load on.
local function sign(v)
    if v > 0 then return 1 elseif v < 0 then return -1 end
    return 0
end
 

-- Rounds source coordinates for object IDs. The negative rounding is unusual but must stay
-- consistent with existing saves.
local function roundi(v)
    v = v or 0
    return math.floor(v + (v >= 0 and 0.5 or -0.5))
end

-- Uses the same area key for live integers and numbers read back from a save file.
local function locationKey(level, area)
    return tostring(math.floor(level or -1)) .. "/" .. tostring(math.floor(area or -1))
end

-- Prefers network area metadata because Mario's area pointer can lag behind an instant area
-- change.
local function playerArea(m, n)
    local area = n and n.currAreaIndex
    return area ~= nil and area > 0 and area or (m and m.area and m.area.index or -1)
end

-- Checks both action and water depth. A leftover swimming action must not turn a save made on land
-- into a water save.
local function genuinelySwimming(m)
    if m == nil then return false end
    local action = m.action or 0
    local waterAction = (action & ACT_FLAG_SWIMMING) ~= 0 or (action & ACT_FLAG_METAL_WATER) ~= 0
    return waterAction and ((m.waterLevel or -11000) - m.pos.y) > 80
end

-- Returns this player's level/area key for pickup and restored-object tracking.
local function currentLocationKey()
    local m, n = gMarioStates[0], gNetworkPlayers[0]
    if n == nil then return nil end
    return locationKey(n.currLevelNum, playerArea(m, n))
end

-- Checks level and area, not act. Checkpoint loads and player visits intentionally have different
-- act rules.
local function atCheckpoint(s, m, n)
    return s ~= nil and m ~= nil and n ~= nil
        and n.currLevelNum == s.spLevel and playerArea(m, n) == s.spArea
end

-- Waits until Mario and the camera exist at the destination. Full level entries can restore before
-- their entrance animation finishes.
local function destinationReady(s, m, n)
    if not atCheckpoint(s, m, n) or m.marioObj == nil or gLakituState == nil then return false end
    if m.health <= 0 then return false end
    if loadUsedLevelWarp then return true end
    return (m.action & ACT_GROUP_MASK) ~= ACT_GROUP_CUTSCENE
        and (m.action & ACT_FLAG_INTANGIBLE) == 0 and m.action ~= ACT_BUBBLED
        and (m.flags & MARIO_TELEPORTING) == 0
end

-- Uses a numeric behavior ID instead of storing the engine's behavior pointer.
local function objectBehaviorId(o)
    return o ~= nil and (get_id_from_behavior(o.behavior) or 0) or 0
end

-- Checks that a shared object's network slot is ready. A nonzero sync ID alone is not enough
-- during level setup.
local function objectSyncInitialized(o)
    if o == nil then return false end
    local syncId = o.oSyncID or 0
    if syncId == 0 then return false end
    local ok, initialized = pcall(sync_object_is_initialized, syncId)
    return ok and initialized == true
end

-- Recognizes an object by its original spawn details. Restored copies keep the source ID so saving
-- one again does not create a new identity.
local function objectKey(o)
    if o == nil then return nil end
    -- A saved copy must continue to name its native source, including when saved into another persistent slot.
    if o.oSimpleSavePointsSerial ~= 0 and o.oSimpleSavePointsSource ~= 0 then
        return tostring(o.oSimpleSavePointsSource)
    end
    local bhv = objectBehaviorId(o)
    local model = obj_get_model_id_extended(o) or 0
    local x = o.oHomeX ~= nil and o.oHomeX or o.oPosX
    local y = o.oHomeY ~= nil and o.oHomeY or o.oPosY
    local z = o.oHomeZ ~= nil and o.oHomeZ or o.oPosZ
    local raw = table.concat({
        tostring(bhv), tostring(model), tostring(o.oBehParams or 0),
        tostring(roundi(x)), tostring(roundi(y)), tostring(roundi(z))
    }, ":")
    return stableHash(raw)
end

-- Animation data can be absent while the game is still setting up an object.
local function animInfo(o)
    return o and o.header and o.header.gfx and o.header.gfx.animInfo or nil
end

-- Builds the saved-field/native-field pairs used below. Optional defaults follow the second colon.
local function fieldMap(default, spec)
    local fields = {}
    for token in spec:gmatch("%S+") do
        local saved, live, override = token:match("(%w+):(%w+):?(-?%d*)")
        fields[#fields + 1] = {saved, live, override ~= "" and tonumber(override) or default}
    end
    return fields
end

---------------------------------------------------------------------------------------------------
-- Recording objects and movement
---------------------------------------------------------------------------------------------------

-- Saving a carried item or shell ride also records its state and Mario's movement. This lets a
-- Bob-omb keep its remaining fuse and a Bowser tail hold keep its spin. Free Bowser attacks use a
-- separate record because Mario may be holding something else.

-- OBJECT_FIELDS maps slot names to CoopDX Object members. captureInteraction() reads it and
-- restoreObjectFields() writes it; explicit code handles animation/scale, Bob-omb fuse, and held Bowser details.
local OBJECT_FIELDS = fieldMap(0, [[
spObjBehParams:oBehParams spObjBehParams2:oBehParams2ndByte spObjX:oPosX spObjY:oPosY spObjZ:oPosZ
spObjHomeX:oHomeX spObjHomeY:oHomeY spObjHomeZ:oHomeZ spObjVelX:oVelX spObjVelY:oVelY spObjVelZ:oVelZ
spObjForwardVel:oForwardVel spObjMovePitch:oMoveAnglePitch spObjMoveYaw:oMoveAngleYaw spObjMoveRoll:oMoveAngleRoll
spObjFacePitch:oFaceAnglePitch spObjFaceYaw:oFaceAngleYaw spObjFaceRoll:oFaceAngleRoll
spObjAngleVelPitch:oAngleVelPitch spObjAngleVelYaw:oAngleVelYaw spObjAngleVelRoll:oAngleVelRoll
spObjAction:oAction spObjPrevAction:oPrevAction spObjSubAction:oSubAction spObjTimer:oTimer spObjAnimState:oAnimState
spObjFlags:oFlags spObjInteractType:oInteractType spObjInteractSubtype:oInteractionSubtype spObjInteractStatus:oInteractStatus
spObjIntangibleTimer:oIntangibleTimer spObjHealth:oHealth spObjOpacity:oOpacity spObjMoveFlags:oMoveFlags
spObjGravity:oGravity spObjFriction:oFriction spObjBuoyancy:oBuoyancy spObjBounciness:oBounciness
spObjGraphYOffset:oGraphYOffset spObjRoom:oRoom spObjAreaTimer:areaTimer
spObjAreaTimerDuration:areaTimerDuration spObjAreaTimerType:areaTimerType
]])

-- BOWSER_WORLD_FIELDS maps the native free-boss root. captureBowserWorldSnapshot() reads it and
-- restoreBowserWorldSnapshot() writes it; children such as the jaw/tail are intentionally never copied.
local BOWSER_WORLD_FIELDS = fieldMap(0, [[
spBowserWorldX:oPosX spBowserWorldY:oPosY spBowserWorldZ:oPosZ
spBowserWorldHomeX:oHomeX spBowserWorldHomeY:oHomeY spBowserWorldHomeZ:oHomeZ
spBowserWorldVelX:oVelX spBowserWorldVelY:oVelY spBowserWorldVelZ:oVelZ spBowserWorldForwardVel:oForwardVel
spBowserWorldMovePitch:oMoveAnglePitch spBowserWorldMoveYaw:oMoveAngleYaw spBowserWorldMoveRoll:oMoveAngleRoll
spBowserWorldFacePitch:oFaceAnglePitch spBowserWorldFaceYaw:oFaceAngleYaw spBowserWorldFaceRoll:oFaceAngleRoll
spBowserWorldAngleVelPitch:oAngleVelPitch spBowserWorldAngleVelYaw:oAngleVelYaw spBowserWorldAngleVelRoll:oAngleVelRoll
spBowserWorldAction:oAction spBowserWorldPrevAction:oPrevAction spBowserWorldSubAction:oSubAction spBowserWorldTimer:oTimer
spBowserWorldAnimState:oAnimState spBowserWorldAnim:oSoundStateID:-1 spBowserWorldHealth:oHealth
spBowserWorldOpacity:oOpacity:255 spBowserWorldMoveFlags:oMoveFlags spBowserWorldIntangible:oIntangibleTimer
spBowserWorldUnk88:oBowserUnk88 spBowserWorldF4:oBowserUnkF4 spBowserWorldF8:oBowserUnkF8
spBowserWorldDist:oBowserDistToCentre spBowserWorldUnk106:oBowserUnk106 spBowserWorldUnk108:oBowserUnk108
spBowserWorldUnk110:oBowserUnk110 spBowserWorldAngleToCentre:oBowserAngleToCentre
spBowserWorldUnk1AC:oBowserUnk1AC spBowserWorldUnk1AE:oBowserUnk1AE
spBowserWorldEyesShut:oBowserEyesShut spBowserWorldUnk1B2:oBowserUnk1B2
]])

-- Checks the boss behavior, not just the model. Bowser's body and tail objects are not the boss
-- itself.
local function isBowserObject(o)
    return o ~= nil and objectBehaviorId(o) == id_bhvBowser
end

-- A save may contain a tail hold or a free Bowser attack; both need the arena's safety checks.
local function checkpointHasBowserState(s)
    return s.spObjMode == OBJ_BOWSER or s.spBowserWorld ~= 0
end

-- Records a living, freely moving Bowser. Dying, disappearing or unfinished network objects are
-- not safe to restore.
local function captureBowserWorldSnapshot(s, o)
    if not isBowserObject(o) or not objectSyncInitialized(o)
        or o.oHeldState ~= FREE or (o.oHealth or 0) <= 0
        or o.oAction == 5 or o.oAction == 6 or o.oAction == 20 then
        return false
    end

    s.spBowserWorld, s.spBowserWorldKey = 1, tonumber(objectKey(o)) or 0
    for _, f in ipairs(BOWSER_WORLD_FIELDS) do s[f[1]] = o[f[2]] ~= nil and o[f[2]] or f[3] end
    s.spBowserWorldDelayTimer = o.bhvDelayTimer or 0
    local anim = animInfo(o)
    s.spBowserWorldAnimFrame = anim and anim.animFrame or 0
    return true
end

-- Records action, momentum and animation for tail holds, rides, flight, bubbles and player visits.
-- Ordinary ground saves deliberately load at rest.
local function captureMarioMotion(s, m)
    s.spIntAction, s.spIntPrevAction = m.action or 0, m.prevAction or 0
    s.spIntActionState, s.spIntActionTimer, s.spIntActionArg = m.actionState or 0, m.actionTimer or 0, m.actionArg or 0
    s.spIntVelX, s.spIntVelY, s.spIntVelZ = m.vel.x or 0, m.vel.y or 0, m.vel.z or 0
    s.spIntForwardVel, s.spIntSlideX, s.spIntSlideZ = m.forwardVel or 0, m.slideVelX or 0, m.slideVelZ or 0
    s.spIntAngleVelX, s.spIntAngleVelY, s.spIntAngleVelZ = m.angleVel.x or 0, m.angleVel.y or 0, m.angleVel.z or 0
    s.spIntTwirlYaw = m.twirlYaw or 0
    s.spIntGrabPos = m.marioBodyState and m.marioBodyState.grabPos or 0
    local marioAnim = animInfo(m.marioObj)
    s.spIntAnimFrame = marioAnim and marioAnim.animFrame or 0
    s.spIntMarioObjPitch = m.marioObj and m.marioObj.oMoveAnglePitch or 0
end

-- Records the held or ridden object and Mario's matching movement, including Bob-omb fuse and
-- Bowser spin details.
local function captureInteraction(s, m, o, objectMode)
    s.spObjMode = objectMode
    if o == nil then return end
    s.spObjBhv = objectBehaviorId(o)
    s.spObjModel = obj_get_model_id_extended(o) or 0
    s.spObjKey = tonumber(objectKey(o)) or 0

    for _, f in ipairs(OBJECT_FIELDS) do s[f[1]] = o[f[2]] or 0 end
    s.spObjBhvTimer = o.bhvDelayTimer or 0
    local objAnim = animInfo(o)
    s.spObjAnimFrame = objAnim and objAnim.animFrame or 0
    local scale = o.header and o.header.gfx and o.header.gfx.scale
    s.spObjScaleX, s.spObjScaleY, s.spObjScaleZ = scale and scale.x or 1, scale and scale.y or 1, scale and scale.z or 1

    if s.spObjBhv == id_bhvBobomb then
        s.spBobombBlinkTimer, s.spBobombFuseLit, s.spBobombFuseTimer =
            o.oBobombBlinkTimer or 0, o.oBobombFuseLit or 0, o.oBobombFuseTimer or 0
    end

    if s.spObjMode == OBJ_BOWSER or isBowserObject(o) then
        s.spBowserF4 = o.oBowserUnkF4 or 0
        s.spBowserHeldPitch, s.spBowserHeldVelYaw, s.spBowserHeldStage =
            o.oBowserHeldAnglePitch or 0, o.oBowserHeldAngleVelYaw or 0, o.oBowserUnk10E or 0
    end
    captureMarioMotion(s, m)
end

---------------------------------------------------------------------------------------------------
-- Coins and 1-Ups
---------------------------------------------------------------------------------------------------

-- Collected coins and 1-Ups follow your checkpoint. Their original objects are hidden and blocked
-- only for you, not deleted for everyone. Caps and shells keep their normal shared behavior; their
-- inventory or riding state is restored separately.

-- Only coins and supported 1-Ups belong to the personal pickup history. Hiding shared caps or
-- shells here breaks them for other players.
local function isOwnedItem(o, interactType)
    if o == nil then return false end
    if interactType == INTERACT_COIN or obj_is_coin(o) or obj_is_mushroom_1up(o) then return true end
    return ((o.oInteractType or 0) & INTERACT_COIN) ~= 0
end

-- Stores pickup IDs in sorted order so saving the same set produces the same data.
local function encodeSet(set)
    local t = {}
    for k in pairs(set or {}) do t[#t + 1] = k end
    table.sort(t)
    return table.concat(t, ",")
end

-- Reads the saved pickup IDs back into a lookup table. No world objects are changed here.
local function decodeSet(value)
    local set = {}
    for k in tostring(value or ""):gmatch("[^,]+") do set[k] = true end
    return set
end

-- Keeps new pickups separate from the loaded set used for hiding objects.
local function copySet(set)
    local out = {}
    for k in pairs(set or {}) do out[k] = true end
    return out
end

-- Gets this area's pickup history, creating an empty set the first time it is needed.
local function currentAreaSet()
    local k = currentLocationKey()
    if k == nil then return {} end
    collectedByArea[k] = collectedByArea[k] or {}
    return collectedByArea[k]
end

-- Forgets the current replacement and its identity together. This does not delete it.
local function clearRestoredTracking()
    restoredObject, restoredObjectSerial = nil, 0
    restoredObjectSourceKey, restoredObjectSourceBehavior, restoredObjectLocation = nil, nil, nil
    restoredObjectSyncFrames = 0
end

-- Checks the replacement's serial as well as its pointer. The game may have reused that object
-- slot for something unrelated.
local function restoredObjectIsLive()
    if restoredObject == nil then return false end
    local ok, live = pcall(function()
        return restoredObject.activeFlags ~= DEACTIVATED
            and restoredObject.oSimpleSavePointsSerial == restoredObjectSerial
            and restoredObjectSerial ~= 0
    end)
    return ok and live
end

-- Hides saved pickups and the original of a restored item on this client only. Runs after a load
-- and every third update; skips the object scan when there is nothing to hide.
local function refreshOwnedItems()
    local here = currentLocationKey()
    if (restoredObjectLocation ~= nil and here ~= restoredObjectLocation)
        or (restoredObject ~= nil and not restoredObjectIsLive()) then
        clearRestoredTracking()
    end
    local activeGone = here == ownedGoneLocation and ownedGone or nil
    local activeSource = here == restoredObjectLocation and restoredObjectSourceKey or nil
    local activeSourceBehavior = activeSource ~= nil and restoredObjectSourceBehavior or nil
    -- Penguins reuse the shared bird; hiding another matching object would hide it only
    -- on this client while its behaviour and sounds continued for everyone.
    if penguinBehavior(activeSourceBehavior) then activeSource = nil end
    -- Most frames have nothing to hide; release stale graphs without scanning every object list.
    if activeSource == nil and (activeGone == nil or next(activeGone) == nil) then
        for o, record in pairs(hiddenObjects) do
            pcall(function()
                if o.activeFlags ~= DEACTIVATED and objectBehaviorId(o) == record.behavior
                    and objectKey(o) == record.key then o.header.gfx.node.flags = record.flags end
            end)
            hiddenObjects[o] = nil
        end
        return
    end
    local m = gMarioStates[0]
    for list = 0, NUM_OBJ_LISTS - 1 do
        local o = obj_get_first(list)
        while o ~= nil do
            local nextObj = obj_get_next(o)
            local protected = o == restoredObject
                or (m ~= nil and (o == m.heldObj or o == m.riddenObj))
            local key = nil
            local shouldHide = false
            local sourceCandidate = activeSource ~= nil
                and (activeSourceBehavior == nil or activeSourceBehavior == 0 or objectBehaviorId(o) == activeSourceBehavior)
            local ownedCandidate = activeGone ~= nil and isOwnedItem(o, nil)
            if not protected and (sourceCandidate or ownedCandidate) then
                key = objectKey(o)
                shouldHide = key ~= nil and (
                    (sourceCandidate and key == activeSource)
                    or (ownedCandidate and activeGone[key])
                )
            end
            if shouldHide then
                if hiddenObjects[o] == nil then
                    hiddenObjects[o] = {flags = o.header.gfx.node.flags, behavior = objectBehaviorId(o), key = key}
                end
                o.header.gfx.node.flags = o.header.gfx.node.flags | GRAPH_RENDER_INVISIBLE
            elseif hiddenObjects[o] ~= nil then
                local record = hiddenObjects[o]
                if objectBehaviorId(o) == record.behavior and objectKey(o) == record.key then
                    o.header.gfx.node.flags = record.flags
                end
                hiddenObjects[o] = nil
            end
            o = nextObj
        end
    end
end

---------------------------------------------------------------------------------------------------
-- Releasing and restoring objects
---------------------------------------------------------------------------------------------------

-- Loading first lets go of what Mario is carrying or riding. Ordinary held items are recreated
-- locally; ridden shells use the game's object synchronization. Bowser is never cloned. These
-- routines keep Mario and the restored object linked so the game can continue their normal
-- behavior.

-- Clients send shell messages to the first connected host; the host sends them to all
-- connected peers in index order. Publishing and forwarding use the same routing.
local function sendShellVisual(packet, serverOnly)
    for i = 1, MAX_PLAYERS - 1 do
        local peer = gNetworkPlayers[i]
        if peer ~= nil and peer.connected and (not serverOnly or peer.type == NPT_SERVER) then
            pcall(network_send_bytestring_to, i, true, packet)
            if serverOnly then break end
        end
    end
end

-- Announces a restored shell ride or dismount. Clients send to the host, which forwards to the
-- other players. The packet contains no save data.
local function publishShellVisual(s, active)
    local n = gNetworkPlayers[0]
    if n == nil or n.globalIndex == nil then return end
    local wasActive = shellVisual.active
    if not active then
        shellVisual.active, shellVisual.lost, shellVisual.resend, shellVisual.pending = false, 0, 0, 0
        shellVisual.states[n.globalIndex] = nil
        if not wasActive then return end
    else
        shellVisual.serial = (shellVisual.serial % 2147483646) + 1
        shellVisual.active, shellVisual.lost = true, 0
        shellVisual.level = s ~= nil and s.spLevel or shellVisual.level
        shellVisual.area = s ~= nil and s.spArea or shellVisual.area
        shellVisual.states[n.globalIndex] = {
            token = shellVisual.serial, level = shellVisual.level, area = shellVisual.area
        }
    end
    if network_player_connected_count() > 1 then
        local packet = string.pack("<BBBBBI4", shellVisual.packet, n.globalIndex, active and 1 or 0,
            shellVisual.level, shellVisual.area, shellVisual.serial)
        sendShellVisual(packet, not network_is_server())
    end
end

-- Records shell announcements and forwards them on the host. Remote shell models are visual only;
-- the rider keeps the actual shell.
local function receiveShellVisualPacket(data)
    if type(data) ~= "string" or #data < 9 then return end
    local ok, packet, owner, active, level, area, token = pcall(string.unpack, "<BBBBBI4", data)
    if not ok or packet ~= shellVisual.packet then return end
    if owner < 0 or owner >= MAX_PLAYERS then return end
    if active == 1 then
        shellVisual.states[owner] = {
            token = token, level = level, area = area
        }
    else
        shellVisual.states[owner] = nil
    end
    local localNetwork = gNetworkPlayers[0]
    if network_is_server() and localNetwork ~= nil and owner ~= localNetwork.globalIndex then
        sendShellVisual(data, false)
    end
end

-- Removes only our previous replacement, after checking its location and serial. The game's
-- drop/dismount routines must run before clearing pointers or deleting the object.
local function clearRestoredObject(m)
    local old, oldLocation = restoredObject, restoredObjectLocation
    local sameLocation = oldLocation == currentLocationKey()
    local oldIsLive = sameLocation and restoredObjectIsLive()
    clearRestoredTracking()
    if old == nil or not oldIsLive then return end

    if m ~= nil and m.heldObj == old then
        mario_drop_held_object(m)
        if m.heldObj == old then m.heldObj = nil end
    end
    if m ~= nil and m.riddenObj == old then
        mario_stop_riding_object(m)
        if m.riddenObj == old then m.riddenObj = nil end
    end
    if m ~= nil then
        if m.usedObj == old then m.usedObj = nil end
        if m.interactObj == old then m.interactObj = nil end
    end
    -- A restored penguin belongs to the level, not to this checkpoint. Dropping it above
    -- already sends its new held state; never delete the shared bird during the next load.
    if not penguinBehavior(objectBehaviorId(old)) then pcall(obj_mark_for_deletion, old) end
end

-- Stops the unfinished tail-hold restoration without resetting or deleting Bowser.
local function clearBowserRestoreState()
    bowserRestoreObject, bowserRestoreFrames, bowserRestoreLocation = nil, 0, nil
    bowserRestorePhase, bowserRestoreSettle = 0, 0
end

-- Lets go of Mario's current item or ride before loading. Use the game's release routines: they
-- handle throw momentum and network cleanup as well as pointers.
local function releaseCurrentInteraction(m)
    penguinRestoreFrames = 0
    publishShellVisual(nil, false)
    clearBowserRestoreState()
    if heldBowserRoot ~= nil and currentLocationKey() == heldBowserLocation then
        pcall(function()
            local node = heldBowserRoot.header.gfx.node
            node.flags = (node.flags or 0) | BOWSER_RENDER_ACTIVE
        end)
    end
    heldBowserRoot, heldBowserLocation = nil, nil
    clearRestoredObject(m)
    if m.heldObj ~= nil then
        mario_drop_held_object(m)
        if m.heldObj ~= nil then m.heldObj = nil end
    end
    if m.riddenObj ~= nil then
        mario_stop_riding_object(m)
        if m.riddenObj ~= nil then m.riddenObj = nil end
    end
    m.usedObj, m.interactObj = nil, nil
end

-- Restores object state, animation, scale and any Bob-omb fuse after the replacement has been
-- created.
local function restoreObjectFields(o, s)
    if o == nil or s.spObjBhv == 0 then return end
    for _, f in ipairs(OBJECT_FIELDS) do o[f[2]] = s[f[1]] end
    o.bhvDelayTimer = s.spObjBhvTimer
    local anim = animInfo(o)
    if anim ~= nil then anim.animFrame = s.spObjAnimFrame end
    local scale = o.header and o.header.gfx and o.header.gfx.scale
    if scale ~= nil then scale.x, scale.y, scale.z = s.spObjScaleX, s.spObjScaleY, s.spObjScaleZ end

    if s.spObjBhv == id_bhvBobomb then
        o.oBobombBlinkTimer, o.oBobombFuseLit, o.oBobombFuseTimer =
            s.spBobombBlinkTimer, s.spBobombFuseLit, s.spBobombFuseTimer
    end
end

-- Ordinary carryables use local copies. Penguins reuse their synchronized level object;
-- shell rides and Bowser have separate restoration paths.
local function spawnCheckpointObject(m, s)
    local bhv, model = s.spObjBhv, s.spObjModel
    if s.spObjMode == OBJ_BOWSER or bhv == id_bhvBowser or model == E_MODEL_BOWSER then
        return nil
    end
    if bhv == nil or bhv == 0 or model == nil then return nil end

    -- Native penguin behaviour initializes networking even for spawn_non_sync_object().
    -- Reuse the matching bird instead of creating a "private" duplicate that later syncs.
    -- Home coordinates distinguish the two CCM babies, including the post-rescue behaviour.
    if penguinBehavior(bhv) then
        for _, behavior in ipairs({id_bhvSmallPenguin, id_bhvPenguinBaby}) do
            local bird = obj_get_first_with_behavior_id(behavior)
            while bird ~= nil do
                if bird.activeFlags ~= DEACTIVATED and objectSyncInitialized(bird)
                    and (tonumber(objectKey(bird)) == s.spObjKey or (bird.oBehParams == s.spObjBehParams
                        and math.abs(bird.oHomeX - s.spObjHomeX) < 1
                        and math.abs(bird.oHomeY - s.spObjHomeY) < 1
                        and math.abs(bird.oHomeZ - s.spObjHomeZ) < 1)) then
                    local occupied = bird.oHeldState == HELD and bird.heldByPlayerIndex ~= 0
                    for i = 1, MAX_PLAYERS - 1 do
                        if gNetworkPlayers[i].connected and gMarioStates[i].heldObj == bird then occupied = true end
                    end
                    if not occupied then return bird end
                end
                bird = obj_get_next_with_same_behavior_id(bird)
            end
        end
        return nil
    end

    local ok, o = pcall(spawn_non_sync_object, bhv, model, m.pos.x, m.pos.y, m.pos.z, function(obj)
        obj.oBehParams = s.spObjBehParams
        obj.oBehParams2ndByte = s.spObjBehParams2
        obj.oFlags = s.spObjFlags
        obj.oInteractType = s.spObjInteractType
        obj.oInteractionSubtype = s.spObjInteractSubtype
        obj.oHomeX, obj.oHomeY, obj.oHomeZ = s.spObjHomeX, s.spObjHomeY, s.spObjHomeZ
        obj.oHeldState = FREE
    end)
    if not ok then return nil end
    return o
end

-- Restores the recorded movement. Flight needs its animation selected first; bubbles skip action
-- setup because mario_set_bubbled() has already done it.
local function restoreMarioMotion(m, s, action)
    if action ~= nil then set_mario_action(m, action, s.spIntActionArg) end
    -- Steady flight does not select its animation again in act_flying(). A new level may still have its entry flip
    -- selected, so initialize the matching character animation before applying the saved frame and motion.
    if action == ACT_FLYING then
        set_character_animation(m, s.spIntActionState ~= 0 and CHAR_ANIM_WING_CAP_FLY
            or (s.spIntActionArg == 0 and CHAR_ANIM_FLY_FROM_CANNON or CHAR_ANIM_FORWARD_SPINNING_FLIP))
    end
    m.prevAction = s.spIntPrevAction
    m.actionState, m.actionTimer, m.actionArg = s.spIntActionState, s.spIntActionTimer, s.spIntActionArg
    m.vel.x, m.vel.y, m.vel.z = s.spIntVelX, s.spIntVelY, s.spIntVelZ
    m.forwardVel, m.slideVelX, m.slideVelZ = s.spIntForwardVel, s.spIntSlideX, s.spIntSlideZ
    m.angleVel.x, m.angleVel.y, m.angleVel.z = s.spIntAngleVelX, s.spIntAngleVelY, s.spIntAngleVelZ
    m.twirlYaw = s.spIntTwirlYaw
    if m.marioBodyState ~= nil then m.marioBodyState.grabPos = s.spIntGrabPos end
    if m.marioObj ~= nil then
        m.marioObj.oMoveAngleYaw = m.faceAngle.y
        m.marioObj.oMoveAnglePitch = s.spIntMarioObjPitch
        m.marioObj.oAngleVelYaw = m.angleVel.y
        local anim = animInfo(m.marioObj)
        if anim ~= nil then anim.animFrame = s.spIntAnimFrame end
    end
    if m.statusForCamera ~= nil then m.statusForCamera.action = action or m.action end
end

-- Chooses the saved hold or ride action, falling back to a normal hold/ride when it is missing,
-- then restores movement.
local function restoreMarioInteraction(m, s, objectMode)
    local action = s.spIntAction
    if objectMode == OBJ_SHELL and (action == 0 or (action & ACT_FLAG_RIDING_SHELL) == 0) then
        action = s.spShellAction
        if action == 0 or (action & ACT_FLAG_RIDING_SHELL) == 0 then action = ACT_RIDING_SHELL_GROUND end
    elseif objectMode == OBJ_BOWSER and action == 0 then
        action = ACT_HOLDING_BOWSER
    elseif objectMode == OBJ_HELD and action == 0 then
        action = ACT_HOLD_IDLE
    end
    restoreMarioMotion(m, s, action)
end

-- Connects both Mario and the object after pickup. Bowser must also remain intangible while held.
local function linkHeldObject(m, o, bowserHeld)
    o.oHeldState, o.heldByPlayerIndex, o.parentObj = HELD, 0, m.marioObj
    if bowserHeld then o.oIntangibleTimer = -1 end
    m.heldObj, m.usedObj, m.interactObj = o, o, o
end

-- Gives a replacement a unique session serial and its saved source ID, so later saves and cleanup
-- still recognize the original item.
local function trackRestoredObject(o, s)
    nextRestoredObjectSerial = nextRestoredObjectSerial % 2147483646 + 1
    restoredObjectSerial = nextRestoredObjectSerial
    o.oSimpleSavePointsSerial = restoredObjectSerial
    o.oSimpleSavePointsSource = s.spObjKey
    restoredObject = o
    restoredObjectSourceKey = s.spObjKey ~= 0 and tostring(math.floor(s.spObjKey)) or objectKey(o)
    restoredObjectSourceBehavior = s.spObjBhv ~= 0 and s.spObjBhv or objectBehaviorId(o)
    restoredObjectLocation = locationKey(s.spLevel, s.spArea)
end

-- Sends a shared object's restored state only once its network slot is ready. Private held copies
-- do not use this.
local function sendObjectSync(o, reliable)
    if not objectSyncInitialized(o) then return false end
    local ok = pcall(network_send_object, o, reliable == true)
    return ok
end

---------------------------------------------------------------------------------------------------
-- Bowser fights
---------------------------------------------------------------------------------------------------

-- In a compatible solo fight, loading restores Bowser's saved attack or tail spin and Bowser 2's
-- platform tilt. In a shared or changed fight, the boss and floor stay as they are; Mario returns
-- to a safe point on the current platform instead. Missing platforms are refused. Bowser's body,
-- jaw and tail belong to the existing boss and must not be recreated separately.

-- Matches the three Bowser battle maps, not the obstacle courses leading to them.
bossArena.isLevel = function(level)
    return level == LEVEL_BOWSER_1 or level == LEVEL_BOWSER_2 or level == LEVEL_BOWSER_3
end

-- Checks for other players in the arena before changing Bowser or the floor. A load must not reset
-- their fight or take their tail hold.
bossArena.otherPresent = function(s)
    if s == nil or not bossArena.isLevel(s.spLevel) then return false end
    for i = 1, MAX_PLAYERS - 1 do
        local n, m = gNetworkPlayers[i], gMarioStates[i]
        if n ~= nil and n.connected and n.currLevelNum == s.spLevel
            and playerArea(m, n) == s.spArea and m ~= nil and m.marioObj ~= nil then return true end
    end
    return false
end

-- Finds the existing saved platform by identity and section number. Missing arena geometry is
-- never respawned.
bossArena.findSupport = function(s, supportType)
    supportType = supportType or s.spBossSupport
    local behavior = supportType == 1 and id_bhvTiltingBowserLavaPlatform
        or (supportType == 2 and id_bhvFallingBowserPlatform or nil)
    if behavior == nil then return nil end
    local wanted = s.spBossSupportKey ~= 0 and tostring(math.floor(s.spBossSupportKey)) or nil
    local selected, o = nil, obj_get_first_with_behavior_id(behavior)
    while o ~= nil do
        if o.activeFlags ~= DEACTIVATED then
            local keyMatch = wanted ~= nil and objectKey(o) == wanted
            local partMatch = supportType ~= 2 or (o.oBehParams2ndByte or 0) == s.spBossSupportParam
            if keyMatch and partMatch then return o end
            if selected == nil and partMatch then selected = o end
        end
        o = obj_get_next_with_same_behavior_id(o)
    end
    return selected
end

-- Converts between world and platform coordinates using SM64's Z-X-Y rotation order. This lets a
-- saved point follow a tilted floor.
bossArena.rotate = function(x, y, z, pitch, yaw, roll, inverse)
    local sx, cx, sy, cy, sz, cz = sins(pitch), coss(pitch), sins(yaw), coss(yaw), sins(roll), coss(roll)
    local a, b, c = sy * sz * sx + cy * cz, sy * cz * sx - cy * sz, cx * sy
    local d, e, f = cx * sz, cx * cz, -sx
    local g, h, j = cy * sz * sx - sy * cz, cy * cz * sx + sy * sz, cx * cy
    if inverse then return x * a + y * d + z * g, x * b + y * e + z * h, x * c + y * f + z * j end
    return x * a + y * b + z * c, x * d + y * e + z * f, x * g + y * h + z * j
end

-- Counts the remaining mines. A used mine means the fight may have progressed beyond the saved
-- state.
bossArena.mineCount = function()
    local count, o = 0, obj_get_first_with_behavior_id(id_bhvBowserBomb)
    while o ~= nil do
        if o.activeFlags ~= DEACTIVATED then count = count + 1 end
        o = obj_get_next_with_same_behavior_id(o)
    end
    return count
end

-- Records the mines, Bowser 2's tilt and Mario's position relative to his platform. Bowser 3's
-- floor is tracked for safe placement, not rebuilt.
bossArena.capture = function(s, m)
    if not bossArena.isLevel(s.spLevel) then return end
    s.spBossMines = bossArena.mineCount()
    local tilt = obj_get_first_with_behavior_id(id_bhvTiltingBowserLavaPlatform)
    if tilt ~= nil and tilt.activeFlags ~= DEACTIVATED then
        s.spBossTilt = 1
        s.spBossTiltFacePitch, s.spBossTiltFaceYaw, s.spBossTiltFaceRoll =
            tilt.oFaceAnglePitch or 0, tilt.oFaceAngleYaw or 0, tilt.oFaceAngleRoll or 0
        s.spBossTiltVelPitch, s.spBossTiltVelYaw, s.spBossTiltVelRoll =
            tilt.oAngleVelPitch or 0, tilt.oAngleVelYaw or 0, tilt.oAngleVelRoll or 0
    end
    local support = m and m.marioObj and m.marioObj.platform or nil
    if support == nil and m ~= nil and m.floor ~= nil then support = m.floor.object end
    local behavior = objectBehaviorId(support)
    s.spBossSupport = behavior == id_bhvTiltingBowserLavaPlatform and 1
        or (behavior == id_bhvFallingBowserPlatform and 2 or 0)
    if s.spBossSupport == 0 then return end
    s.spBossSupportKey = tonumber(objectKey(support)) or 0
    s.spBossSupportParam = support.oBehParams2ndByte or 0
    s.spBossLocalX, s.spBossLocalY, s.spBossLocalZ = bossArena.rotate(
        m.pos.x - support.oPosX, m.pos.y - support.oPosY, m.pos.z - support.oPosZ,
        support.oFaceAnglePitch or 0, support.oFaceAngleYaw or 0, support.oFaceAngleRoll or 0, true)
    s.spBossSupportClearance = math.max(0, m.pos.y - (m.floorHeight or m.pos.y))
end

-- Finds the saved point on the platform as it is now. Refuses missing or dangerous floors rather
-- than dropping Mario at the old point over lava.
bossArena.resolvePosition = function(s)
    local support = bossArena.findSupport(s)
    if support == nil then return nil end
    local x, y, z = bossArena.rotate(s.spBossLocalX, s.spBossLocalY, s.spBossLocalZ,
        support.oFaceAnglePitch or 0, support.oFaceAngleYaw or 0, support.oFaceAngleRoll or 0, false)
    x, y, z = x + support.oPosX, y + support.oPosY, z + support.oPosZ
    local floorHeight, floor = find_floor(x, y + 1000, z)
    if floor == nil or floor.object ~= support or floor.type == SURFACE_BURNING
        or floor.type == SURFACE_DEATH_PLANE then return nil end
    return x, floorHeight + s.spBossSupportClearance, z, support
end

-- Restores the existing Bowser 2 floor after the solo-fight checks pass. Collision needs another
-- object update to catch up with the tilt.
bossArena.restoreTilt = function(s)
    if s.spLevel ~= LEVEL_BOWSER_2 or s.spBossTilt == 0 then return true end
    local o = bossArena.findSupport(s, 1)
    if o == nil or not objectSyncInitialized(o) then return false end
    o.oFaceAnglePitch, o.oFaceAngleYaw, o.oFaceAngleRoll =
        s.spBossTiltFacePitch, s.spBossTiltFaceYaw, s.spBossTiltFaceRoll
    o.oMoveAnglePitch, o.oMoveAngleYaw, o.oMoveAngleRoll =
        s.spBossTiltFacePitch, s.spBossTiltFaceYaw, s.spBossTiltFaceRoll
    o.oAngleVelPitch, o.oAngleVelYaw, o.oAngleVelRoll =
        s.spBossTiltVelPitch, s.spBossTiltVelYaw, s.spBossTiltVelRoll
    obj_set_gfx_angle(o, o.oFaceAnglePitch, o.oFaceAngleYaw, o.oFaceAngleRoll)
    sendObjectSync(o, true)
    return true
end

-- Finds the arena's existing boss, preferring a ready network object and matching saved identity.
-- Partly initialized bosses must not be edited.
local function findBowserForCheckpoint(s)
    local wantedValue = s.spBowserWorld ~= 0 and s.spBowserWorldKey or s.spObjKey
    local wanted = wantedValue ~= 0 and tostring(math.floor(wantedValue)) or nil
    local selected, bestScore = nil, -1
    local o = obj_get_first_with_behavior_id(id_bhvBowser)
    while o ~= nil do
        if o.activeFlags ~= DEACTIVATED then
            local score = (objectSyncInitialized(o) and 100 or 0)
                + (wanted ~= nil and objectKey(o) == wanted and 1 or 0)
            local syncId, selectedSyncId = o.oSyncID or 0, selected and (selected.oSyncID or 0) or 0
            if score > bestScore or (score == bestScore and syncId ~= 0
                and (selectedSyncId == 0 or syncId < selectedSyncId)) then
                selected, bestScore = o, score
            end
        end
        o = obj_get_next_with_same_behavior_id(o)
    end
    if selected == nil then return nil end

    -- Reject partial vanilla roots; touching them corrupts native child anchors.
    if bossArena.isLevel(s.spLevel) and not objectSyncInitialized(selected) then return nil end
    return selected
end

-- Restores Bowser's saved attack without replacing his body parts. Reapplies the animation frame
-- after the game initializes that attack.
local function restoreBowserWorldSnapshot(s)
    if s.spBowserWorld == 0 then return true end
    local o = findBowserForCheckpoint(s)
    if o == nil then return false end
    if not bossArena.rewindAllowed(s, o) then return false end
    if o.oHeldState == HELD and (o.heldByPlayerIndex or 0) ~= 0 then return false end

    -- Root-only restoration preserves the native body, jaw, flame, and tail children.
    for _, f in ipairs(BOWSER_WORLD_FIELDS) do o[f[2]] = s[f[1]] end
    o.bhvDelayTimer = s.spBowserWorldDelayTimer
    o.oHeldState, o.heldByPlayerIndex, o.parentObj, o.oInteractStatus = FREE, 0, o, 0
    local anim = animInfo(o)
    if anim ~= nil then anim.animFrame = s.spBowserWorldAnimFrame end
    bowserWorldAnimObject = o
    bowserWorldAnimLocation = locationKey(s.spLevel, s.spArea)
    bowserWorldAnimFrame = s.spBowserWorldAnimFrame
    pcall(function()
        local node = o.header and o.header.gfx and o.header.gfx.node
        if node ~= nil then node.flags = (node.flags or 0) | BOWSER_RENDER_ACTIVE end
    end)
    sendObjectSync(o)
    return true
end

-- A key or Grand Star means the fight is already finished; loading must not bring Bowser back
-- beside it.
bossArena.rewardExists = function()
    for _, behavior in ipairs({id_bhvBowserKey, id_bhvGrandStar}) do
        local o = obj_get_first_with_behavior_id(behavior)
        if o ~= nil and o.activeFlags ~= DEACTIVATED then return true end
    end
    return false
end

-- Allows a solo restore only while health, mines and rewards still match. Shared fights and Bowser
-- 3's destructible floor keep their current progress.
bossArena.rewindAllowed = function(s, o)
    if bossArena.otherPresent(s) or o == nil or o.activeFlags == DEACTIVATED
        or (o.oHealth or 0) <= 0 or bossArena.rewardExists() then return false end
    -- Bowser 3 sections can be permanently deleted and their native collision hierarchy cannot be safely cloned.
    if s.spLevel == LEVEL_BOWSER_3 or (s.spLevel == LEVEL_BOWSER_2 and s.spBossTilt == 0) then return false end
    local health = s.spObjMode == OBJ_BOWSER and s.spObjHealth
        or (s.spBowserWorld ~= 0 and s.spBowserWorldHealth or o.oHealth)
    if health > 0 and o.oHealth ~= health then return false end
    return s.spBossMines < 0 or bossArena.mineCount() == s.spBossMines
end

-- Decides whether to restore the fight or just Mario's position. If the floor changed, follows the
-- saved platform; if it is gone, refuses the load.
bossArena.plan = function(s)
    local plan = {x = s.spX, y = s.spY, z = s.spZ, rewind = false, preserve = false,
        blocked = false, heldBlocked = false, notice = nil}
    if not bossArena.isLevel(s.spLevel) then return plan end
    local hasState, shared = checkpointHasBowserState(s), bossArena.otherPresent(s)
    local bowser = hasState and findBowserForCheckpoint(s) or nil
    plan.rewind = hasState and bossArena.rewindAllowed(s, bowser)
    if plan.rewind and not bossArena.restoreTilt(s) then plan.rewind = false end
    plan.preserve = hasState and not plan.rewind
    plan.heldBlocked = s.spObjMode == OBJ_BOWSER and not plan.rewind

    if s.spBossSupport ~= 0 then
        if plan.rewind and s.spBossSupport == 1 then
            -- The restored tilt matches the saved point. Its collision updates next frame,
            -- so check the platform itself rather than its still-outdated triangles.
            plan.support = bossArena.findSupport(s)
        else
            local x, y, z, support = bossArena.resolvePosition(s)
            if x ~= nil then plan.x, plan.y, plan.z, plan.support = x, y, z, support end
        end
        if plan.support == nil then
            plan.blocked = true
            plan.notice = "Saved Bowser platform is unavailable; position was not loaded."
            return plan
        end
    elseif (s.spLevel == LEVEL_BOWSER_2 or s.spLevel == LEVEL_BOWSER_3)
        and s.spBossMines < 0 and s.spAir == 0 then
        -- A format-2 slot has no platform-relative data. Use it only while its old world point remains solid.
        local floorHeight, floor = find_floor(plan.x, plan.y + 1000, plan.z)
        if floor == nil or floor.type == SURFACE_BURNING or floor.type == SURFACE_DEATH_PLANE
            or math.abs(plan.y - floorHeight) > 500 then
            plan.blocked = true
            plan.notice = "Older Bowser platform save is unsafe here; make a new checkpoint."
            return plan
        end
        plan.y = floorHeight + math.max(0, plan.y - floorHeight)
    end

    if shared then
        plan.notice = plan.heldBlocked
            and "Shared Bowser fight kept live; saved tail hold was not restored."
            or (hasState and "Shared Bowser fight kept live; Bowser and arena were not rewound." or nil)
    elseif s.spLevel == LEVEL_BOWSER_3 and hasState then
        plan.notice = plan.heldBlocked
            and "Bowser 3 floor kept live; saved tail hold was not restored."
            or "Bowser 3's destructible arena was kept live."
    elseif plan.preserve then
        plan.notice = plan.heldBlocked
            and "Fight progress changed; saved tail hold was not restored."
            or "Fight progress changed; the live Bowser arena was preserved."
    end
    return plan
end

-- Waits for Bowser only when the solo fight can be restored. Shared, completed and Bowser 3 fights
-- must not time out waiting for a boss they cannot rewind.
bossArena.waitForRoot = function(s)
    return checkpointHasBowserState(s) and s.spLevel ~= LEVEL_BOWSER_3
        and not bossArena.otherPresent(s) and not bossArena.rewardExists()
        and findBowserForCheckpoint(s) == nil
end

-- Shows or hides Bowser's normal level model without changing his behavior. Mario's held-object
-- rendering draws him separately during a tail hold.
local function setBowserWorldGraphActive(o, active)
    if o == nil then return false end
    local ok = pcall(function()
        local node = o.header and o.header.gfx and o.header.gfx.node
        if node == nil or type(node.flags) ~= "number" then return end
        node.flags = active and (node.flags | BOWSER_RENDER_ACTIVE) or (node.flags & ~BOWSER_RENDER_ACTIVE)
    end)
    return ok
end

-- Hides the duplicate level rendering while Mario holds Bowser, and keeps the held boss
-- intangible.
local function hideHeldBowserWorldGraph(o)
    setBowserWorldGraphActive(o, false)
    if o ~= nil then o.oIntangibleTimer = -1 end
end

-- Keeps one Bowser visible while held, then restores his normal rendering when released. Old-area
-- pointers are forgotten without touching them.
local function maintainHeldBowserWorldGraph()
    local o = heldBowserRoot
    if o == nil then return end
    local m = gMarioStates[0]
    local here = currentLocationKey()
    if m == nil or o.activeFlags == DEACTIVATED
        or here ~= heldBowserLocation then
        heldBowserRoot, heldBowserLocation = nil, nil
        return
    end
    if m.heldObj == o and o.oHeldState == HELD then
        hideHeldBowserWorldGraph(o)
    else
        setBowserWorldGraphActive(o, true)
        heldBowserRoot, heldBowserLocation = nil, nil
    end
end

-- Applies the saved frame once after Bowser's attack setup, then clears the temporary record.
local function finishBowserWorldAnimationRestore()
    local o = bowserWorldAnimObject
    if o == nil then return end
    if o.activeFlags ~= DEACTIVATED and currentLocationKey() == bowserWorldAnimLocation then
        local anim = animInfo(o)
        if anim ~= nil then anim.animFrame = bowserWorldAnimFrame end
    end
    bowserWorldAnimObject, bowserWorldAnimLocation, bowserWorldAnimFrame = nil, nil, 0
end

-- Restores health and spin details without forcing Bowser's action. Normal pickup and release
-- logic must still handle throws and returns to the platform.
local function restoreBowserHeldSnapshot(o, s)
    o.oHealth, o.oOpacity, o.oBowserUnkF4 = s.spObjHealth, s.spObjOpacity, s.spBowserF4
    o.oBowserHeldAnglePitch, o.oBowserHeldAngleVelYaw = s.spBowserHeldPitch, s.spBowserHeldVelYaw
    o.oMoveFlags = 0
end

-- Finishes the tail pickup through the game's normal holding stages, then restores the saved spin.
-- Releasing Bowser or another player entering stops this setup; it must not keep grabbing him
-- back.
local function advanceBowserRestore()
    local o = bowserRestoreObject
    if o == nil then return end

    local m, n, s = gMarioStates[0], gNetworkPlayers[0], localCheckpoint
    local area = playerArea(m, n)
    if m == nil or n == nil or o.activeFlags == DEACTIVATED
        or currentLocationKey() ~= bowserRestoreLocation
        or n.currLevelNum ~= s.spLevel or area ~= s.spArea then
        clearBowserRestoreState()
        return
    end

    -- Stop setting up the saved hold if Mario throws Bowser or someone joins the fight.
    if m.action == ACT_RELEASING_BOWSER then
        -- Leave the hold links intact so the game can finish the throw and Bowser's return.
        clearBowserRestoreState()
        return
    end
    if bossArena.otherPresent(s) or (o.oHeldState == HELD and (o.heldByPlayerIndex or 0) ~= 0) then
        if m.heldObj == o then m.heldObj = nil end
        m.usedObj, m.interactObj = nil, nil
        o.oHeldState, o.heldByPlayerIndex, o.parentObj = FREE, 0, o
        if m.action == ACT_PICKING_UP_BOWSER or m.action == ACT_HOLDING_BOWSER then
            set_mario_action(m, ACT_IDLE, 0)
        end
        setBowserWorldGraphActive(o, true)
        heldBowserRoot, heldBowserLocation = nil, nil
        sendObjectSync(o, true)
        clearBowserRestoreState()
        return
    end

    bowserRestoreFrames = bowserRestoreFrames + 1
    -- Pickup can briefly clear Mario's reference to Bowser.
    if m.heldObj ~= o then
        o.oHeldState = FREE
        m.usedObj, m.interactObj = o, o
        pcall(mario_grab_used_object, m)
    end
    if m.heldObj ~= o then
        if bowserRestoreFrames >= 45 then
            clearBowserRestoreState()
        end
        return
    end

    linkHeldObject(m, o, true)
    hideHeldBowserWorldGraph(o)

    if bowserRestorePhase == BOWSER_RESTORE_GRAB then
        if m.action == ACT_PICKING_UP_BOWSER then
            -- Let native pickup initialize once, then finish its animation quickly.
            local anim = animInfo(m.marioObj)
            local cur = anim and anim.curAnim
            if bowserRestoreFrames > 1 and cur ~= nil then
                anim.animFrame = math.max((cur.loopEnd or 2) - 2, 0)
            end
        elseif m.action == ACT_HOLDING_BOWSER then
            bowserRestorePhase = BOWSER_RESTORE_HELD
        else
            set_mario_action(m, ACT_PICKING_UP_BOWSER, 0)
            m.actionState, m.actionTimer, m.actionArg = 1, 0, 0
        end
        if bowserRestoreFrames >= 12 and m.action ~= ACT_HOLDING_BOWSER then
            set_mario_action(m, ACT_HOLDING_BOWSER, 0)
            bowserRestorePhase = BOWSER_RESTORE_HELD
        end
        return
    end

    if bowserRestorePhase == BOWSER_RESTORE_SETTLE then
        if m.action ~= ACT_HOLDING_BOWSER then restoreMarioInteraction(m, s, OBJ_BOWSER) end
        bowserRestoreSettle = bowserRestoreSettle - 1
        if bowserRestoreSettle <= 0 then clearBowserRestoreState() end
        return
    end

    if m.action ~= ACT_HOLDING_BOWSER then set_mario_action(m, ACT_HOLDING_BOWSER, 0) end
    local targetStage = s.spBowserHeldStage
    local stage = o.oBowserUnk10E or 0
    if stage == 1 and targetStage >= 2 then
        -- Advance stage 1 through its native animation transition.
        local anim = animInfo(o)
        local cur = anim and anim.curAnim
        if cur ~= nil then anim.animFrame = math.max((cur.loopEnd or 2) - 2, 0) end
        return
    end

    if (targetStage <= 1 and stage >= targetStage) or stage >= 2 or bowserRestoreFrames >= 45 then
        restoreMarioInteraction(m, s, OBJ_BOWSER)
        restoreBowserHeldSnapshot(o, s)
        linkHeldObject(m, o, true)
        hideHeldBowserWorldGraph(o)
        sendObjectSync(o)
        bowserRestorePhase, bowserRestoreSettle = BOWSER_RESTORE_SETTLE, 3
    end
end

-- Starts a real tail pickup on the existing Bowser. advanceBowserRestore() finishes the saved spin
-- once the game's holding state is ready.
local function restoreBowserInteraction(m, s)
    if bossArena.otherPresent(s) then return false end
    local o = findBowserForCheckpoint(s)
    if o == nil then return false end
    if not bossArena.rewindAllowed(s, o) then return false end
    if o.oHeldState == HELD and (o.heldByPlayerIndex or 0) ~= 0 then return false end
    if m.heldObj ~= nil and m.heldObj ~= o then pcall(mario_drop_held_object, m) end
    restoreBowserHeldSnapshot(o, s)
    o.oHeldState = FREE
    o.oInteractType = (o.oInteractType or 0) | INTERACT_GRABBABLE
    o.heldByPlayerIndex, o.oBowserUnk10E = 0, 0
    m.heldObj = nil
    m.usedObj, m.interactObj = o, o
    set_mario_action(m, ACT_PICKING_UP_BOWSER, 0)
    m.actionState, m.actionTimer, m.actionArg = 0, 0, 0
    if m.marioBodyState ~= nil then m.marioBodyState.grabPos = s.spIntGrabPos end
    pcall(mario_grab_used_object, m)
    if m.heldObj ~= o then return false end
    linkHeldObject(m, o, true)
    heldBowserRoot, heldBowserLocation = o, locationKey(s.spLevel, s.spArea)
    hideHeldBowserWorldGraph(o)
    if m.marioObj ~= nil then
        m.marioObj.oMoveAnglePitch = s.spBowserHeldPitch
        m.marioObj.oAngleVelYaw = s.spIntAngleVelY
    end
    bowserRestoreObject = o
    bowserRestoreFrames = 0
    bowserRestoreLocation = locationKey(s.spLevel, s.spArea)
    bowserRestorePhase, bowserRestoreSettle = BOWSER_RESTORE_GRAB, 0
    sendObjectSync(o)
    return true
end

---------------------------------------------------------------------------------------------------
-- Held items and shell rides
---------------------------------------------------------------------------------------------------

-- These routines put the saved item back in Mario's hands or resume his shell ride. Each uses the
-- game's pickup or riding setup before restoring the saved details. Bowser has his own path above
-- because ordinary item spawning breaks the fight.

-- Creates the ridden shell with a small network spawn payload, then restores the rest locally.
-- Sends the completed state when its sync slot is ready and announces the ride after it stays
-- stable.
local function restoreShellInteraction(m, s)
    local bhv = id_bhvKoopaShell
    if s.spShellWater ~= 0 then bhv = id_bhvKoopaShellUnderwater end
    -- Use stable native identifiers and a minimal spawn payload. Saved model/behavior values and the full generic
    -- field set are valid locally, but placing all of them in the spawn callback can make peers reject the object.
    local ok, shell = pcall(spawn_sync_object, bhv, E_MODEL_KOOPA_SHELL,
        m.pos.x, m.pos.y, m.pos.z, function(obj)
            obj.oBehParams, obj.oBehParams2ndByte = s.spObjBehParams, s.spObjBehParams2
            obj.oAction, obj.oInteractStatus, obj.oHeldState = s.spObjAction, 0, FREE
            obj.heldByPlayerIndex = 0
        end)
    if not ok then shell = nil end
    if shell == nil then return false end

    restoreObjectFields(shell, s)
    -- Fresh shells must satisfy fixInvalidShellRides before their first behaviour update.
    -- STOP_RIDING is a one-frame event, never state to replay from a checkpoint.
    shell.oInteractType, shell.oInteractStatus = INTERACT_KOOPA_SHELL, 0
    shell.oAction = 1
    shell.oHeldState, shell.heldByPlayerIndex = FREE, 0
    m.quicksandDepth = 0
    m.interactObj, m.usedObj, m.riddenObj = shell, shell, shell
    trackRestoredObject(shell, s)
    restoreMarioInteraction(m, s, OBJ_SHELL)
    -- Native shell setup can briefly drop Mario's ridden pointer after this function returns. Publish only after
    -- updateRemoteShellVisuals() observes thirty consecutive fully-riding frames.
    shellVisual.pending = 30
    if not sendObjectSync(shell, true) then restoredObjectSyncFrames = 30 end
    play_shell_music()
    return true
end

-- Finds the shared penguin or creates another supported carryable, runs the normal grab,
-- then restores the item and Mario's hold. This order preserves the saved fuse and movement.
local function restoreHeldInteraction(m, s)
    local o = spawnCheckpointObject(m, s)
    if o == nil then return false end
    trackRestoredObject(o, s)
    o.oHeldState = FREE
    o.oInteractType = s.spObjInteractType | INTERACT_GRABBABLE
    o.heldByPlayerIndex = 0
    m.heldObj = nil
    m.usedObj, m.interactObj = o, o
    mario_grab_used_object(m)
    restoreObjectFields(o, s)
    linkHeldObject(m, o, false)
    restoreMarioInteraction(m, s, OBJ_HELD)
    if penguinBehavior(s.spObjBhv) then
        o.oInteractStatus = 0
        if not sendObjectSync(o, true) then restoredObjectSyncFrames = 30 end
    end
    if objectBehaviorId(o) == id_bhvKoopaShellUnderwater then play_shell_music() end
    return true
end

-- Routes held items, shell rides and Bowser tail holds to their different restoration routines.
local function restoreCheckpointInteraction(m, s)
    local objectMode = s.spObjMode
    if objectMode == OBJ_NONE then return true end
    if objectMode == OBJ_SHELL then return restoreShellInteraction(m, s) end
    if objectMode == OBJ_BOWSER then
        local ok, restored = pcall(restoreBowserInteraction, m, s)
        return ok and restored or false
    end
    if objectMode == OBJ_HELD then return restoreHeldInteraction(m, s) end
    return true
end

---------------------------------------------------------------------------------------------------
-- Saving and loading
---------------------------------------------------------------------------------------------------

-- save() records the current moment. load() selects a slot and changes level or area if needed;
-- apply() restores it once that destination is ready. Princess's Secret Slide uses your own saved
-- time. Koopa the Quick's race keeps running for everyone, so loading there moves Mario without
-- rewinding the race.

-- Clears the pending load, including water and level-entry flags that must not carry over to the
-- next load.
local function resetLoad()
    loadMode, timer, loadSettle, lastLevel, lastArea, loadEntryArea = LOAD_NONE, 0, 0, nil, nil, nil
    loadSourceWasWater, loadUsedLevelWarp = false, false
end
 
-- Moves a warp-boundary save slightly to the safe side so loading does not immediately trigger the
-- warp again. Other saved positions are unchanged.
local function checkpointPos(s)
    local x, y, z = s.spX, s.spY, s.spZ
    if s.spIW == 0 then return x, y, z end
    local sx, sy, sz = sign(s.spDX), sign(s.spDY), sign(s.spDZ)
    if sx ~= 0 or sy ~= 0 or sz ~= 0 then
        x, y, z = x - sx * IW_OFFSET, y - sy * math.min(IW_OFFSET, 80), z - sz * IW_OFFSET
    else
        local a = s.spAngleY
        x, z = x - sins(a) * IW_OFFSET, z - coss(a) * IW_OFFSET
    end
    return x, y, z
end

-- Changes the components of a game-owned camera vector; replacing the vector itself is not safe.
local function setCameraVector(v, x, y, z)
    if v == nil then return end
    v.x, v.y, v.z = x or 0, y or 0, z or 0
end

-- Records the view seen when saving. Ignore an area camera left over from before a direct area
-- change.
local function captureCameraView(s, m)
    local c = m.area and m.area.index == s.spArea and m.area.camera or nil
    local l = gLakituState
    if l == nil or l.pos == nil or l.focus == nil then return end
    s.spCamValid = 1
    s.spCamPosX, s.spCamPosY, s.spCamPosZ = l.pos.x, l.pos.y, l.pos.z
    s.spCamFocusX, s.spCamFocusY, s.spCamFocusZ = l.focus.x, l.focus.y, l.focus.z
    s.spCamYaw = c and c.yaw or l.yaw or 0
    s.spCamNextYaw = c and c.nextYaw or l.nextYaw or 0
    s.spCamOldPitch, s.spCamOldYaw, s.spCamFocusDistance = l.oldPitch or 0, l.oldYaw or 0, l.focusDistance or 0
    s.spCamFocHSpeed, s.spCamFocVSpeed = l.focHSpeed or 0.8, l.focVSpeed or 0.3
    s.spCamPosHSpeed, s.spCamPosVSpeed = l.posHSpeed or 0.3, l.posVSpeed or 0.3
end

-- Snaps the camera to the saved view without changing Free or Analog Camera settings. A moved
-- Bowser platform shifts the whole view with Mario.
local function restoreCameraView(s, m)
    local c = m and m.area and m.area.index == s.spArea and m.area.camera or nil
    local l = gLakituState
    if s.spCamValid == 0 or l == nil then return false end
    -- A shared moving-platform load translates the whole saved view by Mario's safe-placement offset. The viewing
    -- angle stays the same while the camera remains beside Mario instead of inside the platform's old location.
    local dx, dy, dz = bossArena.cameraX, bossArena.cameraY, bossArena.cameraZ
    local px, py, pz = s.spCamPosX + dx, s.spCamPosY + dy, s.spCamPosZ + dz
    local fx, fy, fz = s.spCamFocusX + dx, s.spCamFocusY + dy, s.spCamFocusZ + dz
    if c ~= nil then
        setCameraVector(c.pos, px, py, pz); setCameraVector(c.focus, fx, fy, fz)
        c.yaw, c.nextYaw = s.spCamYaw, s.spCamNextYaw
    end
    setCameraVector(l.curPos, px, py, pz); setCameraVector(l.goalPos, px, py, pz); setCameraVector(l.pos, px, py, pz)
    setCameraVector(l.curFocus, fx, fy, fz); setCameraVector(l.goalFocus, fx, fy, fz); setCameraVector(l.focus, fx, fy, fz)
    l.yaw, l.nextYaw = s.spCamYaw, s.spCamNextYaw
    l.oldPitch, l.oldYaw, l.focusDistance = s.spCamOldPitch, s.spCamOldYaw, s.spCamFocusDistance
    l.focHSpeed, l.focVSpeed = s.spCamFocHSpeed, s.spCamFocVSpeed
    l.posHSpeed, l.posVSpeed = s.spCamPosHSpeed, s.spCamPosVSpeed
    skip_camera_interpolation()
    return true
end

-- Places Mario and the camera early while the destination finishes loading. This hides the normal
-- entrance fall or a sweep through the old area's terrain; apply() still restores the actual save.
local function stageCheckpoint(s, m, stopEntryAction)
    if s == nil or m == nil then return end
    local x, y, z = checkpointPos(s)
    if s.spBossSupport ~= 0 then
        local bx, by, bz = bossArena.resolvePosition(s)
        -- Destination objects may not exist on the first setup frame. Avoid previewing the stale absolute point;
        -- beforeMario() will retry and apply() will either find solid support or refuse the position explicitly.
        if bx == nil then return end
        x, y, z = bx, by, bz
    end
    bossArena.cameraX, bossArena.cameraY, bossArena.cameraZ = x - s.spX, y - s.spY, z - s.spZ
    m.pos.x, m.pos.y, m.pos.z = x, y, z
    m.vel.x, m.vel.y, m.vel.z, m.forwardVel, m.slideVelX, m.slideVelZ = 0, 0, 0, 0, 0, 0
    if m.marioObj ~= nil then
        m.marioObj.oPosX, m.marioObj.oPosY, m.marioObj.oPosZ = x, y, z
    end
    if stopEntryAction then
        m.flags = m.flags & ~MARIO_TELEPORTING
        set_mario_action(m, s.spSwim ~= 0 and ACT_WATER_IDLE or (s.spAir ~= 0 and ACT_FREEFALL or ACT_IDLE), 0)
        m.actionState, m.actionTimer, m.actionArg = 0, 0, 0
    end
    if m.area ~= nil and m.area.index == s.spArea and m.area.camera ~= nil then
        soft_reset_camera(m.area.camera)
    end
    cameraRestoreFrames = restoreCameraView(s, m) and CAMERA_RESTORE_FRAMES + LOAD_SETTLE_FRAMES or 0
    guardFrames, guardX, guardY, guardZ = LOAD_SETTLE_FRAMES + 1, x, y, z
end
 
-- Checks the shared Koopa race without changing it. Save/load must leave Koopa and everyone's race
-- progress running normally.
local function koopaRaceActive()
    local endpoint = obj_get_first_with_behavior_id(id_bhvKoopaRaceEndpoint)
    return endpoint ~= nil
        and (endpoint.oKoopaRaceEndpointRaceBegun or 0) ~= 0
        and (endpoint.oKoopaRaceEndpointRaceStatus or 0) == 0
end

-- Shows the local time. Only updateRaceTimer() advances it; extra HUD passes must not count extra
-- frames.
local function showRaceTimer(value)
    hud_set_value(HUD_DISPLAY_TIMER, value)
    hud_set_value(HUD_DISPLAY_FLAGS, hud_get_value(HUD_DISPLAY_FLAGS) | HUD_DISPLAY_FLAG_TIMER)
end

-- Checks whether this player is still in the area that owns the restored timer.
local function inPrivateTimerArea(m, n)
    return n ~= nil and n.currLevelNum == raceTimerLevel and playerArea(m, n) == raceTimerArea
end

-- Shows your PSS time, or hides another player's unrelated HUD time. Runs before slide finish
-- logic and again after the game's HUD updates.
local function enforcePrivateSlideHud(m, n)
    if n == nil or n.currLevelNum ~= LEVEL_PSS then return end
    if raceTimerOverride and inPrivateTimerArea(m, n) then
        showRaceTimer(raceTimerValue)
    else
        hud_set_value(HUD_DISPLAY_FLAGS, hud_get_value(HUD_DISPLAY_FLAGS) & ~HUD_DISPLAY_FLAG_TIMER)
    end
end

-- Clears the local clock. Passing false leaves the shared Koopa timer alone; PSS never uses native
-- timer control because each player needs their own time.
local function clearRaceTimerOverride(hideNative)
    local n = gNetworkPlayers[0]
    local privateSlide = raceTimerLevel == LEVEL_PSS or (n ~= nil and n.currLevelNum == LEVEL_PSS)
    raceTimerOverride, raceTimerRunning = false, false
    raceTimerValue, raceTimerHold = 0, 0
    raceTimerLevel, raceTimerArea = -1, -1
    if hideNative == false then return end
    if not privateSlide and level_control_timer ~= nil then level_control_timer(TIMER_CONTROL_HIDE) end
    hud_set_value(HUD_DISPLAY_FLAGS, hud_get_value(HUD_DISPLAY_FLAGS) & ~HUD_DISPLAY_FLAG_TIMER)
end

-- Checks for the normal slide reward before creating a fallback, to avoid awarding the same star
-- twice.
local function pssTimeTrialStarExists()
    local index = gLevelValues.pssSlideStarIndex
    local o = obj_get_first_with_behavior_id(id_bhvSpawnedStar)
    while o ~= nil do
        if ((o.oBehParams or 0) >> 24) & 0xFF == index then return true end
        o = obj_get_next_with_same_behavior_id(o)
    end
    return false
end

-- Creates the under-time star locally if the shared finish logic missed this player's qualifying
-- run.
local function restoreMissedPssStar(m)
    if raceTimerValue >= gLevelValues.pssSlideStarTime or pssTimeTrialStarExists()
        or m.marioObj == nil then return end
    local pos, index = gLevelValues.starPositions.PssSlideStarPos, gLevelValues.pssSlideStarIndex
    spawn_non_sync_object(id_bhvSpawnedStar, E_MODEL_STAR, pos.x, pos.y, pos.z, function(o)
        o.oBehParams, o.oBehParams2ndByte = index << 24, index
    end)
end

-- Starts or finishes your PSS clock when you touch the timer surfaces. Other players' timer writes
-- must not start or stop your run.
local function updatePrivateSlideSurface(m)
    local n = gNetworkPlayers[0]
    if n == nil or n.currLevelNum ~= LEVEL_PSS then return end
    local area, floorType = playerArea(m, n), m.floor and m.floor.type
    if floorType == SURFACE_TIMER_START then
        if not raceTimerOverride or not raceTimerRunning
            or raceTimerLevel ~= n.currLevelNum or raceTimerArea ~= area then
            raceTimerOverride, raceTimerRunning = true, true
            raceTimerValue, raceTimerHold = 0, 1
            raceTimerLevel, raceTimerArea = n.currLevelNum, area
            showRaceTimer(0)
        end
    elseif floorType == SURFACE_TIMER_END and raceTimerOverride
        and raceTimerLevel == n.currLevelNum and raceTimerArea == area then
        local finishedNow = raceTimerRunning
        raceTimerRunning = false
        showRaceTimer(raceTimerValue)
        if finishedNow then restoreMissedPssStar(m) end
    end
end

-- Loads the selected save: checks the arena, lets go of the current item, then restores Mario,
-- inventory, time, view and saved interaction. The order matters because game setup can otherwise
-- overwrite restored state.
local function apply(m)
    local s = localCheckpoint
    if s == nil then resetLoad() return end
    local arenaPlan = bossArena.plan(s)
    if arenaPlan.blocked then
        resetLoad()
        djui_popup_create("\\#dd3232\\" .. arenaPlan.notice .. "\\#dd3232\\", 3)
        return
    end
    local sourceWasWater, usedLevelWarp = loadSourceWasWater, loadUsedLevelWarp
    bossArena.cameraX, bossArena.cameraY, bossArena.cameraZ =
        arenaPlan.x - s.spX, arenaPlan.y - s.spY, arenaPlan.z - s.spZ

    interactionRetryFrames, bowserWorldRetryFrames = 0, 0
    shellRestoreFrames, shellRestoreAttempts = 0, 0
    bowserWorldAnimObject, bowserWorldAnimLocation, bowserWorldAnimFrame = nil, nil, 0
    -- Discard a previous load's unconsumed instant-warp guard.
    guardFrames = 0
    local deferShell = s.spObjMode == OBJ_SHELL and (m.riddenObj ~= nil or usedLevelWarp)
    releaseCurrentInteraction(m)
 
    local x, y, z = checkpointPos(s)
    if bossArena.isLevel(s.spLevel) then x, y, z = arenaPlan.x, arenaPlan.y, arenaPlan.z end
    m.pos.x, m.pos.y, m.pos.z = x, y, z
    m.faceAngle.x, m.faceAngle.y, m.faceAngle.z = s.spAngleX, s.spAngleY, s.spAngleZ
    m.vel.x, m.vel.y, m.vel.z, m.forwardVel, m.slideVelX, m.slideVelZ = 0, 0, 0, 0, 0, 0
    -- Sync Mario's graph immediately to prevent repeated-load Y drift.
    if m.marioObj ~= nil then
        m.marioObj.oPosX, m.marioObj.oPosY, m.marioObj.oPosZ = x, y, z
        m.marioObj.oMoveAngleYaw = s.spAngleY
        if arenaPlan.support ~= nil then m.marioObj.platform = arenaPlan.support end
    end
 
    if m.area ~= nil then m.area.numRedCoins, m.area.numSecrets = s.spRedCoins, s.spSecrets end
    if keepCoins then m.numCoins = s.spCoins end
    m.numLives, m.numKeys = s.spLives, s.spKeys
    local capMask = MARIO_CAPS | MARIO_CAP_ON_HEAD | MARIO_CAP_IN_HAND
    m.flags = (m.flags & ~capMask) | (s.spCapFlags & capMask)
    if usedLevelWarp then m.flags = m.flags & ~MARIO_TELEPORTING end
    m.capTimer = s.spCapTimer

    ownedGone, ownedGoneLocation = decodeSet(s.spGone), locationKey(s.spLevel, s.spArea)
    collectedByArea[ownedGoneLocation] = copySet(ownedGone)
    worldScanTicker = 0

    -- A shared Koopa race owns its timer and moving Koopa; loading changes Mario only.
    if koopaRaceActive() or s.spSharedRace ~= 0 then
        clearRaceTimerOverride(false)
    else
        -- Independent timers such as Princess's Slide resume from this player's frame.
        raceTimerValue, raceTimerOverride = s.spTimer, s.spTimerOn ~= 0
        raceTimerRunning = s.spTimerOn == 1
        raceTimerHold, raceTimerLevel, raceTimerArea = raceTimerOverride and 1 or 0,
            raceTimerOverride and s.spLevel or -1, raceTimerOverride and s.spArea or -1
        if raceTimerOverride then
            -- PSS stays HUD-only for per-player ownership. Other timer types may need native show/start
            -- control as well as the HUD value to resume their game logic.
            if s.spLevel ~= LEVEL_PSS and level_control_timer ~= nil then
                level_control_timer(TIMER_CONTROL_SHOW)
                if raceTimerRunning then level_control_timer(TIMER_CONTROL_START) end
            end
            showRaceTimer(raceTimerValue)
        else
            clearRaceTimerOverride()
        end
    end

    local savedFlight, savedBubble = s.spAir == 2, s.spAir == 3
    m.health = savedBubble and s.spHP or (fullHP and maxHP or s.spHP)
    -- Flight uses the exact saved action/momentum. Bubble creation must go through the native helper so its local
    -- counter, model, camera status, and revive rules exist; restoring lives immediately undoes its built-in death.
    local neutralAction
    if savedBubble then
        set_mario_action(m, ACT_IDLE, 0)
        mario_set_bubbled(m)
        m.numLives, m.health = s.spLives, s.spHP
        restoreMarioMotion(m, s)
        neutralAction = ACT_BUBBLED
        if m.marioObj ~= nil then m.marioObj.oIntangibleTimer = -1 end
    elseif savedFlight then
        restoreMarioMotion(m, s, ACT_FLYING)
        m.faceAngle.x, m.faceAngle.y, m.faceAngle.z = s.spAngleX, s.spAngleY, s.spAngleZ
        neutralAction = ACT_FLYING
    else
        -- A land checkpoint loaded from water spends one normal update in WATER_IDLE. Native water-exit logic then
        -- selects ACT_IDLE and resets the low water camera; ordinary ground/air/water loads remain unchanged.
        neutralAction = s.spSwim ~= 0 and ACT_WATER_IDLE
            or (sourceWasWater and s.spAir == 0 and ACT_WATER_IDLE)
            or (s.spAir ~= 0 and ACT_FREEFALL or ACT_IDLE)
        set_mario_action(m, neutralAction, 0)
        m.actionState, m.actionTimer, m.actionArg = 0, 0, 0
    end
    if not savedBubble then
        if m.marioObj ~= nil then m.marioObj.oIntangibleTimer = 0 end
        -- Two protected frames absorb an immediate overlap after loading but stay below CoopDX's three-frame
        -- visibility threshold, so Mario remains steadily visible instead of blinking for half a second.
        m.hurtCounter, m.invincTimer = 0, 2
    end
 
    -- A neutral status and soft reset still clear underwater camera carryover. Priming every current/goal
    -- camera point with the checkpoint view prevents that reset from creating a slow altitude transition.
    if m.statusForCamera ~= nil then m.statusForCamera.action = neutralAction end
    if m.area ~= nil and m.area.index == s.spArea and m.area.camera ~= nil then
        soft_reset_camera(m.area.camera)
    end
    cameraRestoreFrames = restoreCameraView(s, m) and CAMERA_RESTORE_FRAMES or 0

    -- A full cross-level entry can still be drawing its star-shaped arrival wipe when Mario becomes ready. Replace
    -- only that active entry with the shortest safe fade; same-area and instant area changes never touch transitions.
    if usedLevelWarp and is_transition_playing() then
        play_transition(WARP_TRANSITION_FADE_FROM_COLOR, 2, 0, 0, 0)
    end
 
    if s.spIW ~= 0 or (arenaPlan.rewind and s.spBossTilt ~= 0) then
        guardFrames, guardX, guardY, guardZ = arenaPlan.rewind and 4 or 1, x, y, z
    end

    if deferShell then
        shellRestoreFrames, shellRestoreAttempts = 6, 30
    elseif not arenaPlan.heldBlocked and not restoreCheckpointInteraction(m, s) then
        if s.spObjMode == OBJ_BOWSER then
            -- Cross-area Bowser roots can appear a few frames after Mario.
            interactionRetryFrames = 30
        elseif s.spObjMode == OBJ_SHELL then
            shellRestoreFrames, shellRestoreAttempts = 1, 30
        elseif s.spObjMode == OBJ_HELD and penguinBehavior(s.spObjBhv) then
            penguinRestoreFrames = 30
        end
    end
    if s.spObjMode == OBJ_SHELL then
        m.quicksandDepth = 0
        if m.area and m.area.camera then soft_reset_camera(m.area.camera) end
        cameraRestoreFrames = restoreCameraView(s, m) and CAMERA_RESTORE_FRAMES or 0
    end
    if arenaPlan.rewind and not restoreBowserWorldSnapshot(s) then bowserWorldRetryFrames = 30 end
    refreshOwnedItems()
 
    m.particleFlags = PARTICLE_SPARKLES
    if m.marioObj ~= nil then play_sound(SOUND_MENU_CLICK_FILE_SELECT, m.marioObj.header.gfx.cameraToObject) end
    resetLoad()

    djui_popup_create("\\#6fd83f\\Loaded " .. SAVE_SLOTS[activeSlot].name .. " savepoint\\#6fd83f\\", 1)
    if arenaPlan.notice ~= nil then
        djui_popup_create("\\#e7b625\\" .. arenaPlan.notice .. "\\#e7b625\\", 3)
    end
end
 
-- Saves the current place and supported state to one D-pad slot. Each save gets a fresh table so
-- the other slots cannot change with it. Writes locally, with no checkpoint broadcast.
local function save(m, slot)
    local s, n = blankCheckpoint(), gNetworkPlayers[0]
    local date = get_date_and_time()
    s.spSavedYear, s.spSavedMonth, s.spSavedDay = date.year + 1900, date.month + 1, date.day
    s.spSavedHour, s.spSavedMinute = date.hour, date.minute
    localCheckpoints[slot] = s
    activeSlot, localCheckpoint = slot, s
    bossArena.cameraX, bossArena.cameraY, bossArena.cameraZ = 0, 0, 0
    s.spLevel, s.spArea = n.currLevelNum, playerArea(m, n)
    s.spAct, s.spHP = n.currActNum, m.health
    s.spX, s.spY, s.spZ = m.pos.x, m.pos.y, m.pos.z
    s.spAngleX, s.spAngleY, s.spAngleZ = m.faceAngle.x, m.faceAngle.y, m.faceAngle.z
    captureCameraView(s, m)
    s.spRedCoins, s.spCoins = m.area and m.area.numRedCoins or 0, m.numCoins
    s.spSecrets = m.area and m.area.numSecrets or 0
    s.spLives, s.spKeys = m.numLives, m.numKeys
    local capMask = MARIO_CAPS | MARIO_CAP_ON_HEAD | MARIO_CAP_IN_HAND
    s.spCapFlags, s.spCapTimer = m.flags & capMask, m.capTimer

    local items = currentAreaSet()
    local ridden = m.riddenObj
    local riddenId = ridden ~= nil and objectBehaviorId(ridden) or -1
    s.spShell = ((m.action & ACT_FLAG_RIDING_SHELL) ~= 0
        or riddenId == id_bhvKoopaShell
        or riddenId == id_bhvKoopaShellUnderwater) and 1 or 0
    s.spShellWater = riddenId == id_bhvKoopaShellUnderwater and 1 or 0
    s.spShellAction = s.spShell ~= 0 and m.action or 0

    local interactionObject, interactionMode = nil, OBJ_NONE
    if s.spShell ~= 0 then
        interactionObject, interactionMode = ridden, OBJ_SHELL
    else
        local held = m.heldObj
        local bowserAction = m.action == ACT_PICKING_UP_BOWSER or m.action == ACT_HOLDING_BOWSER
            or m.action == ACT_RELEASING_BOWSER
        if held == nil and (m.action == ACT_PICKING_UP_BOWSER or m.action == ACT_HOLDING_BOWSER) then
            held = m.usedObj or m.interactObj
        end
        if held ~= nil then
            interactionObject = held
            interactionMode = (bowserAction or isBowserObject(held)) and OBJ_BOWSER or OBJ_HELD
        end
    end
    captureInteraction(s, m, interactionObject, interactionMode)

    -- Flying and bubble states have no simultaneous object, so their action/momentum use the otherwise-empty
    -- interaction motion block without increasing or invalidating the persistent checkpoint format.
    if interactionMode == OBJ_NONE and (m.action == ACT_FLYING or m.action == ACT_BUBBLED) then
        captureMarioMotion(s, m)
    end

    -- Free Bowser state coexists with Mario's held or ridden object.
    if interactionMode ~= OBJ_BOWSER then
        captureBowserWorldSnapshot(s, findBowserForCheckpoint(s))
    end

    if s.spShell ~= 0 and ridden ~= nil then
        local rk = objectKey(ridden)
        if rk ~= nil then items[rk] = true end
    end
    s.spGone = encodeSet(items)
    local savedLocation = locationKey(s.spLevel, s.spArea)
    if ownedGoneLocation ~= savedLocation then
        -- A checkpoint saved elsewhere releases the previous area's hidden set.
        ownedGone, ownedGoneLocation = {}, nil
    end
    -- Koopa's race is globally shared, while slide timers remain player-private.
    s.spSharedRace = koopaRaceActive() and 1 or 0
    if s.spSharedRace ~= 0 then
        clearRaceTimerOverride(false)
    else
        local hudFlags = hud_get_value(HUD_DISPLAY_FLAGS)
        local timerVisible = (hudFlags & HUD_DISPLAY_FLAG_TIMER) ~= 0
        local timerRunning = level_control_timer_running()
        local restoredTimerHere = raceTimerOverride
            and s.spLevel == raceTimerLevel and s.spArea == raceTimerArea
        -- PSS ownership comes from player zero touching its start surface, never from the shared native HUD.
        -- For other timer types, the visible native timer remains the best signal that a race is active.
        s.spTimerOn = restoredTimerHere and (raceTimerRunning and 1 or 2)
            or ((s.spLevel ~= LEVEL_PSS and timerVisible and timerRunning) and 1 or 0)
        if s.spTimerOn ~= 0 then
            -- Resaves capture the displayed override, not a transient native value.
            s.spTimer = restoredTimerHere and raceTimerValue
                or hud_get_value(HUD_DISPLAY_TIMER)
        else
            clearRaceTimerOverride()
        end
    end

    s.spSwim = genuinelySwimming(m) and 1 or 0
    s.spAir = m.action == ACT_BUBBLED and 3 or (m.action == ACT_FLYING and 2
        or (s.spSwim == 0 and ((m.action & ACT_FLAG_AIR) ~= 0) and 1 or 0))
    s.spIW = (iwSurface(m.floor) or iwSurface(m.wall) or iwSurface(m.ceil)) and 1 or 0
    local recentIW = s.spIW ~= 0 and recentIWAge <= IW_RECENT
    s.spDX, s.spDY, s.spDZ = recentIW and recentDX or 0, recentIW and recentDY or 0, recentIW and recentDZ or 0
    bossArena.capture(s, m)
    if not writeCheckpoint(slot, packCheckpoint(s)) then
        djui_popup_create("\\#dd3232\\" .. SAVE_SLOTS[slot].name
            .. " save kept for this session; persistent file unavailable.\\#dd3232\\", 2)
    end
    m.particleFlags = PARTICLE_SPARKLES
    if m.marioObj ~= nil then play_sound(SOUND_MENU_CLICK_CHANGE_VIEW, m.marioObj.header.gfx.cameraToObject) end
    djui_popup_create("\\#e7b625\\Saved " .. SAVE_SLOTS[slot].name .. " savepoint\\#e7b625\\", 1)
end
 
-- Changes to the saved area or requests one full level entry. Internal areas without an entrance
-- use area 1 first. Never repeat a successful level warp: overlapping setup can duplicate objects.
local function requestWarp(s)
    local n = gNetworkPlayers[0]
    timer, loadSettle, lastLevel, lastArea = 0, 0, nil, nil
    loadMode = LOAD_LEVEL
    loadUsedLevelWarp = n == nil or n.currLevelNum ~= s.spLevel
    loadEntryArea = s.spArea
    if not loadUsedLevelWarp then
        smlua_level_util_change_area(s.spArea)
        -- change_area() is synchronous; stage before the next render so neither physics nor the new camera starts
        -- from the tunnel's opposite side while destination objects finish settling.
        stageCheckpoint(s, gMarioStates[0], false)
        return true
    end
    if not warp_to_level(s.spLevel, loadEntryArea, s.spAct) then
        -- Internal areas often have instant-warp connections but no painting/door entry node of their own.
        loadEntryArea = 1
        if s.spArea ~= 1 and warp_to_level(s.spLevel, loadEntryArea, s.spAct) then
            return true
        end
        resetLoad()
        djui_popup_create("\\#dd3232\\SavePoint destination is unavailable.\\#dd3232\\", 2)
        return false
    end
    return true
end

-- Skips the incoming star wipe only for a checkpoint load. Normal entries, deaths and menu travel
-- retain their transitions.
local function suppressCheckpointEntryTransition(kind)
    if loadUsedLevelWarp and kind == WARP_TRANSITION_FADE_FROM_STAR then return false end
end

-- Loads a D-pad slot now, or starts the level/area change needed to reach it. Empty slots show a
-- message. The slot is already in memory, so no file read or host request is needed.
local function load(m, slot)
    local s, n = localCheckpoints[slot], gNetworkPlayers[0]
    if s == nil then
        djui_popup_create("\\#dd3232\\No " .. SAVE_SLOTS[slot].name .. " savepoint saved.\\#dd3232\\", 1)
        return
    end
    -- A checkpoint request supersedes any unconsumed destination selected in the pause-menu level browser.
    queuedLevel, chosenActSelectLevel, queuedLoadSlot = nil, nil, nil
    bossArena.cameraX, bossArena.cameraY, bossArena.cameraZ = 0, 0, 0
    activeSlot, localCheckpoint = slot, s
    loadSourceWasWater = genuinelySwimming(m)
    local a = playerArea(m, n)
    local samePlace = atCheckpoint(s, m, n)
    if samePlace then
        if bossArena.waitForRoot(s) then
            loadMode, timer, loadSettle = LOAD_BOWSER, 0, 0
            lastLevel, lastArea = n.currLevelNum, a
        else
            apply(m)
        end
        return
    end
    requestWarp(s)
end
 
-- Finishes arrival before Mario's first movement update, so loading replaces the entrance fall
-- immediately. Also supplies your PSS time before the game checks the finish line.
local function beforeMario(m)
    if m.playerIndex ~= 0 then return end
    -- A pending shell is a short load stage, not an unprotected landing on lava/sand.
    if shellRestoreFrames > 0 then
        m.quicksandDepth, m.invincTimer = 0, 2
    end
    -- pss_end_slide() reads this HUD value during Mario's update; the same pass hides an unrelated remote value.
    enforcePrivateSlideHud(m, gNetworkPlayers[0])
    if loadMode == LOAD_NONE then return end
    local s, n = localCheckpoint, gNetworkPlayers[0]
    if loadUsedLevelWarp and s ~= nil and n ~= nil and n.currLevelNum == s.spLevel
        and loadEntryArea ~= nil and loadEntryArea ~= s.spArea and playerArea(m, n) == loadEntryArea
        and m.area ~= nil and m.area.index == loadEntryArea and m.area.camera ~= nil and m.marioObj ~= nil then
        smlua_level_util_change_area(s.spArea)
        loadEntryArea, loadSettle = s.spArea, 0
        stageCheckpoint(s, m, true)
        return
    end
    if not destinationReady(s, m, n) then loadSettle = 0 return end
    loadSettle = loadSettle + 1
    if loadSettle < (loadUsedLevelWarp and 1 or LOAD_SETTLE_FRAMES) then return end
    if loadUsedLevelWarp and s.spBossSupport ~= 0 and bossArena.findSupport(s) == nil then
        if loadMode ~= LOAD_BOWSER then timer, loadMode = 0, LOAD_BOWSER end
        return
    end
    -- Never attach before native Bowser sync and callbacks are initialized.
    if bossArena.waitForRoot(s) then
        if loadMode ~= LOAD_BOWSER then timer, loadMode = 0, LOAD_BOWSER end
        stageCheckpoint(s, m, true)
        return
    end
    apply(m)
end

-- Rejects input during cutscenes, death or teleport setup. Checkpoints allow a floating bubble;
-- player visits reject it separately.
local function blocked(m)
    if m == nil then return true end
    if m.action == ACT_BUBBLED then return false end
    return m.health <= 0
        or (m.action & ACT_GROUP_MASK) == ACT_GROUP_CUTSCENE
        or (m.action & ACT_FLAG_INTANGIBLE) ~= 0
        or (m.flags & MARIO_TELEPORTING) ~= 0
end

-- Handles this player's D-pad save/load buttons. During an unfinished load, keeps only the latest
-- requested slot instead of starting overlapping level changes.
local function marioUpdate(m)
    if m.playerIndex ~= 0 then return end
    if playerTravel.busy then return end
    updatePrivateSlideSurface(m)
    if m.health > maxHP then maxHP = m.health end
    local pressed = m.controller.buttonPressed
    if (pressed & SAVE_BUTTON_MASK) == 0 then return end
    local slot = DEFAULT_SLOT
    for i, data in ipairs(SAVE_SLOTS) do if (pressed & data.button) ~= 0 then slot = i break end end
    local loading = (m.controller.buttonDown & L_TRIG) ~= 0
    if loadMode ~= LOAD_NONE then
        if loading then queuedLoadSlot = slot end
        return
    end
    if blocked(m) then return end
    cameraRestoreFrames = 0
    if loading then load(m, slot) else save(m, slot) end
end
 
---------------------------------------------------------------------------------------------------
-- After a load
---------------------------------------------------------------------------------------------------

-- Some parts of a load need a few game updates to finish. These callbacks wait for objects and
-- level setup, keep the camera in place briefly, and maintain local timers and pickup visibility.
-- Each stops its restoration work when finished or timed out; it must not keep restarting a warp.

-- Finishes active Bowser work in order. If an engine call fails, reveals the held boss and clears
-- temporary restoration state rather than leaving an invisible boss.
local function updateBowserRuntime()
    if bowserRestoreObject == nil and heldBowserRoot == nil and bowserWorldAnimObject == nil then return end
    local bowserOk = pcall(function()
        advanceBowserRestore(); maintainHeldBowserWorldGraph(); finishBowserWorldAnimationRestore()
    end)
    if not bowserOk then
        if heldBowserRoot ~= nil and currentLocationKey() == heldBowserLocation then
            setBowserWorldGraphActive(heldBowserRoot, true)
        end
        heldBowserRoot, heldBowserLocation = nil, nil
        clearBowserRestoreState()
        bowserWorldAnimObject, bowserWorldAnimLocation, bowserWorldAnimFrame = nil, nil, 0
    end
end

-- Retries the restored shell's first state send for up to thirty frames while its network slot
-- becomes ready.
local function updateRestoredObjectSync()
    if restoredObjectSyncFrames <= 0 then return end
    if not restoredObjectIsLive() or restoredObjectLocation ~= currentLocationKey()
        or sendObjectSync(restoredObject, true) then
        restoredObjectSyncFrames = 0
    else
        restoredObjectSyncFrames = restoredObjectSyncFrames - 1
    end
end

-- Waits for the previous shell's deletion before recreating a ride. Otherwise a delayed deletion
-- packet can remove the replacement shell on another player's screen.
local function updateDelayedShellRestore()
    if shellRestoreFrames <= 0 then return end
    local m, n, s = gMarioStates[0], gNetworkPlayers[0], localCheckpoint
    if m == nil or n == nil or s == nil or s.spObjMode ~= OBJ_SHELL or not atCheckpoint(s, m, n) then
        shellRestoreFrames, shellRestoreAttempts = 0, 0
        return
    end

    local x, y, z = checkpointPos(s)
    m.pos.x, m.pos.y, m.pos.z = x, y, z
    m.vel.x, m.vel.y, m.vel.z, m.forwardVel, m.slideVelX, m.slideVelZ = 0, 0, 0, 0, 0, 0
    if m.marioObj ~= nil then
        m.marioObj.oPosX, m.marioObj.oPosY, m.marioObj.oPosZ = x, y, z
    end
    shellRestoreFrames = shellRestoreFrames - 1
    if shellRestoreFrames > 0 then return end
    if restoreShellInteraction(m, s) then
        shellRestoreAttempts = 0
        if m.area and m.area.camera then soft_reset_camera(m.area.camera) end
        cameraRestoreFrames = restoreCameraView(s, m) and CAMERA_RESTORE_FRAMES or 0
        refreshOwnedItems()
    elseif shellRestoreAttempts > 1 then
        shellRestoreAttempts, shellRestoreFrames = shellRestoreAttempts - 1, 1
    else
        shellRestoreAttempts = 0
        djui_popup_create("Shell unavailable; checkpoint position loaded.", 3)
    end
end

-- Looks for the real shell near a remote rider so a cosmetic fallback does not draw a second one.
local function remoteHasNativeShell(m)
    if m == nil or m.marioObj == nil then return false end
    for _, bhv in ipairs({id_bhvKoopaShell, id_bhvKoopaShellUnderwater}) do
        local o = obj_get_first_with_behavior_id(bhv)
        while o ~= nil do
            local dx, dy, dz = o.oPosX - m.pos.x, o.oPosY - m.pos.y, o.oPosZ - m.pos.z
            if (o.oAction or 0) == 1 and dx * dx + dy * dy + dz * dz < 40000 then return true end
            o = obj_get_next_with_same_behavior_id(o)
        end
    end
    return false
end

-- Announces stable rides and maintains remote fallback models where the real shell is missing.
-- Late joiners get a resend; there are no per-frame packets.
local function updateRemoteShellVisuals()
    local localMario, localNetwork = gMarioStates[0], gNetworkPlayers[0]
    if localMario == nil or localNetwork == nil then return end
    local riding = localMario.riddenObj ~= nil
    if shellVisual.pending > 0 then
        if localCheckpoint == nil or not atCheckpoint(localCheckpoint, localMario, localNetwork) then
            shellVisual.pending = 0
        elseif riding then
            shellVisual.pending = shellVisual.pending - 1
            if shellVisual.pending == 0 then publishShellVisual(localCheckpoint, true) end
        else
            shellVisual.pending = 30
        end
    end
    if shellVisual.active then
        if riding and shellVisual.level == localNetwork.currLevelNum
            and shellVisual.area == playerArea(localMario, localNetwork) then
            shellVisual.lost = 0
        else
            shellVisual.lost = shellVisual.lost + 1
            if shellVisual.lost > 90 then
                publishShellVisual(nil, false)
                if localCheckpoint ~= nil and localCheckpoint.spObjMode == OBJ_SHELL
                    and atCheckpoint(localCheckpoint, localMario, localNetwork) then shellVisual.pending = 1 end
            end
        end
    end
    local connected = network_player_connected_count()
    if connected ~= shellVisual.playerCount then
        shellVisual.playerCount = connected
        if shellVisual.active then shellVisual.resend = 30 end
    elseif shellVisual.resend > 0 then
        shellVisual.resend = shellVisual.resend - 1
        if shellVisual.resend == 0 and shellVisual.active then publishShellVisual(nil, true) end
    end

    -- Keep local announcements above running even with no remote riders to draw.
    if next(shellVisual.states) == nil and next(shellVisual.visuals) == nil then return end
    local wanted = {}
    for i = 1, MAX_PLAYERS - 1 do
        local n, m = gNetworkPlayers[i], gMarioStates[i]
        local key = n and n.globalIndex or -1
        local state = shellVisual.states[key]
        local active = key >= 0 and n.connected and m ~= nil and m.marioObj ~= nil and state ~= nil
            and n.currLevelNum == localNetwork.currLevelNum
            and playerArea(m, n) == playerArea(localMario, localNetwork)
            and state.level == localNetwork.currLevelNum
            and state.area == playerArea(localMario, localNetwork)
        if active then
            wanted[key] = true
            local visual = shellVisual.visuals[key]
            if remoteHasNativeShell(m) then
                if visual ~= nil then pcall(obj_mark_for_deletion, visual) shellVisual.visuals[key] = nil end
            else
                if visual == nil or visual.activeFlags == DEACTIVATED then
                    visual = spawn_non_sync_object(id_bhvStaticObject, E_MODEL_KOOPA_SHELL,
                        m.pos.x, m.pos.y, m.pos.z, function(o)
                            o.oFlags, o.oInteractType, o.oIntangibleTimer = OBJ_FLAG_UPDATE_GFX_POS_AND_ANGLE, 0, -1
                    end)
                    shellVisual.visuals[key] = visual
                end
                if visual ~= nil then
                    visual.oPosX, visual.oPosY, visual.oPosZ = m.pos.x, m.pos.y, m.pos.z
                    visual.oMoveAngleYaw, visual.oFaceAngleYaw = m.faceAngle.y, m.faceAngle.y
                end
            end
        end
    end
    for key, visual in pairs(shellVisual.visuals) do
        if not wanted[key] then
            if visual ~= nil then pcall(obj_mark_for_deletion, visual) end
            shellVisual.visuals[key] = nil
        end
    end
    for key in pairs(shellVisual.states) do
        local i = network_local_index_from_global(key)
        local n = i ~= nil and i >= 0 and i < MAX_PLAYERS and gNetworkPlayers[i] or nil
        if n == nil or not n.connected or n.globalIndex ~= key then shellVisual.states[key] = nil end
    end
end

-- Advances your private clock once per game update. The first update after loading holds the saved
-- value; leaving the area clears it.
local function updateRaceTimer()
    if not raceTimerOverride then return end
    local m, n = gMarioStates[0], gNetworkPlayers[0]
    if not inPrivateTimerArea(m, n) then
        clearRaceTimerOverride()
        return
    end

    if raceTimerHold > 0 then raceTimerHold = raceTimerHold - 1
    elseif raceTimerRunning and raceTimerValue < 17999 then raceTimerValue = raceTimerValue + 1 end
    showRaceTimer(raceTimerValue)
end

-- Retries free and held Bowser restoration for a limited time. Leaving the area or another player
-- joining the fight cancels both.
local function updateBowserRetries()
    if bowserWorldRetryFrames <= 0 and interactionRetryFrames <= 0 then return end
    local m, n, s = gMarioStates[0], gNetworkPlayers[0], localCheckpoint
    local inArea = atCheckpoint(s, m, n)
    if bossArena.otherPresent(s) then
        bowserWorldRetryFrames, interactionRetryFrames = 0, 0
        return
    end

    if bowserWorldRetryFrames > 0 then
        if not inArea or s.spBowserWorld == 0 or restoreBowserWorldSnapshot(s) then
            bowserWorldRetryFrames = 0
        else
            bowserWorldRetryFrames = bowserWorldRetryFrames - 1
        end
    end

    if interactionRetryFrames > 0 then
        if not inArea or s.spObjMode ~= OBJ_BOWSER
            or (m.heldObj ~= nil and not isBowserObject(m.heldObj)) then
            interactionRetryFrames = 0
        elseif restoreBowserInteraction(m, s) then
            interactionRetryFrames = 0
            refreshOwnedItems()
        else
            interactionRetryFrames = interactionRetryFrames - 1
        end
    end
end

-- Times out a stalled load without issuing another warp. Actual level/area progress restarts the
-- wait; Bowser initialization gets a longer limit.
local function updatePendingLoad()
    if loadMode == LOAD_NONE then return end
    local m, n, s = gMarioStates[0], gNetworkPlayers[0], localCheckpoint
    if m == nil or n == nil or s == nil then return end
    local a = playerArea(m, n)
    if n.currLevelNum ~= lastLevel or a ~= lastArea then
        lastLevel, lastArea, timer, loadSettle = n.currLevelNum, a, 0, 0
    else timer = timer + 1 end
    local timeout = loadMode == LOAD_BOWSER and BOWSER_READY_TIMEOUT or LOAD_TIMEOUT
    if timer >= timeout then
        resetLoad()
        djui_popup_create("\\#dd3232\\SavePoint load stopped; press load again.\\#dd3232\\", 2)
    end
end

-- Runs the delayed load work, then any queued slot or level choice. Pickup visibility is checked
-- every third update, not every frame.
local function update()
    if penguinRestoreFrames > 0 then
        local m, n, s = gMarioStates[0], gNetworkPlayers[0], localCheckpoint
        if not atCheckpoint(s, m, n) or m.heldObj ~= nil then
            penguinRestoreFrames = 0
        elseif restoreHeldInteraction(m, s) then
            penguinRestoreFrames = 0
            refreshOwnedItems()
        else
            penguinRestoreFrames = penguinRestoreFrames - 1
            if penguinRestoreFrames == 0 then
                djui_popup_create("Saved penguin unavailable or held by another player. Position loaded without it.", 3)
            end
        end
    end
    updateBowserRuntime()
    if not pcall(updateDelayedShellRestore) then shellRestoreFrames, shellRestoreAttempts = 0, 0 end
    updateRemoteShellVisuals(); updateRestoredObjectSync(); updateRaceTimer()
    updateBowserRetries()
    if recentIWAge <= IW_RECENT then recentIWAge = recentIWAge + 1 end
    worldScanTicker = worldScanTicker + 1
    if worldScanTicker >= 3 then worldScanTicker = 0; refreshOwnedItems() end
    updatePendingLoad()
    if loadMode == LOAD_NONE and queuedLoadSlot ~= nil then
        local m = gMarioStates[0]
        if m ~= nil and not blocked(m) then
            local slot = queuedLoadSlot
            queuedLoadSlot = nil
            load(m, slot)
        end
    end
    if queuedLevel ~= nil and not djui_hud_is_pause_menu_created() then
        if gGlobalSyncTable.spSaveLoadOnly then queuedLevel = nil; travelRestricted(); return end
        local level = queuedLevel
        queuedLevel = nil
        queuedLoadSlot = nil
        resetLoad(); cameraRestoreFrames = 0; clearRaceTimerOverride()
        chosenActSelectLevel = get_level_course_num(level) ~= COURSE_NONE and level or nil
        if is_game_paused() then game_unpause() end
        initiate_warp(level, 1, 0x0A, WARP_ARG_EXIT_COURSE)
        fade_into_special_warp(0, 0)
    end
end

-- Keeps the saved view for a few frames after normal camera processing, and corrects the local
-- timer display without advancing it.
local function latePlayModeRestore()
    if cameraRestoreFrames > 0 then
        local m, n = gMarioStates[0], gNetworkPlayers[0]
        if atCheckpoint(localCheckpoint, m, n) and restoreCameraView(localCheckpoint, m) then
            cameraRestoreFrames = cameraRestoreFrames - 1
        elseif loadMode == LOAD_NONE then
            cameraRestoreFrames = 0
        end
    end
    local m, n = gMarioStates[0], gNetworkPlayers[0]
    enforcePrivateSlideHud(m, n)
    if raceTimerOverride and n ~= nil and n.currLevelNum ~= LEVEL_PSS and inPrivateTimerArea(m, n) then
        showRaceTimer(raceTimerValue)
    end
end
 

---------------------------------------------------------------------------------------------------
-- Pickup and warp hooks
---------------------------------------------------------------------------------------------------

-- The game tells us when Mario collects an item or crosses an instant warp. We record those events
-- for the next save. A brief movement guard during loading prevents the destination's warp surface
-- or changing platform from moving Mario before the load finishes.

-- Records your successful coin and 1-Up pickups for the next save. Remote pickups do not change
-- this history.
local function onInteract(m, o, interactType, interactValue)
    if interactValue == false or m == nil or m.playerIndex ~= 0 or not isOwnedItem(o, interactType) then return end
    local k = objectKey(o)
    if k == nil then return end
    currentAreaSet()[k] = true
end

-- Blocks your interaction with hidden pickups or a replaced item's original. Other players and the
-- playable restored item remain unaffected.
local function allowInteract(m, o, interactType)
    if m == nil or m.playerIndex ~= 0 or o == nil then return end
    if o == restoredObject or o == m.heldObj or o == m.riddenObj then return end
    local here = currentLocationKey()
    local source = here == restoredObjectLocation and restoredObjectSourceKey ~= nil
        and (restoredObjectSourceBehavior == nil or restoredObjectSourceBehavior == 0
            or objectBehaviorId(o) == restoredObjectSourceBehavior)
    local owned = here == ownedGoneLocation and isOwnedItem(o, interactType)
    if not source and not owned then return end
    local k = objectKey(o)
    if k ~= nil and ((source and k == restoredObjectSourceKey) or (owned and ownedGone[k])) then return false end
end

-- Keeps the latest warp displacement briefly so a save on its boundary can load on the correct
-- side.
local function instantWarp(_area, _id, d)
    recentIWAge = 0
    recentDX, recentDY, recentDZ = 0, 0, 0
    if d ~= nil then recentDX, recentDY, recentDZ = d.x or 0, d.y or 0, d.z or 0 end
end
 
-- Holds Mario at the corrected point during a short warp/platform guard. The return value tells
-- the relevant movement step not to move him again.
local function beforePhys(m, step)
    if m.playerIndex ~= 0 then return end
    if shellRestoreFrames > 0 then
        if step == STEP_TYPE_GROUND then return GROUND_STEP_NONE end
        if step == STEP_TYPE_AIR then return AIR_STEP_NONE end
        if step == STEP_TYPE_WATER then return WATER_STEP_NONE end
        return 0
    end
    if guardFrames <= 0 then return end
    m.pos.x, m.pos.y, m.pos.z = guardX, guardY, guardZ
    m.vel.x, m.vel.y, m.vel.z, m.forwardVel = 0, 0, 0, 0
    guardFrames = guardFrames - 1
    if step == STEP_TYPE_GROUND then return GROUND_STEP_NONE end
    if step == STEP_TYPE_AIR then return AIR_STEP_NONE end
    if step == STEP_TYPE_WATER then return WATER_STEP_NONE end
    return 0
end
 
---------------------------------------------------------------------------------------------------
-- Choosing a level
---------------------------------------------------------------------------------------------------

-- The pause menu lists the standard levels, including secret courses and Bowser fights. Pick one
-- and close the menu to travel there without meeting its star requirement. Courses open their act
-- screen; castle areas load directly. This does not create or overwrite a save.

-- Every playable vanilla area is listed once; separate Bowser battle maps are named explicitly so they cannot be
-- confused with their obstacle courses. The numeric level constants remain authoritative for the actual warp.
local LEVEL_MENU = {
    {LEVEL_CASTLE_GROUNDS, "Castle Grounds"}, {LEVEL_CASTLE, "Inside the Castle"},
    {LEVEL_CASTLE_COURTYARD, "Castle Courtyard"}, {LEVEL_BOB, "Bob-omb Battlefield"},
    {LEVEL_WF, "Whomp's Fortress"}, {LEVEL_JRB, "Jolly Roger Bay"},
    {LEVEL_CCM, "Cool, Cool Mountain"}, {LEVEL_BBH, "Big Boo's Haunt"},
    {LEVEL_HMC, "Hazy Maze Cave"}, {LEVEL_LLL, "Lethal Lava Land"},
    {LEVEL_SSL, "Shifting Sand Land"}, {LEVEL_DDD, "Dire, Dire Docks"},
    {LEVEL_SL, "Snowman's Land"}, {LEVEL_WDW, "Wet-Dry World"},
    {LEVEL_TTM, "Tall, Tall Mountain"}, {LEVEL_THI, "Tiny-Huge Island"},
    {LEVEL_TTC, "Tick Tock Clock"}, {LEVEL_RR, "Rainbow Ride"},
    {LEVEL_PSS, "The Princess's Secret Slide"}, {LEVEL_SA, "The Secret Aquarium"},
    {LEVEL_TOTWC, "Tower of the Wing Cap"}, {LEVEL_VCUTM, "Vanish Cap Under the Moat"},
    {LEVEL_COTMC, "Cavern of the Metal Cap"}, {LEVEL_WMOTR, "Wing Mario Over the Rainbow"},
    {LEVEL_BITDW, "Bowser in the Dark World"}, {LEVEL_BOWSER_1, "Bowser in the Dark World - Battle"},
    {LEVEL_BITFS, "Bowser in the Fire Sea"}, {LEVEL_BOWSER_2, "Bowser in the Fire Sea - Battle"},
    {LEVEL_BITS, "Bowser in the Sky"}, {LEVEL_BOWSER_3, "Bowser in the Sky - Battle"},
}

-- Queues the selected level. Travel waits for the pause menu to close because Lua cannot safely
-- close that native panel itself.
local function chooseLevel(entry)
    if travelRestricted() then return end
    menuPages.loadSlot = nil
    queuedLevel = entry[1]
    djui_popup_create(entry[2] .. " selected.\nClose the pause menu to travel.", 2)
end

-- Opens the chosen course's act screen once. Unrelated level entries keep the game's normal
-- decision.
local function useChosenActSelect(level)
    if level ~= chosenActSelectLevel then return end
    chosenActSelectLevel = nil
    return true
end

---------------------------------------------------------------------------------------------------
-- Load preferences and hooks
---------------------------------------------------------------------------------------------------

-- The menu and chat commands let you choose full health on load and whether to restore saved
-- coins. Both settings apply only to you for this session. The registrations below connect saving,
-- loading and their follow-up work to the appropriate game updates.

-- Toggles full health on load with /fullhp or /fh. The preferences page reads the same value. Does not change
-- the health stored in a save.
local function fullhp()
    fullHP = not fullHP
    djui_chat_message_create("Full HP on load: " .. (fullHP and "\\#6fd83f\\enabled\\#6fd83f\\" or "\\#dd3232\\disabled\\#dd3232\\"))
    return true
end
 
-- Toggles saved-coin restoration with /keepcoin or /kc. The preferences page reads the same value. Other saved
-- inventory is unchanged.
local function keepcoin()
    keepCoins = not keepCoins
    djui_chat_message_create("Keep coins on load: " .. (keepCoins and "\\#6fd83f\\enabled\\#6fd83f\\" or "\\#dd3232\\disabled\\#dd3232\\"))
    return true
end

-- Keep this order: arrival and PSS finish checks run before Mario, input during his
-- update, then delayed object work and finally camera/HUD correction.
hook_event(HOOK_BEFORE_MARIO_UPDATE, beforeMario)
hook_event(HOOK_MARIO_UPDATE, marioUpdate)
hook_event(HOOK_UPDATE, update)
hook_event(HOOK_ON_PLAY_MODE_UPDATE, latePlayModeRestore)
hook_event(HOOK_ON_INSTANT_WARP, instantWarp)
hook_event(HOOK_BEFORE_PHYS_STEP, beforePhys)
-- Protect only this player's brief shell setup, not ordinary play or anyone else's hazards.
hook_event(HOOK_ALLOW_HAZARD_SURFACE, function(m)
    if m.playerIndex == 0 and shellRestoreFrames > 0 then return false end
end)
hook_event(HOOK_ON_INTERACT, onInteract)
hook_event(HOOK_ALLOW_INTERACT, allowInteract)
hook_event(HOOK_ON_PACKET_BYTESTRING_RECEIVE, receiveShellVisualPacket)
hook_event(HOOK_USE_ACT_SELECT, useChosenActSelect)
hook_event(HOOK_ON_SCREEN_TRANSITION, suppressCheckpointEntryTransition)

hook_mod_menu_button("\\#00ff7f\\Warp to player...\\#ffffff\\", function()
    if travelRestricted() then return end
    menuPages.page = nil
    playerTravel.open()
end)
hook_mod_menu_button("Choose level", function() menuPages.open("levels") end)
hook_mod_menu_button("Current saves", function() menuPages.open("saves") end)
hook_mod_menu_button("Preferences", function() menuPages.open("preferences") end)
for _, name in ipairs({"fullhp", "fh"}) do hook_chat_command(name, "Toggle full HP on load.", fullhp) end
for _, name in ipairs({"keepcoin", "kc"}) do hook_chat_command(name, "Toggle saved coin restoration.", keepcoin) end

---------------------------------------------------------------------------------------------------
-- Current saves overlay
---------------------------------------------------------------------------------------------------

-- Type /saves to show or hide your four slots on the left of the screen. The list shows each
-- destination and save time, and updates when you save again. It is a display, not a menu. CoopDX
-- does not expose which mod page is open, so it follows the chat toggle rather than automatically
-- opening with the SavePoints menu.

-- A separate function scope keeps HUD-only locals away from the main script's Lua local-variable limit.
;(function(hud)
    -- The display order does not change the existing slot/file mapping. Native up/down HUD arrows also supply
    -- left/right by rotation, matching the mockup without new textures or clickable button backgrounds.
    local order, names = {1, 3, 2, 4}, {}
    hud.order = order
    for _, entry in ipairs(LEVEL_MENU) do names[entry[1]] = entry[2]:gsub(" %- Battle$", "") end

    -- Shows or hides the save list with /saves. This display preference lasts for the session and
    -- does not change any slot.
    function hud.toggle()
        hud.enabled = not hud.enabled
        djui_chat_message_create("Current saves: " .. (hud.enabled and "shown" or "hidden"))
        return true
    end

    -- Formats a slot's destination and timestamp, reusing that text until a new save replaces the
    -- slot.
    function hud.row(slot)
        local s, row = localCheckpoints[slot], hud.rows[slot]
        if row and row.source == s then return row end
        row = {source = s, name = "Slot empty", date = ""}
        if s then
            row.name = names[s.spLevel] or string.format("Level %d", s.spLevel)
            if s.spLevel ~= LEVEL_BOWSER_1 and s.spLevel ~= LEVEL_BOWSER_2 and s.spLevel ~= LEVEL_BOWSER_3 then
                row.name = row.name .. string.format(", Act %d", s.spAct)
            end
            row.date = s.spSavedYear > 0 and string.format("%02d/%02d/%04d, %02d:%02d",
                s.spSavedDay, s.spSavedMonth, s.spSavedYear, s.spSavedHour, s.spSavedMinute) or "Date unavailable"
        end
        hud.rows[slot] = row
        return row
    end

    -- Adds a dark text shadow. Destinations get a second foreground pass for weight; dates stay
    -- lighter.
    local function label(text, x, y, scale, bold, empty, unit)
        local weight, shadow = bold and 0.18 * unit or 0, 0.5 * unit
        djui_hud_set_color(0, 0, 0, 230)
        djui_hud_print_text(text, x + shadow, y + shadow, scale)
        if bold then djui_hud_print_text(text, x + shadow + weight, y + shadow, scale) end
        djui_hud_set_color(255, empty and 0 or 255, empty and 0 or 255, 255)
        djui_hud_print_text(text, x, y, scale)
        if bold then djui_hud_print_text(text, x + weight, y, scale) end
    end

    -- Draws Current saves in the game's title font, alternating the overlay colors between
    -- letters.
    function hud.title(x, y, width, unit, text)
        djui_hud_set_font(FONT_MENU)
        text = text or "CURRENT SAVES"
        local textWidth, textHeight = djui_hud_measure_text(text)
        local scale = math.min(0.34 * unit, width / math.max(1, textWidth), 10 * unit / math.max(1, textHeight))
        djui_hud_set_color(0, 0, 0, 230)
        djui_hud_print_text(text, x + 0.5 * unit, y + 0.5 * unit, scale)
        local colors, letter = {{255,48,48}, {64,231,64}, {64,176,255}, {255,239,64}}, 0
        for i = 1, #text do
            local char = text:sub(i, i)
            if char ~= " " then
                local color = colors[letter % 4 + 1]
                djui_hud_set_color(color[1], color[2], color[3], 255)
                djui_hud_print_text(char, x + djui_hud_measure_text(text:sub(1, i - 1)) * scale, y, scale)
                letter = letter + 1
            end
        end
        djui_hud_set_font(FONT_NORMAL)
    end

    -- Both /saves and the clickable Saves page use this exact drawing code. Return the row
    -- scale and panel bottom so menu hitboxes follow the arrows and text at any screen size.
    function hud.draw(x, top, column, titleY)
        djui_hud_set_resolution(RESOLUTION_N64)
        djui_hud_set_font(FONT_NORMAL)
        djui_hud_set_rotation(0, 0.5, 0.5)
        -- Measure standard names once in the active native font; custom/unknown destinations are checked below.
        if not hud.longestName then
            hud.longestName = 1
            for _, name in pairs(names) do
                hud.longestName = math.max(hud.longestName, djui_hud_measure_text(name .. ", Act 6"))
            end
        end
        local longest = hud.longestName
        for _, slot in ipairs(order) do longest = math.max(longest, djui_hud_measure_text(hud.row(slot).name)) end
        local unit = math.min(1, (column - 9) / (longest * 0.30 + 0.18))
        local textX, dateRight = x + 9 * unit, x + column
        -- Draw behind every element, never over the arrows/text. Constant padding encloses even the final date;
        -- 60% opaque black improves contrast while keeping the game visible through the non-clickable panel.
        local panelTop, padding = titleY - 4 * unit, 4 * unit
        djui_hud_set_color(0, 0, 0, 153)
        djui_hud_render_rect(x - padding, panelTop, column + 2 * padding, top + 76 * unit - panelTop)
        hud.title(textX, titleY, column - 9 * unit, unit)
        for i, slot in ipairs(order) do
            local y, row = top + (i - 1) * 18 * unit, hud.row(slot)
            djui_hud_set_color(255, 255, 255, 255)
            local texture = slot == 3 and gTextures.arrow_down or gTextures.arrow_up
            djui_hud_set_rotation(slot == 2 and 0x4000 or slot == 4 and -0x4000 or 0, 0.5, 0.5)
            -- The native arrow has transparent padding. After rotating right, its visible triangle sits left
            -- of the left-arrow triangle; compensate only that direction so their visible edges share a column.
            local arrowX = x + (slot == 4 and 2 * unit or 0)
            djui_hud_render_texture(texture, arrowX, y + 2 * unit, 6 * unit / texture.width, 6 * unit / texture.height)
            djui_hud_set_rotation(0, 0.5, 0.5)
            label(row.name, textX, y, 0.30 * unit, true, not row.source, unit)
            if row.date ~= "" then
                local dateWidth = djui_hud_measure_text(row.date)
                local dateScale = 0.22 * unit
                label(row.date, dateRight - dateWidth * dateScale, y + 10 * unit, dateScale, false, false, unit)
            end
        end
        return unit, top + 76 * unit
    end

    -- The chat overlay stays non-clickable and yields its space to an open subpage.
    function hud.render()
        if not hud.enabled or playerTravel.popup or menuPages.page then return end
        djui_hud_set_resolution(RESOLUTION_N64)
        local w, h = djui_hud_get_screen_width(), djui_hud_get_screen_height()
        hud.draw(10, h * 0.275, math.min(w * 0.28, 110), h * 0.20)
    end

    -- Each arrow is drawn inside its own hitbox; the page counter is never clickable.
    -- A single press moves one page, and the endpoints wrap in the expected direction.
    function hud.navigator(x, y, width, page, pages, mx, my, click)
        djui_hud_set_font(FONT_NORMAL)
        local scale, turn = 0.27, 0
        for _, direction in ipairs({-1, 1}) do
            local left = direction == -1 and x + 2 or x + width - 14
            local hover = mx >= left and mx < left + 12 and my >= y and my < y + 13
            djui_hud_set_color(255, 255, 255, hover and 45 or 0)
            djui_hud_render_rect(left, y, 12, 13)
            local text = direction == -1 and "<" or ">"
            djui_hud_set_color(255, 255, 255, 255)
            djui_hud_print_text(text, left + (12 - djui_hud_measure_text(text) * scale) / 2, y, scale)
            if hover and click then turn = direction end
        end
        local text = (page + 1) .. "/" .. pages
        djui_hud_print_text(text, x + (width - djui_hud_measure_text(text) * scale) / 2, y, scale)
        if turn ~= 0 then play_sound(SOUND_MENU_CLICK_CHANGE_VIEW, gGlobalSoundSource) end
        return (page + turn) % pages
    end

    hook_chat_command("saves", "Show or hide your four saved destinations.", hud.toggle)
    hook_event(HOOK_ON_HUD_RENDER, hud.render)
end)(savesHud)

---------------------------------------------------------------------------------------------------
-- Warping to another player
---------------------------------------------------------------------------------------------------

-- Choose someone from Warp to player, then close the pause menu to join them at their captured
-- location. You arrive flying, swimming, climbing, hanging or sliding as appropriate, but without
-- their held item or shell. Only your position, movement and slide timer change, not their game.
-- Their position is captured when the request reaches their game, so network delay affects that
-- moment. Cutscenes, level transitions, bubbles and missing climbing or hanging surfaces make the
-- destination unavailable.
;(function(travel)
    -- Looks up a connected player by global ID. Do not cache their local index, which can change
    -- after a disconnect.
    local function peer(id)
        for i = 1, MAX_PLAYERS - 1 do
            local n = gNetworkPlayers[i]
            if n and n.connected and n.globalIndex == id then return n, i end
        end
    end

    -- Checks that this player is fully in a level and safe to visit, rather than in a cutscene,
    -- bubble or another load.
    local function ready()
        local m, n = gMarioStates[0], gNetworkPlayers[0]
        return m and n and n.connected and n.currLevelSyncValid and n.currAreaSyncValid
            and n.currLevelNum > 0 and n.currActNum ~= 99 and m.marioObj and m.area and m.area.camera
            and m.area.index == n.currAreaIndex and m.area.camera.cutscene == 0
            and m.health > 0xff and not blocked(m) and m.action ~= ACT_BUBBLED
            and not is_transition_playing() and loadMode == LOAD_NONE
            and queuedLoadSlot == nil and queuedLevel == nil and not travel.busy
    end

    -- Only numbers go into a player-warp reply, never object pointers or a full save.
    local visitFields = {"level", "area", "act", "x", "y", "z", "pitch", "yaw", "roll", "wing", "capTime",
        "timerValue", "timerOn", "poleBehavior", "poleX", "poleY", "poleZ", "polePos", "poleYaw"}
    for key in ("spIntAction spIntPrevAction spIntActionState spIntActionTimer spIntActionArg "
        .. "spIntVelX spIntVelY spIntVelZ spIntForwardVel spIntSlideX spIntSlideZ "
        .. "spIntAngleVelX spIntAngleVelY spIntAngleVelZ spIntTwirlYaw spIntGrabPos "
        .. "spIntAnimFrame spIntMarioObjPitch"):gmatch("%S+") do visitFields[#visitFields + 1] = key end

    -- Captures the chosen player's location and movement for a visit. Held and ridden objects are
    -- omitted; their poses become standing, falling or swimming. Unsupported automatic actions are
    -- refused.
    local function snapshot(reply)
        local m, n = gMarioStates[0], gNetworkPlayers[0]
        captureMarioMotion(reply, m)
        reply.level, reply.area, reply.act = n.currLevelNum, n.currAreaIndex, n.currActNum
        reply.x, reply.y, reply.z = m.pos.x, m.pos.y, m.pos.z
        reply.pitch, reply.yaw, reply.roll = m.faceAngle.x, m.faceAngle.y, m.faceAngle.z
        reply.wing, reply.capTime = m.flags & MARIO_WING_CAP, m.capTimer
        reply.timerValue = n.currLevelNum == LEVEL_PSS and raceTimerOverride and raceTimerValue or 0
        reply.timerOn = n.currLevelNum == LEVEL_PSS and raceTimerOverride and (raceTimerRunning and 1 or 2) or 0
        reply.poleBehavior, reply.poleX, reply.poleY, reply.poleZ, reply.polePos, reply.poleYaw = 0,0,0,0,0,0
        if (m.action & ACT_FLAG_ON_POLE) ~= 0 then
            if not m.usedObj or objectBehaviorId(m.usedObj)==0 then return false end
            reply.poleBehavior = objectBehaviorId(m.usedObj)
            reply.poleX, reply.poleY, reply.poleZ = m.usedObj.oPosX, m.usedObj.oPosY, m.usedObj.oPosZ
            reply.polePos, reply.poleYaw = m.marioObj.oMarioPolePos, m.marioObj.oMarioPoleYawVel
        elseif m.heldObj or m.riddenObj then
            reply.spIntAction = genuinelySwimming(m) and ACT_WATER_IDLE
                or (m.pos.y > m.floorHeight + 30 and ACT_FREEFALL or ACT_IDLE)
            reply.spIntActionState, reply.spIntActionTimer, reply.spIntActionArg = 0,0,0
            reply.spIntGrabPos = 0
        elseif (m.action & ACT_GROUP_MASK) == ACT_GROUP_AUTOMATIC
            and m.action ~= ACT_START_HANGING and m.action ~= ACT_HANGING and m.action ~= ACT_HANG_MOVING
            and m.action ~= ACT_LEDGE_GRAB and m.action ~= ACT_LEDGE_CLIMB_SLOW_1
            and m.action ~= ACT_LEDGE_CLIMB_SLOW_2 and m.action ~= ACT_LEDGE_CLIMB_DOWN
            and m.action ~= ACT_LEDGE_CLIMB_FAST then
            return false -- Cannons and other automatic object-controlled rides need their own lifecycle.
        end
        return true
    end

    -- Ends a player warp, reporting unavailability on failure. Does not alter save slots or retry
    -- the level warp.
    local function finish(failed)
        if failed then djui_popup_create((travel.name or "Player") .. " is currently unavailable", 3) end
        travel.busy, travel.phase, travel.reply, travel.destination = false, nil, nil, nil
    end

    -- Requests the chosen player's position when the menu closes. The reply is used for the whole
    -- journey, even if they move afterwards.
    local function ask()
        local n, index = peer(travel.target)
        if not n then finish(true); return end
        travel.serial = travel.serial + 1
        travel.phase, travel.deadline = "locate", travel.tick + 120
        network_send_to(index, true, {spVisit = 3, from = gNetworkPlayers[0].globalIndex,
            to = travel.target, token = travel.serial})
    end

    -- Answers player-warp requests and checks replies. Accepts only the current player's
    -- outstanding request, with valid numeric data; repeated incoming requests are rate-limited.
    local function receive(data)
        if type(data) ~= "table" or data.to ~= gNetworkPlayers[0].globalIndex
            or type(data.token) ~= "number" or data.token ~= math.floor(data.token) then return end
        local n, index = peer(data.from)
        if not n then return end
        if data.spVisit == 3 then
            if travel.tick < (travel.limits[data.from] or 0) then return end
            travel.limits[data.from] = travel.tick + 3
            local reply = {spVisit=4,from=gNetworkPlayers[0].globalIndex,to=data.from,token=data.token}
            reply.ready = ready() and travel.stable >= 2 and snapshot(reply) or false
            network_send_to(index, true, reply)
        elseif data.spVisit == 4 and travel.busy and travel.phase == "locate"
            and data.from == travel.target and data.token == travel.serial then
            if data.ready ~= true then finish(true); return end
            for _, key in ipairs(visitFields) do
                local value = data[key]
                if type(value) ~= "number" or value ~= value or math.abs(value) > 0xffffffff then finish(true); return end
            end
            for _, key in ipairs({"level","area","act","spIntAction","spIntPrevAction","spIntActionArg","timerOn","poleBehavior"}) do
                if data[key]~=math.floor(data[key]) then finish(true); return end
            end
            if data.level < 1 or data.level > 255 or data.area < 1 or data.area > 8
                or data.act < 0 or data.act > 6 or math.abs(data.x)>32767 or math.abs(data.y)>32767
                or math.abs(data.z)>32767 or data.spIntAction == ACT_BUBBLED
                or (data.spIntAction & ACT_GROUP_MASK) == ACT_GROUP_CUTSCENE
                or (data.spIntAction & ACT_FLAG_INTANGIBLE) ~= 0
                or data.timerOn < 0 or data.timerOn > 2 or data.timerValue < 0 or data.timerValue > 17999
                then finish(true); return end
            travel.reply = data
        end
    end

    -- Finds the matching tree or pole in the visitor's own area. A pointer from the other player's
    -- game cannot be used here.
    local function pole(data)
        if data.poleBehavior == 0 then return end
        local o = obj_get_first_with_behavior_id(data.poleBehavior)
        while o do
            if o.activeFlags ~= ACTIVE_FLAG_DEACTIVATED
                and (o.oPosX-data.poleX)^2+(o.oPosY-data.poleY)^2+(o.oPosZ-data.poleZ)^2 < 4 then return o end
            o = obj_get_next_with_same_behavior_id(o)
        end
    end

    -- Starts the destination's normal view with your own camera settings, not the other player's
    -- camera or your previous area's water angle.
    local function resetVisitCamera(m)
        local c, n = m.area.camera, gNetworkPlayers[0]
        if m.statusForCamera then
            setCameraVector(m.statusForCamera.pos,m.pos.x,m.pos.y,m.pos.z)
            setCameraVector(m.statusForCamera.faceAngle,m.faceAngle.x,m.faceAngle.y,m.faceAngle.z)
            m.statusForCamera.action = m.action
        end
        c.mode = c.defMode
        -- Boss visits must not replay an arena-entry camera cutscene. Seed the soft reset near Mario, then let
        -- the arena's normal camera logic determine its view. Other areas retain their native initialization,
        -- including the Free Camera slide-centering setup that a soft reset would omit.
        if bossArena.isLevel(n.currLevelNum) then
            setCameraVector(c.pos,m.pos.x-600*sins(m.faceAngle.y),m.pos.y+200,m.pos.z-600*coss(m.faceAngle.y))
            setCameraVector(c.focus,m.pos.x,m.pos.y+100,m.pos.z)
            soft_reset_camera(c)
        else
            reset_camera(c)
        end
        travel.cameraLevel,travel.cameraArea,travel.cameraFrames = n.currLevelNum,n.currAreaIndex,2
        skip_camera_interpolation()
    end

    -- Uses the game's collision-adjusted view for the first two arrival frames, preventing a slow
    -- pan from the old location.
    local function settleVisitCamera()
        if (travel.cameraFrames or 0)==0 then return end
        local m,n,l = gMarioStates[0],gNetworkPlayers[0],gLakituState
        if loadMode~=LOAD_NONE or cameraRestoreFrames>0 or travel.busy or not m or not n or not l
            or n.currLevelNum~=travel.cameraLevel or n.currAreaIndex~=travel.cameraArea
            or not m.area or m.area.index~=travel.cameraArea or not m.area.camera then
            travel.cameraFrames=0; return
        end
        if m.area.camera.cutscene~=0 then travel.cameraFrames=0; return end
        setCameraVector(l.curPos,l.pos.x,l.pos.y,l.pos.z)
        setCameraVector(l.curFocus,l.focus.x,l.focus.y,l.focus.z)
        skip_camera_interpolation()
        travel.cameraFrames=travel.cameraFrames-1
    end

    -- Places you at the captured point before movement begins, empty-handed and with the matching
    -- action. Checks climbing/hanging support and adopts only your copy of the PSS time.
    local function arrive(m)
        local d, n = travel.destination, gNetworkPlayers[0]
        if not d or n.currLevelNum ~= d.level or n.currActNum ~= d.act
            or not m.marioObj or not m.area or not m.area.camera then return end
        if n.currAreaIndex ~= d.area or m.area.index ~= d.area then
            if not travel.areaChanged then smlua_level_util_change_area(d.area); travel.areaChanged = true end
            return
        end
        local fy, floor = find_floor(d.x, d.y + 80, d.z)
        local cy, ceil = find_ceil(d.x, d.y, d.z)
        local support = pole(d)
        local hanging = d.spIntAction == ACT_START_HANGING or d.spIntAction == ACT_HANGING or d.spIntAction == ACT_HANG_MOVING
        if not floor or (floor.type == SURFACE_BURNING and d.y < fy + 20)
            or (d.poleBehavior ~= 0 and not support)
            or (hanging and (not ceil or ceil.type ~= SURFACE_HANGABLE or math.abs(cy-d.y-160)>30))
            then finish(true); return end
        releaseCurrentInteraction(m)
        m.usedObj, m.interactObj = support, nil
        m.flags = m.flags & ~MARIO_TELEPORTING
        m.pos.x, m.pos.y, m.pos.z = d.x,d.y,d.z
        m.faceAngle.x, m.faceAngle.y, m.faceAngle.z = d.pitch,d.yaw,d.roll
        m.floor, m.floorHeight, m.ceil, m.ceilHeight = floor,fy,ceil,cy
        m.waterLevel = find_water_level(d.x,d.z)
        m.marioObj.platform = nil
        if d.spIntAction == ACT_FLYING then
            m.flags = m.flags | MARIO_WING_CAP | MARIO_CAP_ON_HEAD
            m.capTimer = math.max(m.capTimer, d.capTime)
        end
        restoreMarioMotion(m,d,d.spIntAction)
        m.faceAngle.x, m.faceAngle.y, m.faceAngle.z = d.pitch,d.yaw,d.roll
        m.marioObj.oPosX, m.marioObj.oPosY, m.marioObj.oPosZ = d.x,d.y,d.z
        if support then m.marioObj.oMarioPolePos, m.marioObj.oMarioPoleYawVel = d.polePos,d.poleYaw end
        m.hurtCounter, m.invincTimer = 0,2
        cameraRestoreFrames = 0
        resetVisitCamera(m)
        if d.level == LEVEL_PSS then
            raceTimerValue, raceTimerOverride, raceTimerRunning = d.timerValue,d.timerOn~=0,d.timerOn==1
            raceTimerHold, raceTimerLevel, raceTimerArea = 1,d.level,d.area
            enforcePrivateSlideHud(m,n)
        else
            clearRaceTimerOverride(false) -- Koopa's shared race is never stopped or rewound.
        end
        if travel.usedWarp and is_transition_playing() then play_transition(WARP_TRANSITION_FADE_FROM_COLOR,2,0,0,0) end
        travel.grace = 15
        gPlayerSyncTable[0].spVisitGrace = true
        djui_popup_create("Warped to " .. travel.name,2)
        finish(false)
    end

    -- Waits for the menu to close, requests the destination and starts one warp. Also handles
    -- timeouts and the brief player-collision protection after arrival.
    local function updateVisit()
        local m, n = gMarioStates[0], gNetworkPlayers[0]
        if not m or not n then return end
        travel.tick = travel.tick + 1
        if (travel.grace or 0)>0 then
            travel.grace = travel.grace-1
            if travel.grace==0 then gPlayerSyncTable[0].spVisitGrace=false end
        end
        travel.stable = ready() and n.currLevelNum==travel.level and n.currAreaIndex==travel.area
            and n.currActNum==travel.act and travel.stable+1 or 0
        travel.level,travel.area,travel.act = n.currLevelNum,n.currAreaIndex,n.currActNum
        if not travel.busy then return end
        if loadMode~=LOAD_NONE or queuedLoadSlot or queuedLevel or not peer(travel.target) then finish(true); return end
        if travel.phase=="queued" then
            if gGlobalSyncTable.spSaveLoadOnly then finish(false); travelRestricted(); return end
            if djui_hud_is_pause_menu_created() then return end
            if blocked(m) or m.action==ACT_BUBBLED or is_transition_playing() then finish(true); return end
            if is_game_paused() then game_unpause() end
            chosenActSelectLevel = nil
            ask()
        elseif travel.tick>travel.deadline then finish(true)
        elseif travel.reply then
            local d = travel.reply
            travel.reply,travel.destination,travel.phase,travel.deadline = nil,d,"enter",travel.tick+300
            travel.areaChanged = false
            travel.usedWarp = n.currLevelNum~=d.level or n.currActNum~=d.act
            cameraRestoreFrames = 0
            if travel.usedWarp then
                if not warp_to_level(d.level,d.area,d.act)
                    and not (d.area~=1 and warp_to_level(d.level,1,d.act)) then finish(true) end
            elseif n.currAreaIndex~=d.area then
                smlua_level_util_change_area(d.area)
                travel.areaChanged = true
            end
        end
    end

    -- Exact placement briefly overlaps the target. Suppress player-only collisions on both peers for half a
    -- second, allowing movement away without a shove; terrain, enemies and normal gameplay remain active.
    gPlayerSyncTable[0].spVisitGrace = false
    hook_event(HOOK_ALLOW_INTERACT, function(m,o,kind)
        if kind~=INTERACT_PLAYER or not m or not o then return end
        if gPlayerSyncTable[m.playerIndex].spVisitGrace then return false end
        for i=0,MAX_PLAYERS-1 do
            if gNetworkPlayers[i].connected and gPlayerSyncTable[i].spVisitGrace
                and gMarioStates[i].marioObj==o then return false end
        end
    end)
    hook_event(HOOK_BEFORE_MARIO_UPDATE,function(m)
        if m.playerIndex==0 and travel.busy and travel.phase=="enter" then arrive(m) end
    end)
    hook_event(HOOK_ON_SCREEN_TRANSITION,function(kind)
        if travel.busy and travel.usedWarp and kind==WARP_TRANSITION_FADE_FROM_STAR then return false end
    end)

    -- Opens the connected-player list from Warp to player. Waits if another load or player warp is
    -- still in progress.
    function travel.open()
        if travelRestricted() then return end
        if travel.busy or loadMode ~= LOAD_NONE then djui_popup_create("Wait for the current travel to finish.", 2); return end
        menuPages.loadSlot = nil
        travel.popup, travel.page, travel.mouseDown = true, 0, true
    end

    -- Match Current saves: same title font, letter colours and shadow.
    local function playerTitle(x,y,width)
        savesHud.title(x+4,y+3,width-8,1,"CHOOSE PLAYER")
    end

    -- Draws the player list alongside the pause menu. Choosing a name queues travel; Back or an
    -- outside click dismisses the list. Your own name is shown but cannot be selected.
    local function drawPicker()
        if not travel.popup then return end
        if gGlobalSyncTable.spSaveLoadOnly then travel.popup = false; travelRestricted(); return end
        if not djui_hud_is_pause_menu_created() then travel.popup = false; return end
        djui_hud_set_resolution(RESOLUTION_N64)
        djui_hud_set_font(FONT_NORMAL)
        local w, h = djui_hud_get_screen_width(), djui_hud_get_screen_height()
        -- Mouse positions always use DJUI units, even when HUD rendering uses N64 coordinates. Convert via
        -- both viewport dimensions so the clickable rows match the visible names at every UI scale/aspect ratio.
        djui_hud_set_resolution(RESOLUTION_DJUI)
        local mx = djui_hud_get_mouse_x() * w / djui_hud_get_screen_width()
        local my = djui_hud_get_mouse_y() * h / djui_hud_get_screen_height()
        djui_hud_set_resolution(RESOLUTION_N64)
        local x, y, width = 5, h * 0.20, math.min(w * 0.27, 110)
        local players = {}
        -- CoopDX exposes this flag as an integer: Lua considers even zero true. Compare explicitly so clients
        -- see a normal host; only an actual headless server is omitted from the selectable players.
        local headless = gServerSettings.headlessServer ~= 0
        for i = 0, MAX_PLAYERS - 1 do
            local n = gNetworkPlayers[i]
            if n and n.connected and not (headless and n.type == NPT_SERVER) then players[#players+1] = {id=n.globalIndex,name=n.name,self=i==0} end
        end
        local pages = math.max(1, math.ceil(#players / 8))
        travel.page = math.min(travel.page, pages-1)
        -- Cursor/HUD reads refresh the native mouse state between simulation ticks, so the engine's one-frame
        -- pressed flag can miss a click. Track our own rising edge from the live button state instead. Opening
        -- starts with the button treated as held: release the opener before a fresh press can choose a player.
        local down = (djui_hud_get_mouse_buttons_down() & 1) ~= 0
        local click = down and not travel.mouseDown
        travel.mouseDown = down
        djui_hud_set_color(0,0,0,153); djui_hud_render_rect(x,y,width,154)
        playerTitle(x,y,width)
        for row = 1, 8 do
            local p = players[travel.page*8+row]
            if p then
                local ry = y+18+(row-1)*13
                local hover = mx>=x and mx<x+width and my>=ry and my<ry+12
                djui_hud_set_color(255,255,255,hover and 45 or 0); djui_hud_render_rect(x+2,ry,width-4,12)
                djui_hud_set_color(p.self and 140 or 255,p.self and 140 or 255,p.self and 140 or 255,255)
                local name = p.name .. (p.self and " (you)" or "")
                djui_hud_print_text(name,x+4,ry+1,math.min(0.27,(width-8)/math.max(1,djui_hud_measure_text(name))))
                if hover and click and not p.self then
                    travel.target,travel.name,travel.phase,travel.busy,travel.popup = p.id,p.name,"queued",true,false
                    djui_popup_create(p.name .. " selected.\nClose the pause menu to travel.",3)
                    return
                end
            end
        end
        travel.page = savesHud.navigator(x,y+123,width,travel.page,pages,mx,my,click)
        -- Back dismisses only this picker with the native Back sound, leaving the level chooser open.
        local back = mx>=x+2 and mx<x+width-2 and my>=y+137 and my<y+151
        djui_hud_set_color(255,255,255,back and 45 or 0)
        djui_hud_render_rect(x+2,y+137,width-4,14)
        djui_hud_set_color(255,255,255,255)
        djui_hud_print_text("Back",x+(width-djui_hud_measure_text("Back")*0.27)/2,y+139,0.27)
        if click then
            if back then play_sound(SOUND_MENU_CLICK_FILE_SELECT,gGlobalSoundSource) end
            if back or mx<x or mx>=x+width or my<y or my>=y+154 then travel.popup=false end
        end
    end

    -- Disconnect clears in-flight identity and rate-limit state before an engine network slot can be reused.
    hook_event(HOOK_ON_PLAYER_DISCONNECTED, function(m)
        local n = gNetworkPlayers[m.playerIndex]
        if n then travel.limits[n.globalIndex] = nil; if travel.busy and n.globalIndex == travel.target then finish(true) end end
    end)
    hook_event(HOOK_ON_PACKET_RECEIVE, receive)
    hook_event(HOOK_UPDATE, updateVisit)
    hook_event(HOOK_ON_PLAY_MODE_UPDATE, settleVisitCamera)
    hook_event(HOOK_ON_HUD_RENDER, drawPicker)
end)(playerTravel)

---------------------------------------------------------------------------------------------------
-- Levels, saves and preferences
---------------------------------------------------------------------------------------------------

-- The four native buttons open one side panel at a time. Like the original player picker,
-- Back closes only that panel; selecting a destination waits for the native pause menu to close.
-- Nothing here changes the game's pause state while a panel is visible.
;(function(menu)
    function menu.open(page)
        if page == "levels" and travelRestricted() then return end
        if page ~= "preferences" and (playerTravel.busy or loadMode ~= LOAD_NONE) then
            djui_popup_create("Wait for the current travel to finish.", 2)
            return
        end
        playerTravel.popup = false
        menu.page, menu.index, menu.mouseDown = page, 0, true
    end

    local function back()
        play_sound(SOUND_MENU_CLICK_FILE_SELECT, gGlobalSoundSource)
        menu.page = nil
    end

    -- Use our own mouse edge, as in the player picker: native pressed flags can be
    -- consumed between HUD draws. Converting DJUI coordinates keeps hitboxes aligned.
    local function render()
        if not menu.page then return end
        if not djui_hud_is_pause_menu_created() then menu.page = nil; return end
        if menu.page == "levels" and gGlobalSyncTable.spSaveLoadOnly then
            menu.page = nil
            travelRestricted()
            return
        end
        djui_hud_set_resolution(RESOLUTION_N64)
        djui_hud_set_rotation(0, 0.5, 0.5)
        local w, h = djui_hud_get_screen_width(), djui_hud_get_screen_height()
        djui_hud_set_resolution(RESOLUTION_DJUI)
        local mx = djui_hud_get_mouse_x() * w / djui_hud_get_screen_width()
        local my = djui_hud_get_mouse_y() * h / djui_hud_get_screen_height()
        djui_hud_set_resolution(RESOLUTION_N64)
        djui_hud_set_font(FONT_NORMAL)
        local down = (djui_hud_get_mouse_buttons_down() & 1) ~= 0
        local click = down and not menu.mouseDown
        menu.mouseDown = down
        local x, y, width = 5, h * 0.20, math.min(w * 0.27, 110)

        -- Save rows share every font, colour, arrow and spacing calculation with /saves.
        -- Empty slots keep the normal load() message rather than inventing another path.
        if menu.page == "saves" then
            x, width = 10, math.min(w * 0.28, 110)
            local top = h * 0.275
            local unit, bottom = savesHud.draw(x, top, width, y)
            if click and mx >= x and mx < x + width then
                local index = math.floor((my - top) / (18 * unit)) + 1
                if index >= 1 and index <= 4 then
                    menu.loadSlot, menu.page = savesHud.order[index], nil
                    queuedLevel = nil
                    djui_popup_create("Save selected.\nClose the pause menu to load.", 2)
                    return
                end
            end
            y = bottom + 2
        else
            local rows, pages = {}, 1
            if menu.page == "levels" then
                pages = math.ceil(#LEVEL_MENU / 7)
                for i = menu.index * 7 + 1, math.min(#LEVEL_MENU, (menu.index + 1) * 7) do
                    rows[#rows + 1] = {text = LEVEL_MENU[i][2], level = LEVEL_MENU[i]}
                end
            else
                rows = {{text = "Full HP on load", checked = fullHP, toggle = fullhp},
                    {text = "Restore saved coins", checked = keepCoins, toggle = keepcoin}}
                if network_is_server() then
                    rows[#rows + 1] = {text = "Save/load only mode", checked = gGlobalSyncTable.spSaveLoadOnly == true,
                        toggle = function()
                            -- The callback also checks ownership; clients never write this field.
                            if not network_is_server() then return end
                            gGlobalSyncTable.spSaveLoadOnly = not gGlobalSyncTable.spSaveLoadOnly
                            djui_chat_message_create("Save/load only mode: " .. (gGlobalSyncTable.spSaveLoadOnly
                                and "\\#6fd83f\\enabled\\#ffffff\\" or "\\#dd3232\\disabled\\#ffffff\\"))
                        end}
                end
            end
            djui_hud_set_color(0, 0, 0, 153)
            djui_hud_render_rect(x, y, width, 20 + #rows * 15 + (pages > 1 and 15 or 0) + 17)
            djui_hud_set_color(255, 255, 255, 255)
            local heading = menu.page == "levels" and "CHOOSE LEVEL" or "PREFERENCES"
            savesHud.title(x + 4, y + 3, width - 8, 1, heading)
            y = y + 20
            for _, row in ipairs(rows) do
                local hover = mx >= x + 2 and mx < x + width - 2 and my >= y and my < y + 13
                djui_hud_set_color(255, 255, 255, hover and 45 or 0)
                djui_hud_render_rect(x + 2, y, width - 4, 13)
                djui_hud_set_color(255, 255, 255, 255)
                local text = row.toggle and ((row.checked and "[x] " or "[ ] ") .. row.text) or row.text
                local scale = math.min(0.27, (width - 8) / math.max(1, djui_hud_measure_text(text)))
                djui_hud_print_text(text, x + 4, y + 2, scale)
                if hover and click then
                    play_sound(SOUND_MENU_CLICK_CHANGE_VIEW, gGlobalSoundSource)
                    if row.level then chooseLevel(row.level); menu.page = nil else row.toggle() end
                    return
                end
                y = y + 15
            end
            if pages > 1 then
                menu.index = savesHud.navigator(x, y, width, menu.index, pages, mx, my, click)
                y = y + 15
            end
        end
        local hover = mx >= x + 2 and mx < x + width - 2 and my >= y and my < y + 14
        djui_hud_set_color(0, 0, 0, menu.page == "saves" and 153 or 0)
        djui_hud_render_rect(x + 2, y, width - 4, 14)
        if hover then
            djui_hud_set_color(255, 255, 255, 45)
            djui_hud_render_rect(x + 2, y, width - 4, 14)
        end
        djui_hud_set_color(255, 255, 255, 255)
        djui_hud_print_text("Back", x + (width - djui_hud_measure_text("Back") * 0.27) / 2, y + 2, 0.27)
        if hover and click then back() end
    end

    -- Hand the selected slot to the existing rapid-load queue only after native UI closes.
    -- That queue already waits for current level setup and checks Mario before loading.
    hook_event(HOOK_UPDATE, function()
        if menu.loadSlot and not djui_hud_is_pause_menu_created() then
            if is_game_paused() then game_unpause() end
            queuedLoadSlot, menu.loadSlot = menu.loadSlot, nil
        end
    end)
    hook_event(HOOK_ON_PLAYER_DISCONNECTED, function(m)
        if m.playerIndex == 0 then menu.page, menu.loadSlot = nil, nil end
    end)
    hook_event(HOOK_ON_HUD_RENDER, render)
end)(menuPages)
