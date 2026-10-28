if GetResourceState('qb-core') ~= 'started' or GetResourceState('qbx_core') == 'started' then return end

QBCore = exports['qb-core']:GetCoreObject()

function RegisterUsableItem(...)
    QBCore.Functions.CreateUseableItem(...)
end

function ShowNotification(target, text)
	TriggerClientEvent(GetCurrentResourceName()..":showNotification", target, text)
end

function GetIdentifier(source)
    local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))?.PlayerData
    if not xPlayer or not xPlayer.citizenid then return end
    return xPlayer.citizenid 
end

function GetSourceFromIdentifier(identifier)
    local xPlayer = QBCore.Functions.GetPlayerByCitizenId(identifier)
    return xPlayer and xPlayer?.PlayerData.source or nil
end

function GetPlayerCharacterName(source)
    local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))
    if not xPlayer or not xPlayer.PlayerData then return "Unknown Name" end
    return xPlayer.PlayerData.charinfo.firstname .. " " .. xPlayer.PlayerData.charinfo.lastname
end

--- Resolves a display name for an arbitrary identifier — works for offline
--- players too. Used for ledger entries, top-seller reporting, fire-on-
--- offline-employee messages, etc. Non-bridge code must not hit QB's
--- `players` table directly or it'll silently break on ESX/standalone.
--- Returns nil if the identifier isn't known.
---@param identifier string
---@return string|nil
function GetCharacterNameByIdentifier(identifier)
    if not identifier or identifier == "" then return nil end
    -- Online first — avoids an SQL round-trip when the player's in-game.
    -- gsub returns (str, count) so wrap in a helper that trims both ends
    -- and returns a single value — otherwise Lua's multi-return leaks the
    -- count through `return`.
    local function trim(s)
        local t = s:gsub("^%s+", ""):gsub("%s+$", "")
        return t
    end
    local xPlayer = QBCore.Functions.GetPlayerByCitizenId(identifier)
    if xPlayer and xPlayer.PlayerData and xPlayer.PlayerData.charinfo then
        local info = xPlayer.PlayerData.charinfo
        return trim((info.firstname or "") .. " " .. (info.lastname or ""))
    end
    -- Offline — read from `players.charinfo` (QB's authoritative store).
    local row = MySQL.single.await(
        "SELECT charinfo FROM players WHERE citizenid = ? LIMIT 1",
        { identifier }
    )
    if not row or not row.charinfo then return nil end
    local info = type(row.charinfo) == "string" and (json.decode(row.charinfo) or {}) or row.charinfo
    if not info.firstname and not info.lastname then return nil end
    return trim((info.firstname or "") .. " " .. (info.lastname or ""))
end

function GetEmployees(jobName, cb)
    local employees = {}
    local seen = {}
    local players = QBCore.Functions.GetQBPlayers()
    for _, player in pairs(players) do
        if player and player.PlayerData and player.PlayerData.job and player.PlayerData.job.name == jobName then
            seen[player.PlayerData.citizenid] = true
            employees[#employees + 1] = {
                source = player.PlayerData.source,
                identifier = player.PlayerData.citizenid,
                name = player.PlayerData.charinfo.firstname .. " " .. player.PlayerData.charinfo.lastname,
                grade = player.PlayerData.job.grade.level,
                gradeLabel = player.PlayerData.job.grade.name,
                online = true,
            }
        end
    end

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
    local job = QBCore.Shared.Jobs[jobName]
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
    local pdata = QBCore.Functions.GetPlayer(tonumber(source)).PlayerData
    for k,v in pairs(data) do 
        if (pdata.job.name == k and pdata.job.grade.level >= v) then return true end
    end
    return false
end

function CheckPermission(source, permission)
    if permission.ignorePermissions then return true end
    local source = tonumber(source)
    local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))?.PlayerData
    if not xPlayer then return end
    local name = xPlayer.job.name
    local rank = xPlayer.job.grade.level
    if permission.jobs[name] and permission.jobs[name] <= rank then 
        return true
    end
    for i=1, #(permission.groups or {}) do 
        if QBCore.Functions.HasPermission(source, permission.groups[i]) then 
            return true 
        end
    end
end

function AddMoney(source, count, currency)
    if type(count) ~= 'number' or count < 0 or count % 1 ~= 0 then return false end
    local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))
    if not xPlayer then return false end
    currency = currency or "money"
    if currency ~= "money" and currency ~= "bank" and currency ~= "dirty" then return false end
    if count == 0 then return true end
    if (currency == "money") then
        return xPlayer.Functions.AddMoney('cash', count) == true
    elseif (currency == "bank") then
        return xPlayer.Functions.AddMoney('bank', count) == true
    elseif (currency == "dirty") then
        local setting = Config.FrameworkSettings.dirtyMoney
        return Inventory.AddItem(source, setting == "DEFAULT" and 'dirty_money' or setting, count) == true
    end
    return false
end

function RemoveMoney(source, count, currency)
    if type(count) ~= 'number' or count < 0 or count % 1 ~= 0 then return false end
    local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))
    if not xPlayer then return false end
    currency = currency or "money"
    if currency ~= "money" and currency ~= "bank" and currency ~= "dirty" then return false end
    if count == 0 then return true end
    if (currency == "money") then
        return xPlayer.Functions.RemoveMoney('cash', count)
    elseif (currency == "bank") then
        return xPlayer.Functions.RemoveMoney('bank', count)
    elseif (currency == "dirty") then
        local setting = Config.FrameworkSettings.dirtyMoney
        return Inventory.RemoveItem(source, setting == "DEFAULT" and 'dirty_money' or setting, count) == true
    end
    return false
end

function GetMoney(source, currency)
    local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))
    if not xPlayer then return 0 end
    local currency = currency or "money"
    local money = 0
    if (currency == "money") then
        money = xPlayer.PlayerData.money.cash
    elseif (currency == "bank") then
        money = xPlayer.PlayerData.money.bank
    elseif (currency == "dirty") then
        local setting = Config.FrameworkSettings.dirtyMoney
        money = Inventory.GetItemCount(source, setting == "DEFAULT" and 'dirty_money' or setting)
    end
    return money
end

function GetOwnedVehicleFromPlate(plate)
    if not plate then return nil end
    -- Normalize: strip ALL whitespace and uppercase; compare the same way in SQL
    local normalized = string.upper(tostring(plate):gsub('%s+', ''))
    local data = MySQL.Sync.fetchAll("SELECT * FROM player_vehicles WHERE REPLACE(UPPER(plate), ' ', '')=@plate LIMIT 1;", {
        ['@plate'] = normalized,
    })[1]
    return data and {owner = data.citizenid, model = data.vehicle, properties=data.mods} or nil
end

-- CD Garage adds an `in_garage` column to player_vehicles and uses it
-- (not `state`) to decide whether the car is physically parked. We probe
-- the schema once at boot and inject the column only when present, so the
-- bridge stays compatible with vanilla QB garages too.
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

-- Plate format: 4 letters + 4 digits, no space. The legacy "3+space+3"
-- format is 7 chars and CD Garage normalises stored plates to 8 chars,
-- which caused sync mismatches when the script and the garage disagreed
-- on trailing whitespace.
local function GeneratePlateQB()
    local letters = {"A","B","C","D","E","F","G","H","I","J","K","L","M","N","O","P","Q","R","S","T","U","V","W","X","Y","Z"}
    local numbers = {"0","1","2","3","4","5","6","7","8","9"}
    local parts = {}
    for i = 1, 4 do parts[#parts + 1] = letters[math.random(1, #letters)] end
    for i = 1, 4 do parts[#parts + 1] = numbers[math.random(1, #numbers)] end
    return table.concat(parts)
end

--- Inserts a new owned vehicle for the player. `state = 1` marks the car as
--- "out" (the player drives it away from the dealership); `in_garage = 0`
--- is the CD Garage equivalent, injected only if the column exists.
--- The mods JSON always carries `model` and `plate` so CD Garage's
--- integrity check (error 5111) treats it as a legitimate vehicle.
function AddOwnedVehicle(source, model)
    local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))
    if not xPlayer then return end
    local plate = GeneratePlateQB()
    local mods = json.encode({ model = joaat(model), plate = plate })

    if DetectInGarageColumn() then
        MySQL.Async.execute(
            'INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state, in_garage) VALUES (@license, @citizenid, @vehicle, @hash, @mods, @plate, @garage, @state, @in_garage)',
            {
                ['@license']   = xPlayer.PlayerData.license,
                ['@citizenid'] = xPlayer.PlayerData.citizenid,
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
                ['@license']   = xPlayer.PlayerData.license,
                ['@citizenid'] = xPlayer.PlayerData.citizenid,
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
    local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))
    if not xPlayer or not plate then return false end

    local changed=0
    -- Normalise the plate and inject model + plate into the mods JSON so
    -- the CD Garage integrity check sees a consistent record.
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
                ['@license']   = xPlayer.PlayerData.license,
                ['@citizenid'] = xPlayer.PlayerData.citizenid,
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
                ['@license']   = xPlayer.PlayerData.license,
                ['@citizenid'] = xPlayer.PlayerData.citizenid,
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
    local changed=MySQL.update.await("DELETE FROM player_vehicles WHERE REPLACE(UPPER(plate), ' ', '')=REPLACE(UPPER(@plate), ' ', '') AND citizenid=@citizenid",
    {
        ['@plate'] = plate,
        ['@citizenid'] = identifier,
    })
    return changed==1
end

function UpdateVehiclePlate(source, plate, newPlate)
    local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))
    MySQL.Async.execute('UPDATE player_vehicles SET plate = @newPlate WHERE plate = @plate AND citizenid = @citizenid',
    {
        ['@newPlate'] = newPlate,
        ['@plate'] = plate,
        ['@citizenid'] = xPlayer.PlayerData.citizenid
    })
end

function GetPlayerJob(source)
    local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))
    if not xPlayer then return end
    return {label = xPlayer.PlayerData.job.label, rank_label = xPlayer.PlayerData.job.grade.name}
end

function GetPlayerJobName(source)
    local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))
    if not xPlayer or not xPlayer.PlayerData or not xPlayer.PlayerData.job then return nil end
    return xPlayer.PlayerData.job.name
end

function GetPlayerJobGrade(source)
    local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))
    if not xPlayer or not xPlayer.PlayerData or not xPlayer.PlayerData.job then return 0 end
    return xPlayer.PlayerData.job.grade.level or 0
end

function GetPlayerGangName(source)
    local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))
    if not xPlayer or not xPlayer.PlayerData or not xPlayer.PlayerData.gang then return nil end
    return xPlayer.PlayerData.gang.name
end

function GetPlayerGangGrade(source)
    local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))
    if not xPlayer or not xPlayer.PlayerData or not xPlayer.PlayerData.gang or not xPlayer.PlayerData.gang.grade then return 0 end
    return xPlayer.PlayerData.gang.grade.level or 0
end

function SetPlayerGang(source, gang, grade)
    local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))
    if not xPlayer or not xPlayer.Functions.SetGang then return false end
    xPlayer.Functions.SetGang(gang, grade)
    return true
end

--- Applies a faction change to a player by citizenid, whether online or offline.
function SetFactionByIdentifier(factionType, identifier, factionName, grade)
    if not identifier or not factionName then return false end
    local src = GetSourceFromIdentifier(identifier)
    if src then
        if factionType == "gang" then return SetPlayerGang(src, factionName, grade) end
        SetPlayerJob(src, factionName, grade)
        return true
    end
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
    if not QBCore.Shared or not QBCore.Shared.Gangs then return {} end
    local gang = QBCore.Shared.Gangs[gangName]
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
    local players = QBCore.Functions.GetQBPlayers()
    for _, player in pairs(players) do
        if player and player.PlayerData and player.PlayerData.gang and player.PlayerData.gang.name == gangName then
            seen[player.PlayerData.citizenid] = true
            members[#members + 1] = {
                source = player.PlayerData.source,
                identifier = player.PlayerData.citizenid,
                name = player.PlayerData.charinfo.firstname .. " " .. player.PlayerData.charinfo.lastname,
                grade = player.PlayerData.gang.grade and player.PlayerData.gang.grade.level or 0,
                gradeLabel = player.PlayerData.gang.grade and player.PlayerData.gang.grade.name or "",
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

function SetPlayerJob(source, job, grade)
    local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))
    xPlayer.Functions.SetJob(job, grade)
end

function IsPlayerAdmin(source)
    local source = tonumber(source)
    local permissions = QBCore.Functions.GetPermission(source)
    for i=1, #Config.AdminGroups do 
        if QBCore.Functions.HasPermission(source, Config.AdminGroups[i]) then
            return true 
        end
    end
    return false
end

function AddAlcohol(source, amount)
    if not amount or amount <= 0 then return end
    local Player = QBCore.Functions.GetPlayer(tonumber(source))
    if not Player then return end
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
    local system = Config.FrameworkSettings.society or "qb-management"
    if system == "qb-management" then
        local ok, balance = pcall(function()
            return exports["qb-management"]:GetAccount(name) or 0
        end)
        cb(ok and balance or 0)
    else
        local ok, balance = pcall(function()
            return exports["qb-banking"]:GetAccount(name) or 0
        end)
        cb(ok and balance or 0)
    end
end

function RemoveSocietyMoney(name, amount, cb)
    local system = Config.FrameworkSettings.society or "qb-management"
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
    
    if InitializeInventory then return InitializeInventory() end -- Already loaded through inventory folder.
    
    Inventory = {}

    Inventory.Items = {}
    
    Inventory.Ready = false

    Inventory.CanCarryItem = function(source, name, count)
        local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))
        local weight = QBCore.Player.GetTotalWeight(xPlayer.PlayerData.items)
        local item = QBCore.Shared.Items[name:lower()]
        if not item then return true end -- QBX Compatibility
        if not QBCore.Config or not QBCore.Config.Player or not QBCore.Config.Player.MaxWeight then return true end -- QBX Compatibility
        return ((weight + (item.weight * count)) <= QBCore.Config.Player.MaxWeight)
    end

    Inventory.GetInventory = function(source)
        local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))
        local items = {}
        local data = xPlayer.PlayerData.items
        for slot, item in pairs(data) do 
            items[#items + 1] = {
                name = item.name,
                label = item.label,
                count = item.amount,
                weight = item.weight
            }
        end
        return items
    end

    Inventory.UpdateInventory = function(source)
        SetTimeout(1000, function()
            TriggerClientEvent("pickle_dealerships:updateInventory", source, Inventory.GetInventory(source))
        end)
    end

    Inventory.AddItem = function(source, name, count, metadata) -- Metadata is not required.
        local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))
        local result = xPlayer.Functions.AddItem(name, count, nil, metadata)
        Inventory.UpdateInventory(source)
        return result
    end

    Inventory.RemoveItem = function(source, name, count)
        local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))
        local result = xPlayer.Functions.RemoveItem(name, count)
        Inventory.UpdateInventory(source)
        return result
    end

    Inventory.AddWeapon = function(source, name, count, metadata) -- Metadata is not required.
        Inventory.AddItem(source, name, count, metadata)
    end

    Inventory.RemoveWeapon = function(source, name, count)
        Inventory.RemoveItem(source, name, count, metadata)
    end

    Inventory.GetItemCount = function(source, name)
        local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))
        if not xPlayer then return 0 end
        local item = xPlayer.Functions.GetItemByName(name)
        return item and item.amount or 0
    end

    Inventory.HasWeapon = function(source, name, count)
        return (Inventory.GetItemCount(source, name) > 0)
    end

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
        local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))
        if not xPlayer then return {} end
        local out = {}
        for slot, item in pairs(xPlayer.PlayerData.items or {}) do
            if item.name == name then
                out[#out + 1] = { slot = item.slot or slot, count = item.amount, metadata = item.info or item.metadata }
            end
        end
        return out
    end

    lib.callback.register("pickle_dealerships:getInventory", function(source)
        return Inventory.GetInventory(source)
    end)

    for item, data in pairs(QBCore.Shared.Items) do
        Inventory.Items[item] = {label = data.label}
    end
    Inventory.Ready = true
end)