-- =============================================
--  pickle_dealerships | modules/delivery/server.lua
--  Gameplay delivery system: queue browsing, claim, payout, progression
-- =============================================

local activeDeliveries = {} -- source -> { orderId, dealershipId, identifier, route, vehicle, qty, fee, catalogTier }

-- ─── Helpers ─────────────────────────────────────────────────────────────────

--- Picks the depot closest to the destination dealership at claim time.
--- Falls back to any available depot if dealership coords are missing.
--- Returns (depot, depotId) or (nil, nil) if no depots are configured.
local function PickNearestDepot(targetCoords)
    local depots = GetDeliveryDepots() or {}
    if #depots == 0 then return nil, nil end
    if not targetCoords then
        local d = depots[1]
        return d, d.id
    end
    local best, bestDist
    for _, d in ipairs(depots) do
        local c = d.pickupCoords
        if c then
            local dx, dy, dz = (c.x - targetCoords.x), (c.y - targetCoords.y), (c.z - targetCoords.z)
            local sq = dx * dx + dy * dy + dz * dz
            if not bestDist or sq < bestDist then
                best, bestDist = d, sq
            end
        end
    end
    if not best then return nil, nil end
    return best, best.id
end

--- Returns the highest-ranked default-group name the vehicle belongs to, used
--- as the "tier" key for xpTierMultiplier. Non-default (admin-created) groups
--- don't contribute to XP scaling — a vehicle only in custom groups falls
--- back to 'basic'. This preserves the old xpTierMultiplier config shape
--- (`{ basic = 1.0, expanded = 1.2, ... }`) without another migration.
local TIER_RANK = { basic = 1, expanded = 2, full = 3, exclusive = 4 }
local function ResolveCatalogTier(model)
    if not model then return 'basic' end
    local rows = MySQL.query.await([[
        SELECT g.name
        FROM pickle_wholesale_catalog wc
        JOIN pickle_catalog_vehicle_groups vg ON vg.catalog_id = wc.id
        JOIN pickle_catalog_groups g ON g.id = vg.group_id
        WHERE wc.model = ? AND g.is_default = 1
    ]], { model }) or {}
    local best, bestRank = 'basic', 0
    for _, r in ipairs(rows) do
        local rank = TIER_RANK[r.name] or 0
        if rank > bestRank then best, bestRank = r.name, rank end
    end
    return best
end

-- ─── Trailer planning ────────────────────────────────────────────────────────
-- All the tunables — class buckets, capacity, slot order, offsets, trailer models — live in
-- Config.Trailer (config.lua) so servers can adjust them without touching module code.

local function TrailerCfg() return (Config and Config.Trailer) or {} end

local function IsMediumClass(vehicleClass)
    local classes = TrailerCfg().classes or {}
    return (classes.medium or {})[string.lower(tostring(vehicleClass or ''))] == true
end

local function IsTr2Class(vehicleClass)
    local classes = TrailerCfg().classes or {}
    local c = string.lower(tostring(vehicleClass or ''))
    return (classes.medium or {})[c] or (classes.small or {})[c] or (classes.bike or {})[c] or false
end

-- Single bucket for every tr2-compatible road vehicle. Anything else routes to the enclosed trailer.
function TrailerSizeForClass(vehicleClass)
    return IsTr2Class(vehicleClass) and 'tr2' or 'enclosed'
end

-- Exposed as a global so stock/server.lua can reuse the capacity table when grouping.
-- Falls back to sane defaults if Config.Trailer hasn't loaded yet.
CAP_BY_SIZE = setmetatable({}, {
    __index = function(_, key)
        local caps = TrailerCfg().capacity or {}
        return caps[key] or { total = 4, medium = 4 }
    end,
})

--- Builds a trailer plan from a bundle of compatible orders. Each slot carries the model it should spawn.
--- Mediums fill their preferred slot list (non-adjacent), smalls fill the first free slot in their list.
local function ComputeTrailerPlan(bundle)
    local cfg = TrailerCfg()
    local models = cfg.models or {}
    if not bundle or #bundle == 0 then
        return { trailerModel = models.enclosed or 'trailers', size = 'enclosed', slots = {} }
    end
    local size = TrailerSizeForClass(bundle[1].class)
    if size == 'enclosed' then
        return { trailerModel = models.enclosed or 'trailers', size = 'enclosed', slots = {} }
    end

    local tr2Slots = cfg.tr2Slots or {}
    local orders   = cfg.slotOrder or {}
    local mediumOrder = orders.medium or {}
    local smallOrder  = orders.small  or {}
    local caps = (cfg.capacity and cfg.capacity.tr2) or { total = 6, medium = 4 }

    local slots, used = {}, {}
    local mediumIdx, smallIdx = 0, 0

    local function pushSlot(model, slotNum)
        if not slotNum or not tr2Slots[slotNum] or used[slotNum] then return end
        used[slotNum] = true
        local src = tr2Slots[slotNum]
        slots[#slots + 1] = {
            model = model,
            x = src.x, y = src.y, z = src.z,
            rotX = src.rotX or 0.0, rotY = src.rotY or 0.0, rotZ = src.rotZ or 0.0,
        }
    end

    for _, v in ipairs(bundle) do
        local qty = tonumber(v.quantity) or 1
        local isMedium = IsMediumClass(v.class)
        for _ = 1, qty do
            if #slots >= caps.total then break end
            if isMedium then
                mediumIdx = mediumIdx + 1
                if mediumIdx > #mediumOrder then break end -- hit medium cap
                pushSlot(v.model, mediumOrder[mediumIdx])
            else
                repeat
                    smallIdx = smallIdx + 1
                until (not smallOrder[smallIdx]) or (not used[smallOrder[smallIdx]])
                local s = smallOrder[smallIdx]
                if not s then break end
                pushSlot(v.model, s)
            end
        end
    end
    return { trailerModel = models.tr2 or 'tr2', size = 'tr2', slots = slots }
end

--- Returns the bucket size for a given class (used to test sibling compatibility).
--- For bundling purposes, 'bike' and 'small' are NOT interchangeable (different layouts).
--- Global so stock/server.lua can reuse when grouping the dealership management view.
function BundleBucketForClass(vehicleClass)
    return TrailerSizeForClass(vehicleClass)
end

--- Groups a set of local-delivery order rows into trailer-load cards.
--- Each returned card represents ONE trailer-run — driven by CAP_BY_SIZE for the bucket.
--- A `(dealership, bucket)` pair with more orders than one trailer holds produces multiple cards.
--- In-transit orders (claimed_by set) are split from unclaimed so the management view can tell them apart.
---
--- `rows` is an array of order rows with at least: id, dealership_id, dealership_name, vehicle_model,
--- vehicle_label, retail_price, delivery_fee, quantity, ordered_at, claimed_by, class, image.
--- `streakMult` scales projected payout; pass 1.0 for management views where streak is irrelevant.
function GroupLocalOrders(rows, streakMult)
    streakMult = streakMult or 1.0

    -- Pass 1: bucket rows by (dealership_id, trailer-bucket, claimed_by). claimed_by=nil groups separately
    -- from any specific driver so unclaimed + in-transit deliveries never merge into the same card.
    local groupMap, keyList = {}, {}
    for _, r in ipairs(rows) do
        local bucket = BundleBucketForClass(r.class or 'sedan')
        local claimedKey = r.claimed_by or 'NULL'
        local key = ('%d:%s:%s'):format(r.dealership_id, bucket, claimedKey)
        if not groupMap[key] then
            groupMap[key] = {
                dealership_id = r.dealership_id,
                dealership_name = r.dealership_name,
                bucket = bucket,
                claimed_by = r.claimed_by,
                orders = {},
            }
            keyList[#keyList + 1] = key
        end
        table.insert(groupMap[key].orders, r)
    end

    -- Pass 2: within each group, greedy-pack into trailer-loads. Each load tracks both the total
    -- slot count and a separate medium quota so we never exceed 4 mediums on a trailer.
    local result = {}
    for _, k in ipairs(keyList) do
        local g = groupMap[k]
        local caps = CAP_BY_SIZE[g.bucket] or { total = 4, medium = 4 }

        table.sort(g.orders, function(a, b)
            local aq, bq = (a.quantity or 1), (b.quantity or 1)
            if aq ~= bq then return aq < bq end
            return (a.ordered_at or '') < (b.ordered_at or '')
        end)

        local loads = {}
        local current = { orders = {}, totalLeft = caps.total, mediumLeft = caps.medium }
        local function flushCurrent()
            if #current.orders > 0 then
                loads[#loads + 1] = current.orders
                current = { orders = {}, totalLeft = caps.total, mediumLeft = caps.medium }
            end
        end
        for _, o in ipairs(g.orders) do
            local qty = o.quantity or 1
            local isMedium = IsMediumClass(o.class)
            local fits = qty <= current.totalLeft and (not isMedium or qty <= current.mediumLeft)
            if fits then
                current.orders[#current.orders + 1] = o
                current.totalLeft = current.totalLeft - qty
                if isMedium then current.mediumLeft = current.mediumLeft - qty end
            else
                flushCurrent()
                local fitsFresh = qty <= caps.total and (not isMedium or qty <= caps.medium)
                if fitsFresh then
                    current.orders[#current.orders + 1] = o
                    current.totalLeft = caps.total - qty
                    current.mediumLeft = caps.medium - (isMedium and qty or 0)
                else
                    -- Order larger than a whole trailer of its class — its own card.
                    loads[#loads + 1] = { o }
                end
            end
        end
        flushCurrent()

        for _, load in ipairs(loads) do
            local totalFee, totalQty = 0, 0
            local vehicles, bundleIds = {}, {}
            local primary = load[1]
            for _, o in ipairs(load) do
                totalFee = totalFee + (o.delivery_fee or 0)
                totalQty = totalQty + (o.quantity or 1)
                vehicles[#vehicles + 1] = {
                    id = o.id, model = o.vehicle_model, label = o.vehicle_label, quantity = o.quantity,
                }
                bundleIds[#bundleIds + 1] = o.id
                if (o.retail_price or 0) > (primary.retail_price or 0) then primary = o end
            end
            result[#result + 1] = {
                primaryOrderId = primary.id,
                orderIds = bundleIds,
                dealership_id = g.dealership_id,
                dealership_name = g.dealership_name,
                bucket = g.bucket,
                claimed_by = g.claimed_by,
                vehicles = vehicles,
                primaryModel = primary.vehicle_model,
                primaryLabel = primary.vehicle_label,
                primaryRetail = primary.retail_price,
                primaryImage = primary.image,
                primaryClass = primary.class,
                primaryWholesale = primary.wholesale_cost,
                totalQty = totalQty,
                bundleSize = #load,
                totalFee = totalFee,
                projectedPayout = math.floor(totalFee * streakMult),
                orderedAt = (load[1] and load[1].ordered_at) or nil,
            }
        end
    end

    return result
end

local function GetDealershipCoords(dealership)
    local meta = dealership.metadata
    if type(meta) == 'string' then meta = json.decode(meta) or {} end
    if type(meta) == 'table' and meta.coords then
        return vector3(meta.coords.x, meta.coords.y, meta.coords.z)
    end
    return nil
end

--- Returns the dedicated drop-off point (deliveryPoint) as a plain {x,y,z,w} table, or nil.
--- Local deliveries require this point — the queue filter + order-placement guard prevent
--- pickle_dealerships without it from participating in local delivery, so by the time a mission is
--- assembled we can trust it exists.
local function GetDealershipDropoff(dealership)
    local meta = dealership.metadata
    if type(meta) == 'string' then meta = json.decode(meta) or {} end
    if type(meta) == 'table' and meta.deliveryPoint then
        local p = meta.deliveryPoint
        return { x = p.x, y = p.y, z = p.z, w = p.w or 0.0 }
    end
    return nil
end

--- Computes the final payout at completion time (after streak + damage modifiers).
local function ComputeFinalPayout(baseFee, identifier, condition)
    local cfg = Config.Delivery or {}
    local streakMult = GetDriverStreakMultiplier and GetDriverStreakMultiplier(identifier) or 1.0
    local damageMult = 1.0

    if cfg.damagePenalty and cfg.damagePenalty.enabled and condition then
        local full = cfg.damagePenalty.fullPayoutAboveCondition or 90
        local zero = cfg.damagePenalty.zeroPayoutBelowCondition or 25
        if condition >= full then
            damageMult = 1.0
        elseif condition <= zero then
            damageMult = 0.0
        else
            damageMult = (condition - zero) / (full - zero)
        end
    end

    return math.floor(baseFee * streakMult * damageMult), streakMult, damageMult
end

--- XP scales per vehicle: summed across every model in the bundle × each model's tier multiplier.
--- `delivery` is an activeDeliveries[source] entry (has a `catalogTier` + legacy fallback for tests).
local function ComputeXPAward(delivery, failed)
    local cfg = Config.Delivery or {}
    local base = cfg.xpPerDelivery or 25
    local total = 0
    if delivery.orders then
        for _, o in ipairs(delivery.orders) do
            local tier = ResolveCatalogTier(o.model) or delivery.catalogTier or 'basic'
            local mult = (cfg.xpTierMultiplier and cfg.xpTierMultiplier[tier]) or 1.0
            total = total + math.floor(base * mult) * (o.quantity or 1)
        end
    else
        total = math.floor(base * ((cfg.xpTierMultiplier and cfg.xpTierMultiplier[delivery.catalogTier]) or 1.0))
    end
    if failed then total = -math.floor(total * (cfg.failXpPenalty or 0.5)) end
    return total
end

-- ─── Queue Browsing ──────────────────────────────────────────────────────────

--- Returns the list of available offers for the requesting player.
--- Local offers are always first and visible to everyone regardless of level.
lib.callback.register('pickle_dealerships:getDeliveryQueue', function(source)
    local identifier = GetIdentifier(source)
    if not identifier then return { ['local'] = {}, premium = {} } end

    local rows = MySQL.query.await([[
        SELECT o.id, o.dealership_id, o.vehicle_model, o.vehicle_label, o.retail_price,
               o.quantity, o.delivery_fee, o.ordered_at, o.claimed_by,
               COALESCE(c.class, 'sedan') AS class, c.image AS image,
               d.name AS dealership_name
          FROM pickle_dealership_orders o
          LEFT JOIN pickle_wholesale_catalog c ON c.model = o.vehicle_model
          JOIN pickle_dealerships d ON d.id = o.dealership_id
         WHERE o.delivery_mode = 'local' AND o.claimed_by IS NULL
         ORDER BY o.ordered_at ASC
    ]]) or {}

    -- Filter out any orders whose dealership has no deliveryPoint set. Without a drop-off point
    -- there's nowhere to land the trailer, so the offer is hidden from drivers until the owner
    -- configures one (orders already in the queue for unconfigured pickle_dealerships simply stay idle).
    do
        local filtered = {}
        for _, r in ipairs(rows) do
            local d = GetDealership(r.dealership_id)
            if d and GetDealershipDropoff(d) then
                filtered[#filtered + 1] = r
            end
        end
        rows = filtered
    end

    local prog = GetDriverProgression(identifier) or { level = 1, xp = 0, streak = 0, completed_count = 0, failed_count = 0 }
    local streakMult = GetDriverStreakMultiplier(identifier)

    local grouped = GroupLocalOrders(rows, streakMult)
    local localOffers = {}
    for _, g in ipairs(grouped) do
        localOffers[#localOffers + 1] = {
            orderId = g.primaryOrderId,  -- legacy handle (server acceptDelivery will also accept this)
            orderIds = g.orderIds,        -- full bundle the UI previewed
            dealershipId = g.dealership_id,
            dealershipName = g.dealership_name,
            vehicleModel = g.primaryModel,
            vehicleLabel = g.primaryLabel,
            retailPrice = g.primaryRetail,
            quantity = g.totalQty,
            bundleSize = g.bundleSize,
            vehicles = g.vehicles,
            baseFee = g.totalFee,
            projectedPayout = g.projectedPayout,
            orderedAt = g.orderedAt,
        }
    end

    return {
        ['local'] = localOffers,
        premium = {},
        driver = {
            level = prog.level,
            xp = prog.xp,
            xpToNext = prog.xp_to_next,
            streak = prog.streak,
            streakMultiplier = streakMult,
            completed = prog.completed_count,
            failed = prog.failed_count,
        },
    }
end)

--- Returns the player's current progression stats.
lib.callback.register('pickle_dealerships:getDriverStats', function(source)
    local identifier = GetIdentifier(source)
    if not identifier then return nil end
    local prog = GetDriverProgression(identifier)
    if not prog then return nil end
    local levelDef = (Config.DeliveryProgression and Config.DeliveryProgression.levels or {})[prog.level] or {}
    local unlocked = {}
    if levelDef.catalogAccess then
        for tier, _ in pairs(levelDef.catalogAccess) do unlocked[#unlocked + 1] = tier end
    end
    return {
        level = prog.level,
        label = levelDef.label or 'Rookie',
        xp = prog.xp,
        xpToNext = prog.xp_to_next,
        streak = prog.streak,
        completed = prog.completed_count,
        failed = prog.failed_count,
        lifetimeEarnings = prog.lifetime_earnings,
        unlockedTiers = unlocked,
    }
end)

-- ─── Depot admin (DB-driven configuration) ──────────────────────────────────

lib.callback.register('pickle_dealerships:getDeliveryDepots', function(source)
    return GetDeliveryDepots() or {}
end)

--- Creates a depot with both interact (pickup) + truck-spawn coords supplied from the admin
--- creation dialog. Both are required — the new UX forces the admin to place each point via
--- gizmo before the Create button enables, so we don't accept the legacy "spawn falls back to
--- pickup" shape here.
lib.callback.register('pickle_dealerships:createDeliveryDepot', function(source, payload)
    if not IsPlayerAdmin(source) then return false, 'Admin only.' end
    if not payload or not payload.name then return false, 'Invalid payload.' end
    local p = payload.pickupCoords
    local s = payload.spawnCoords
    if not p or not p.x or not p.y or not p.z then return false, 'Missing pickup coords.' end
    if not s or not s.x or not s.y or not s.z then return false, 'Missing spawn coords.' end
    local id = CreateDeliveryDepot(
        payload.name,
        tonumber(p.x), tonumber(p.y), tonumber(p.z), tonumber(p.w) or 0.0
    )
    if not id then return false end
    SetDeliveryDepotSpawn(id, tonumber(s.x), tonumber(s.y), tonumber(s.z), tonumber(s.w) or 0.0)
    TriggerClientEvent('pickle_dealerships:depotsChanged', -1)
    return true, id
end)

lib.callback.register('pickle_dealerships:updateDeliveryDepot', function(source, id, fields)
    if not IsPlayerAdmin(source) then return false, 'Admin only.' end
    local ok = UpdateDeliveryDepot(id, fields)
    if ok then TriggerClientEvent('pickle_dealerships:depotsChanged', -1) end
    return ok
end)

lib.callback.register('pickle_dealerships:deleteDeliveryDepot', function(source, id)
    if not IsPlayerAdmin(source) then return false, 'Admin only.' end
    local ok = DeleteDeliveryDepot(id)
    if ok then TriggerClientEvent('pickle_dealerships:depotsChanged', -1) end
    return ok
end)

--- Admin moves the dispatch-ped (pickup) coords of an existing depot.
lib.callback.register('pickle_dealerships:setDeliveryDepotPickup', function(source, payload)
    if not IsPlayerAdmin(source) then return false, 'Admin only.' end
    if not payload or not payload.id or not payload.coords then return false, 'Invalid payload.' end
    local c = payload.coords
    if not c.x or not c.y or not c.z then return false, 'Missing coords.' end
    local ok = SetDeliveryDepotPickup(payload.id, tonumber(c.x), tonumber(c.y), tonumber(c.z), tonumber(c.w) or 0.0)
    if ok then TriggerClientEvent('pickle_dealerships:depotsChanged', -1) end
    return ok
end)

--- Admin sets the truck-spawn point for a depot. Coords come captured client-side.
--- The create flow requires both points so legacy "clear to fall back" is no longer exposed in the UI,
--- but the clear path is kept here for safety / potential future use.
lib.callback.register('pickle_dealerships:setDeliveryDepotSpawn', function(source, payload)
    if not IsPlayerAdmin(source) then return false, 'Admin only.' end
    if not payload or not payload.id then return false, 'Invalid payload.' end
    local ok
    if payload.clear then
        ok = SetDeliveryDepotSpawn(payload.id)
    else
        local c = payload.coords
        if not c or not c.x or not c.y or not c.z then return false, 'Missing coords.' end
        ok = SetDeliveryDepotSpawn(payload.id, tonumber(c.x), tonumber(c.y), tonumber(c.z), tonumber(c.w) or 0.0)
    end
    if ok then TriggerClientEvent('pickle_dealerships:depotsChanged', -1) end
    return ok
end)

-- ─── Claim + Start Mission ───────────────────────────────────────────────────

lib.callback.register('pickle_dealerships:acceptDelivery', function(source, orderIdOrIds, depotId)
    local identifier = GetIdentifier(source)
    if not identifier then return false, 'Unable to identify player.' end
    if activeDeliveries[source] then return false, _L('delivery_already_active') end

    -- Normalize argument: UI sends an array of orderIds (the pre-grouped bundle), legacy callers send a single id.
    local requestedIds
    if type(orderIdOrIds) == 'table' then
        requestedIds = {}
        for _, v in ipairs(orderIdOrIds) do requestedIds[#requestedIds + 1] = tonumber(v) end
    else
        requestedIds = { tonumber(orderIdOrIds) }
    end
    if #requestedIds == 0 then return false, 'No order specified.' end
    local orderId = requestedIds[1]

    -- 1. Atomic claim of the primary (first) order — always the one that must succeed for the mission to start.
    local claimed = MySQL.update.await(
        "UPDATE pickle_dealership_orders SET claimed_by = ?, claimed_at = NOW() WHERE id = ? AND delivery_mode = 'local' AND claimed_by IS NULL",
        { identifier, orderId }
    )
    if not claimed or claimed == 0 then
        return false, _L('delivery_claimed_by_another')
    end

    local primaryOrder = MySQL.single.await('SELECT * FROM pickle_dealership_orders WHERE id = ?', { orderId })
    if not primaryOrder then return false, 'Order not found.' end

    local dealership = GetDealership(primaryOrder.dealership_id)
        or MySQL.single.await('SELECT * FROM pickle_dealerships WHERE id = ?', { primaryOrder.dealership_id })
    if not dealership then
        MySQL.update.await('UPDATE pickle_dealership_orders SET claimed_by = NULL, claimed_at = NULL WHERE id = ?', { orderId })
        return false, 'Dealership not found.'
    end

    -- Depot resolution: if the driver started the mission at a specific depot (talked to that depot's
    -- ped), use that depot. Fall back to the nearest depot to the destination dealership when the UI
    -- didn't supply one (legacy callers / admin tools).
    local dealerCoords = GetDealershipCoords(dealership)
    local route, routeId
    if depotId then
        local cache = DeliveryDepotCache and DeliveryDepotCache[tonumber(depotId)] or nil
        if cache and cache.pickupCoords then
            route, routeId = cache, cache.id
        end
    end
    if not route then
        route, routeId = PickNearestDepot(dealerCoords)
    end
    if not route then
        MySQL.update.await('UPDATE pickle_dealership_orders SET claimed_by = NULL, claimed_at = NULL WHERE id = ?', { orderId })
        return false, 'No delivery depots configured.'
    end

    -- 2. Resolve primary class + bucket and determine remaining trailer capacity (total + medium axes).
    local primaryCatalog = MySQL.single.await('SELECT class FROM pickle_wholesale_catalog WHERE model = ?', { primaryOrder.vehicle_model })
    local primaryClass = (primaryCatalog and primaryCatalog.class) or 'sedan'
    local primaryBucket = BundleBucketForClass(primaryClass)
    local caps = CAP_BY_SIZE[primaryBucket] or { total = 4, medium = 4 }
    local primaryIsMedium = IsMediumClass(primaryClass)
    local totalLeft = math.max(0, caps.total - primaryOrder.quantity)
    local mediumLeft = math.max(0, caps.medium - (primaryIsMedium and primaryOrder.quantity or 0))

    -- 3. Look for bundle-compatible siblings from the same dealership.
    -- Compatibility: same delivery_mode='local', unclaimed, and whose catalog class maps to the same bucket.
    -- Greedy pack smallest-first so we bundle as many separate orders as possible.
    local bundledIds = { primaryOrder.id }
    local bundle = {
        {
            id = primaryOrder.id, model = primaryOrder.vehicle_model, label = primaryOrder.vehicle_label,
            wholesale = primaryOrder.wholesale_cost, retail = primaryOrder.retail_price,
            quantity = primaryOrder.quantity, fee = primaryOrder.delivery_fee, class = primaryClass,
        },
    }
    local totalFee = primaryOrder.delivery_fee or 0

    if (totalLeft + mediumLeft) > 0 then
        -- If the UI pre-grouped the bundle, prefer claiming exactly those IDs (minus primary, already claimed).
        -- Otherwise fall back to server-side greedy packing from the same dealership + bucket.
        local siblingQuery, siblingParams
        if #requestedIds > 1 then
            local uiIds = {}
            for i = 2, #requestedIds do uiIds[#uiIds + 1] = requestedIds[i] end
            local placeholders = {}
            for _ = 1, #uiIds do placeholders[#placeholders + 1] = '?' end
            siblingQuery = ([[
                SELECT o.id, o.vehicle_model, o.vehicle_label, o.wholesale_cost, o.retail_price,
                       o.quantity, o.delivery_fee, COALESCE(c.class, 'sedan') AS class
                  FROM pickle_dealership_orders o
                  LEFT JOIN pickle_wholesale_catalog c ON c.model = o.vehicle_model
                 WHERE o.dealership_id = ?
                   AND o.delivery_mode = 'local'
                   AND o.claimed_by IS NULL
                   AND o.id IN (%s)
            ]]):format(table.concat(placeholders, ','))
            siblingParams = { primaryOrder.dealership_id }
            for _, id in ipairs(uiIds) do siblingParams[#siblingParams + 1] = id end
        else
            siblingQuery = [[
                SELECT o.id, o.vehicle_model, o.vehicle_label, o.wholesale_cost, o.retail_price,
                       o.quantity, o.delivery_fee, COALESCE(c.class, 'sedan') AS class
                  FROM pickle_dealership_orders o
                  LEFT JOIN pickle_wholesale_catalog c ON c.model = o.vehicle_model
                 WHERE o.dealership_id = ?
                   AND o.delivery_mode = 'local'
                   AND o.claimed_by IS NULL
                   AND o.id <> ?
                 ORDER BY o.quantity ASC, o.ordered_at ASC
            ]]
            siblingParams = { primaryOrder.dealership_id, primaryOrder.id }
        end
        local siblings = MySQL.query.await(siblingQuery, siblingParams) or {}

        local siblingIdsToClaim = {}
        for _, s in ipairs(siblings) do
            if BundleBucketForClass(s.class) == primaryBucket then
                local sIsMedium = IsMediumClass(s.class)
                local fits = s.quantity <= totalLeft and (not sIsMedium or s.quantity <= mediumLeft)
                if fits then
                    siblingIdsToClaim[#siblingIdsToClaim + 1] = s
                    totalLeft = totalLeft - s.quantity
                    if sIsMedium then mediumLeft = mediumLeft - s.quantity end
                    if totalLeft <= 0 then break end
                end
            end
        end

        -- Atomic claim of the picked siblings. Any that got sniped by a concurrent driver just don't get bundled.
        if #siblingIdsToClaim > 0 then
            local placeholders, params = {}, { identifier }
            for _, s in ipairs(siblingIdsToClaim) do
                placeholders[#placeholders + 1] = '?'
                params[#params + 1] = s.id
            end
            MySQL.update.await(
                ("UPDATE pickle_dealership_orders SET claimed_by = ?, claimed_at = NOW() WHERE id IN (%s) AND delivery_mode = 'local' AND claimed_by IS NULL"):format(table.concat(placeholders, ',')),
                params
            )
            -- Re-read to see which actually got claimed by us (race-safe confirmation)
            local confirmed = MySQL.query.await(
                ("SELECT id FROM pickle_dealership_orders WHERE id IN (%s) AND claimed_by = ?"):format(table.concat(placeholders, ',')),
                (function() local p = { table.unpack(params, 2) }; p[#p + 1] = identifier; return p end)()
            ) or {}
            local claimedSet = {}
            for _, row in ipairs(confirmed) do claimedSet[row.id] = true end
            for _, s in ipairs(siblingIdsToClaim) do
                if claimedSet[s.id] then
                    bundledIds[#bundledIds + 1] = s.id
                    bundle[#bundle + 1] = {
                        id = s.id, model = s.vehicle_model, label = s.vehicle_label,
                        wholesale = s.wholesale_cost, retail = s.retail_price,
                        quantity = s.quantity, fee = s.delivery_fee, class = s.class,
                    }
                    totalFee = totalFee + (s.delivery_fee or 0)
                end
            end
        end
    end

    -- 4. Stamp route_id on every claimed order so orphan-recovery still works cleanly.
    do
        local placeholders, params = {}, { routeId }
        for _, id in ipairs(bundledIds) do
            placeholders[#placeholders + 1] = '?'
            params[#params + 1] = id
        end
        MySQL.update.await(
            ("UPDATE pickle_dealership_orders SET route_id = ? WHERE id IN (%s)"):format(table.concat(placeholders, ',')),
            params
        )
    end

    -- 5. Compute the trailer plan over the full bundle and spin up the delivery record.
    local trailerPlan = ComputeTrailerPlan(bundle)
    local totalQty = 0
    for _, v in ipairs(bundle) do totalQty = totalQty + v.quantity end

    local deliveryId = MySQL.insert.await(
        "INSERT INTO pickle_dealership_deliveries (dealership_id, stock_ids, pickup_location, route, status, assigned_to, started_at) VALUES (?, ?, ?, ?, 'in_progress', ?, NOW())",
        { primaryOrder.dealership_id, json.encode(bundledIds), routeId, routeId, identifier }
    )

    activeDeliveries[source] = {
        deliveryId = deliveryId,
        orderIds = bundledIds,
        orders = bundle, -- per-line detail for stocking + refund
        dealershipId = primaryOrder.dealership_id,
        dealershipLocation = dealership.location,
        identifier = identifier,
        started=os.time(),
        trailerModel=trailerPlan.trailerModel,
        route = route,
        routeId = routeId,
        primaryLabel = primaryOrder.vehicle_label or primaryOrder.vehicle_model,
        totalQty = totalQty,
        fee = totalFee,
        catalogTier = ResolveCatalogTier(primaryOrder.vehicle_model),
    }

    -- 6. Client payload includes per-vehicle breakdown (for overlay label) and the slot-level model assignment.
    local clientVehicles = {}
    for _, v in ipairs(bundle) do
        clientVehicles[#clientVehicles + 1] = { model = v.model, label = v.label, quantity = v.quantity, class = v.class }
    end

    TriggerClientEvent('pickle_dealerships:startDeliveryMission', source, {
        deliveryId = deliveryId,
        orderIds = bundledIds,
        locationKey = dealership.location,
        -- The client spawns the truck + trailer + cargo here. `spawnCoords` is a separately-configured
        -- yard location when the depot sets one; otherwise we fall back to the ped coords so depots
        -- that never set a spawn still work.
        pickupCoords = route and (route.spawnCoords or route.pickupCoords) or nil,
        route = route,
        vehicles = clientVehicles,
        dealershipCoords = dealerCoords,
        -- The drop-off point is the dealership's dedicated trailer-delivery zone. Required for
        -- local deliveries (queue filter + order-placement guard enforce it upstream) — the client
        -- renders the rectangle + ghost tr2 here and checks trailer unhitch against this coord.
        dropoffCoords = GetDealershipDropoff(dealership),
        trailerPlan = trailerPlan,
        baseFee = totalFee,
        streakMultiplier = GetDriverStreakMultiplier(identifier),
        damagePenalty = (Config.Delivery and Config.Delivery.damagePenalty) or { enabled = false, fullPayoutAboveCondition = 90, zeroPayoutBelowCondition = 25 },
    })

    TriggerClientEvent('pickle_dealerships:deliveryQueueChanged', -1)
    -- Client emits delivery_vehicles_loaded on mission start; no server toast needed.
    return true, deliveryId
end)

-- ─── Completion ──────────────────────────────────────────────────────────────

RegisterNetEvent('pickle_dealerships:bindDeliveryEntities',function(id,truckNet,trailerNet)
    local src=source; local delivery=activeDeliveries[src]
    if not delivery or delivery.deliveryId~=id or delivery.truck or delivery.identifier~=GetIdentifier(src) then return end
    if not DealerInt(truckNet,1,2147483647) or not DealerInt(trailerNet,1,2147483647) then return end
    local truck=NetworkGetEntityFromNetworkId(truckNet); local trailer=NetworkGetEntityFromNetworkId(trailerNet)
    local pickup=delivery.route and (delivery.route.spawnCoords or delivery.route.pickupCoords or delivery.route.pickup)
    if not pickup or truck==0 or trailer==0 or NetworkGetEntityOwner(truck)~=src or NetworkGetEntityOwner(trailer)~=src
        or GetEntityModel(truck)~=joaat(Config.Trailer.models.truck or 'phantom')
        or GetEntityModel(trailer)~=joaat(delivery.trailerModel or Config.Trailer.models.enclosed)
        or #(GetEntityCoords(truck)-vector3(pickup.x,pickup.y,pickup.z))>30 then return end
    delivery.truck=truck; delivery.trailer=trailer
    CreateThread(function()
        local last=GetEntityCoords(truck)
        while activeDeliveries[src]==delivery and not delivery.completing do
            Wait(1000)
            if not DoesEntityExist(truck) or not DoesEntityExist(trailer) then delivery.invalid=true; return end
            local coords=GetEntityCoords(truck)
            if #(coords-last)>250 then delivery.invalid=true; return end
            last=coords
        end
    end)
end)

lib.callback.register('pickle_dealerships:completeDelivery', function(source, deliveryId, vehicleCondition)
    local delivery = activeDeliveries[source]
    if not delivery or delivery.deliveryId ~= deliveryId then
        return false, 'No matching active delivery found.'
    end

    if delivery.invalid or not delivery.truck or not delivery.trailer or not DoesEntityExist(delivery.truck) or not DoesEntityExist(delivery.trailer) then return false,'Verified mission rig required' end
    local ok,body=pcall(GetVehicleBodyHealth,delivery.truck)
    local condition=ok and math.max(0,math.min(100,body/10)) or 0
    local payout, streakMult, damageMult = ComputeFinalPayout(delivery.fee or 0, delivery.identifier, condition)

    if delivery.identifier~=GetIdentifier(source) or delivery.completing or os.time()-(delivery.started or 0)<30 then return false,'Invalid delivery session' end
    local dealer=GetDealership(delivery.dealershipId)
    local drop=GetDealershipDropoff(dealer)
    local ped=GetPlayerPed(source)
    if not drop or ped==0 or #(GetEntityCoords(ped)-vector3(drop.x,drop.y,drop.z))>20 then return false,'Not at the delivery point' end
    if #(GetEntityCoords(delivery.trailer)-vector3(drop.x,drop.y,drop.z))>20 or #(GetEntityCoords(delivery.truck)-vector3(drop.x,drop.y,drop.z))>40 then return false,'The verified rig must reach the drop-off' end
    delivery.completing=true
    if not DealerCommitOrders(delivery.orderIds,delivery.identifier) then delivery.completing=nil; return false,'Orders already processed or unavailable' end

    MySQL.update.await(
        "UPDATE pickle_dealership_deliveries SET status = 'completed', completed_at = NOW() WHERE id = ?",
        { deliveryId }
    )

    -- Local delivery is a server-sponsored payout — the dealership contributes $0
    -- (the incentive for routing orders through real drivers). Paying into the
    -- player's bank directly acts as a server faucet; no balance ledger to touch.
    if payout > 0 then
        AddMoney(source, payout, 'bank')
    end

    -- XP + streak + lifetime earnings
    local xpAward = ComputeXPAward(delivery, false)
    local xpResult = AddDriverXP(delivery.identifier, xpAward)
    RecordDriverDelivery(delivery.identifier, payout, true)

    -- Dealership reputation bump (synergy with NPC customer module)
    local repBonus = (Config.Delivery and Config.Delivery.dealershipRepBonus) or 0
    if repBonus > 0 then
        MySQL.update.await('UPDATE pickle_dealerships SET reputation = reputation + ? WHERE id = ?', { repBonus, delivery.dealershipId })
        local cached = GetDealership(delivery.dealershipId)
        if cached then UpdateDealershipCache(delivery.dealershipId, { reputation = (cached.reputation or 0) + repBonus }) end
    end

    local bundleDesc = (delivery.orders and #delivery.orders > 1)
        and ('%s +%d more'):format(delivery.primaryLabel or '?', #delivery.orders - 1)
        or (delivery.primaryLabel or '?')
    AddLedgerEntry(
        delivery.dealershipId,
        'delivery',
        0,
        ('Local delivery completed: %s x%d (driver paid $%d)'):format(bundleDesc, delivery.totalQty or 1, payout),
        delivery.identifier
    )

    activeDeliveries[source] = nil
    TriggerClientEvent('pickle_dealerships:refreshDisplay', -1, delivery.dealershipLocation)
    TriggerClientEvent('pickle_dealerships:deliveryQueueChanged', -1)

    if xpResult and xpResult.leveledUp then
        TriggerClientEvent('pickle_dealerships:driverLevelUp', source, xpResult.level)
    end

    -- Client shows delivery_complete_client + payout toast; skip the dupe.
    return true, {
        payout = payout,
        streakMultiplier = streakMult,
        damageMultiplier = damageMult,
        xpGained = xpAward,
        levelUp = xpResult and xpResult.leveledUp or false,
        newLevel = xpResult and xpResult.level or nil,
    }
end)

-- ─── Failure ─────────────────────────────────────────────────────────────────

local function AbandonDelivery(source, reason)
    local delivery = activeDeliveries[source]
    if not delivery then return false end

    -- Unclaim every bundled order in a single query so compatible siblings all return to the queue.
    if delivery.orderIds and #delivery.orderIds > 0 then
        local placeholders, params = {}, {}
        for _, id in ipairs(delivery.orderIds) do
            placeholders[#placeholders + 1] = '?'
            params[#params + 1] = id
        end
        params[#params + 1] = delivery.identifier
        MySQL.update.await(
            ("UPDATE pickle_dealership_orders SET claimed_by = NULL, claimed_at = NULL, route_id = NULL WHERE id IN (%s) AND claimed_by = ?"):format(table.concat(placeholders, ',')),
            params
        )
    end

    -- Partial wholesale refund summed across every bundled line.
    local cfg = Config.Delivery or {}
    local refundRate = cfg.failRefundRate or 0.5
    local refund = 0
    for _, line in ipairs(delivery.orders or {}) do
        refund = refund + math.floor((line.wholesale or 0) * (line.quantity or 1) * refundRate)
    end

    MySQL.update.await(
        "UPDATE pickle_dealership_deliveries SET status = 'failed', completed_at = NOW() WHERE id = ?",
        { delivery.deliveryId }
    )

    -- Driver penalty
    local xpPenalty = ComputeXPAward(delivery, true)
    AddDriverXP(delivery.identifier, xpPenalty)
    RecordDriverDelivery(delivery.identifier, 0, false)

    AddLedgerEntry(
        delivery.dealershipId,
        'delivery',
        0,
        ('Local delivery failed (%s): %d order(s) returned to queue'):format(reason or 'abandoned', #(delivery.orderIds or {})),
        delivery.identifier
    )

    activeDeliveries[source] = nil
    TriggerClientEvent('pickle_dealerships:deliveryQueueChanged', -1)
    return true, refund
end

lib.callback.register('pickle_dealerships:failDelivery', function(source, deliveryId)
    local delivery = activeDeliveries[source]
    if not delivery or delivery.deliveryId ~= deliveryId then
        return false, 'No matching active delivery found.'
    end
    local ok = AbandonDelivery(source, 'player_cancelled')
    -- Client shows delivery_cancelled / delivery_failed_died toast; skip the dupe.
    return ok
end)

AddEventHandler('playerDropped', function()
    local src = source
    if activeDeliveries[src] then
        AbandonDelivery(src, 'disconnected')
    end
end)

-- ─── Orphan recovery on resource (re)start ───────────────────────────────────
-- `activeDeliveries` is in-memory only. If the server restarts (or this resource is
-- restarted) while a driver is mid-mission, the DB row still reads `claimed_by = <them>`
-- but there's no live mission tracking it — the order becomes frozen and no-one else
-- can grab it. On boot we force-unclaim every local order and mark any still-pending
-- `pickle_dealership_deliveries` rows as failed so the queue self-heals.
AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    CreateThread(function()
        local unclaimed = MySQL.update.await([[
            UPDATE pickle_dealership_orders
               SET claimed_by = NULL, claimed_at = NULL, route_id = NULL
             WHERE delivery_mode = 'local' AND claimed_by IS NOT NULL
        ]])
        local failed = MySQL.update.await([[
            UPDATE pickle_dealership_deliveries
               SET status = 'failed', completed_at = NOW()
             WHERE status = 'in_progress'
        ]])
        if (unclaimed and unclaimed > 0) or (failed and failed > 0) then
            print(('[pickle_dealerships] Recovered %d orphaned order(s) and %d stale delivery record(s) on boot.'):format(unclaimed or 0, failed or 0))
            TriggerClientEvent('pickle_dealerships:deliveryQueueChanged', -1)
        end
    end)
end)

-- ─── Order-expiry sweep ──────────────────────────────────────────────────────
-- Unclaimed local orders sitting > 24h are refunded (wholesale only) back to the dealership
-- so long-stale premium offers nobody wants don't permanently clog the queue or capacity.
CreateThread(function()
    while true do
        Wait(60 * 60 * 1000) -- hourly
        local stale = MySQL.query.await([[
            SELECT id, dealership_id, wholesale_cost, quantity, vehicle_model
            FROM pickle_dealership_orders
            WHERE delivery_mode = 'local' AND claimed_by IS NULL
              AND ordered_at < DATE_SUB(NOW(), INTERVAL 24 HOUR)
        ]]) or {}
        for _, o in ipairs(stale) do
            local removed=MySQL.update.await('DELETE FROM pickle_dealership_orders WHERE id=? AND claimed_by IS NULL',{o.id})
            local refund = removed==1 and math.floor((o.wholesale_cost or 0) * (o.quantity or 1) * 0.5) or 0
            if refund > 0 then
                MySQL.update.await('UPDATE pickle_dealerships SET balance = balance + ? WHERE id = ?', { refund, o.dealership_id })
                AddLedgerEntry(o.dealership_id, 'refund', refund, ('Stale local delivery order expired: %s'):format(o.vehicle_model), nil)
            end

        end
        if #stale > 0 then
            TriggerClientEvent('pickle_dealerships:deliveryQueueChanged', -1)
        end
    end
end)
