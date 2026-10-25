-- =============================================
--  pickle_dealerships | bridge/conversion/registry/server.lua
--  Conversion adapter registry. Each adapter represents one (resource, version)
--  pair — e.g. ('okok_vehicleshop', 'v2'). Adapters self-register by calling
--  RegisterConversionAdapter from their own file under bridge/conversion/<res>/<ver>/server.lua.
-- =============================================

ConversionAdapters = ConversionAdapters or {}

--- Registers a conversion adapter. Silently no-ops if malformed so a broken
--- adapter can never take down resource startup.
--- Expected def:
---   {
---     resource = 'okok_vehicleshop',
---     version  = 'v2',
---     label    = 'okok Vehicleshop (v2)',
---     entities = {
---       catalog = {
---         label    = 'Wholesale Catalog',
---         requires = { 'okokvehicleshop_vehicles' },
---         list     = function() return { { id=..., label=..., meta=... }, ... } end,
---         import   = function(selectedIds, options, ctx) ... end,
---       },
---       ...
---     },
---     -- Ordering for import() dependency resolution. Entities not listed run last.
---     order = { 'catalog', 'dealerships', 'employees', 'stock', 'coupons', 'sales', 'financing' },
---   }
function RegisterConversionAdapter(def)
    if type(def) ~= 'table' then return end
    if type(def.resource) ~= 'string' or def.resource == '' then return end
    if type(def.version) ~= 'string' or def.version == '' then return end
    if type(def.entities) ~= 'table' then return end

    ConversionAdapters[def.resource] = ConversionAdapters[def.resource] or {}
    ConversionAdapters[def.resource][def.version] = def
end

function GetConversionAdapter(resource, version)
    local v = ConversionAdapters[resource]
    if not v then return nil end
    return v[version]
end

--- Checks a single table exists in the current DB. Cached per (table) lookup
--- for the life of the registry — on restart this cache is rebuilt.
local _tableCache = {}
function ConversionTableExists(name)
    if _tableCache[name] ~= nil then return _tableCache[name] end
    local row = MySQL.single.await(
        "SELECT TABLE_NAME FROM information_schema.tables WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? LIMIT 1",
        { name }
    )
    local exists = row ~= nil
    _tableCache[name] = exists
    return exists
end

--- Invalidates the table-exists cache. Call between sessions if a source
--- resource is added or dropped while the server is running.
function ConversionInvalidateCache()
    _tableCache = {}
end

--- Returns the full catalogue for the import UI:
--- [{ resource, label, versions: [{ version, label, entities: [{ key, label, available, missingTables }] }] }]
function ListConversionResources()
    ConversionInvalidateCache()
    local out = {}
    for resource, versions in pairs(ConversionAdapters) do
        local versionList = {}
        local resourceLabel = resource
        for version, def in pairs(versions) do
            resourceLabel = def.resourceLabel or resourceLabel
            local entityList = {}
            for key, entity in pairs(def.entities) do
                local missing = {}
                if type(entity.requires) == 'table' then
                    for _, t in ipairs(entity.requires) do
                        if not ConversionTableExists(t) then missing[#missing + 1] = t end
                    end
                end
                entityList[#entityList + 1] = {
                    key = key,
                    label = entity.label or key,
                    available = #missing == 0,
                    missingTables = missing,
                }
            end
            table.sort(entityList, function(a, b) return a.key < b.key end)
            versionList[#versionList + 1] = {
                version = version,
                label = def.versionLabel or version,
                entities = entityList,
            }
        end
        -- Newest version first (v2 before v1) so the import dropdown defaults
        -- to the current schema instead of the legacy one.
        table.sort(versionList, function(a, b) return a.version > b.version end)
        out[#out + 1] = {
            resource = resource,
            label = resourceLabel,
            versions = versionList,
        }
    end
    table.sort(out, function(a, b) return a.resource < b.resource end)
    return out
end

--- Assigns a freshly-imported catalog row to the group ids the admin chose
--- in the Import tab. `options.groupIds` is the explicit selection; nil or an
--- empty list means "all groups" so a vanilla import keeps the pre-tier-split
--- behavior of every dealership seeing the row. Idempotent (INSERT IGNORE),
--- so repeated imports won't duplicate junction rows.
function AssignCatalogModelToGroups(model, options)
    if not model or model == '' then return end
    local catalogId = MySQL.scalar.await(
        "SELECT id FROM pickle_wholesale_catalog WHERE model = ? LIMIT 1",
        { model }
    )
    if not catalogId then return end

    local groupIds = options and options.groupIds
    local resolved = {}
    if type(groupIds) == 'table' and #groupIds > 0 then
        for _, gid in ipairs(groupIds) do
            local n = tonumber(gid)
            if n then resolved[#resolved + 1] = n end
        end
    end
    if #resolved == 0 then
        local rows = MySQL.query.await("SELECT id FROM pickle_catalog_groups") or {}
        for _, r in ipairs(rows) do resolved[#resolved + 1] = tonumber(r.id) end
    end

    for _, gid in ipairs(resolved) do
        MySQL.update.await(
            "INSERT IGNORE INTO pickle_catalog_vehicle_groups (catalog_id, group_id) VALUES (?, ?)",
            { catalogId, gid }
        )
    end
end

--- Runs an adapter's entities in dependency order with a shared legacyIdMap
--- context that later entities can read to resolve foreign keys. `selections`
--- is a table keyed by entity name → array of source-row ids the user picked.
function RunConversionImport(resource, version, selections, options)
    local adapter = GetConversionAdapter(resource, version)
    if not adapter then
        return { success = false, message = 'Unknown adapter.' }
    end
    options = options or {}
    selections = selections or {}

    local mapKey='conversion-map:'..resource..':'..version
    local saved=GetResourceKvpString(mapKey)
    local decoded,map=pcall(json.decode,saved or '{}')
    local ctx = {
        legacyIdMap = decoded and type(map)=='table' and map or {}, -- shared: source_dealership_id → pickle_dealerships.id
        options = options,
    }

    local order = adapter.order or { 'catalog', 'dealerships', 'employees', 'stock', 'coupons', 'sales', 'financing' }
    local seen = {}
    local ordered = {}
    for _, k in ipairs(order) do
        if adapter.entities[k] then
            ordered[#ordered + 1] = k
            seen[k] = true
        end
    end
    for k in pairs(adapter.entities) do
        if not seen[k] then ordered[#ordered + 1] = k end
    end

    local results = {}
    for _, key in ipairs(ordered) do
        local ids = selections[key]
        if type(ids) == 'table' and #ids > 0 then
            local entity = adapter.entities[key]
            local fresh={}; local receipts={}
            for _,id in ipairs(ids) do
                local receipt='conversion:'..resource..':'..version..':'..key..':'..tostring(id)
                if not GetResourceKvpString(receipt) then fresh[#fresh+1]=id; receipts[#receipts+1]=receipt; SetResourceKvp(receipt,'pending') end
            end
            local ok,res=true,{inserted=0,skipped=#ids,notFound={}}
            if #fresh>0 then ok,res=pcall(entity.import,fresh,options,ctx) end
            if ok and type(res)=='table' and not res.error then for _,receipt in ipairs(receipts) do SetResourceKvp(receipt,'done') end end
            SetResourceKvp(mapKey,json.encode(ctx.legacyIdMap))
            if ok and type(res) == 'table' then
                results[key] = res
            else
                results[key] = { inserted = 0, skipped = 0, notFound = {}, error = tostring(res) }
            end
        end
    end

    BackfillCatalogGroups()
    LoadDealerships()
    return { success = true, results = results }
end

--- Runs a single entity's list() with an existence guard so a broken adapter
--- can't crash the callback chain.
function ListConversionEntity(resource, version, entityKey)
    local adapter = GetConversionAdapter(resource, version)
    if not adapter or not adapter.entities[entityKey] then return nil end
    local entity = adapter.entities[entityKey]
    if type(entity.list) ~= 'function' then return {} end
    local ok, rows = pcall(entity.list)
    if not ok or type(rows) ~= 'table' then return {} end
    return rows
end
