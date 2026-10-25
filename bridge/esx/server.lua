if GetResourceState('es_extended') ~= 'started' then return end

ESX = exports.es_extended:getSharedObject()

function RegisterUsableItem(...)
    ESX.RegisterUsableItem(...)
end

function ShowNotification(target, text)
	TriggerClientEvent(GetCurrentResourceName()..":showNotification", target, text)
end

function GetIdentifier(source)
    local xPlayer = ESX.GetPlayerFromId(source)
    if not xPlayer or not xPlayer.identifier then return end
    return xPlayer and xPlayer.identifier
end

function GetSourceFromIdentifier(identifier)
    local xPlayer = ESX.GetPlayerFromIdentifier(identifier)
    return xPlayer and xPlayer.source or nil
end

function GetPlayerCharacterName(source)
    local xPlayer = ESX.GetPlayerFromId(source)
    if not xPlayer then return "Unknown Name" end
    return xPlayer.getName()
end

--- Resolves a display name for an arbitrary identifier — online or offline.
--- ESX stores character data in the `users` table with `firstname` /
--- `lastname` columns (no JSON blob like QB). Used by ledger entries,
--- top-seller reporting, fire-offline-employee flows — anywhere that
--- previously hit a `players` table directly and broke on ESX.
---@param identifier string
---@return string|nil
function GetCharacterNameByIdentifier(identifier)
    if not identifier or identifier == "" then return nil end
    local function trim(s)
        local t = s:gsub("^%s+", ""):gsub("%s+$", "")
        return t
    end
    -- Online first — skip the DB round-trip when we can.
    local xPlayer = ESX.GetPlayerFromIdentifier(identifier)
    if xPlayer and xPlayer.getName then
        local name = xPlayer.getName()
        if name and name ~= "" then return name end
    end
    local row = MySQL.single.await(
        "SELECT firstname, lastname FROM users WHERE identifier = ? LIMIT 1",
        { identifier }
    )
    if not row then return nil end
    if not row.firstname and not row.lastname then return nil end
    return trim((row.firstname or "") .. " " .. (row.lastname or ""))
end

function GetEmployees(jobName,cb)
    local rows=MySQL.query.await('SELECT identifier,firstname,lastname,job_grade FROM users WHERE job=?',{jobName}) or {}
    local employees={}
    for _,row in ipairs(rows) do
        local src=GetSourceFromIdentifier(row.identifier)
        employees[#employees+1]={identifier=row.identifier,source=src,name=(row.firstname or '')..' '..(row.lastname or ''),grade=row.job_grade,online=src~=nil}
    end
    if type(cb)=='function' then cb(employees) end
    return employees
end

function GetJobGrades(jobName)
    local job = ESX.GetJobs()
    if not job or not job[jobName] or not job[jobName].grades then return {} end
    local grades = {}
    for _, grade in pairs(job[jobName].grades) do
        grades[#grades + 1] = {
            level = grade.grade,
            label = grade.label or ("Grade " .. grade.grade),
        }
    end
    table.sort(grades, function(a, b) return a.level < b.level end)
    return grades
end

function CanAccessGroup(source, data)
    if not data then return true end
    local pdata = ESX.GetPlayerFromId(source)
    for k,v in pairs(data.jobs) do 
        if (pdata.job.name == k and pdata.job.grade >= v) then return true end
    end
    return false
end 

function CheckPermission(source, permission)
    if permission.ignorePermissions then return true end
    local xPlayer = ESX.GetPlayerFromId(source)
    if not xPlayer then return end
    local name = xPlayer.job.name
    local rank = xPlayer.job.grade
    local group = xPlayer.getGroup()
    if permission.jobs[name] and permission.jobs[name] <= rank then 
        return true
    end
    for i=1, #(permission.groups or {}) do 
        if group == permission.groups[i] then 
            return true 
        end
    end
end

function AddMoney(source, count, currency)
    local xPlayer = ESX.GetPlayerFromId(source)
    if not xPlayer then return false end
    local currency = currency or "money"
    local before=GetMoney(source,currency)
    if not DealerInt(count,0,2147483647) then return false end
    if (currency == "money") then
        xPlayer.addMoney(count)
    elseif (currency == "dirty") then
        xPlayer.addAccountMoney("black_money", count)
    elseif (currency == "bank") then
        xPlayer.addAccountMoney("bank", count)
    end
    TriggerClientEvent("pickle_dealerships:updateMoney", source, GetMoney(source, currency))
    return GetMoney(source,currency)==before + count
end

function RemoveMoney(source, count, currency)
    local xPlayer = ESX.GetPlayerFromId(source)
    if not xPlayer then return false end
    local currency = currency or "money"
    local before=GetMoney(source,currency)
    if not DealerInt(count,0,2147483647) or before<count then return false end
    if (currency == "money") then
        xPlayer.removeMoney(count)
    elseif (currency == "dirty") then
        xPlayer.removeAccountMoney("black_money", count)
    elseif (currency == "bank") then
        xPlayer.removeAccountMoney("bank", count)
    end
    TriggerClientEvent("pickle_dealerships:updateMoney", source, GetMoney(source, currency))
    return GetMoney(source,currency)==before - count
end

function GetMoney(source, currency)
    local xPlayer = ESX.GetPlayerFromId(source)
    local currency = currency or "money"
    local money = 0
    if (currency == "money") then
        money = xPlayer.getMoney()
    elseif (currency == "dirty") then
        money = xPlayer.getAccount("black_money").money
    elseif (currency == "bank") then
        money = xPlayer.getAccount("bank").money
    end
    TriggerClientEvent("pickle_dealerships:updateMoney", source, money)
    return money
end

function GetOwnedVehicleFromPlate(plate)
    local data = MySQL.Sync.fetchAll("SELECT * FROM owned_vehicles WHERE plate=@plate;", {
        ['@plate'] = plate,
    })[1]
    if not data then return nil end
    local model = nil
    if data.vehicle then
        local props = json.decode(data.vehicle)
        if type(props) == 'table' then
            -- ESX stores model as a hash; we may not be able to reverse it here.
            model = props.modelName or props.model_name or nil
        end
    end
    return { owner = data.owner, model = model, properties=data.vehicle }
end

function AddOwnedVehicleWithProps(source, model, plate, properties)
    local xPlayer = ESX.GetPlayerFromId(source)
    if not xPlayer or not plate then return false end
    local changed=0
    local props = type(properties) == "table" and properties or (type(properties) == "string" and json.decode(properties) or {})
    props.plate = DealerPlate(plate)
    props.model = joaat(model)
    props.modelName=model
    changed=MySQL.update.await("INSERT INTO owned_vehicles (owner, plate, vehicle) VALUES (@owner, @plate, @vehicle);", {
        ['@owner'] = xPlayer.identifier,
        ['@plate'] = DealerPlate(plate),
        ['@vehicle'] = json.encode(props),
    })
    return changed==1
end

function RemoveOwnedVehicle(identifier, plate)
    if not identifier or not plate then return false end
    local changed=MySQL.update.await("DELETE FROM owned_vehicles WHERE owner=@owner AND plate=@plate;", {
        ['@owner'] = identifier,
        ['@plate'] = plate,
    })
    return changed==1
end

function UpdateVehiclePlate(source, plate, newPlate)
    local xPlayer = ESX.GetPlayerFromId(source)
    MySQL.Async.execute("UPDATE owned_vehicles SET plate=@newPlate WHERE owner=@owner AND plate=@plate;", {
        ['@owner'] = xPlayer.identifier,
        ['@plate'] = plate,
        ['@newPlate'] = newPlate,
    })
end

function GetPlayerJob(source)
    local xPlayer = ESX.GetPlayerFromId(tonumber(source))
    if not xPlayer then return "Unknown Job", "Unknown Grade" end
    return {label = xPlayer.job.label, rank_label = xPlayer.job.grade_label}
end

function GetPlayerJobName(source)
    local xPlayer = ESX.GetPlayerFromId(tonumber(source))
    if not xPlayer or not xPlayer.job then return nil end
    return xPlayer.job.name
end

function GetPlayerJobGrade(source)
    local xPlayer = ESX.GetPlayerFromId(tonumber(source))
    if not xPlayer or not xPlayer.job then return 0 end
    return xPlayer.job.grade or 0
end

function GetPlayerGangName(_)
    -- ESX has no native gang concept; frameworks extending ESX can override this bridge.
    return nil
end

function GetPlayerGangGrade(_)
    return 0
end

function SetPlayerGang(_, _, _)
    return false
end

--- ESX doesn't natively track gangs; fallback to job only.
function SetFactionByIdentifier(factionType, identifier, factionName, grade)
    if factionType == "gang" or not identifier or not factionName then return false end
    local src = GetSourceFromIdentifier(identifier)
    if src then
        SetPlayerJob(src, factionName, grade)
        return true
    end
    local ok = pcall(function()
        MySQL.update.await(
            "UPDATE users SET job = ?, job_grade = ? WHERE identifier = ?",
            { factionName, tonumber(grade) or 0, identifier }
        )
    end)
    return ok
end

function GetGangGrades(_)
    return {}
end

function GetGangMembers(_, cb)
    if type(cb) == "function" then cb({}) end
    return {}
end

function SetPlayerJob(source, job, grade)
    local xPlayer = ESX.GetPlayerFromId(tonumber(source))
    if not xPlayer then return end
    xPlayer.setJob(job, grade)
end

function IsPlayerAdmin(source)
    local xPlayer = ESX.GetPlayerFromId(source)
    if not xPlayer then return false end
    local group = xPlayer.getGroup()
    for i=1, #Config.AdminGroups do 
        if group == Config.AdminGroups[i] then
            return true 
        end
    end
    return false
end

function AddAlcohol(source, amount)
    if not amount or amount <= 0 then return end
    TriggerClientEvent("esx_status:add", source, "drunk", amount)
end

function AddSocietyMoney(name, amount)
    TriggerEvent('esx_addonaccount:getSharedAccount', "society_"..name, function(account)
        account.addMoney(amount)
    end)
end

function GetSocietyBalance(name, cb)
    if type(cb) ~= "function" then return end
    TriggerEvent('esx_addonaccount:getSharedAccount', "society_"..name, function(account)
        cb(account and account.money or 0)
    end)
end

function RemoveSocietyMoney(name, amount, cb)
    cb = (type(cb) == "function") and cb or function() end
    TriggerEvent('esx_addonaccount:getSharedAccount', "society_"..name, function(account)
        if account then
            account.removeMoney(amount)
        end
        cb()
    end)
end

function AddOwnedVehicle(source, model)
    local xPlayer = ESX.GetPlayerFromId(source)
    local plate = ""
    local letters = {"A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z"}
    local numbers = {"0", "1", "2", "3", "4", "5", "6", "7", "8", "9"}
    for i = 1, 3 do
        plate = plate .. letters[math.random(1, #letters)]
    end
    plate = plate .. " "
    for i = 1, 3 do
        plate = plate .. numbers[math.random(1, #numbers)]
    end
    MySQL.Async.execute("INSERT INTO owned_vehicles (owner, plate, vehicle) VALUES (@owner, @plate, @vehicle);", {
        ['@owner'] = xPlayer.identifier,
        ['@plate'] = plate,
        ['@vehicle'] = json.encode({
            plate = toupper(plate),
            model = joaat(model),
        }),
    })
end

-- Inventory Fallback

CreateThread(function()
    Wait(100)

    if InitializeInventory then return InitializeInventory() end -- Already loaded through inventory folder.
    
    Inventory = {}

    Inventory.Items = {}
    
    Inventory.Ready = false

    Inventory.CanCarryItem = function(source, name, count)
        local xPlayer = ESX.GetPlayerFromId(source)
        if Config.InventoryLimit then 
            local item = xPlayer.getInventoryItem(name)
            return (item.limit >= item.count + count)
        else 
            return xPlayer.canCarryItem(name, count)
        end
    end

    Inventory.GetInventory = function(source)
        local xPlayer = ESX.GetPlayerFromId(source)
        local items = {}
        local data = xPlayer.getInventory()
        for i=1, #data do 
            local item = data[i]
            if item then
                items[#items + 1] = {
                    name = item.name,
                    label = item.label,
                    count = item.count,
                    weight = item.weight
                }
            end
        end
        return items
    end

    Inventory.UpdateInventory = function(source)
        SetTimeout(1000, function()
            TriggerClientEvent("pickle_dealerships:updateInventory", source, Inventory.GetInventory(source))
        end)
    end

    Inventory.AddItem = function(source, name, count, metadata) -- Metadata is not required.
        local xPlayer = ESX.GetPlayerFromId(source)
        xPlayer.addInventoryItem(name, count)
        Inventory.UpdateInventory(source)
    end

    Inventory.RemoveItem = function(source, name, count)
        local xPlayer = ESX.GetPlayerFromId(source)
        xPlayer.removeInventoryItem(name, count)
        Inventory.UpdateInventory(source)
    end

    Inventory.AddWeapon = function(source, name, count, metadata) -- Metadata is not required.
        local xPlayer = ESX.GetPlayerFromId(source)
        xPlayer.addWeapon(name, 0)
        Inventory.UpdateInventory(source)
    end

    Inventory.RemoveWeapon = function(source, name, count)
        local xPlayer = ESX.GetPlayerFromId(source)
        xPlayer.removeWeapon(name, 0)
        Inventory.UpdateInventory(source)
    end

    Inventory.GetItemCount = function(source, name)
        local xPlayer = ESX.GetPlayerFromId(source)
        local item = xPlayer.getInventoryItem(name)
        return item and item.count or 0
    end

    Inventory.HasWeapon = function(source, name, count)
        local xPlayer = ESX.GetPlayerFromId(source)
        return xPlayer.hasWeapon(name)
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
        local xPlayer = ESX.GetPlayerFromId(source)
        if not xPlayer then return {} end
        local item = xPlayer.getInventoryItem(name)
        if not item or (item.count or 0) <= 0 then return {} end
        -- Vanilla ESX inventories don't model per-slot metadata. Surface a
        -- single aggregated entry so the picker still works; metadata-rich
        -- coupon items only really matter on ox_inventory anyway.
        return { { slot = nil, count = item.count, metadata = nil } }
    end

    lib.callback.register("pickle_dealerships:getInventory", function(source)
        return Inventory.GetInventory(source)
    end)
    
    if GetResourceState("ox_inventory") == "started" then 
        for item, data in pairs(exports.ox_inventory:Items()) do
            Inventory.Items[item] = {label = data.label}
        end
        Inventory.Ready = true
    elseif GetResourceState("qs-inventory") == "started" then 
        for item, data in pairs(exports['qs-inventory']:GetItemList()) do
            Inventory.Items[item] = {label = data.label}
        end
        Inventory.Ready = true
    else
        MySQL.ready(function() 
            MySQL.Async.fetchAll("SELECT * FROM items;", {}, function(results) 
                for i=1, #results do 
                    Inventory.Items[results[i].name] = {label = results[i].label}
                end
                Inventory.Ready = true
            end)
        end)
    end
end)