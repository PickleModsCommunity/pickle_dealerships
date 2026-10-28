if GetResourceState('qbx_core') ~= 'started' then return end

-- QBX Core bridge. QBX differs from QBCore in key ways:
--   • No GetCoreObject — everything is accessed via exports.qbx_core directly.
--   • Player state is in `Player.PlayerData` (same shape) but setters are exports.
--   • Shared data (jobs/items) via exports.qbx_core:GetSharedJobs() / GetSharedItems().
--   • Money / job setters are first-class exports, not `Player.Functions.*`.
--   • Inventory is ox_inventory-first; fallback only covers bare setups.

local function GetPlayer(source)
    return exports.qbx_core:GetPlayer(tonumber(source))
end

function RegisterUsableItem(item, cb)
    exports.qbx_core:CreateUseableItem(item, cb)
end

function ShowNotification(target, text)
    TriggerClientEvent(GetCurrentResourceName()..":showNotification", target, text)
end

function GetIdentifier(source)
    local player = GetPlayer(source)
    return player and player.PlayerData and player.PlayerData.citizenid or nil
end

function GetSourceFromIdentifier(identifier)
    local player = exports.qbx_core:GetPlayerByCitizenId(identifier)
    return player and player.PlayerData and player.PlayerData.source or nil
end

function GetPlayerCharacterName(source)
    local player = GetPlayer(source)
    if not player or not player.PlayerData then return "Unknown Name" end
    local info = player.PlayerData.charinfo or {}
    return (info.firstname or "Unknown") .. " " .. (info.lastname or "")
end

--- Resolves a display name for an arbitrary identifier — online or offline.
--- See the QB bridge for the broader rationale; QBX uses the same
--- `players` schema so the offline fallback is identical.
---@param identifier string
---@return string|nil
function GetCharacterNameByIdentifier(identifier)
    if not identifier or identifier == "" then return nil end
    local function trim(s)
        local t = s:gsub("^%s+", ""):gsub("%s+$", "")
        return t
    end
    local ok, player = pcall(function() return exports.qbx_core:GetPlayerByCitizenId(identifier) end)
    if ok and player and player.PlayerData and player.PlayerData.charinfo then
        local info = player.PlayerData.charinfo
        return trim((info.firstname or "") .. " " .. (info.lastname or ""))
    end
    local row = MySQL.single.await(
        "SELECT charinfo FROM players WHERE citizenid = ? LIMIT 1",
        { identifier }
    )
    if not row or not row.charinfo then return nil end
    local info = type(row.charinfo) == "string" and (json.decode(row.charinfo) or {}) or row.charinfo
    if not info.firstname and not info.lastname then return nil end
    return trim((info.firstname or "") .. " " .. (info.lastname or ""))
end

--- Returns all online player source IDs. Modern QBX exposes GetPlayers(); older
--- versions used GetQBPlayers(). Fall back to fetching from qbx_core or GetPlayers().
local function GetAllQbxPlayerSources()
    local ok, result = pcall(function() return exports.qbx_core:GetPlayers() end)
    if ok and type(result) == "table" then return result end
    -- Vanilla CFX fallback
    local players = {}
    for _, src in ipairs(GetPlayers()) do players[#players + 1] = tonumber(src) end
    return players
end

--- Cross-version shared jobs accessor. QBX renamed GetSharedJobs → GetJobs.
local function GetQbxJobs()
    local ok, result = pcall(function() return exports.qbx_core:GetJobs() end)
    if ok and type(result) == "table" then return result end
    ok, result = pcall(function() return exports.qbx_core:GetSharedJobs() end)
    if ok and type(result) == "table" then return result end
    return {}
end

--- Cross-version shared gangs accessor.
local function GetQbxGangs()
    local ok, result = pcall(function() return exports.qbx_core:GetGangs() end)
    if ok and type(result) == "table" then return result end
    ok, result = pcall(function() return exports.qbx_core:GetSharedGangs() end)
    if ok and type(result) == "table" then return result end
    return {}
end

function GetEmployees(jobName, cb)
    local employees = {}
    local seen = {}

    -- Online members first (authoritative source for current grade).
    for _, src in ipairs(GetAllQbxPlayerSources()) do
        local player = GetPlayer(src)
        if player and player.PlayerData and player.PlayerData.job and player.PlayerData.job.name == jobName then
            local info = player.PlayerData.charinfo or {}
            local grade = player.PlayerData.job.grade or {}
            local cid = player.PlayerData.citizenid
            if cid then seen[cid] = true end
            employees[#employees + 1] = {
                source = src,
                identifier = cid,
                name = (info.firstname or "Unknown") .. " " .. (info.lastname or ""),
                grade = grade.level or 0,
                gradeLabel = grade.name or "",
                online = true,
            }
        end
    end

    -- Offline members from the players table. QBX stores job as JSON.
    local rows = MySQL.query.await(
        "SELECT citizenid, charinfo, job FROM players WHERE JSON_EXTRACT(job, '$.name') = ?",
        { jobName }
    ) or {}
    for _, row in ipairs(rows) do
        if not seen[row.citizenid] then
            local info = type(row.charinfo) == "string" and (json.decode(row.charinfo) or {}) or (row.charinfo or {})
            local job = type(row.job) == "string" and (json.decode(row.job) or {}) or (row.job or {})
            local grade = job.grade or {}
            employees[#employees + 1] = {
                source = nil,
                identifier = row.citizenid,
                name = (info.firstname or "Unknown") .. " " .. (info.lastname or ""),
                grade = tonumber(grade.level) or 0,
                gradeLabel = grade.name or "",
                online = false,
            }
        end
    end

    if type(cb) == "function" then cb(employees) end
    return employees
end

function GetJobGrades(jobName)
    local jobs = GetQbxJobs()
    local job = jobs[jobName]
    if not job or not job.grades then return {} end
    local grades = {}
    for level, grade in pairs(job.grades) do
        grades[#grades + 1] = {
            level = tonumber(level),
            label = grade.name or ("Grade " .. level),
        }
    end
    table.sort(grades, function(a, b) return a.level < b.level end)
    return grades
end

function CanAccessGroup(source, data)
    if not data then return true end
    local player = GetPlayer(source)
    if not player or not player.PlayerData then return false end
    local job = player.PlayerData.job
    for k, v in pairs(data) do
        if job.name == k and job.grade.level >= v then return true end
    end
    return false
end

function CheckPermission(source, permission)
    if permission.ignorePermissions then return true end
    source = tonumber(source)
    local player = GetPlayer(source)
    if not player or not player.PlayerData then return end
    local name = player.PlayerData.job.name
    local rank = player.PlayerData.job.grade.level
    if permission.jobs[name] and permission.jobs[name] <= rank then
        return true
    end
    for i = 1, #(permission.groups or {}) do
        if exports.qbx_core:HasPermission(source, permission.groups[i]) then
            return true
        end
    end
end

function AddMoney(source, count, currency)
    if type(count) ~= 'number' or count < 0 or count % 1 ~= 0 then return false end
    source = tonumber(source)
    if not source or not GetPlayer(source) then return false end
    currency = currency or "money"
    if currency ~= "money" and currency ~= "bank" and currency ~= "dirty" then return false end
    if count == 0 then return true end
    if currency == "money" then
        return exports.qbx_core:AddMoney(source, 'cash', count, 'pickle_dealerships') == true
    elseif currency == "bank" then
        return exports.qbx_core:AddMoney(source, 'bank', count, 'pickle_dealerships') == true
    elseif currency == "dirty" then
        local setting = Config.FrameworkSettings.dirtyMoney
        return Inventory.AddItem(source, setting == "DEFAULT" and 'dirty_money' or setting, count) == true
    end
    return false
end

function RemoveMoney(source, count, currency)
    if type(count) ~= 'number' or count < 0 or count % 1 ~= 0 then return false end
    source = tonumber(source)
    if not source or not GetPlayer(source) then return false end
    currency = currency or "money"
    if currency ~= "money" and currency ~= "bank" and currency ~= "dirty" then return false end
    if count == 0 then return true end
    if currency == "money" then
        return exports.qbx_core:RemoveMoney(source, 'cash', count, 'pickle_dealerships')
    elseif currency == "bank" then
        return exports.qbx_core:RemoveMoney(source, 'bank', count, 'pickle_dealerships')
    elseif currency == "dirty" then
        local setting = Config.FrameworkSettings.dirtyMoney
        return Inventory.RemoveItem(source, setting == "DEFAULT" and 'dirty_money' or setting, count) == true
    end
    return false
end

function GetMoney(source, currency)
    local player = GetPlayer(source)
    if not player or not player.PlayerData then return 0 end
    currency = currency or "money"
    if currency == "money" then
        return player.PlayerData.money.cash or 0
    elseif currency == "bank" then
        return player.PlayerData.money.bank or 0
    elseif currency == "dirty" then
        local setting = Config.FrameworkSettings.dirtyMoney
        return Inventory.GetItemCount(source, setting == "DEFAULT" and 'dirty_money' or setting)
    end
    return 0
end

function GetOwnedVehicleFromPlate(plate)
    if not plate then return nil end
    local normalized = string.upper(tostring(plate):gsub('%s+', ''))
    local data = MySQL.Sync.fetchAll("SELECT * FROM player_vehicles WHERE REPLACE(UPPER(plate), ' ', '')=@plate LIMIT 1;", {
        ['@plate'] = normalized,
    })[1]
    return data and { owner = data.citizenid, model = data.vehicle, properties=data.mods } or nil
end

-- CD Garage adds an `in_garage` column and uses it (not `state`) to decide
-- whether the car is parked. Probe once and inject the column only when
-- present, so this bridge stays compatible with vanilla QBx garages.
local HasInGarageColumn
local function DetectInGarageColumn()
    if HasInGarageColumn ~= nil then return HasInGarageColumn end
    local ok, res = pcall(MySQL.Sync.fetchScalar, [[
        SELECT COUNT(*) FROM information_schema.columns
        WHERE table_schema = DATABASE()
          AND table_name = 'player_vehicles'
          AND column_name = 'in_garage'
    ]])
    HasInGarageColumn = ok and tonumber(res or 0) > 0 or false
    return HasInGarageColumn
end

-- 4+4 plate, no space — CD Garage normalises to 8 chars and the legacy
-- "3+space+3" format triggers trailing-whitespace sync mismatches.
local function GeneratePlateQBX()
    local letters = { "A","B","C","D","E","F","G","H","I","J","K","L","M","N","O","P","Q","R","S","T","U","V","W","X","Y","Z" }
    local numbers = { "0","1","2","3","4","5","6","7","8","9" }
    local parts = {}
    for i = 1, 4 do parts[#parts + 1] = letters[math.random(1, #letters)] end
    for i = 1, 4 do parts[#parts + 1] = numbers[math.random(1, #numbers)] end
    return table.concat(parts)
end

--- state = 1 (out) so vanilla QBx garages accept a store attempt; in_garage
--- = 0 is the CD Garage equivalent, injected only if the column exists.
--- mods JSON always carries `model` + `plate` for CD Garage's 5111 check.
function AddOwnedVehicle(source, model)
    local player = GetPlayer(source)
    if not player then return end
    local plate = GeneratePlateQBX()
    local mods = json.encode({ model = joaat(model), plate = plate })

    if DetectInGarageColumn() then
        MySQL.Async.execute(
            'INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state, in_garage) VALUES (@license, @citizenid, @vehicle, @hash, @mods, @plate, @garage, @state, @in_garage)',
            {
                ['@license']   = player.PlayerData.license,
                ['@citizenid'] = player.PlayerData.citizenid,
                ['@vehicle']   = model,
                ['@hash']      = joaat(model),
                ['@mods']      = mods,
                ['@plate']     = plate,
                ['@garage']    = "pillboxgarage",
                ['@state']     = 1,
                ['@in_garage'] = 0,
            }
        )
    else
        MySQL.Async.execute(
            'INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state) VALUES (@license, @citizenid, @vehicle, @hash, @mods, @plate, @garage, @state)',
            {
                ['@license']   = player.PlayerData.license,
                ['@citizenid'] = player.PlayerData.citizenid,
                ['@vehicle']   = model,
                ['@hash']      = joaat(model),
                ['@mods']      = mods,
                ['@plate']     = plate,
                ['@garage']    = "pillboxgarage",
                ['@state']     = 1,
            }
        )
    end
end

function AddOwnedVehicleWithProps(source, model, plate, properties)
    local player = GetPlayer(source)
    if not player or not plate then return false end

    local cleanPlate = DealerPlate(plate)
    local props = properties
    if type(props) == "string" then props = json.decode(props) end
    if type(props) ~= "table" then props = {} end
    props.model = joaat(model)
    props.modelName=model
    props.plate = cleanPlate
    local mods = json.encode(props)

    if DetectInGarageColumn() then
        changed=MySQL.update.await(
            'INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state, in_garage) VALUES (@license, @citizenid, @vehicle, @hash, @mods, @plate, @garage, @state, @in_garage)',
            {
                ['@license']   = player.PlayerData.license,
                ['@citizenid'] = player.PlayerData.citizenid,
                ['@vehicle']   = model,
                ['@hash']      = joaat(model),
                ['@mods']      = mods,
                ['@plate']     = cleanPlate,
                ['@garage']    = "pillboxgarage",
                ['@state']     = 1,
                ['@in_garage'] = 0,
            }
        )
    else
        changed=MySQL.update.await(
            'INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state) VALUES (@license, @citizenid, @vehicle, @hash, @mods, @plate, @garage, @state)',
            {
                ['@license']   = player.PlayerData.license,
                ['@citizenid'] = player.PlayerData.citizenid,
                ['@vehicle']   = model,
                ['@hash']      = joaat(model),
                ['@mods']      = mods,
                ['@plate']     = cleanPlate,
                ['@garage']    = "pillboxgarage",
                ['@state']     = 1,
            }
        )
    end
    return changed==1
end

function RemoveOwnedVehicle(identifier, plate)
    if not identifier or not plate then return false end
    local changed=MySQL.update.await("DELETE FROM player_vehicles WHERE REPLACE(UPPER(plate), ' ', '')=REPLACE(UPPER(@plate), ' ', '') AND citizenid=@citizenid", {
        ['@plate'] = plate,
        ['@citizenid'] = identifier,
    })
    return changed==1
end

function UpdateVehiclePlate(source, plate, newPlate)
    local player = GetPlayer(source)
    if not player then return end
    MySQL.Async.execute('UPDATE player_vehicles SET plate = @newPlate WHERE plate = @plate AND citizenid = @citizenid', {
        ['@newPlate'] = newPlate,
        ['@plate'] = plate,
        ['@citizenid'] = player.PlayerData.citizenid,
    })
end

function GetPlayerJob(source)
    local player = GetPlayer(source)
    if not player or not player.PlayerData then return end
    return { label = player.PlayerData.job.label, rank_label = player.PlayerData.job.grade.name }
end

function GetPlayerJobName(source)
    local player = GetPlayer(source)
    if not player or not player.PlayerData or not player.PlayerData.job then return nil end
    return player.PlayerData.job.name
end

function GetPlayerJobGrade(source)
    local player = GetPlayer(source)
    if not player or not player.PlayerData or not player.PlayerData.job then return 0 end
    return player.PlayerData.job.grade.level or 0
end

function SetPlayerJob(source, job, grade)
    exports.qbx_core:SetJob(tonumber(source), job, grade)
end

function GetPlayerGangName(source)
    local player = GetPlayer(source)
    if not player or not player.PlayerData or not player.PlayerData.gang then return nil end
    return player.PlayerData.gang.name
end

function GetPlayerGangGrade(source)
    local player = GetPlayer(source)
    if not player or not player.PlayerData or not player.PlayerData.gang or not player.PlayerData.gang.grade then return 0 end
    return player.PlayerData.gang.grade.level or 0
end

function SetPlayerGang(source, gang, grade)
    local ok = pcall(function() exports.qbx_core:SetGang(tonumber(source), gang, grade) end)
    return ok
end

--- Applies a faction change to a player identified by citizenid. Uses the live
--- setter if they're online so framework notifications/state fire normally;
--- otherwise writes directly to the players table so offline hires/fires stick.
function SetFactionByIdentifier(factionType, identifier, factionName, grade)
    if not identifier or not factionName then return false end
    local src = GetSourceFromIdentifier(identifier)
    if src then
        if factionType == "gang" then return SetPlayerGang(src, factionName, grade) end
        SetPlayerJob(src, factionName, grade)
        return true
    end

    -- Offline write — update the JSON column directly. Preserves other fields by
    -- using JSON_SET so we don't clobber unrelated job/gang state.
    local column = (factionType == "gang") and "gang" or "job"
    local ok = pcall(function()
        MySQL.update.await(
            ("UPDATE players SET %s = JSON_SET(COALESCE(%s, JSON_OBJECT()), '$.name', ?, '$.grade', JSON_OBJECT('level', ?)) WHERE citizenid = ?"):format(column, column),
            { factionName, tonumber(grade) or 0, identifier }
        )
    end)
    return ok
end

function GetGangGrades(gangName)
    local gangs = GetQbxGangs()
    local gang = gangs[gangName]
    if not gang or not gang.grades then return {} end
    local grades = {}
    for level, grade in pairs(gang.grades) do
        grades[#grades + 1] = {
            level = tonumber(level),
            label = grade.name or ("Grade " .. level),
        }
    end
    table.sort(grades, function(a, b) return a.level < b.level end)
    return grades
end

function GetGangMembers(gangName, cb)
    local members = {}
    local seen = {}

    for _, src in ipairs(GetAllQbxPlayerSources()) do
        local player = GetPlayer(src)
        if player and player.PlayerData and player.PlayerData.gang and player.PlayerData.gang.name == gangName then
            local info = player.PlayerData.charinfo or {}
            local grade = player.PlayerData.gang.grade or {}
            local cid = player.PlayerData.citizenid
            if cid then seen[cid] = true end
            members[#members + 1] = {
                source = src,
                identifier = cid,
                name = (info.firstname or "Unknown") .. " " .. (info.lastname or ""),
                grade = grade.level or 0,
                gradeLabel = grade.name or "",
                online = true,
            }
        end
    end

    local rows = MySQL.query.await(
        "SELECT citizenid, charinfo, gang FROM players WHERE JSON_EXTRACT(gang, '$.name') = ?",
        { gangName }
    ) or {}
    for _, row in ipairs(rows) do
        if not seen[row.citizenid] then
            local info = type(row.charinfo) == "string" and (json.decode(row.charinfo) or {}) or (row.charinfo or {})
            local gang = type(row.gang) == "string" and (json.decode(row.gang) or {}) or (row.gang or {})
            local grade = gang.grade or {}
            members[#members + 1] = {
                source = nil,
                identifier = row.citizenid,
                name = (info.firstname or "Unknown") .. " " .. (info.lastname or ""),
                grade = tonumber(grade.level) or 0,
                gradeLabel = grade.name or "",
                online = false,
            }
        end
    end

    if type(cb) == "function" then cb(members) end
    return members
end

function IsPlayerAdmin(source)
    source = tonumber(source)
    for i = 1, #Config.AdminGroups do
        if exports.qbx_core:HasPermission(source, Config.AdminGroups[i]) then
            return true
        end
    end
    return false
end

function AddAlcohol(source, amount)
    if not amount or amount <= 0 then return end
    local player = GetPlayer(source)
    if not player then return end
    TriggerClientEvent("pickle_dealerships:addAlcohol", source, amount)
end

function AddSocietyMoney(name, amount)
    if Config.FrameworkSettings.society == "qb-management" then
        exports["qb-management"]:AddMoney(name, amount)
    else
        exports["qb-banking"]:AddMoney(name, amount)
    end
end

function GetSocietyBalance(name, cb)
    if type(cb) ~= "function" then return end
    local system = Config.FrameworkSettings.society or "qb-banking"
    local ok, balance = pcall(function()
        if system == "qb-management" then
            return exports["qb-management"]:GetAccount(name) or 0
        end
        return exports["qb-banking"]:GetAccount(name) or 0
    end)
    cb(ok and balance or 0)
end

function RemoveSocietyMoney(name, amount, cb)
    local system = Config.FrameworkSettings.society or "qb-banking"
    if system == "qb-management" then
        exports["qb-management"]:RemoveMoney(name, amount)
    else
        exports["qb-banking"]:RemoveMoney(name, amount)
    end
    if type(cb) == "function" then cb() end
end

-- Inventory Fallback
CreateThread(function()
    Wait(100)

    if InitializeInventory then return InitializeInventory() end -- ox_inventory / custom bridge took over

    Inventory = {}
    Inventory.Items = {}
    Inventory.Ready = false

    Inventory.CanCarryItem = function(source, name, count)
        -- ox_inventory is the standard for QBX; if we're in the fallback we assume no limits.
        return true
    end

    Inventory.GetInventory = function(source)
        local player = GetPlayer(source)
        if not player or not player.PlayerData then return {} end
        local items = {}
        for _, item in pairs(player.PlayerData.items or {}) do
            items[#items + 1] = {
                name = item.name,
                label = item.label,
                count = item.amount,
                weight = item.weight,
            }
        end
        return items
    end

    Inventory.UpdateInventory = function(source)
        SetTimeout(1000, function()
            TriggerClientEvent("pickle_dealerships:updateInventory", source, Inventory.GetInventory(source))
        end)
    end

    Inventory.AddItem = function(source, name, count, metadata)
        local result = exports.qbx_core:AddItem(source, name, count, nil, metadata)
        Inventory.UpdateInventory(source)
        return result
    end

    Inventory.RemoveItem = function(source, name, count)
        local result = exports.qbx_core:RemoveItem(source, name, count)
        Inventory.UpdateInventory(source)
        return result
    end

    Inventory.AddWeapon = function(source, name, count, metadata)
        Inventory.AddItem(source, name, count, metadata)
    end

    Inventory.RemoveWeapon = function(source, name, count)
        Inventory.RemoveItem(source, name, count)
    end

    Inventory.GetItemCount = function(source, name)
        local player = GetPlayer(source)
        if not player then return 0 end
        for _, item in pairs(player.PlayerData.items or {}) do
            if item.name == name then return item.amount end
        end
        return 0
    end

    Inventory.HasWeapon = function(source, name)
        return Inventory.GetItemCount(source, name) > 0
    end

    -- Returns every slot of `name` the player is carrying, with metadata. Used
    -- by the printable-coupon picker so the customer can choose which coupon
    -- in their inventory to apply at purchase. Prefers ox_inventory's native
    -- search since QBX hosts items there; falls back to the QBX item table.
    Inventory.GetItemsByName = function(source, name)
        if GetResourceState("ox_inventory") == "started" then
            local ok, slots = pcall(function() return exports.ox_inventory:Search(source, "slots", name) end)
            if ok and type(slots) == "table" then
                local out = {}
                for _, s in ipairs(slots) do
                    out[#out + 1] = { slot = s.slot, count = s.count, metadata = s.metadata }
                end
                return out
            end
        end
        local player = GetPlayer(source)
        if not player or not player.PlayerData then return {} end
        local out = {}
        for slot, item in pairs(player.PlayerData.items or {}) do
            if item.name == name then
                out[#out + 1] = { slot = item.slot or slot, count = item.amount, metadata = item.info or item.metadata }
            end
        end
        return out
    end

    lib.callback.register("pickle_dealerships:getInventory", function(source)
        return Inventory.GetInventory(source)
    end)

    -- QBX uses ox_inventory as the canonical item source; qbx_core no longer
    -- exposes a GetSharedItems export. Prefer ox_inventory, then fall back to
    -- older QBX builds that still carry the export.
    local sharedItems = {}
    if GetResourceState("ox_inventory") == "started" then
        local ok, items = pcall(function() return exports.ox_inventory:Items() end)
        if ok and type(items) == "table" then sharedItems = items end
    end
    if next(sharedItems) == nil then
        local ok, items = pcall(function() return exports.qbx_core:GetSharedItems() end)
        if ok and type(items) == "table" then sharedItems = items end
    end
    for item, itemData in pairs(sharedItems) do
        Inventory.Items[item] = { label = itemData.label }
    end
    Inventory.Ready = true
end)
