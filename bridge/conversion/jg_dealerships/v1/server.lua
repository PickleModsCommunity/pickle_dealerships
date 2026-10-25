-- =============================================
--  pickle_dealerships | bridge/conversion/jg_dealerships/v1/server.lua
--  Adapter for jg_dealerships (Qbox). Reads its live tables and maps rows
--  into pickle_* schema. User picks which specific rows to import via the
--  Import tab — this adapter only fulfils those picks.
-- =============================================

local function safeJsonDecode(value)
    if value == nil or value == '' then return nil end
    if type(value) == 'table' then return value end
    local ok, decoded = pcall(json.decode, value)
    if ok then return decoded end
    return nil
end

-- JG stores coords in several shapes: a plain {x,y,z,w}; an array of {x,y,z};
-- or an array of marker configs each wrapping a nested coords array. Normalize
-- to a single {x,y,z,w} point so we can drop it into pickle metadata fields.
local function extractPoint(value)
    local v = safeJsonDecode(value)
    if type(v) ~= 'table' then return nil end
    if v.x and v.y and v.z then
        return { x = tonumber(v.x), y = tonumber(v.y), z = tonumber(v.z), w = tonumber(v.w or 0.0) or 0.0 }
    end
    local first = v[1]
    if type(first) == 'table' then
        if first.x and first.y and first.z then
            return { x = tonumber(first.x), y = tonumber(first.y), z = tonumber(first.z), w = tonumber(first.w or 0.0) or 0.0 }
        end
        local nested = first.coords
        if type(nested) == 'table' and type(nested[1]) == 'table' and nested[1].x then
            local n = nested[1]
            return { x = tonumber(n.x), y = tonumber(n.y), z = tonumber(n.z), w = tonumber(n.w or first.heading or 0.0) or 0.0 }
        end
    end
    return nil
end

local function inferTypeFromCategories(categories)
    local cats = safeJsonDecode(categories) or {}
    local hasAir, hasBoat, hasCar = false, false, false
    for _, c in ipairs(cats) do
        c = string.lower(c)
        if c == 'helicopters' or c == 'planes' then hasAir = true
        elseif c == 'boat' or c == 'boats' then hasBoat = true
        else hasCar = true end
    end
    local count = (hasAir and 1 or 0) + (hasBoat and 1 or 0) + (hasCar and 1 or 0)
    if count > 1 then return 'mixed' end
    if hasAir then return 'air' end
    if hasBoat then return 'boat' end
    return 'car'
end

--- Build a set of ids from an array for O(1) membership checks.
local function idSet(ids)
    local s = {}
    for _, v in ipairs(ids) do s[tostring(v)] = true end
    return s
end

-- ===================== entity: catalog =====================
-- jg has no catalog table, so we derive rows from the distinct vehicle models
-- seen in dispveh + sales. The "id" is the model name itself.
local catalogEntity = {
    label = 'Wholesale Catalog',
    requires = { 'dealership_dispveh' },
    list = function()
        local rows = MySQL.query.await([[
            SELECT vehicle AS model, MIN(paid) AS price_floor FROM (
                SELECT vehicle, NULL AS paid FROM dealership_dispveh
                UNION ALL
                SELECT vehicle, paid FROM dealership_sales WHERE paid > 0
            ) AS combined
            GROUP BY vehicle
        ]]) or {}
        local out = {}
        for _, r in ipairs(rows) do
            local floor = tonumber(r.price_floor) or 50000
            out[#out + 1] = {
                id = r.model,
                label = r.model,
                meta = { priceFloor = floor },
            }
        end
        return out
    end,
    import = function(selectedIds, options, _ctx)
        local policy = options.conflictPolicy or 'skip'
        local res = { inserted = 0, skipped = 0, notFound = {} }
        local set = idSet(selectedIds)
        -- Re-fetch to validate the picked ids still exist in the source.
        local rows = MySQL.query.await([[
            SELECT vehicle AS model, MIN(paid) AS price_floor FROM (
                SELECT vehicle, NULL AS paid FROM dealership_dispveh
                UNION ALL
                SELECT vehicle, paid FROM dealership_sales WHERE paid > 0
            ) AS combined
            GROUP BY vehicle
        ]]) or {}
        local byId = {}
        for _, r in ipairs(rows) do byId[r.model] = r end
        for id in pairs(set) do
            local r = byId[id]
            if not r then
                res.notFound[#res.notFound + 1] = id
            else
                -- price_floor is the price players actually paid in jg (jg v1
                -- has no separate cost column). Treat it as the sticker price and
                -- back-derive wholesale so pickle's ×1.3 markup reproduces it on
                -- seed/order, instead of marking it down to 70%.
                local floor = tonumber(r.price_floor) or 50000
                local wholesale = math.max(1000, math.floor(floor / 1.3))
                local label = r.model:sub(1,1):upper() .. r.model:sub(2)
                local sql = policy == 'overwrite'
                    and "INSERT INTO pickle_wholesale_catalog (model, label, wholesale, tier, class, vehicle_type) VALUES (?, ?, ?, 'basic', 'sedan', 'car') ON DUPLICATE KEY UPDATE wholesale = VALUES(wholesale), label = VALUES(label)"
                    or  "INSERT IGNORE INTO pickle_wholesale_catalog (model, label, wholesale, tier, class, vehicle_type) VALUES (?, ?, ?, 'basic', 'sedan', 'car')"
                local affected = MySQL.update.await(sql, { r.model, label, wholesale })
                if affected and affected > 0 then
                    res.inserted = res.inserted + 1
                    AssignCatalogModelToGroups(r.model, options)
                else res.skipped = res.skipped + 1 end
            end
        end
        return res
    end,
}

-- ===================== entity: dealerships =====================
local dealershipsEntity = {
    label = 'Dealerships',
    requires = { 'dealership_locations' },
    list = function()
        local rows = MySQL.query.await("SELECT id, name, type, owner_id, balance FROM dealership_locations") or {}
        local out = {}
        for _, r in ipairs(rows) do
            out[#out + 1] = {
                id = r.id,
                label = r.name or ('Dealership ' .. r.id),
                meta = { mode = r.type, owner = r.owner_id, balance = tonumber(r.balance) or 0 },
            }
        end
        return out
    end,
    import = function(selectedIds, options, ctx)
        local policy = options.conflictPolicy or 'skip'
        local prefix = options.namePrefix or ''
        local res = { inserted = 0, skipped = 0, notFound = {} }
        for _, id in ipairs(selectedIds) do
            local r = MySQL.single.await("SELECT * FROM dealership_locations WHERE id = ?", { id })
            if not r then
                res.notFound[#res.notFound + 1] = id
            else
                local locationKey = 'jg_' .. tostring(r.id)
                if policy ~= 'duplicate' then
                    local existing = MySQL.single.await("SELECT id FROM pickle_dealerships WHERE location = ? LIMIT 1", { locationKey })
                    if existing then
                        ctx.legacyIdMap[tostring(r.id)] = existing.id
                        res.skipped = res.skipped + 1
                        goto continue
                    end
                end

                -- Extract pickle-shaped positions from JG's per-column coord blobs.
                local coords        = extractPoint(r.showroom_coords)
                local spawnPoint    = extractPoint(r.purchase_vehicle_coords)
                local deliveryPoint = extractPoint(r.trucking_vehicle_coords)
                local mgmtPoint     = extractPoint(r.management_coords)
                local salesPoint    = extractPoint(r.sell_vehicle_coords)
                local testDrivePt   = extractPoint(r.test_drive_coords)

                local meta = {
                    imported_from = 'jg_dealerships',
                    legacy_id = r.id,
                    colorMode = (r.colour_selection_type == 'RGB') and 'rgb_wheel' or 'color_ids',
                    acceptedCurrency = 'both',
                    categories = safeJsonDecode(r.categories) or {},
                    enable_finance = r.enable_finance == 1,
                    enable_test_drive = r.enable_test_drive == 1,
                }
                if coords then meta.coords = coords end
                if spawnPoint then meta.spawnPoint = spawnPoint end
                if deliveryPoint then meta.deliveryPoint = deliveryPoint end

                local ipts = {}
                if mgmtPoint    then ipts.management = mgmtPoint end
                if salesPoint   then ipts.sales      = salesPoint end
                if testDrivePt  then ipts.testDrive  = testDrivePt end
                if coords       then ipts.showroom   = ipts.showroom or coords end
                if next(ipts) then meta.interactionPoints = ipts end

                -- Preload display spots from JG's dispveh rows so the imported
                -- dealership has its showroom slots ready without re-placing them.
                local dispRows = MySQL.query.await(
                    "SELECT coords FROM dealership_dispveh WHERE dealership = ?", { r.id }
                ) or {}
                if #dispRows > 0 then
                    local spots, nextId = {}, 0
                    for _, dv in ipairs(dispRows) do
                        local pt = extractPoint(dv.coords)
                        if pt then
                            nextId = nextId + 1
                            pt.id = nextId
                            spots[#spots + 1] = pt
                        end
                    end
                    if #spots > 0 then
                        meta.displaySpots = spots
                        meta._nextSpotId = nextId
                    end
                end

                -- Faction: JG's single source of truth is `job_name`. Blank means
                -- the dealership is NPC-operated (no faction, no player owner).
                local factionName = (r.job_name and r.job_name ~= '') and r.job_name or nil
                if factionName then meta.factionType = 'job' end

                local ownerId = (r.owner_id and r.owner_id ~= '') and r.owner_id or nil
                local mode = ownerId and 'player-owned' or 'managed'

                local newId = MySQL.insert.await(
                    "INSERT INTO pickle_dealerships (name, location, type, mode, owner_identifier, balance, job, metadata) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    {
                        prefix .. (r.name or ('JG Dealership ' .. r.id)),
                        locationKey,
                        inferTypeFromCategories(r.categories),
                        mode,
                        ownerId,
                        tonumber(r.balance) or 0,
                        factionName,
                        json.encode(meta),
                    }
                )
                if newId then
                    ctx.legacyIdMap[tostring(r.id)] = newId
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

-- ===================== entity: employees =====================
local employeesEntity = {
    label = 'Employees',
    requires = { 'dealership_employees' },
    list = function()
        local rows = MySQL.query.await("SELECT * FROM dealership_employees") or {}
        local out = {}
        for _, r in ipairs(rows) do
            out[#out + 1] = {
                id = r.id,
                label = (r.citizenid or r.identifier or '?') .. ' @ ' .. (r.dealership or '?'),
                meta = { role = r.role, dealership = r.dealership },
            }
        end
        return out
    end,
    import = function(selectedIds, _options, ctx)
        local res = { inserted = 0, skipped = 0, notFound = {} }
        for _, id in ipairs(selectedIds) do
            local r = MySQL.single.await("SELECT * FROM dealership_employees WHERE id = ?", { id })
            if not r then
                res.notFound[#res.notFound + 1] = id
            else
                local pickleId = ctx.legacyIdMap[tostring(r.dealership)]
                local citizenid = r.citizenid or r.identifier
                if pickleId and citizenid then
                    local newId = MySQL.insert.await(
                        "INSERT INTO pickle_dealership_employees (dealership_id, identifier, role, commission_rate) VALUES (?, ?, ?, ?)",
                        { pickleId, citizenid, r.role or 'salesperson', tonumber(r.commission) or 0 }
                    )
                    if newId then res.inserted = res.inserted + 1
                    else res.skipped = res.skipped + 1 end
                else
                    res.skipped = res.skipped + 1
                end
            end
        end
        return res
    end,
}

-- ===================== entity: stock (display vehicles) =====================
local stockEntity = {
    label = 'Display Vehicles',
    requires = { 'dealership_dispveh' },
    list = function()
        local rows = MySQL.query.await("SELECT id, dealership, vehicle FROM dealership_dispveh") or {}
        local out = {}
        for _, r in ipairs(rows) do
            out[#out + 1] = {
                id = r.id,
                label = r.vehicle .. ' @ ' .. (r.dealership or '?'),
                meta = { dealership = r.dealership, vehicle = r.vehicle },
            }
        end
        return out
    end,
    import = function(selectedIds, _options, ctx)
        local res = { inserted = 0, skipped = 0, notFound = {} }
        for _, id in ipairs(selectedIds) do
            local r = MySQL.single.await("SELECT * FROM dealership_dispveh WHERE id = ?", { id })
            if not r then
                res.notFound[#res.notFound + 1] = id
            else
                local pickleId = ctx.legacyIdMap[tostring(r.dealership)]
                if not pickleId then
                    res.skipped = res.skipped + 1
                else
                    local catalogRow = MySQL.single.await(
                        "SELECT label, wholesale FROM pickle_wholesale_catalog WHERE model = ? LIMIT 1", { r.vehicle }
                    )
                    local wholesale = (catalogRow and catalogRow.wholesale) or 50000
                    local label = (catalogRow and catalogRow.label) or r.vehicle
                    local retail = math.floor(wholesale * 1.3)
                    local color = safeJsonDecode(r.color)
                    local newId = MySQL.insert.await(
                        "INSERT INTO pickle_dealership_stock (dealership_id, vehicle_model, vehicle_label, wholesale_cost, retail_price, color, display_spot, ordered_at, delivered_at, acquired_from) VALUES (?, ?, ?, ?, ?, ?, ?, NOW(), NOW(), 'jg_import')",
                        { pickleId, r.vehicle, label, wholesale, retail, color and json.encode(color) or nil, nil }
                    )
                    if newId then res.inserted = res.inserted + 1
                    else res.skipped = res.skipped + 1 end
                end
            end
        end
        return res
    end,
}

-- ===================== entity: coupons =====================
local couponsEntity = {
    label = 'Coupons',
    requires = { 'dealership_coupons' },
    list = function()
        local rows = MySQL.query.await("SELECT id, code, dealership_id, discount_type, discount_value FROM dealership_coupons") or {}
        local out = {}
        for _, r in ipairs(rows) do
            out[#out + 1] = {
                id = r.id,
                label = (r.code or '?') .. ' (' .. (r.discount_value or 0) .. (r.discount_type == 'percent' and '%' or '$') .. ')',
                meta = { dealership = r.dealership_id, code = r.code },
            }
        end
        return out
    end,
    import = function(selectedIds, _options, ctx)
        local res = { inserted = 0, skipped = 0, notFound = {} }
        for _, id in ipairs(selectedIds) do
            local r = MySQL.single.await("SELECT * FROM dealership_coupons WHERE id = ?", { id })
            if not r then
                res.notFound[#res.notFound + 1] = id
            else
                local pickleId = ctx.legacyIdMap[tostring(r.dealership_id)]
                local filter = nil
                local vr = safeJsonDecode(r.vehicle_restrictions)
                local cr = safeJsonDecode(r.category_restrictions)
                if vr or cr then filter = json.encode({ vehicles = vr, categories = cr }) end
                local expires = nil
                if r.expiry_date and tonumber(r.expiry_date) then
                    expires = os.date('%Y-%m-%d %H:%M:%S', math.floor(tonumber(r.expiry_date) / 1000))
                end
                local newId = MySQL.insert.await(
                    "INSERT IGNORE INTO pickle_dealership_coupons (dealership_id, code, discount_type, discount_value, max_uses, uses, vehicle_filter, expires_at, created_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    {
                        pickleId or 0, r.code, r.discount_type or 'percent',
                        tonumber(r.discount_value) or 0, tonumber(r.max_uses) or 0,
                        tonumber(r.current_uses) or 0, filter, expires, r.created_by,
                    }
                )
                if newId then res.inserted = res.inserted + 1
                else res.skipped = res.skipped + 1 end
            end
        end
        return res
    end,
}

-- ===================== entity: sales =====================
local salesEntity = {
    label = 'Sales History → Ledger',
    requires = { 'dealership_sales' },
    list = function()
        local rows = MySQL.query.await("SELECT id, dealership, vehicle, paid, created_at FROM dealership_sales ORDER BY id DESC LIMIT 500") or {}
        local out = {}
        for _, r in ipairs(rows) do
            out[#out + 1] = {
                id = r.id,
                label = (r.vehicle or '?') .. ' — $' .. (r.paid or 0) .. ' (' .. (r.created_at or '?') .. ')',
                meta = { dealership = r.dealership },
            }
        end
        return out
    end,
    import = function(selectedIds, _options, ctx)
        local res = { inserted = 0, skipped = 0, notFound = {} }
        for _, id in ipairs(selectedIds) do
            local r = MySQL.single.await("SELECT * FROM dealership_sales WHERE id = ?", { id })
            if not r then
                res.notFound[#res.notFound + 1] = id
            else
                local pickleId = ctx.legacyIdMap[tostring(r.dealership)]
                if not pickleId then
                    res.skipped = res.skipped + 1
                else
                    local desc = string.format('Imported sale: %s (plate %s) → %s', r.vehicle or '?', r.plate or '?', r.player or '?')
                    local newId = MySQL.insert.await(
                        "INSERT INTO pickle_dealership_ledger (dealership_id, type, amount, description, identifier, created_at) VALUES (?, 'sale', ?, ?, ?, ?)",
                        { pickleId, tonumber(r.paid) or 0, desc, r.seller or r.player, r.created_at }
                    )
                    if newId then res.inserted = res.inserted + 1
                    else res.skipped = res.skipped + 1 end
                end
            end
        end
        return res
    end,
}

-- Expose shared entity definitions so the v2 adapter can reuse the unchanged ones.
JgConversionHelpers = JgConversionHelpers or {}
JgConversionHelpers.dealershipsEntity = dealershipsEntity
JgConversionHelpers.employeesEntity = employeesEntity
JgConversionHelpers.couponsEntity = couponsEntity
JgConversionHelpers.salesEntity = salesEntity

CreateThread(function()
    RegisterConversionAdapter({
        resource = 'jg_dealerships',
        version = 'v1',
        resourceLabel = 'JG Dealerships',
        order = { 'catalog', 'dealerships', 'employees', 'stock', 'coupons', 'sales' },
        entities = {
            catalog = catalogEntity,
            dealerships = dealershipsEntity,
            employees = employeesEntity,
            stock = stockEntity,
            coupons = couponsEntity,
            sales = salesEntity,
        },
    })
end)
