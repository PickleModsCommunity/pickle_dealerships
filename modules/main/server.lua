-- Uses the global DealershipCache from core/server.lua (keyed by id)
-- Helper to find a dealership by location key
local function GetCachedByLocation(locationKey)
    for _, d in pairs(DealershipCache) do
        if d.location == locationKey then
            return d
        end
    end
    return nil
end

--- Builds a resolved config for a dealership from its DB metadata
---@param cached table
---@return table|nil
local function ResolveDealershipConfig(cached)
    if not cached then return nil end

    local meta = cached.metadata
    if type(meta) == "string" then
        meta = json.decode(meta) or {}
    end
    if type(meta) ~= "table" then meta = {} end

    local defaults = Config.DealershipDefaults or {}

    if not meta.coords then return nil end

    local resolved = {
        label = cached.name or "Dealership",
        mode = cached.mode or "player-owned",
        type = cached.type or "car",
        purchasePrice = meta.purchasePrice or 0,
        selfService = meta.selfService or defaults.selfService or false,
        deliveryMode = meta.deliveryMode or defaults.deliveryMode or "timed",
        colorMode = meta.colorMode or defaults.colorMode or "rgb_wheel",
        acceptedCurrency = meta.acceptedCurrency or defaults.acceptedCurrency or "both",
        blip = meta.blip or defaults.blip or { sprite = 326, color = 3, scale = 0.8 },
    }

    resolved.coords = vector3(meta.coords.x, meta.coords.y, meta.coords.z)
    resolved.heading = meta.coords.w or 0.0
    resolved.zones = {
        { coords = vector3(meta.coords.x, meta.coords.y, meta.coords.z), radius = meta.zoneRadius or defaults.zoneRadius or 40.0 },
    }

    if meta.spawnPoint then
        resolved.spawnPoint = vector4(meta.spawnPoint.x, meta.spawnPoint.y, meta.spawnPoint.z, meta.spawnPoint.w or 0.0)
    end

    if meta.interactionPoints then
        resolved.interactionPoints = {}
        for pointType, point in pairs(meta.interactionPoints) do
            resolved.interactionPoints[pointType] = vector4(point.x, point.y, point.z, point.w or 0.0)
        end
    end

    if meta.displaySpots then
        resolved.displaySpots = {}
        for _, spot in ipairs(meta.displaySpots) do
            resolved.displaySpots[#resolved.displaySpots + 1] = {
                x = spot.x,
                y = spot.y,
                z = spot.z,
                w = spot.w or 0.0,
                id = spot.id,
            }
        end
    end

    if meta.npcSpawnPoints then
        resolved.npcSpawnPoints = {}
        for _, point in ipairs(meta.npcSpawnPoints) do
            resolved.npcSpawnPoints[#resolved.npcSpawnPoints + 1] = vector4(point.x, point.y, point.z, point.w or 0.0)
        end
    end

    return resolved
end

--- Returns summary data for all dealership locations
---@param source number
lib.callback.register('pickle_dealerships:getDealerships', function(source)
    local dealerships = {}

    for _, cached in pairs(DealershipCache) do
        local resolved = ResolveDealershipConfig(cached)
        if resolved then
            local stockCount = 0
            local result = MySQL.scalar.await(
                'SELECT COALESCE(SUM(quantity), 0) FROM pickle_dealership_stock WHERE dealership_id = ? AND sold_at IS NULL',
                { cached.id }
            )
            stockCount = tonumber(result or 0)

            dealerships[cached.location] = {
                location = cached.location,
                name = cached.name,
                mode = cached.mode or "player-owned",
                type = cached.type or "car",
                owner_identifier = cached.owner_identifier,
                purchasePrice = resolved.purchasePrice,
                tier = cached.tier or 1,
                stockCount = stockCount,
                owned = cached.owner_identifier ~= nil,
                resolvedConfig = resolved,
            }
        end
    end

    return dealerships
end)

--- Access gate: returns true if the caller may browse/purchase at this location.
--- Used by the client openers (OpenKiosk / OpenSalesTablet) to short-circuit
--- with a notification before even fetching data.
lib.callback.register('pickle_dealerships:canAccessDealership', function(source, locationKey)
    local cached = GetCachedByLocation(locationKey)
    if not cached then return true end
    return PlayerCanAccessDealership(source, cached)
end)

--- Returns full dealership data for a specific location
---@param source number
---@param locationKey string
lib.callback.register('pickle_dealerships:getDealershipData', function(source, locationKey)
    local cached = GetCachedByLocation(locationKey)
    local resolved = ResolveDealershipConfig(cached)
    if not resolved then return nil end

    -- Stock and employees are intentionally NOT loaded here. Earlier versions
    -- shipped every stock row (potentially thousands) on every zone entry, but
    -- no caller of getDealershipData consumes .stock or .employees — the
    -- management UI, sales UI, and display spawner each call their own
    -- targeted endpoints (`getStock` with displayOnly, `getEmployees`, etc.).

    -- Surface the disableSelfPurchase toggle so the client can hide customer
    -- purchase buttons before the request even goes server-side.
    local meta = cached and cached.metadata or nil
    if type(meta) == "string" then meta = json.decode(meta) or {} end
    if type(meta) ~= "table" then meta = {} end

    return {
        id = cached and cached.id or nil,
        location = locationKey,
        name = cached and cached.name or resolved.label,
        mode = resolved.mode,
        type = resolved.type or 'car',
        owner_identifier = cached and cached.owner_identifier or nil,
        balance = cached and cached.balance or 0,
        tier = cached and cached.tier or 1,
        purchasePrice = resolved.purchasePrice or 0,
        coords = resolved.coords,
        displaySpots = resolved.displaySpots or {},
        deliveryMode = resolved.deliveryMode or 'timed',
        selfService = resolved.selfService or false,
        disableSelfPurchase = meta.disableSelfPurchase == true,
        -- "How many models the store could ever carry" (all tiers unlocked) —
        -- denominator on the dashboard stock bar.
        stockCapacity = GetDealershipCatalogMax({ type = resolved.type or 'car' }),
    }
end)

--- Player purchases an unclaimed player-owned dealership
---@param source number
---@param locationKey string
lib.callback.register('pickle_dealerships:purchaseDealership', function(source, locationKey)
    return DealerTransaction(source, function()
        local cached = GetCachedByLocation(locationKey)
        local resolved = ResolveDealershipConfig(cached)
        if not resolved then
            return { success = false, error = _L("invalid_dealership_location") }
        end

        if resolved.mode ~= 'player-owned' then
            return { success = false, error = _L("dealership_cannot_be_purchased") }
        end

        if cached and cached.owner_identifier then
            return { success = false, error = _L("dealership_already_owned") }
        end

        local price = resolved.purchasePrice or 0
        local identifier = GetIdentifier(source)
        if not identifier then
            return { success = false, error = _L("unable_to_identify_player") }
        end

        local money = GetMoney(source, 'bank')
        if money < price then
            return { success = false, error = _L("not_enough_money") }
        end

        local success = RemoveMoney(source, price, 'bank')
        if not success then
            return { success = false, error = _L("failed_deduct_payment") }
        end

        MySQL.update.await(
            'UPDATE pickle_dealerships SET owner_identifier = ?, balance = 0 WHERE id = ?',
            { identifier, cached.id }
        )
        cached.owner_identifier = identifier
        cached.balance = 0

        ShowNotification(source, _L("dealership_purchased_price", GetCurrencyString(price)))
        return { success = true }
    end)
end)

--- Owner sells their dealership back
---@param source number
---@param locationKey string
lib.callback.register('pickle_dealerships:sellDealership', function(source, locationKey)
    return DealerTransaction(source, function()
        local cached = GetCachedByLocation(locationKey)
        local resolved = ResolveDealershipConfig(cached)
        if not resolved then
            return { success = false, error = _L("invalid_dealership_location") }
        end

        if not cached or not cached.owner_identifier then
            return { success = false, error = _L("dealership_not_owned") }
        end

        local identifier = GetIdentifier(source)
        if identifier ~= cached.owner_identifier then
            return { success = false, error = _L("you_do_not_own_dealership") }
        end

        local sellbackRate = Config.SellbackRate or 0.5
        local refund = math.floor((resolved.purchasePrice or 0) * sellbackRate)

        MySQL.update.await('DELETE FROM pickle_dealership_employees WHERE dealership_id = ?', { cached.id })
        MySQL.update.await('DELETE FROM pickle_dealership_stock WHERE dealership_id = ? AND sold_at IS NULL', { cached.id })
        MySQL.update.await('UPDATE pickle_dealerships SET owner_identifier = NULL, balance = 0 WHERE id = ?', { cached.id })

        cached.owner_identifier = nil
        cached.balance = 0

        AddMoney(source, refund, 'bank')
        ShowNotification(source, _L("dealership_sold_refund", GetCurrencyString(refund)))
        TriggerClientEvent('pickle_dealerships:refreshDisplay', -1, locationKey)

        return { success = true, refund = refund }
    end)
end)

--- Owner renames their dealership
---@param source number
---@param locationKey string
---@param newName string
lib.callback.register('pickle_dealerships:renameDealership', function(source, locationKey, newName)
    local cached = GetCachedByLocation(locationKey)
    if not cached or not cached.owner_identifier then
        return { success = false, error = _L("dealership_not_owned") }
    end

    local identifier = GetIdentifier(source)
    if identifier ~= cached.owner_identifier then
        return { success = false, error = _L("you_do_not_own_dealership") }
    end

    if not newName or #newName < 1 or #newName > 50 then
        return { success = false, error = _L("invalid_name_length") }
    end

    MySQL.update.await('UPDATE pickle_dealerships SET name = ? WHERE id = ?', { newName, cached.id })
    cached.name = newName
    ShowNotification(source, _L("dealership_renamed_to", newName))
    return { success = true }
end)

--- Returns the player's role at a specific dealership
--- Uses framework job if dealership has a job set, otherwise falls back to owner check
---@param source number
---@param locationKey string
lib.callback.register('pickle_dealerships:getPlayerRole', function(source, locationKey)
    -- Delegate to the single authoritative resolver in core/server.lua so the
    -- role the client uses to OPEN the menu is exactly the role the server gates
    -- enforce INSIDE it. (Previously this resolved from job grades while the
    -- server gates resolved from the employee roster — they disagreed, so the
    -- menu would open for staff the server then denied at every action.)
    if IsPlayerAdmin(source) then return 'admin' end

    local cached = GetCachedByLocation(locationKey)
    if not cached then return nil end

    return GetPlayerDealershipRole(source, cached.id)
end)
