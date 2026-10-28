--- Returns the wholesale catalog filtered by the dealership's assigned groups
--- and vehicle type (DB-driven). Catalog visibility used to be a one-tier
--- comparison; it's now a many-to-many group-membership check via the
--- pickle_catalog_vehicle_groups + pickle_dealership_groups junction tables.
--- A vehicle is included iff it shares at least one group with the dealership.
---@param source number
---@param data table|string
lib.callback.register('pickle_dealerships:getCatalog', function(source, data)
    local locationKey = type(data) == 'string' and data or (data and data.location)
    if not locationKey then return { items = {}, total = 0, page = 1, pageSize = 50 } end

    local dealership = MySQL.single.await(
        'SELECT id, type FROM pickle_dealerships WHERE location = ?',
        { locationKey }
    )
    if not dealership then return { items = {}, total = 0, page = 1, pageSize = 50 } end

    local dealershipId = dealership.id
    local vehicleType = dealership.type or 'car'

    local page = tonumber(data and data.page) or 1
    local pageSize = tonumber(data and data.pageSize) or 50
    local search = data and data.search or ''
    local classFilter = data and data.classFilter or 'all'
    local groupFilter = tonumber(data and data.groupFilter) -- optional: narrow to one group
    local offset = (page - 1) * pageSize

    -- Build type filter
    local types = {}
    if vehicleType == 'mixed' then
        types = { 'car', 'boat', 'air' }
    else
        types = { vehicleType }
    end

    local typePlaceholders = {}
    local params = {}

    for _, t in ipairs(types) do
        typePlaceholders[#typePlaceholders + 1] = '?'
        params[#params + 1] = t
    end

    -- Group-membership gate. EXISTS keeps it cheap with the junction table;
    -- when the admin narrows by a specific group the optional second EXISTS
    -- pins the row to just that group.
    local where = string.format([[
        wc.vehicle_type IN (%s)
        AND EXISTS (
            SELECT 1
            FROM pickle_catalog_vehicle_groups vg
            JOIN pickle_dealership_groups dg ON dg.group_id = vg.group_id
            WHERE vg.catalog_id = wc.id AND dg.dealership_id = ?
        )
    ]], table.concat(typePlaceholders, ','))
    params[#params + 1] = dealershipId

    if search ~= '' then
        where = where .. ' AND (wc.label LIKE ? OR wc.model LIKE ?)'
        local pattern = '%' .. search .. '%'
        params[#params + 1] = pattern
        params[#params + 1] = pattern
    end

    if classFilter ~= 'all' then
        where = where .. ' AND wc.class = ?'
        params[#params + 1] = classFilter
    end

    if groupFilter then
        where = where .. ' AND EXISTS (SELECT 1 FROM pickle_catalog_vehicle_groups vg2 WHERE vg2.catalog_id = wc.id AND vg2.group_id = ?)'
        params[#params + 1] = groupFilter
    end

    local countParams = { table.unpack(params) }
    local countResult = MySQL.scalar.await(
        ('SELECT COUNT(*) FROM pickle_wholesale_catalog wc WHERE %s'):format(where),
        countParams
    )

    params[#params + 1] = pageSize
    params[#params + 1] = offset

    local results = MySQL.query.await(
        ('SELECT wc.* FROM pickle_wholesale_catalog wc WHERE %s ORDER BY wc.wholesale ASC LIMIT ? OFFSET ?'):format(where),
        params
    )

    return {
        items = results or {},
        total = countResult or 0,
        page = page,
        pageSize = pageSize,
    }
end)

--- Returns the catalog groups assigned to a dealership so the catalog page can
--- offer a group filter. Available to any player (no admin check needed) because
--- the catalog itself is already player-accessible.
lib.callback.register('pickle_dealerships:getCatalogGroups', function(source, locationKey)
    if not locationKey then return {} end
    local dealership = MySQL.single.await(
        'SELECT id FROM pickle_dealerships WHERE location = ?',
        { locationKey }
    )
    if not dealership then return {} end

    local rows = MySQL.query.await([[
        SELECT g.id, g.name, g.label
        FROM pickle_catalog_groups g
        JOIN pickle_dealership_groups dg ON dg.group_id = g.id
        WHERE dg.dealership_id = ?
        ORDER BY g.label ASC
    ]], { dealership.id }) or {}
    return rows
end)

-- ─── In-transit + orders summary ───────────────────────────────────────────
--
-- The "in-transit" cards rendered above the available grid in StockPage come
-- from two sources:
--   1. Stock rows that exist but whose delivered_at is still in the future
--      (admin-added stock with delayed delivery).
--   2. Pending rows in pickle_dealership_orders (purchased from wholesale,
--      not yet entered into stock). Local orders are collapsed into trailer
--      bundles to match the driver queue UI.
-- Both are small datasets — never thousands of rows — so they're returned in
-- full as part of the summary block instead of being paginated.
local function buildInTransitSummary(dealership)
    local rows = MySQL.query.await(
        [[
            SELECT ds.id, ds.vehicle_model, ds.vehicle_label, ds.retail_price,
                   ds.wholesale_cost, ds.quantity, ds.ordered_at, ds.delivered_at,
                   ds.unlisted, ds.auction_id, ds.acquired_from, ds.is_used,
                   wc.image, wc.class
              FROM pickle_dealership_stock ds
              LEFT JOIN pickle_wholesale_catalog wc ON wc.model = ds.vehicle_model
             WHERE ds.dealership_id = ?
               AND ds.sold_at IS NULL
               AND (ds.delivered_at IS NULL OR ds.delivered_at > NOW())
        ]],
        { dealership.id }
    ) or {}

    local orderRows = MySQL.query.await(
        [[
            SELECT dor.id, dor.dealership_id, dor.vehicle_model, dor.vehicle_label, dor.retail_price,
                   dor.wholesale_cost, dor.quantity, dor.delivery_mode, dor.delivery_fee,
                   dor.ordered_at, dor.delivered_at, dor.claimed_by,
                   wc.image, COALESCE(wc.class, 'sedan') AS class
              FROM pickle_dealership_orders dor
              LEFT JOIN pickle_wholesale_catalog wc ON wc.model = dor.vehicle_model
             WHERE dor.dealership_id = ?
             ORDER BY dor.ordered_at DESC
        ]],
        { dealership.id }
    ) or {}

    local localOrders, expeditedOrders = {}, {}
    for _, o in ipairs(orderRows) do
        if o.delivery_mode == 'local' then
            o.dealership_name = dealership.name
            localOrders[#localOrders + 1] = o
        else
            expeditedOrders[#expeditedOrders + 1] = o
        end
    end

    local out = {}
    for i = 1, #rows do out[#out + 1] = rows[i] end

    for _, g in ipairs(GroupLocalOrders(localOrders, 1.0)) do
        out[#out + 1] = {
            is_order = true,
            is_used = 0,
            id = -g.primaryOrderId, -- negative ID keeps React keys distinct from real stock
            vehicle_model = g.primaryModel,
            vehicle_label = g.primaryLabel,
            retail_price = g.primaryRetail,
            wholesale_cost = g.primaryWholesale,
            quantity = g.totalQty,
            ordered_at = g.orderedAt,
            delivered_at = nil,
            image = g.primaryImage,
            class = g.primaryClass,
            delivery_mode = 'local',
            bundle = {
                order_ids = g.orderIds,
                vehicles = g.vehicles,
                total_qty = g.totalQty,
                bundle_size = g.bundleSize,
                claimed_by = g.claimed_by,
                bucket = g.bucket,
            },
        }
    end

    for _, o in ipairs(expeditedOrders) do
        o.is_order = true
        o.is_used = 0
        o.id = -o.id
        o.sold_at = nil
        o.sold_to = nil
        o.sold_by = nil
        o.display_spot = nil
        out[#out + 1] = o
    end

    return out
end

-- ─── WHERE-clause builder ──────────────────────────────────────────────────
-- Builds the WHERE clause and parameters shared between the count and select
-- queries so pagination math stays consistent.
local function buildStockWhere(dealership, opts)
    local where = 'ds.dealership_id = ? AND ds.sold_at IS NULL'
    local params = { dealership.id }

    local tab = opts.tab
    if tab == 'new' then
        where = where .. ' AND ds.is_used = 0'
    elseif tab == 'used' then
        where = where .. ' AND ds.is_used = 1'
    end -- 'all' or anything else: no is_used filter

    -- 'public' scope is what customers (and the immersive showroom / NPC
    -- showroom / sales tablet for non-staff) see — strip unlisted, auctioned,
    -- and pre-delivery rows. 'manager' includes everything so staff can
    -- manage them.
    if opts.scope == 'public' then
        where = where .. ' AND ds.unlisted = 0 AND ds.auction_id IS NULL AND ds.delivered_at IS NOT NULL AND ds.delivered_at <= NOW()'
    elseif opts.availableOnly then
        where = where .. ' AND ds.delivered_at IS NOT NULL AND ds.delivered_at <= NOW()'
    end

    local search = type(opts.search) == 'string' and opts.search ~= '' and opts.search or nil
    if search then
        where = where .. ' AND (ds.vehicle_label LIKE ? OR ds.vehicle_model LIKE ?)'
        local pattern = '%' .. search .. '%'
        params[#params + 1] = pattern
        params[#params + 1] = pattern
    end

    if opts.classFilter and opts.classFilter ~= '' and opts.classFilter ~= 'all' then
        where = where .. ' AND wc.class = ?'
        params[#params + 1] = opts.classFilter
    end

    local minPrice = tonumber(opts.minPrice)
    if minPrice and minPrice > 0 then
        where = where .. ' AND ds.retail_price >= ?'
        params[#params + 1] = minPrice
    end

    local maxPrice = tonumber(opts.maxPrice)
    if maxPrice and maxPrice > 0 then
        where = where .. ' AND ds.retail_price <= ?'
        params[#params + 1] = maxPrice
    end

    return where, params
end

local SORT_MAP = {
    name_asc      = 'ds.vehicle_label ASC',
    name_desc     = 'ds.vehicle_label DESC',
    price_asc     = 'ds.retail_price ASC',
    price_desc    = 'ds.retail_price DESC',
    ordered_desc  = 'ds.ordered_at DESC',
    ordered_asc   = 'ds.ordered_at ASC',
}

local function clampPageSize(n)
    n = tonumber(n) or 50
    if n < 1 then n = 1 end
    if n > 200 then n = 200 end
    return math.floor(n)
end

-- Pull summary metadata (counts per tab, available classes, max price,
-- in-transit rows) in one shot. Returned with page=1 responses so the
-- React UI can populate filter chips, header counts, and the in-transit
-- strip without extra round-trips.
local function buildStockSummary(dealership, scope)
    local scopePredicate = (scope == 'public')
        and 'AND ds.unlisted = 0 AND ds.auction_id IS NULL AND ds.delivered_at IS NOT NULL AND ds.delivered_at <= NOW()'
        or  ''

    local newCount = MySQL.scalar.await(
        ('SELECT COUNT(*) FROM (SELECT 1 FROM pickle_dealership_stock ds LEFT JOIN pickle_wholesale_catalog wc ON wc.model = ds.vehicle_model WHERE ds.dealership_id = ? AND ds.sold_at IS NULL AND ds.is_used = 0 %s GROUP BY ds.vehicle_model, ds.retail_price) sub'):format(scopePredicate),
        { dealership.id }
    ) or 0

    local usedCount = MySQL.scalar.await(
        ('SELECT COUNT(*) FROM pickle_dealership_stock ds LEFT JOIN pickle_wholesale_catalog wc ON wc.model = ds.vehicle_model WHERE ds.dealership_id = ? AND ds.sold_at IS NULL AND ds.is_used = 1 %s'):format(scopePredicate),
        { dealership.id }
    ) or 0

    local totalQuantity = MySQL.scalar.await(
        ('SELECT COALESCE(SUM(ds.quantity), 0) FROM pickle_dealership_stock ds LEFT JOIN pickle_wholesale_catalog wc ON wc.model = ds.vehicle_model WHERE ds.dealership_id = ? AND ds.sold_at IS NULL %s'):format(scopePredicate),
        { dealership.id }
    ) or 0

    local classRows = MySQL.query.await(
        ('SELECT DISTINCT wc.class FROM pickle_dealership_stock ds LEFT JOIN pickle_wholesale_catalog wc ON wc.model = ds.vehicle_model WHERE ds.dealership_id = ? AND ds.sold_at IS NULL %s AND wc.class IS NOT NULL AND wc.class <> \'\' ORDER BY wc.class'):format(scopePredicate),
        { dealership.id }
    ) or {}
    local classes = {}
    for _, row in ipairs(classRows) do classes[#classes + 1] = row.class end

    local maxRetailPrice = MySQL.scalar.await(
        ('SELECT COALESCE(MAX(ds.retail_price), 0) FROM pickle_dealership_stock ds LEFT JOIN pickle_wholesale_catalog wc ON wc.model = ds.vehicle_model WHERE ds.dealership_id = ? AND ds.sold_at IS NULL %s'):format(scopePredicate),
        { dealership.id }
    ) or 0

    -- In-transit only meaningful for managers — customers don't see incoming
    -- stock until it's actually on the lot.
    local inTransit = (scope == 'public') and {} or buildInTransitSummary(dealership)

    return {
        totals = {
            ['new']   = tonumber(newCount) or 0,
            used      = tonumber(usedCount) or 0,
            all       = (tonumber(newCount) or 0) + (tonumber(usedCount) or 0),
            quantity  = tonumber(totalQuantity) or 0,
        },
        classes = classes,
        maxRetailPrice = tonumber(maxRetailPrice) or 0,
        inTransit = inTransit,
    }
end

--- Paginated stock fetch.
---
--- opts:
---   displayOnly    — legacy display-spawner shortcut, returns rows with
---                    display_spot set, no pagination.
---   tab            — 'new' | 'used' | 'all'. 'new' consolidates rows that
---                    share (vehicle_model, retail_price) into a single card
---                    via SQL GROUP BY so a 1000-row Comet dealership ships
---                    one row, not 1000.
---   scope          — 'manager' (sees unlisted/auctioned/pending) or
---                    'public' (only available, listed, non-auctioned).
---   availableOnly  — when scope=manager but caller only wants delivered
---                    rows (the available grid).
---   page, pageSize — pagination. Default 1 / 50, pageSize capped at 200.
---   search, classFilter, minPrice, maxPrice, sortBy — filters / sort.
---   includeSummary — returns totals / classes / maxRetailPrice / inTransit.
---                    Send only on first page, not on infinite-scroll loads.
---@param source number
---@param locationKey string
---@param opts table|nil
lib.callback.register('pickle_dealerships:getStock', function(source, locationKey, opts)
    opts = type(opts) == 'table' and opts or {}

    local dealership = MySQL.single.await(
        'SELECT * FROM pickle_dealerships WHERE location = ?',
        { locationKey }
    )
    if not dealership then
        return { items = {}, total = 0, page = 1, pageSize = 50 }
    end

    -- Process any orders that have arrived
    ProcessDeliveredOrders(dealership.id)

    -- displayOnly: caller (SpawnDisplayVehicles) only needs rows actually
    -- placed on a display spot — typically a handful out of potentially
    -- thousands of stock rows. Returns the bare array for back-compat.
    if opts.displayOnly == true then
        return MySQL.query.await(
            'SELECT ds.*, wc.image, wc.class FROM pickle_dealership_stock ds LEFT JOIN pickle_wholesale_catalog wc ON wc.model = ds.vehicle_model WHERE ds.dealership_id = ? AND ds.sold_at IS NULL AND ds.display_spot IS NOT NULL',
            { dealership.id }
        ) or {}
    end

    -- Resolve scope. If the caller didn't request explicitly, default by role
    -- (managers see everything, customers only see public).
    local scope = opts.scope
    if scope ~= 'manager' and scope ~= 'public' then
        scope = CanPlayerManageOps(source, dealership.id) and 'manager' or 'public'
    end

    local page = math.max(1, math.floor(tonumber(opts.page) or 1))
    local pageSize = clampPageSize(opts.pageSize)
    local offset = (page - 1) * pageSize
    local tab = opts.tab == 'new' and 'new' or opts.tab == 'used' and 'used' or 'all'
    local orderBy = SORT_MAP[opts.sortBy] or 'ds.ordered_at DESC'

    local where, params = buildStockWhere(dealership, {
        tab = tab,
        scope = scope,
        availableOnly = opts.availableOnly == true,
        search = opts.search,
        classFilter = opts.classFilter,
        minPrice = opts.minPrice,
        maxPrice = opts.maxPrice,
    })

    local items, total

    if tab == 'new' then
        -- Consolidate by (model, retail_price). Same-model duplicates collapse
        -- to one card with summed quantity. ANY_VALUE picks a representative
        -- for the columns that vary within a group; MIN(ds.id) gives the row
        -- mutations (set price, set min grade, etc.) will target.
        local groupBy = 'ds.id, ds.vehicle_model, ds.retail_price'
        local countParams = { table.unpack(params) }
        total = MySQL.scalar.await(
            ('SELECT COUNT(*) FROM (SELECT 1 FROM pickle_dealership_stock ds LEFT JOIN pickle_wholesale_catalog wc ON wc.model = ds.vehicle_model WHERE %s GROUP BY %s) sub'):format(where, groupBy),
            countParams
        ) or 0

        local pageParams = { table.unpack(params) }
        pageParams[#pageParams + 1] = pageSize
        pageParams[#pageParams + 1] = offset
        items = MySQL.query.await(
            -- MariaDB lacks ANY_VALUE, so we use MAX as the "pick a
            -- representative" aggregate. Within a (model, retail_price)
            -- group the model-derived columns (label, image, class,
            -- acquired_from) are functionally dependent on the model and
            -- MAX returns whichever non-NULL value is highest — which is
            -- fine for display purposes.
            ([[
                SELECT MIN(ds.id) AS id,
                       ds.dealership_id,
                       ds.vehicle_model,
                       MAX(ds.vehicle_label) AS vehicle_label,
                       ds.retail_price,
                       MAX(ds.wholesale_cost) AS wholesale_cost,
                       SUM(ds.quantity) AS quantity,
                       0 AS is_used,
                       MAX(ds.unlisted) AS unlisted,
                       MAX(ds.auction_id) AS auction_id,
                       MIN(ds.ordered_at) AS ordered_at,
                       MAX(ds.delivered_at) AS delivered_at,
                       MAX(ds.acquired_from) AS acquired_from,
                       MAX(ds.metadata) AS metadata,
                       MAX(ds.display_spot) AS display_spot,
                       MAX(ds.color) AS color,
                       MAX(wc.image) AS image,
                       MAX(wc.class) AS class
                  FROM pickle_dealership_stock ds
                  LEFT JOIN pickle_wholesale_catalog wc ON wc.model = ds.vehicle_model
                 WHERE %s
                 GROUP BY ds.dealership_id, ds.vehicle_model, ds.retail_price
                 ORDER BY %s
                 LIMIT ? OFFSET ?
            ]]):format(where, orderBy),
            pageParams
        ) or {}
    else
        -- 'used' and 'all' return individual rows.
        local countParams = { table.unpack(params) }
        total = MySQL.scalar.await(
            ('SELECT COUNT(*) FROM pickle_dealership_stock ds LEFT JOIN pickle_wholesale_catalog wc ON wc.model = ds.vehicle_model WHERE %s'):format(where),
            countParams
        ) or 0

        local pageParams = { table.unpack(params) }
        pageParams[#pageParams + 1] = pageSize
        pageParams[#pageParams + 1] = offset
        items = MySQL.query.await(
            ('SELECT ds.*, wc.image, wc.class FROM pickle_dealership_stock ds LEFT JOIN pickle_wholesale_catalog wc ON wc.model = ds.vehicle_model WHERE %s ORDER BY %s LIMIT ? OFFSET ?'):format(where, orderBy),
            pageParams
        ) or {}
    end

    local response = {
        items = items,
        total = tonumber(total) or 0,
        page = page,
        pageSize = pageSize,
    }

    if opts.includeSummary == true then
        response.summary = buildStockSummary(dealership, scope)
    end

    return response
end)

--- Returns paginated available stock for the showroom
---@param source number
---@param data table
lib.callback.register('pickle_dealerships:getShowroomStock', function(source, data)
    local locationKey = data and data.location
    if not locationKey then return { items = {}, total = 0, page = 1, pageSize = 20 } end

    local dealership = MySQL.single.await(
        'SELECT * FROM pickle_dealerships WHERE location = ?',
        { locationKey }
    )
    if not dealership then return { items = {}, total = 0, page = 1, pageSize = 20 } end

    -- Process any orders that have arrived
    ProcessDeliveredOrders(dealership.id)

    local page = tonumber(data.page) or 1
    local pageSize = tonumber(data.pageSize) or 20
    local search = data.search or ''
    local classFilter = data.classFilter or 'all'
    local minPrice = tonumber(data.minPrice)
    local maxPrice = tonumber(data.maxPrice)
    local sortBy = data.sortBy or 'name_asc'
    local offset = (page - 1) * pageSize

    local sortMap = {
        name_asc = 'ds.vehicle_label ASC',
        name_desc = 'ds.vehicle_label DESC',
        price_asc = 'ds.retail_price ASC',
        price_desc = 'ds.retail_price DESC',
    }
    local orderBy = sortMap[sortBy] or 'ds.vehicle_label ASC'

    local where = 'ds.dealership_id = ? AND ds.sold_at IS NULL AND ds.unlisted = 0 AND ds.auction_id IS NULL AND ds.delivered_at IS NOT NULL AND ds.delivered_at <= NOW()'
    local params = { dealership.id }

    if search ~= '' then
        where = where .. ' AND (ds.vehicle_label LIKE ? OR ds.vehicle_model LIKE ?)'
        local pattern = '%' .. search .. '%'
        params[#params + 1] = pattern
        params[#params + 1] = pattern
    end

    if classFilter ~= 'all' then
        where = where .. ' AND wc.class = ?'
        params[#params + 1] = classFilter
    end

    if minPrice then
        where = where .. ' AND ds.retail_price >= ?'
        params[#params + 1] = minPrice
    end

    if maxPrice then
        where = where .. ' AND ds.retail_price <= ?'
        params[#params + 1] = maxPrice
    end

    local countParams = { table.unpack(params) }
    local countResult = MySQL.scalar.await(
        ('SELECT COUNT(*) FROM pickle_dealership_stock ds LEFT JOIN pickle_wholesale_catalog wc ON wc.model = ds.vehicle_model WHERE %s'):format(where),
        countParams
    )

    params[#params + 1] = pageSize
    params[#params + 1] = offset

    local results = MySQL.query.await(
        ('SELECT ds.*, wc.image, wc.class FROM pickle_dealership_stock ds LEFT JOIN pickle_wholesale_catalog wc ON wc.model = ds.vehicle_model WHERE %s ORDER BY %s LIMIT ? OFFSET ?'):format(where, orderBy),
        params
    )

    -- Get filter metadata (only on first unfiltered page)
    local classes = {}
    local highestPrice = 0
    if page == 1 and search == '' and classFilter == 'all' and not minPrice and not maxPrice then
        local classRows = MySQL.query.await(
            'SELECT DISTINCT wc.class FROM pickle_dealership_stock ds LEFT JOIN pickle_wholesale_catalog wc ON wc.model = ds.vehicle_model WHERE ds.dealership_id = ? AND ds.sold_at IS NULL AND ds.unlisted = 0 AND ds.auction_id IS NULL AND ds.delivered_at IS NOT NULL AND ds.delivered_at <= NOW() AND wc.class IS NOT NULL ORDER BY wc.class',
            { dealership.id }
        )
        if classRows then
            for _, row in ipairs(classRows) do
                classes[#classes + 1] = row.class
            end
        end

        highestPrice = MySQL.scalar.await(
            'SELECT COALESCE(MAX(ds.retail_price), 0) FROM pickle_dealership_stock ds WHERE ds.dealership_id = ? AND ds.sold_at IS NULL AND ds.unlisted = 0 AND ds.auction_id IS NULL AND ds.delivered_at IS NOT NULL AND ds.delivered_at <= NOW()',
            { dealership.id }
        ) or 0
    end

    return {
        items = results or {},
        total = countResult or 0,
        page = page,
        pageSize = pageSize,
        classes = classes,
        maxRetailPrice = tonumber(highestPrice) or 0,
    }
end)

--- Normalizes legacy delivery mode names to the current two-mode model.
local function NormalizeDeliveryMode(mode)
    if mode == 'trucking' then return 'local' end
    if mode == 'timed' then return 'expedited' end
    return mode or 'expedited'
end

--- Pure cost calculator used both by the stock order flow and by the UI cost-preview callback.
--- Both modes: the dealership pays the wholesale cost (+ import tax) for the
--- vehicle itself — that's the cost of the inventory and can't be free.
--- Expedited adds a configurable surcharge (Config.Delivery.expeditedFeePct)
--- on top; that surcharge sinks to the server (no player receives it).
--- Local adds a driver delivery fee routed to the player who fulfils the run.
--- Returns: { unitCost, totalCost, deliveryFee, retailPrice } (all integers, per-order totals).
function ResolveOwnerOrderCost(mode, wholesalePrice, retailPrice, qty)
    mode = NormalizeDeliveryMode(mode)
    if mode=="instant" then mode="expedited" end
    local importTax = Config.ImportTax or 0
    local cfg = Config.Delivery or {}
    local unitCost, deliveryFee = 0, 0

    if mode == 'expedited' then
        unitCost = wholesalePrice * (1 + importTax) + wholesalePrice * (cfg.expeditedFeePct or 0)
    elseif mode == 'local' then
        -- Dealership pays straight wholesale (MSRP) for the vehicle — no tax
        -- or surcharge. The driver's payout is tracked separately and routed
        -- through the earnings pipeline when the run is fulfilled.
        unitCost = wholesalePrice
        deliveryFee = math.floor(retailPrice * qty * (cfg.payoutPct or 0))
    end

    unitCost = math.floor(unitCost)
    return {
        unitCost = unitCost,
        totalCost = unitCost * qty,
        deliveryFee = deliveryFee,
        retailPrice = retailPrice,
    }
end

--- Owner/manager orders a vehicle from wholesale catalog.
--- `deliveryMode`: 'expedited' (timed auto-stock) | 'local' (player-delivery queue) | 'instant' (admin only)
--- Route for local orders is picked at claim time, not at order time.
lib.callback.register('pickle_dealerships:orderVehicle', function(source, locationKey, model, wholesalePrice, orderQuantity, deliveryMode)
    return DealerTransaction(source, function(transaction)
        -- Verify player role
        local identifier = GetIdentifier(source)
        if not identifier then return false, 'Unable to identify player.' end

        local dealership = MySQL.single.await(
            'SELECT * FROM pickle_dealerships WHERE location = ?',
            { locationKey }
        )
        if not dealership then return false, 'Dealership not found.' end

        -- Owner + managers (by roster OR job grade) may order stock. Resolving via
        -- the shared gate means job-graded managers aren't locked out the way the
        -- old roster-only check left them.
        if not CanPlayerManageOps(source, dealership.id) then
            return false, 'You do not have permission to order vehicles.'
        end

        -- Verify the model is in the DB catalog
        local catalogEntry = MySQL.single.await(
            'SELECT * FROM pickle_wholesale_catalog WHERE model = ?',
            { model }
        )

        if not catalogEntry then
            return false, 'This vehicle is not available in the catalog.'
        end

        -- Verify the dealership is allowed to order this vehicle: vehicle must
        -- share at least one group with the dealership.
        local hasOverlap = MySQL.scalar.await([[
            SELECT 1
            FROM pickle_catalog_vehicle_groups vg
            JOIN pickle_dealership_groups dg ON dg.group_id = vg.group_id
            WHERE vg.catalog_id = ? AND dg.dealership_id = ?
            LIMIT 1
        ]], { catalogEntry.id, dealership.id })
        if not hasOverlap then
            return false, 'Your dealership is not assigned to a group containing this vehicle.'
        end

        -- Verify wholesale price matches
        if catalogEntry.wholesale ~= wholesalePrice then
            return false, 'Price mismatch. Please refresh the catalog.'
        end

        -- Resolve delivery mode: explicit arg > dealership default > config default
        local meta = dealership.metadata
        if type(meta) == "string" then meta = json.decode(meta) or {} end
        if type(meta) ~= "table" then meta = {} end
        local resolvedMode = NormalizeDeliveryMode(
            deliveryMode
            or (meta and meta.deliveryMode)
            or (Config.DealershipDefaults and Config.DealershipDefaults.deliveryMode)
            or 'expedited'
        )

        -- For local mode, confirm routes exist globally and the queue isn't over cap
        if resolvedMode == 'local' then
            if not next(Config.DeliveryRoutes or {}) then
                return false, 'No delivery routes configured.'
            end
            -- Local deliveries require the dealership to have a configured drop-off point so the
            -- driver has somewhere to unhitch the trailer. Block placement otherwise.
            local dropMeta = meta or {}
            if type(dealership.metadata) == 'string' then
                dropMeta = json.decode(dealership.metadata) or {}
            elseif type(dealership.metadata) == 'table' then
                dropMeta = dealership.metadata
            end
            if not dropMeta.deliveryPoint then
                return false, 'This dealership has no delivery point configured. Ask an admin to place one before ordering locally.'
            end
            local cfg = Config.Delivery or {}
            local openOffers = MySQL.scalar.await(
                "SELECT COUNT(*) FROM pickle_dealership_orders WHERE dealership_id = ? AND delivery_mode = 'local' AND claimed_by IS NULL",
                { dealership.id }
            ) or 0
            if tonumber(openOffers) >= (cfg.maxActiveQueuePerDealership or 10) then
                return false, 'Too many open local delivery offers. Wait for drivers to complete existing runs.'
            end
        end

        -- Finalize any delivered orders first so stock counts stay consistent even
        -- though we no longer gate on capacity here.
        ProcessDeliveredOrders(dealership.id, transaction)

        local qty = math.max(1, math.min(100, tonumber(orderQuantity) or 1))

        -- Shared cost resolver (one source of truth for UI previews and order writes)
        local retailPrice = math.floor(wholesalePrice * 1.3)
        local costs = ResolveOwnerOrderCost(resolvedMode, wholesalePrice, retailPrice, qty)
        local totalCost = costs.totalCost

        if dealership.balance < totalCost then
            return false, 'Insufficient dealership funds. Need $' .. totalCost .. ', have $' .. dealership.balance .. '.'
        end

        MySQL.update.await('UPDATE pickle_dealerships SET balance = balance - ? WHERE id = ?', { totalCost, dealership.id })

        local stockId
        if resolvedMode == 'instant' then
            -- Admin/testing: stack directly into stock
            local existing = MySQL.single.await(
                'SELECT id FROM pickle_dealership_stock WHERE dealership_id = ? AND vehicle_model = ? AND sold_at IS NULL AND display_spot IS NULL AND is_used = 0 AND (`condition` = 100.00 OR `condition` IS NULL) ORDER BY id ASC LIMIT 1',
                { dealership.id, model }
            )
            if existing then
                MySQL.update.await('UPDATE pickle_dealership_stock SET quantity = quantity + ? WHERE id = ?', { qty, existing.id })
                stockId = existing.id
            else
                stockId = MySQL.insert.await(
                    'INSERT INTO pickle_dealership_stock (dealership_id, vehicle_model, vehicle_label, wholesale_cost, retail_price, ordered_at, delivered_at, quantity) VALUES (?, ?, ?, ?, ?, NOW(), NOW(), ?)',
                    { dealership.id, model, catalogEntry.label or model, wholesalePrice, retailPrice, qty }
                )
            end
        elseif resolvedMode == 'expedited' then
            -- Auto-resolves on a timer. Stack into an existing open order or create new.
            local deliveryMinutes = (Config.DeliveryTime or 20) * qty
            local deliveredAt = os.date('%Y-%m-%d %H:%M:%S', os.time() + (deliveryMinutes * 60))
            local existingOrder = MySQL.single.await(
                "SELECT id FROM pickle_dealership_orders WHERE dealership_id = ? AND vehicle_model = ? AND delivery_mode = 'expedited' AND (delivered_at IS NULL OR delivered_at > NOW()) ORDER BY id ASC LIMIT 1",
                { dealership.id, model }
            )
            if existingOrder then
                MySQL.update.await(
                    'UPDATE pickle_dealership_orders SET quantity = quantity + ?, delivered_at = GREATEST(COALESCE(delivered_at, ?), ?) WHERE id = ?',
                    { qty, deliveredAt, deliveredAt, existingOrder.id }
                )
                stockId = existingOrder.id
            else
                stockId = MySQL.insert.await(
                    "INSERT INTO pickle_dealership_orders (dealership_id, vehicle_model, vehicle_label, wholesale_cost, retail_price, quantity, delivery_mode, ordered_at, delivered_at) VALUES (?, ?, ?, ?, ?, ?, 'expedited', NOW(), ?)",
                    { dealership.id, model, catalogEntry.label or model, wholesalePrice, retailPrice, qty, deliveredAt }
                )
            end
        else
            -- Local delivery: order sits in queue for any player to claim. Route is picked at claim time.
            stockId = MySQL.insert.await(
                "INSERT INTO pickle_dealership_orders (dealership_id, vehicle_model, vehicle_label, wholesale_cost, retail_price, quantity, delivery_mode, delivery_fee, ordered_at, delivered_at) VALUES (?, ?, ?, ?, ?, ?, 'local', ?, NOW(), NULL)",
                { dealership.id, model, catalogEntry.label or model, wholesalePrice, retailPrice, qty, costs.deliveryFee }
            )
        end

        -- Ledger entry only for paid orders — local mode is free to the dealership.
        if totalCost > 0 then
            local desc = ('Vehicle order (%s): %s x%d'):format(resolvedMode, model, qty)
            MySQL.insert.await(
                'INSERT INTO pickle_dealership_ledger (dealership_id, type, amount, description, identifier, created_at) VALUES (?, ?, ?, ?, ?, NOW())',
                { dealership.id, 'expense', -totalCost, desc, identifier }
            )
        end

        -- Success toast is delivered by the NUI wrapper; avoid double-notifying.
        TriggerClientEvent('pickle_dealerships:refreshDisplay', -1, locationKey)
        TriggerClientEvent('pickle_dealerships:deliveryQueueChanged', -1)

        LogDiscord("stock", {
            title = "Stock Order Placed",
            actor = source,
            dealershipId = dealership.id,
            fields = {
                { name = "Dealership", value = dealership.name or "?", inline = true },
                { name = "Vehicle", value = (catalogEntry.label or model) .. " (`" .. tostring(model) .. "`)", inline = true },
                { name = "Qty", value = tostring(qty), inline = true },
                { name = "Mode", value = tostring(resolvedMode), inline = true },
                { name = "Wholesale", value = GetCurrencyString(wholesalePrice), inline = true },
                { name = "Total Cost", value = GetCurrencyString(totalCost), inline = true },
            },
        })

        return true, stockId
    end, true)
end)

--- UI cost-preview callback used by the stock ordering dialog.
--- Returns the total cost + driver fee for each mode, so the owner can compare before confirming.
lib.callback.register('pickle_dealerships:previewOrderCost', function(source, model, qty)
    local catalogEntry = MySQL.single.await('SELECT * FROM pickle_wholesale_catalog WHERE model = ?', { model })
    if not catalogEntry then return nil end
    local q = math.max(1, math.min(100, tonumber(qty) or 1))
    local wholesale = catalogEntry.wholesale
    local retail = math.floor(wholesale * 1.3)
    return {
        expedited = ResolveOwnerOrderCost('expedited', wholesale, retail, q),
        ['local'] = ResolveOwnerOrderCost('local', wholesale, retail, q),
    }
end)

--- Owner/manager sets the retail price for a stock item
---@param source number
---@param locationKey string
---@param stockId number
---@param retailPrice number
lib.callback.register('pickle_dealerships:setRetailPrice', function(source, locationKey, stockId, retailPrice)
    local identifier = GetIdentifier(source)
    if not identifier then return false, 'Unable to identify player.' end

    local dealership = MySQL.single.await(
        'SELECT * FROM pickle_dealerships WHERE location = ?',
        { locationKey }
    )
    if not dealership then return false, 'Dealership not found.' end

    -- Verify permission: owner + managers (roster or job grade).
    if not CanPlayerManageOps(source, dealership.id) then
        return false, 'You do not have permission.'
    end

    if not retailPrice or retailPrice < 0 then
        return false, 'Invalid retail price.'
    end

    -- Verify stock belongs to this dealership
    local stock = MySQL.single.await(
        'SELECT * FROM pickle_dealership_stock WHERE id = ? AND dealership_id = ? AND sold_at IS NULL',
        { stockId, dealership.id }
    )
    if not stock then return false, 'Stock item not found.' end

    MySQL.update.await(
        'UPDATE pickle_dealership_stock SET retail_price = ? WHERE id = ?',
        { retailPrice, stockId }
    )

    ShowNotification(source, _L('stock_retail_price_updated', GetCurrencyString(retailPrice)), 'success')
    return true
end)

--- Owner/manager sets the minimum faction grade required to purchase a stock item.
--- Grade is scoped to the dealership's assigned job/gang (dealership.job). A minGrade
--- of 0 or nil removes the restriction. The value is persisted in pickle_dealership_stock.metadata.
---@param locationKey string
---@param stockId number
---@param minGrade number|nil
lib.callback.register('pickle_dealerships:setStockMinGrade', function(source, locationKey, stockId, minGrade)
    local identifier = GetIdentifier(source)
    if not identifier then return false, 'Unable to identify player.' end

    local dealership = MySQL.single.await(
        'SELECT * FROM pickle_dealerships WHERE location = ?',
        { locationKey }
    )
    if not dealership then return false, 'Dealership not found.' end
    if not CanPlayerManageOps(source, dealership.id) then return false, 'You do not have permission.' end

    local stock = MySQL.single.await(
        'SELECT id, metadata, vehicle_label FROM pickle_dealership_stock WHERE id = ? AND dealership_id = ? AND sold_at IS NULL',
        { stockId, dealership.id }
    )
    if not stock then return false, 'Stock item not found.' end

    local meta = stock.metadata
    if type(meta) == 'string' then meta = json.decode(meta) or {} end
    if type(meta) ~= 'table' then meta = {} end

    local clamped = tonumber(minGrade)
    if not clamped or clamped <= 0 then
        meta.minGrade = nil
    else
        meta.minGrade = math.floor(clamped)
    end

    MySQL.update.await(
        'UPDATE pickle_dealership_stock SET metadata = ? WHERE id = ?',
        { json.encode(meta), stockId }
    )

    ShowNotification(source, _L('stock_min_grade_updated', stock.vehicle_label or 'Vehicle'), 'success')
    return true, meta.minGrade or 0
end)

--- Owner/manager toggles the unlisted flag on a stock item
lib.callback.register('pickle_dealerships:toggleUnlisted', function(source, locationKey, stockId)
    local identifier = GetIdentifier(source)
    if not identifier then return false, 'Unable to identify player.' end

    local dealership = MySQL.single.await(
        'SELECT * FROM pickle_dealerships WHERE location = ?',
        { locationKey }
    )
    if not dealership then return false, 'Dealership not found.' end
    if not CanPlayerManageOps(source, dealership.id) then return false, 'You do not have permission.' end

    local stock = MySQL.single.await(
        'SELECT id, unlisted, vehicle_label, auction_id FROM pickle_dealership_stock WHERE id = ? AND dealership_id = ? AND sold_at IS NULL',
        { stockId, dealership.id }
    )
    if not stock then return false, 'Stock item not found.' end

    local newValue = (stock.unlisted == 1 or stock.unlisted == true) and 0 or 1

    -- While a vehicle is tied to an auction, unlisting is blocked entirely.
    -- Tearing down the auction from here raced with the auction viewer and
    -- could leave the car in a glitched state; owners must cancel/end the
    -- auction from the auction UI before they can unlist.
    if newValue == 1 and stock.auction_id then
        return false, 'Cannot unlist while the vehicle is at auction. Cancel the auction first.'
    end

    -- If unlisting, also remove from display spot
    if newValue == 1 then
        MySQL.update.await('UPDATE pickle_dealership_stock SET unlisted = 1, display_spot = NULL WHERE id = ?', { stockId })
    else
        MySQL.update.await('UPDATE pickle_dealership_stock SET unlisted = 0 WHERE id = ?', { stockId })
    end

    local statusKey = newValue == 1 and 'stock_unlisted' or 'stock_listed'
    ShowNotification(source, _L(statusKey, stock.vehicle_label or 'Vehicle'), 'success')
    return true, newValue == 1
end)

--- Assigns a stock item to a display spot (or removes from display)
---@param source number
---@param locationKey string
---@param stockId number
---@param spot number|nil
--- Returns the stock row currently assigned to `spotId` at this dealership, or nil.
--- Used by the client's targeted single-spot refresh to avoid re-fetching the
--- whole stock list when only one spot changed.
lib.callback.register('pickle_dealerships:getStockAtSpot', function(_, locationKey, spotId)
    if not locationKey or not spotId then return nil end
    local dealership = MySQL.single.await('SELECT id FROM pickle_dealerships WHERE location = ?', { locationKey })
    if not dealership then return nil end

    local row = MySQL.single.await([[
        SELECT ds.*, wc.image, wc.class
        FROM pickle_dealership_stock ds
        LEFT JOIN pickle_wholesale_catalog wc ON wc.model = ds.vehicle_model
        WHERE ds.dealership_id = ?
          AND ds.display_spot = ?
          AND ds.sold_at IS NULL
          AND ds.delivered_at IS NOT NULL
          AND ds.delivered_at <= NOW()
          AND (ds.unlisted IS NULL OR ds.unlisted = 0)
          AND ds.auction_id IS NULL
        LIMIT 1
    ]], { dealership.id, tonumber(spotId) })

    return row
end)

lib.callback.register('pickle_dealerships:setDisplaySpot', function(source, locationKey, stockId, spot)
    local identifier = GetIdentifier(source)
    if not identifier then return false, 'Unable to identify player.' end

    local dealership = MySQL.single.await(
        'SELECT * FROM pickle_dealerships WHERE location = ?',
        { locationKey }
    )
    if not dealership then return false, 'Dealership not found.' end

    -- Verify permission: owner + managers (roster or job grade).
    if not CanPlayerManageOps(source, dealership.id) then
        return false, 'You do not have permission.'
    end

    -- Verify stock belongs to this dealership and is delivered
    local stock = MySQL.single.await(
        'SELECT * FROM pickle_dealership_stock WHERE id = ? AND dealership_id = ? AND sold_at IS NULL',
        { stockId, dealership.id }
    )
    if not stock then return false, 'Stock item not found.' end
    if spot and (stock.unlisted == 1 or stock.unlisted == true) then return false, 'Cannot display an unlisted vehicle.' end

    -- Track every spot that changed so the clients can do a surgical re-render
    -- instead of tearing down + rebuilding the whole lot.
    local affectedSpots = {}
    local function markSpot(s)
        s = tonumber(s)
        if s then affectedSpots[s] = true end
    end

    -- The stock item's current spot (if any) is about to be vacated.
    if stock.display_spot then markSpot(stock.display_spot) end

    if spot then
        -- Check if spot is already occupied by another vehicle
        local existing = MySQL.single.await(
            'SELECT id FROM pickle_dealership_stock WHERE dealership_id = ? AND display_spot = ? AND sold_at IS NULL AND id != ?',
            { dealership.id, spot, stockId }
        )
        if existing then
            -- Remove previous vehicle from spot
            MySQL.update.await(
                'UPDATE pickle_dealership_stock SET display_spot = NULL WHERE id = ?',
                { existing.id }
            )
        end

        -- Assign the spot directly on the stock entry (no splitting)
        MySQL.update.await(
            'UPDATE pickle_dealership_stock SET display_spot = ? WHERE id = ?',
            { spot, stockId }
        )
        markSpot(spot)
    else
        MySQL.update.await(
            'UPDATE pickle_dealership_stock SET display_spot = NULL WHERE id = ?',
            { stockId }
        )
    end

    local spotList = {}
    for s in pairs(affectedSpots) do spotList[#spotList + 1] = s end

    -- Notify clients: pass the affected spot IDs so only those re-render.
    TriggerClientEvent('pickle_dealerships:refreshDisplay', -1, locationKey, spotList)
    ShowNotification(source, spot and _L('stock_display_spot_set', spot) or _L('stock_display_removed_server'), 'success')
    return true
end)

--- Recolor a stock row. Owner/manager only. The `color` payload is stored
--- as JSON in `pickle_dealership_stock.color` (same shape vehicle spawn
--- already reads), and if the row currently sits on a display spot we fire
--- `refreshDisplay` so the in-world vehicle restyles within a tick.
lib.callback.register('pickle_dealerships:setStockColor', function(source, data)
    local stockId = tonumber(data and data.stockId)
    local dealershipId = tonumber(data and data.dealershipId)
    if not stockId or not dealershipId then return { success = false, message = 'Invalid request.' } end

    if not CanPlayerManageOps(source, dealershipId) then
        return { success = false, message = _L('no_permission') }
    end

    local stock = MySQL.single.await(
        [[SELECT ds.id, ds.dealership_id, d.location, ds.display_spot, ds.is_used, ds.color
            FROM pickle_dealership_stock ds
            JOIN pickle_dealerships d ON d.id = ds.dealership_id
           WHERE ds.id = ? AND ds.dealership_id = ? AND ds.sold_at IS NULL]],
        { stockId, dealershipId }
    )
    if not stock then return { success = false, message = 'Stock not found.' } end

    -- Pre-owned units carry their own captured properties (incl. color) in the
    -- `metadata` blob; recoloring just the `color` column would have no effect
    -- because the spawn path reads metadata first. Reject so the operator
    -- doesn't think they changed something that didn't change.
    if stock.is_used == 1 or stock.is_used == true then
        return { success = false, message = _L('recolor_pre_owned_unsupported') }
    end

    local primary = data.primary
    local secondary = data.secondary
    if type(primary) ~= 'table' or primary.r == nil or primary.g == nil or primary.b == nil then
        return { success = false, message = 'Invalid color.' }
    end

    -- Sanitise (0-255 ints) so we never write garbage that might crash the client setter.
    local function clampByte(v) return math.max(0, math.min(255, math.floor(tonumber(v) or 0))) end
    local payload = {
        r = clampByte(primary.r),
        g = clampByte(primary.g),
        b = clampByte(primary.b),
        secondary = (type(secondary) == 'table' and secondary.r) and {
            r = clampByte(secondary.r),
            g = clampByte(secondary.g),
            b = clampByte(secondary.b),
        } or nil,
    }

    MySQL.update.await(
        'UPDATE pickle_dealership_stock SET color = ? WHERE id = ?',
        { json.encode(payload), stockId }
    )

    if stock.display_spot then
        -- Live recolor of the in-world entity rather than a full re-spawn,
        -- so a staff member picking colors from the spot view doesn't see
        -- their camera target disappear and reappear on every swatch click.
        TriggerClientEvent('pickle_dealerships:displayColorChanged', -1, stock.location, stockId, payload)
    end

    return { success = true, message = _L('recolor_saved') }
end)

--- Checks for stock items whose delivery time has passed and marks them delivered
---@param source number
---@param locationKey string
lib.callback.register('pickle_dealerships:checkDeliveries', function(source, locationKey)
    local dealership = MySQL.single.await(
        'SELECT * FROM pickle_dealerships WHERE location = ?',
        { locationKey }
    )
    if not dealership then return {} end

    -- Find items that have a future delivered_at that has now passed
    local delivered = MySQL.query.await(
        'SELECT * FROM pickle_dealership_stock WHERE dealership_id = ? AND sold_at IS NULL AND delivered_at IS NOT NULL AND delivered_at <= NOW()',
        { dealership.id }
    )

    return delivered or {}
end)

--- Returns a wholesale MSRP suggestion + resolved model name for a vehicle by plate
lib.callback.register('pickle_dealerships:getTradeInSuggestion', function(source, locationKey, plate)
    if not plate then return nil end
    plate = string.upper(tostring(plate):gsub('^%s*(.-)%s*$', '%1'))

    local dealership = MySQL.single.await('SELECT id FROM pickle_dealerships WHERE location = ?', { locationKey })
    if not dealership then return nil end
    if not CanPlayerManageOps(source, dealership.id) then DenyAccess(source) return nil end

    local owned = GetOwnedVehicleFromPlate(plate)
    if not owned then return { ownerless = true } end

    local model = owned.model
    if not model then
        return { model = nil, label = nil, wholesale = nil, owner = owned.owner }
    end

    local entry = MySQL.single.await('SELECT label, wholesale FROM pickle_wholesale_catalog WHERE model = ?', { model })
    return {
        model = model,
        label = (entry and entry.label) or model,
        wholesale = entry and tonumber(entry.wholesale) or nil,
        owner = owned.owner,
    }
end)

--- Quick lookup: is this plate registered to a player? (for client-side pre-flight checks)
lib.callback.register('pickle_dealerships:isPlateOwned', function(source, plate)
    if not plate then return false end
    plate = string.upper(tostring(plate):gsub('^%s*(.-)%s*$', '%1'))
    local owned = GetOwnedVehicleFromPlate(plate)
    return owned and owned.owner ~= nil
end)

--- Manager trades in a player vehicle as pre-owned stock
lib.callback.register('pickle_dealerships:tradeInVehicle', function(source, locationKey, payload)
    return DealerTransaction(source, function(transaction)
        local identifier = GetIdentifier(source)
        if not identifier then return false, 'Unable to identify player.' end
        if type(payload) ~= 'table' then return false, 'Invalid payload.' end

        local plate = payload.plate and string.upper(tostring(payload.plate):gsub('^%s*(.-)%s*$', '%1')) or nil
        local properties = payload.properties
        local buyPrice = math.max(0, math.floor(tonumber(payload.buyPrice) or 0))
        local retailPrice = math.max(0, math.floor(tonumber(payload.retailPrice) or 0))

        if not plate or not properties then return false, 'Missing vehicle data.' end
        if buyPrice <= 0 or retailPrice <= 0 then return false, 'Buy and retail prices must be set.' end

        local dealership = MySQL.single.await('SELECT * FROM pickle_dealerships WHERE location = ?', { locationKey })
        if not dealership then return false, 'Dealership not found.' end
        if not CanPlayerManageOps(source, dealership.id) then return false, 'You do not have permission.' end

        -- Look up owner + model of the plate from the framework record (server-trusted)
        local owned = GetOwnedVehicleFromPlate(plate)
        if not owned or not owned.owner then return false, 'This vehicle is not registered to anyone.' end
        local sellerIdentifier = owned.owner
        local model = owned.model
        -- Fall back to the client-supplied model name (resolved from the entity hash)
        -- when the framework bridge didn't persist a model string in the DB record.
        -- This mirrors the identical fallback in seizeVehicle (lines ~1292-1296).
        if (not model or model == '') and payload.modelName and payload.modelName ~= '' then
            model = tostring(payload.modelName):lower()
        end
        if not model then return false, 'Could not resolve vehicle model.' end

        -- Require consent from the online owner before taking their vehicle
        local sellerSource = GetSourceFromIdentifier(sellerIdentifier)
        if not sellerSource then
            return false, 'The vehicle owner is not online.'
        end

        local catalogLookup = MySQL.single.await('SELECT label FROM pickle_wholesale_catalog WHERE model = ?', { model })
        local displayLabel = (catalogLookup and catalogLookup.label) or model

        local consented = lib.callback.await('pickle_dealerships:confirmTradeIn', sellerSource, {
            dealershipName = dealership.name,
            label = displayLabel,
            plate = plate,
            buyPrice = buyPrice,
        })
        if not consented then
            return false, 'The owner declined the trade-in.'
        end

        -- Re-verify ownership after consent in case something changed during the prompt
        local recheck = GetOwnedVehicleFromPlate(plate)
        if not recheck or recheck.owner ~= sellerIdentifier then
            return false, 'Ownership changed before the trade-in completed.'
        end

        -- Block trade-in if vehicle is under active financing
        local activeFinancing = MySQL.scalar.await(
            "SELECT COUNT(*) FROM `pickle_dealership_financing` WHERE `vehicle_plate` = ? AND `status` = 'active'",
            { plate }
        )
        if activeFinancing and tonumber(activeFinancing) > 0 then
            return false, 'This vehicle is under active financing and cannot be traded in.'
        end

        -- Reconcile any delivered orders before balance checks.
        ProcessDeliveredOrders(dealership.id, transaction)

        -- Balance check
        if dealership.balance < buyPrice then
            return false, 'Insufficient dealership funds.'
        end

        -- Derive condition from health (0-1000 in props.bodyHealth/engineHealth → percent)
        local props = properties
        if type(props) == 'string' then props = json.decode(props) or {} end
        local body = tonumber(props.bodyHealth) or 1000
        local engine = tonumber(props.engineHealth) or 1000
        local condition = math.max(0, math.min(100, ((body + engine) / 2) / 10))

        local catalog = MySQL.single.await('SELECT label FROM pickle_wholesale_catalog WHERE model = ?', { model })
        local label = (catalog and catalog.label) or model

        if GetIdentifier(sellerSource)~=sellerIdentifier then return false,'Seller session changed.' end
        local currentOwner=GetOwnedVehicleFromPlate(plate)
        if not currentOwner or currentOwner.owner~=sellerIdentifier then return false,'Ownership changed.' end
        if RemoveOwnedVehicle(sellerIdentifier,plate)~=true then return false,'Ownership removal failed.' end
        if MySQL.update.await('UPDATE pickle_dealerships SET balance=balance-? WHERE id=? AND balance>=?',{buyPrice,dealership.id,buyPrice})~=1 then
            DealerRestoreVehicle(sellerIdentifier,model,plate,props)
            return false,'Insufficient dealership funds.'
        end

        -- Pay the seller (consent already confirmed above)
        -- Seller payment is queued only after stock insertion succeeds.
        ShowNotification(sellerSource, _L('stock_trade_in_seller', label, GetCurrencyString(buyPrice)))

        -- Remove ownership from the seller's framework records
        -- Ownership was claimed before the dealership debit.

        -- Insert pre-owned stock row (captured vehicle properties stored in metadata)
        local inserted,stockId=pcall(MySQL.insert.await,
            'INSERT INTO pickle_dealership_stock (dealership_id, vehicle_model, vehicle_label, wholesale_cost, retail_price, ordered_at, delivered_at, quantity, is_used, metadata, plate, acquired_from, `condition`) VALUES (?, ?, ?, ?, ?, NOW(), NOW(), 1, 1, ?, ?, ?, ?)',
            {
                dealership.id, model, label, buyPrice, retailPrice,
                json.encode(props), plate, sellerIdentifier, condition,
            }
        )

        if not inserted or not stockId then
            DealerRestoreVehicle(sellerIdentifier,model,plate,props)
            MySQL.update.await('UPDATE pickle_dealerships SET balance=balance+? WHERE id=?',{buyPrice,dealership.id})
            return false,'Trade-in stock insertion failed; ownership recovery queued.'
        end
        DealerCredit(sellerIdentifier,buyPrice,'bank' ,'trade-in:'..tostring(stockId))
        AddLedgerEntry(dealership.id, 'expense', -buyPrice, 'Trade-in: ' .. label .. ' (' .. plate .. ')', identifier)

        ShowNotification(source, _L('stock_trade_in_buyer', label, GetCurrencyString(buyPrice)))
        TriggerClientEvent('pickle_dealerships:refreshDisplay', -1, locationKey)

        -- Authoritative server-side delete. Client-side DeleteEntity silently
        -- fails when the manager running the trade-in doesn't own the vehicle's
        -- network entity; deleting from the server handles it regardless of owner.
        local netId = tonumber(payload.netId)
        if netId then
            local ent = NetworkGetEntityFromNetworkId(netId)
            if ent and ent ~= 0 and DoesEntityExist(ent) then
                DeleteEntity(ent)
            end
        end

        return true, stockId
    end, true)
end)

--- Returns seize-enabled dealerships that this player can manage
lib.callback.register('pickle_dealerships:getSeizeDealerships', function(source)
    local identifier = GetIdentifier(source)
    if not identifier then return {} end

    local dealerships = MySQL.query.await(
        'SELECT id, name, location FROM pickle_dealerships WHERE seize_enabled = 1'
    ) or {}

    local result = {}
    for _, d in ipairs(dealerships) do
        if CanPlayerManageOps(source, d.id) then
            result[#result + 1] = { id = d.id, name = d.name, location = d.location }
        end
    end
    return result
end)

--- Manager seizes a vehicle (no consent, no payment, unlisted by default)
lib.callback.register('pickle_dealerships:seizeVehicle', function(source, data)
    return DealerTransaction(source, function(transaction)
        local identifier = GetIdentifier(source)
        if not identifier then return false, 'Unable to identify player.' end
        if type(data) ~= 'table' then return false, 'Invalid payload.' end

        local dealershipId = tonumber(data.dealershipId)
        local plate = data.plate and string.upper(tostring(data.plate):gsub('^%s*(.-)%s*$', '%1')) or nil
        local properties = data.properties

        if not dealershipId or not plate or not properties then return false, 'Missing data.' end

        local dealership = MySQL.single.await('SELECT * FROM pickle_dealerships WHERE id = ?', { dealershipId })
        if not dealership then return false, 'Dealership not found.' end
        if not dealership.seize_enabled or dealership.seize_enabled == 0 or dealership.seize_enabled == false then return false, 'Seize mode is not enabled for this dealership.' end
        if not CanPlayerManageOps(source, dealership.id) then return false, 'You do not have permission.' end

        -- Only player-owned vehicles can be seized. NPC / unregistered vehicles are rejected.
        local owned = GetOwnedVehicleFromPlate(plate)
        if not owned or not owned.owner then
            return false, 'Only player-owned vehicles can be seized.'
        end

        -- Prefer the framework-stored model name, but fall back to the client-supplied
        -- name (resolved from the entity hash) when the bridge doesn't persist the model.
        local model = type(owned.model)=='string' and owned.model or nil
        if (not model or model == '') and data.modelName and data.modelName ~= '' then
            model = tostring(data.modelName):lower()
        end
        if not model then return false, 'Could not resolve vehicle model.' end

        -- Reconcile any delivered orders so counts stay consistent.
        ProcessDeliveredOrders(dealership.id, transaction)

        -- Derive condition from health
        local props = properties
        if type(props) == 'string' then props = json.decode(props) or {} end
        local body = tonumber(props.bodyHealth) or 1000
        local engine = tonumber(props.engineHealth) or 1000
        local condition = math.max(0, math.min(100, ((body + engine) / 2) / 10))

        local catalog = MySQL.single.await('SELECT label FROM pickle_wholesale_catalog WHERE model = ?', { model })
        local label = (catalog and catalog.label) or (data.label and data.label ~= '' and data.label) or model

        -- Remove ownership if the vehicle is registered
        local previousOwner = nil
        if owned and owned.owner then
            previousOwner = owned.owner
            if RemoveOwnedVehicle(owned.owner, plate)~=true then return false,'Ownership removal failed.' end
        end

        -- Cancel any active financing on this vehicle (no refund — the player loses the vehicle)
        local activeLoan = MySQL.single.await(
            "SELECT id, identifier, dealership_id FROM pickle_dealership_financing WHERE vehicle_plate = ? AND status = 'active'",
            { plate }
        )
        if activeLoan then
            MySQL.update.await(
                "UPDATE pickle_dealership_financing SET status = 'repossessed' WHERE id = ?",
                { activeLoan.id }
            )
            AddLedgerEntry(activeLoan.dealership_id, "repossession", 0, ("Vehicle seized — financing cancelled: plate %s"):format(plate), activeLoan.identifier)
            local debtorSource = GetSourceFromIdentifier(activeLoan.identifier)
            if debtorSource then
                TriggerClientEvent("pickle_dealerships:vehicleRepossessed", debtorSource, {
                    plate = plate,
                    missedPayments = 0,
                })
            end
        end

        -- Insert as unlisted pre-owned stock (no cost to dealership)
        local inserted,stockId=pcall(MySQL.insert.await,
            'INSERT INTO pickle_dealership_stock (dealership_id, vehicle_model, vehicle_label, wholesale_cost, retail_price, ordered_at, delivered_at, quantity, is_used, unlisted, metadata, plate, acquired_from, `condition`) VALUES (?, ?, ?, 0, 0, NOW(), NOW(), 1, 1, 1, ?, ?, ?, ?)',
            {
                dealership.id, model, label,
                json.encode(props), plate, previousOwner or 'seized', condition,
            }
        )

        if not inserted or not stockId then
            DealerRestoreVehicle(previousOwner,model,plate,props)
            if activeLoan then MySQL.update.await("UPDATE pickle_dealership_financing SET status='active' WHERE id=?",{activeLoan.id}) end
            return false,'Seizure could not be committed; ownership recovery queued.'
        end
        AddLedgerEntry(dealership.id, 'seize' , 0, 'Seized: ' .. label .. ' (' .. plate .. ')' .. (previousOwner and (' from ' .. previousOwner) or ''), identifier)

        ShowNotification(source, _L('seize_success', label, plate))
        TriggerClientEvent('pickle_dealerships:refreshDisplay', -1, dealership.location)

        -- Authoritative server-side delete (see tradeInVehicle for rationale).
        local netId = tonumber(data.netId)
        if netId then
            local ent = NetworkGetEntityFromNetworkId(netId)
            if ent and ent ~= 0 and DoesEntityExist(ent) then
                DeleteEntity(ent)
            end
        end

        return true, stockId
    end, true)
end)

--- On-demand: process any delivered orders for a dealership
--- Moves delivered orders from pickle_dealership_orders into pickle_dealership_stock (stacking onto existing stock)
function ProcessDeliveredOrders(id, operation)
    return DealerRunMutation(function()
        local rows=MySQL.query.await('SELECT id FROM pickle_dealership_orders WHERE dealership_id=? AND delivered_at IS NOT NULL AND delivered_at<=NOW() AND claimed_by IS NULL',{id}) or {}
        local ids={}; for _,row in ipairs(rows) do ids[#ids+1]=row.id end
        return DealerCommitOrders(ids)
    end, operation)
end
