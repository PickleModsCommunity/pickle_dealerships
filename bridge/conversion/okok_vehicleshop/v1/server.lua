-- =============================================
--  pickle_dealerships | bridge/conversion/okok_vehicleshop/v1/server.lua
--  Adapter for okok_vehicleshop v1. Shared helpers are exposed on OkokConversionHelpers
--  so v2 can reuse them without duplicating SQL.
-- =============================================

OkokConversionHelpers = OkokConversionHelpers or {}

local function safeJsonDecode(value)
    if value == nil or value == '' then return nil end
    if type(value) == 'table' then return value end
    local ok, decoded = pcall(json.decode, value)
    if ok then return decoded end
    return nil
end

local function okokTypeToPickleType(t)
    if t == 'air' then return 'air' end
    if t == 'boat' or t == 'water' then return 'boat' end
    return 'car'
end

--- Sources Config.Stands from okok_vehicleshop's own config.lua. okok ships all
--- shop geometry as a Lua table rather than in the DB, so we evaluate the file
--- in a sandboxed env with vector* stubs to recover it.
local _okokStandsCache
local function loadOkokStands()
    if _okokStandsCache ~= nil then return _okokStandsCache or nil end
    local cfgStr = LoadResourceFile('okok_vehicleshop', 'config.lua')
    if not cfgStr or cfgStr == '' then
        _okokStandsCache = false
        return nil
    end
    local toPoint3 = function(x, y, z) return { x = x, y = y, z = z } end
    local toPoint4 = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end
    local env = {
        vector  = toPoint3,
        vec3    = toPoint3,
        vector3 = toPoint3,
        vector4 = toPoint4,
        vec4    = toPoint4,
        Config  = {},
        Locales = {},
        GetResourceState = function() return 'missing' end,
    }
    env.math=math; env.string=string; env.table=table; env.pairs=pairs; env.ipairs=ipairs
    env.type=type; env.tonumber=tonumber; env.tostring=tostring; env.joaat=joaat; env.GetHashKey=joaat
    local fn = load(cfgStr, 'okok_config', 't', env)
    if not fn then
        _okokStandsCache = false
        return nil
    end
    local ok = pcall(fn)
    if not ok or type(env.Config.Stands) ~= 'table' then
        _okokStandsCache = false
        return nil
    end
    _okokStandsCache = env.Config.Stands
    return _okokStandsCache
end

local function findOkokStand(shopId)
    local stands = loadOkokStands()
    if not stands then return nil end
    for _, s in ipairs(stands) do
        if tostring(s.id) == tostring(shopId) then return s end
    end
    return nil
end

--- Maps one okok stand entry to pickle metadata fields (coords, spawnPoint,
--- interactionPoints, displaySpots, deliveryPoint). Returns the mutated meta.
local function applyOkokStandToMeta(meta, stand)
    if type(stand) ~= 'table' then return meta end
    local function point(p)
        if type(p) ~= 'table' or p.x == nil then return nil end
        return { x = p.x, y = p.y, z = p.z, w = p.w or 0.0 }
    end

    local marker = stand.markerSettings or {}
    local target = stand.targetSettings or {}
    local vehSettings = stand.vehicleSettings or {}
    local camera = stand.vehicleCameraSettings or {}
    local testDrive = stand.testDriveSettings or {}
    local flatbed = stand.flatbedSettings or {}

    local mainPt = point(marker.vehicleCoords) or point(target.vehicleCoords) or point(stand.blipCoords)
    if mainPt then meta.coords = mainPt end

    local purchase = vehSettings.purchaseVehicleCoords
    if type(purchase) == 'table' and purchase[1] then
        -- Each slot is either a bare vector4 or a single-element array wrapping one.
        local first = purchase[1]
        if type(first) == 'table' and first[1] then first = first[1] end
        local sp = point(first)
        if sp then meta.spawnPoint = sp end
    end

    local sell = point(vehSettings.sellVehicleCoords)
    local mgmt = point(marker.ownerCoords) or point(target.ownerCoords)
    local show = mainPt
    local td   = point(testDrive.carLocation) or point(testDrive.boatLocation) or point(testDrive.airLocation)
    local ipts = meta.interactionPoints or {}
    if sell then ipts.sales = sell end
    if mgmt then ipts.management = mgmt end
    if show then ipts.showroom = show end
    if td   then ipts.testDrive = td end
    if next(ipts) then meta.interactionPoints = ipts end

    if flatbed.spawnPosition then
        local dp = point(flatbed.spawnPosition)
        if dp then meta.deliveryPoint = dp end
    end

    if camera.camera then
        local c = point(camera.camera)
        if c then meta.cameraPoint = c end
    end

    -- Turn each purchase slot into a display spot so the imported shop has
    -- showroom positions out of the box.
    if type(purchase) == 'table' and #purchase > 0 then
        local spots, nextId = {}, 0
        for _, group in ipairs(purchase) do
            local p = group
            if type(group) == 'table' and group[1] then p = group[1] end
            local sp = point(p)
            if sp then
                nextId = nextId + 1
                sp.id = nextId
                spots[#spots + 1] = sp
            end
        end
        if #spots > 0 then
            meta.displaySpots = spots
            meta._nextSpotId = nextId
        end
    end

    return meta
end

OkokConversionHelpers.loadStands = loadOkokStands
OkokConversionHelpers.findStand = findOkokStand
OkokConversionHelpers.applyStandToMeta = applyOkokStandToMeta

-- ===================== catalog =====================
function OkokConversionHelpers.catalogEntity()
    return {
        label = 'Wholesale Catalog',
        requires = { 'okokvehicleshop_vehicles' },
        list = function()
            local rows = MySQL.query.await("SELECT vehicle_id, vehicle_name, category, type, price, owner_buy_price FROM okokvehicleshop_vehicles") or {}
            local out = {}
            for _, r in ipairs(rows) do
                -- Show the sticker price players actually pay so the picker
                -- reflects what the imported listing will cost.
                local sticker = tonumber(r.price) or tonumber(r.owner_buy_price) or 0
                out[#out + 1] = {
                    id = r.vehicle_id,
                    label = (r.vehicle_name or r.vehicle_id) .. ' — $' .. math.floor(sticker),
                    meta = { class = r.category, type = r.type },
                }
            end
            return out
        end,
        import = function(selectedIds, options, _ctx)
            local policy = options.conflictPolicy or 'skip'
            local res = { inserted = 0, skipped = 0, notFound = {} }
            for _, id in ipairs(selectedIds) do
                local r = MySQL.single.await("SELECT * FROM okokvehicleshop_vehicles WHERE vehicle_id = ? LIMIT 1", { id })
                if not r then
                    res.notFound[#res.notFound + 1] = id
                else
                    -- okok's `price` is the sticker players pay; `owner_buy_price`
                    -- is the owner's restock cost. Reproduce the player price by
                    -- back-deriving wholesale from it (pickle re-applies the ×1.3
                    -- markup on seed/order). Fall back to the owner buy price when
                    -- no sticker is recorded so the row is never zero-cost.
                    local sticker = tonumber(r.price)
                    local wholesale
                    if sticker and sticker > 0 then
                        wholesale = math.max(1, math.floor(sticker / 1.3))
                    else
                        wholesale = tonumber(r.owner_buy_price) or 50000
                    end
                    local sql = policy == 'overwrite'
                        and "INSERT INTO pickle_wholesale_catalog (model, label, wholesale, tier, class, vehicle_type) VALUES (?, ?, ?, 'basic', ?, ?) ON DUPLICATE KEY UPDATE wholesale = VALUES(wholesale), label = VALUES(label), class = VALUES(class), vehicle_type = VALUES(vehicle_type)"
                        or  "INSERT IGNORE INTO pickle_wholesale_catalog (model, label, wholesale, tier, class, vehicle_type) VALUES (?, ?, ?, 'basic', ?, ?)"
                    local affected = MySQL.update.await(sql, {
                        r.vehicle_id, r.vehicle_name or r.vehicle_id, wholesale,
                        r.category or 'sedan', okokTypeToPickleType(r.type),
                    })
                    if affected and affected > 0 then
                        res.inserted = res.inserted + 1
                        AssignCatalogModelToGroups(r.vehicle_id, options)
                    else res.skipped = res.skipped + 1 end
                end
            end
            return res
        end,
    }
end

-- ===================== dealerships =====================
function OkokConversionHelpers.dealershipsEntity(v2)
    return {
        label = 'Dealerships',
        requires = { 'okokvehicleshop_shops' },
        list = function()
            local rows = MySQL.query.await("SELECT shop_id, shop_name, owner, money FROM okokvehicleshop_shops") or {}
            local out = {}
            for _, r in ipairs(rows) do
                out[#out + 1] = {
                    id = r.shop_id,
                    label = r.shop_name or r.shop_id,
                    meta = { owner = r.owner, balance = tonumber(r.money) or 0 },
                }
            end
            return out
        end,
        import = function(selectedIds, options, ctx)
            local policy = options.conflictPolicy or 'skip'
            local prefix = options.namePrefix or ''
            local res = { inserted = 0, skipped = 0, notFound = {} }
            for _, id in ipairs(selectedIds) do
                local r = MySQL.single.await("SELECT * FROM okokvehicleshop_shops WHERE shop_id = ? LIMIT 1", { id })
                if not r then
                    res.notFound[#res.notFound + 1] = id
                else
                    local locationKey = 'okok_' .. tostring(r.shop_id)
                    if policy ~= 'duplicate' then
                        local existing = MySQL.single.await("SELECT id FROM pickle_dealerships WHERE location = ? LIMIT 1", { locationKey })
                        if existing then
                            ctx.legacyIdMap[tostring(r.shop_id)] = existing.id
                            res.skipped = res.skipped + 1
                            goto continue
                        end
                    end
                    local stand = findOkokStand(r.shop_id)
                    local meta = {
                        imported_from = 'okok_vehicleshop',
                        imported_version = v2 and 'v2' or 'v1',
                        legacy_id = r.shop_id,
                    }
                    if v2 then
                        meta.weekly_profit_goal = tonumber(r.weekly_profit_goal)
                        meta.weekly_profits = tonumber(r.weekly_profits)
                    end
                    applyOkokStandToMeta(meta, stand)
                    -- If the okok config couldn't be read we still want the record — flag it
                    -- so the admin UI shows a "needs placement" warning.
                    if not stand or not meta.coords then meta.needs_location = true end

                    local ownerId = (r.owner and r.owner ~= '') and r.owner or nil
                    local mode = ownerId and 'player-owned' or 'managed'
                    local shopType = 'car'
                    if stand and stand.type then
                        if stand.type == 'air' then shopType = 'air'
                        elseif stand.type == 'boat' then shopType = 'boat' end
                    end

                    local newId = MySQL.insert.await(
                        "INSERT INTO pickle_dealerships (name, location, type, mode, owner_identifier, balance, metadata) VALUES (?, ?, ?, ?, ?, ?, ?)",
                        {
                            prefix .. (r.shop_name or ('okok Shop ' .. r.shop_id)),
                            locationKey, shopType, mode, ownerId, tonumber(r.money) or 0,
                            json.encode(meta),
                        }
                    )
                    if newId then
                        ctx.legacyIdMap[tostring(r.shop_id)] = newId
                        res.inserted = res.inserted + 1
                    else
                        res.skipped = res.skipped + 1
                    end
                end
                ::continue::
            end
            return res
        end,
    }
end

-- ===================== employees =====================
-- okok stores employees as a JSON array on the shops row. We expose each
-- employee as a synthetic id "<shop_id>:<index>" so the user can pick them
-- individually.
function OkokConversionHelpers.employeesEntity()
    return {
        label = 'Employees',
        requires = { 'okokvehicleshop_shops' },
        list = function()
            local rows = MySQL.query.await("SELECT shop_id, shop_name, employees FROM okokvehicleshop_shops") or {}
            local out = {}
            for _, r in ipairs(rows) do
                local emps = safeJsonDecode(r.employees)
                if type(emps) == 'table' then
                    for i, emp in ipairs(emps) do
                        local cid = type(emp) == 'table' and (emp.identifier or emp.citizenid or emp.id) or tostring(emp)
                        out[#out + 1] = {
                            id = tostring(r.shop_id) .. ':' .. tostring(i),
                            label = (cid or '?') .. ' @ ' .. (r.shop_name or r.shop_id),
                            meta = { shop_id = r.shop_id, citizenid = cid },
                        }
                    end
                end
            end
            return out
        end,
        import = function(selectedIds, _options, ctx)
            local res = { inserted = 0, skipped = 0, notFound = {} }
            for _, compositeId in ipairs(selectedIds) do
                local shopId, idx = compositeId:match('^(.+):(%d+)$')
                idx = tonumber(idx)
                if not shopId or not idx then
                    res.notFound[#res.notFound + 1] = compositeId
                else
                    local r = MySQL.single.await("SELECT employees FROM okokvehicleshop_shops WHERE shop_id = ? LIMIT 1", { shopId })
                    local emps = r and safeJsonDecode(r.employees)
                    local emp = emps and emps[idx]
                    local pickleId = ctx.legacyIdMap[tostring(shopId)]
                    if not emp or not pickleId then
                        res.notFound[#res.notFound + 1] = compositeId
                    else
                        local cid = type(emp) == 'table' and (emp.identifier or emp.citizenid or emp.id) or tostring(emp)
                        local newId = MySQL.insert.await(
                            "INSERT INTO pickle_dealership_employees (dealership_id, identifier, role, commission_rate) VALUES (?, ?, 'salesperson', 0)",
                            { pickleId, cid }
                        )
                        if newId then res.inserted = res.inserted + 1
                        else res.skipped = res.skipped + 1 end
                    end
                end
            end
            return res
        end,
    }
end

-- ===================== sales history =====================
function OkokConversionHelpers.salesEntity()
    return {
        label = 'Sales History → Ledger',
        requires = { 'okokvehicleshop_saleshistory' },
        list = function()
            local rows = MySQL.query.await("SELECT rowid, shop_id, vehicle_name, price, date, buyer_name FROM (SELECT *, (@rn := @rn + 1) AS rowid FROM okokvehicleshop_saleshistory, (SELECT @rn := 0) r) t ORDER BY rowid DESC LIMIT 500") or {}
            local out = {}
            for _, r in ipairs(rows) do
                out[#out + 1] = {
                    id = r.rowid,
                    label = (r.vehicle_name or '?') .. ' — $' .. (r.price or 0) .. ' (' .. (r.date or '?') .. ')',
                    meta = { shop_id = r.shop_id, buyer = r.buyer_name },
                }
            end
            return out
        end,
        import = function(selectedIds, _options, ctx)
            local res = { inserted = 0, skipped = 0, notFound = {} }
            -- We have to stream the history in row order to re-match synthetic rowids
            local all = MySQL.query.await("SELECT * FROM okokvehicleshop_saleshistory") or {}
            local byRow = {}
            for i, r in ipairs(all) do byRow[i] = r end
            for _, rowId in ipairs(selectedIds) do
                local r = byRow[tonumber(rowId)]
                if not r then
                    res.notFound[#res.notFound + 1] = rowId
                else
                    local pickleId = ctx.legacyIdMap[tostring(r.shop_id)]
                    if not pickleId then
                        res.skipped = res.skipped + 1
                    else
                        local desc = string.format('Imported sale: %s → %s', r.vehicle_name or '?', r.buyer_name or '?')
                        local newId = MySQL.insert.await(
                            "INSERT INTO pickle_dealership_ledger (dealership_id, type, amount, description, identifier) VALUES (?, 'sale', ?, ?, ?)",
                            { pickleId, tonumber(r.price) or 0, desc, r.buyer_id }
                        )
                        if newId then res.inserted = res.inserted + 1
                        else res.skipped = res.skipped + 1 end
                    end
                end
            end
            return res
        end,
    }
end

-- Register the v1 adapter using the shared helpers (no v2 flag).
CreateThread(function()
    RegisterConversionAdapter({
        resource = 'okok_vehicleshop',
        version = 'v1',
        label = 'okok Vehicleshop (v1)',
        resourceLabel = 'okok Vehicleshop',
        order = { 'catalog', 'dealerships', 'employees', 'sales' },
        entities = {
            catalog = OkokConversionHelpers.catalogEntity(),
            dealerships = OkokConversionHelpers.dealershipsEntity(false),
            employees = OkokConversionHelpers.employeesEntity(),
            sales = OkokConversionHelpers.salesEntity(),
        },
    })
end)
