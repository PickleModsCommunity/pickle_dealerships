--- NPC-operated dealerships don't use the order/delivery flow. At creation (and
--- on mode flips back to 'managed') we seed one stock row per wholesale catalog
--- entry that lives in any of the dealership's assigned groups, with a very
--- large quantity so it reads as effectively infinite. Owners/admins can then
--- tune retail prices per row on the stock tab.
local function seedManagedDealershipStock(dealershipId, vehicleType)
    local types = {}
    if vehicleType == 'mixed' or not vehicleType or vehicleType == '' then
        types = { 'car', 'boat', 'air' }
    else
        types = { vehicleType }
    end

    if #types == 0 then return 0 end

    local typeMarks = string.rep('?,', #types):sub(1, -2)
    -- Vehicle is eligible if it shares at least one group with the dealership.
    -- An EXISTS join keeps the query single-pass even with many groups.
    local sql = ([[
        INSERT INTO pickle_dealership_stock
            (dealership_id, vehicle_model, vehicle_label, wholesale_cost, retail_price, quantity, ordered_at, delivered_at, acquired_from)
        SELECT ?, wc.model, wc.label, wc.wholesale, ROUND(wc.wholesale * 1.3), 999999, NOW(), NOW(), 'npc_seed'
        FROM pickle_wholesale_catalog wc
        WHERE wc.vehicle_type IN (%s)
          AND EXISTS (
              SELECT 1
              FROM pickle_catalog_vehicle_groups vg
              JOIN pickle_dealership_groups dg ON dg.group_id = vg.group_id
              WHERE vg.catalog_id = wc.id AND dg.dealership_id = ?
          )
          AND NOT EXISTS (
              SELECT 1 FROM pickle_dealership_stock ds
              WHERE ds.dealership_id = ? AND ds.vehicle_model = wc.model
                AND ds.acquired_from = 'npc_seed' AND ds.sold_at IS NULL
          )
    ]]):format(typeMarks)

    local params = { dealershipId }
    for _, tval in ipairs(types) do params[#params + 1] = tval end
    params[#params + 1] = dealershipId
    params[#params + 1] = dealershipId

    return MySQL.update.await(sql, params) or 0
end

--- Wipes the dealership's group assignments and replaces them with the given
--- list. Used by adminCreateDealership and adminSetDealershipGroups.
local function setDealershipGroups(dealershipId, groupIds)
    MySQL.update.await(
        "DELETE FROM pickle_dealership_groups WHERE dealership_id = ?",
        { dealershipId }
    )
    if type(groupIds) ~= "table" then return end
    for _, gid in ipairs(groupIds) do
        local n = tonumber(gid)
        if n then
            MySQL.insert.await(
                "INSERT IGNORE INTO pickle_dealership_groups (dealership_id, group_id) VALUES (?, ?)",
                { dealershipId, n }
            )
        end
    end
end

--- Returns { id } for every default-seeded group. Used as a sane fallback when
--- a managed dealership is created with no explicit groupIds — otherwise it
--- would have an empty catalog and zero NPC stock.
local function getDefaultGroupIds()
    local rows = MySQL.query.await(
        "SELECT id FROM pickle_catalog_groups WHERE is_default = 1 ORDER BY id ASC"
    ) or {}
    local ids = {}
    for _, r in ipairs(rows) do ids[#ids + 1] = r.id end
    return ids
end

--- Get all dealerships (admin only)
lib.callback.register("pickle_dealerships:adminGetAllDealerships", function(source)
    if not IsPlayerAdmin(source) then
        return nil
    end

    local dealerships = MySQL.query.await("SELECT * FROM pickle_dealerships ORDER BY id ASC")
    if dealerships and #dealerships > 0 then
        -- Bulk-load the group assignments in a single round-trip and fan them
        -- out by dealership id so the admin list shows the correct group count
        -- immediately — no per-row follow-up fetch needed when the user clicks
        -- into Settings.
        local ids = {}
        for _, d in ipairs(dealerships) do ids[#ids + 1] = d.id end
        local marks = string.rep('?,', #ids):sub(1, -2)
        local junction = MySQL.query.await(
            ("SELECT dealership_id, group_id FROM pickle_dealership_groups WHERE dealership_id IN (%s)"):format(marks),
            ids
        ) or {}
        local byDealership = {}
        for _, row in ipairs(junction) do
            byDealership[row.dealership_id] = byDealership[row.dealership_id] or {}
            byDealership[row.dealership_id][#byDealership[row.dealership_id] + 1] = row.group_id
        end
        for _, d in ipairs(dealerships) do
            d.groupIds = byDealership[d.id] or {}
            if d.owner_identifier then
                local ownerSource = GetSourceFromIdentifier(d.owner_identifier)
                if ownerSource then
                    d.owner_name = GetPlayerCharacterName(ownerSource) or GetPlayerName(ownerSource)
                else
                    d.owner_name = d.owner_identifier
                end
            end
        end
    end
    return dealerships or {}
end)

--- Get online players for admin dropdown
lib.callback.register("pickle_dealerships:adminGetOnlinePlayers", function(source)
    if not IsPlayerAdmin(source) then DenyAccess(source, "admin_no_permission") return {} end

    local players = {}
    for _, playerId in ipairs(GetPlayers()) do
        local src = tonumber(playerId)
        if src then
            local identifier = GetIdentifier(src)
            local name = GetPlayerCharacterName(src) or GetPlayerName(src)
            if identifier and name then
                players[#players + 1] = {
                    source = src,
                    name = name,
                    identifier = identifier,
                }
            end
        end
    end
    return players
end)

--- Force transfer dealership ownership
lib.callback.register("pickle_dealerships:adminTransferOwnership", function(source, data)
    if not IsPlayerAdmin(source) then
        return { success = false, message = _L("admin_no_permission") }
    end

    local dealershipId = data.dealershipId
    local newOwnerId = data.newOwnerId

    if not dealershipId or not newOwnerId then
        return { success = false, message = _L("admin_missing_owner_data") }
    end

    local dealership = GetDealership(dealershipId)
    if not dealership then
        return { success = false, message = _L("dealership_not_found") }
    end

    local previousOwner = dealership.owner_identifier or "none"
    MySQL.update.await("UPDATE pickle_dealerships SET owner_identifier = ? WHERE id = ?", { newOwnerId, dealershipId })
    UpdateDealershipCache(dealershipId, { owner_identifier = newOwnerId })

    local adminName = GetPlayerCharacterName(source) or GetPlayerName(source)
    AddLedgerEntry(dealershipId, "admin", 0, "Ownership transferred to " .. newOwnerId .. " by admin " .. adminName, GetIdentifier(source))

    debugPrint("Admin " .. adminName .. " transferred dealership #" .. dealershipId .. " to " .. newOwnerId)

    LogDiscord("admin", {
        title = "Ownership Transferred",
        actor = source,
        dealershipId = dealershipId,
        fields = {
            { name = "Dealership Name", value = dealership.name or "?", inline = true },
            { name = "Previous Owner", value = "`" .. tostring(previousOwner) .. "`", inline = true },
            { name = "New Owner", value = "`" .. tostring(newOwnerId) .. "`", inline = true },
        },
    })

    return { success = true, message = _L("admin_ownership_transferred_msg") }
end)

--- Set dealership balance
lib.callback.register("pickle_dealerships:adminSetBalance", function(source, data)
    if not IsPlayerAdmin(source) then
        return { success = false, message = _L("admin_no_permission") }
    end

    local dealershipId = data.dealershipId
    local amount = tonumber(data.amount)

    if not dealershipId or not amount then
        return { success = false, message = _L("admin_missing_amount") }
    end

    if amount < 0 then
        return { success = false, message = _L("admin_balance_negative") }
    end

    local dealership = GetDealership(dealershipId)
    if not dealership then
        return { success = false, message = _L("dealership_not_found") }
    end

    MySQL.update.await("UPDATE pickle_dealerships SET balance = ? WHERE id = ?", { amount, dealershipId })
    UpdateDealershipCache(dealershipId, { balance = amount })

    local adminName = GetPlayerCharacterName(source) or GetPlayerName(source)
    AddLedgerEntry(dealershipId, "admin", amount, "Balance set to " .. GetCurrencyString(amount) .. " by admin " .. adminName, GetIdentifier(source))

    LogDiscord("finances", {
        title = "Admin Balance Override",
        actor = source,
        dealershipId = dealershipId,
        fields = {
            { name = "Dealership", value = dealership.name or "?", inline = true },
            { name = "Previous Balance", value = GetCurrencyString(dealership.balance or 0), inline = true },
            { name = "New Balance", value = GetCurrencyString(amount), inline = true },
        },
    })

    return { success = true, newBalance = amount, message = _L("admin_balance_set_to", GetCurrencyString(amount)) }
end)

-- adminSetTier was removed when catalog access switched to many-to-many groups.
-- The pickle_dealerships.tier column is preserved for rollback safety but no
-- longer drives anything. To change which catalog vehicles a dealership sells,
-- use adminSetDealershipGroups instead.

--- Reset dealership (wipe owner, employees, stock, balance, group assignments)
lib.callback.register("pickle_dealerships:adminResetDealership", function(source, data)
    if not IsPlayerAdmin(source) then
        return { success = false, message = _L("admin_no_permission") }
    end

    local dealershipId = data.dealershipId
    if not dealershipId then
        return { success = false, message = _L("admin_missing_dealership_id") }
    end

    local dealership = GetDealership(dealershipId)
    if not dealership then
        return { success = false, message = _L("dealership_not_found") }
    end

    -- Wipe all related data. Tier column is left intact (legacy / unread) but
    -- group assignments are cleared so a fresh-after-reset dealership picks up
    -- whatever the admin assigns next.
    MySQL.update.await("UPDATE pickle_dealerships SET owner_identifier = NULL, balance = 0, reputation = 0 WHERE id = ?", { dealershipId })
    MySQL.update.await("DELETE FROM pickle_dealership_groups WHERE dealership_id = ?", { dealershipId })
    MySQL.update.await("DELETE FROM pickle_dealership_employees WHERE dealership_id = ?", { dealershipId })
    MySQL.update.await("DELETE FROM pickle_dealership_stock WHERE dealership_id = ?", { dealershipId })
    MySQL.update.await("DELETE FROM pickle_dealership_orders WHERE dealership_id = ?", { dealershipId })
    MySQL.update.await("DELETE FROM pickle_dealership_coupon_uses WHERE coupon_id IN (SELECT id FROM pickle_dealership_coupons WHERE dealership_id = ?)", { dealershipId })
    MySQL.update.await("DELETE FROM pickle_dealership_coupons WHERE dealership_id = ?", { dealershipId })

    UpdateDealershipCache(dealershipId, {
        owner_identifier   = nil,
        balance    = 0,
        reputation = 0,
    })

    local adminName = GetPlayerCharacterName(source) or GetPlayerName(source)
    AddLedgerEntry(dealershipId, "admin", 0, "Dealership reset by admin " .. adminName, GetIdentifier(source))

    debugPrint("Admin " .. adminName .. " reset dealership #" .. dealershipId)

    return { success = true, message = _L("admin_dealership_reset_msg") }
end)

--- Permanently delete a dealership and all related data (employees, stock, orders, coupons,
--- ledger, financing, deliveries, auctions + bids). Unrecoverable — confirmation is handled client-side.
lib.callback.register("pickle_dealerships:adminDeleteDealership", function(source, data)
    if not IsPlayerAdmin(source) then
        return { success = false, message = _L("admin_no_permission") }
    end

    local dealershipId = data.dealershipId
    if not dealershipId then
        return { success = false, message = _L("admin_missing_dealership_id") }
    end

    local dealership = GetDealership(dealershipId)
    if not dealership then
        return { success = false, message = _L("dealership_not_found") }
    end

    -- Auction bids reference auctions, not the dealership directly — wipe them first via subquery.
    MySQL.update.await("DELETE FROM pickle_dealership_auction_bids WHERE auction_id IN (SELECT id FROM pickle_dealership_auctions WHERE dealership_id = ?)", { dealershipId })
    MySQL.update.await("DELETE FROM pickle_dealership_auctions WHERE dealership_id = ?",   { dealershipId })
    MySQL.update.await("DELETE FROM pickle_dealership_deliveries WHERE dealership_id = ?", { dealershipId })
    MySQL.update.await("DELETE FROM pickle_dealership_financing WHERE dealership_id = ?",  { dealershipId })
    MySQL.update.await("DELETE FROM pickle_dealership_ledger WHERE dealership_id = ?",     { dealershipId })
    MySQL.update.await("DELETE FROM pickle_dealership_coupon_uses WHERE coupon_id IN (SELECT id FROM pickle_dealership_coupons WHERE dealership_id = ?)", { dealershipId })
    MySQL.update.await("DELETE FROM pickle_dealership_coupons WHERE dealership_id = ?",    { dealershipId })
    MySQL.update.await("DELETE FROM pickle_dealership_orders WHERE dealership_id = ?",     { dealershipId })
    MySQL.update.await("DELETE FROM pickle_dealership_stock WHERE dealership_id = ?",      { dealershipId })
    MySQL.update.await("DELETE FROM pickle_dealership_employees WHERE dealership_id = ?",  { dealershipId })
    MySQL.update.await("DELETE FROM pickle_dealerships WHERE id = ?",                      { dealershipId })

    DealershipCache[tonumber(dealershipId)] = nil

    local adminName = GetPlayerCharacterName(source) or GetPlayerName(source)
    debugPrint("Admin " .. adminName .. " deleted dealership #" .. dealershipId .. " (" .. (dealership.label or "?") .. ")")

    -- Seize-cache refresh covers clients that had this dealership flagged for seizure.
    TriggerClientEvent('pickle_dealerships:refreshSeizeCache', -1)

    -- Rebuild world on every client so blips, zones, interactions, display
    -- vehicles, and NPC customers for the deleted dealership get torn down
    -- without a resource restart.
    TriggerClientEvent('pickle_dealerships:reloadWorld', -1)

    LogDiscord("admin", {
        title = "Dealership Deleted",
        actor = source,
        dealershipId = dealershipId,
        description = "All associated stock, employees, ledger, auctions, and financing rows were purged.",
        fields = {
            { name = "Name", value = dealership.name or "?", inline = true },
            { name = "Owner", value = "`" .. tostring(dealership.owner_identifier or "none") .. "`", inline = true },
            { name = "Mode", value = tostring(dealership.mode or "?"), inline = true },
        },
    })

    return { success = true, message = _L("admin_dealership_deleted_msg") }
end)

--- Toggle dealership between public and player-owned mode
lib.callback.register("pickle_dealerships:adminToggleMode", function(source, data)
    if not IsPlayerAdmin(source) then
        return { success = false, message = _L("admin_no_permission") }
    end

    local dealershipId = data.dealershipId
    if not dealershipId then
        return { success = false, message = _L("admin_missing_dealership_id") }
    end

    local dealership = GetDealership(dealershipId)
    if not dealership then
        return { success = false, message = _L("dealership_not_found") }
    end

    -- Canonical values: 'player-owned' and 'managed' (NPC/automated). Anything
    -- else (legacy 'public' rows, stray 'player_owned' underscore form) is
    -- normalized on the next toggle.
    local currentMode = dealership.mode or "managed"
    local newMode = currentMode == "player-owned" and "managed" or "player-owned"

    -- Clearing owner on every mode flip prevents a stale owner_identifier from
    -- silently granting permissions after a switch (e.g. a managed dealership
    -- still treating the previous player as owner).
    MySQL.update.await("UPDATE pickle_dealerships SET mode = ?, owner_identifier = NULL WHERE id = ?", { newMode, dealershipId })
    UpdateDealershipCache(dealershipId, { mode = newMode })
    local cached = GetDealership(dealershipId)
    if cached then cached.owner_identifier = nil end

    -- A player-owned dealership must always start with zero inventory —
    -- otherwise converting a fully-stocked NPC shop would hand the new owner
    -- hundreds of free vehicles. Purge the seed rows and zero the balance on
    -- the transition. Converting back to managed re-seeds the auto-stock.
    if newMode == "player-owned" then
        MySQL.update.await(
            "DELETE FROM pickle_dealership_stock WHERE dealership_id = ? AND acquired_from = 'npc_seed'",
            { dealershipId }
        )
    elseif newMode == "managed" then
        -- Fresh managed dealerships need at least one group assigned or the
        -- seed query returns nothing. If admins haven't picked groups yet,
        -- fall back to the four default groups so the conversion produces
        -- visible stock immediately.
        local existingGroups = MySQL.query.await(
            "SELECT 1 FROM pickle_dealership_groups WHERE dealership_id = ? LIMIT 1",
            { dealershipId }
        )
        if not existingGroups or #existingGroups == 0 then
            setDealershipGroups(dealershipId, getDefaultGroupIds())
        end
        seedManagedDealershipStock(dealershipId, dealership.type)
    end

    local adminName = GetPlayerCharacterName(source) or GetPlayerName(source)
    AddLedgerEntry(dealershipId, "admin", 0, "Mode changed to " .. newMode .. " by admin " .. adminName, GetIdentifier(source))

    LogDiscord("admin", {
        title = "Dealership Mode Changed",
        actor = source,
        dealershipId = dealershipId,
        fields = {
            { name = "Dealership", value = dealership.name or "?", inline = true },
            { name = "Previous", value = tostring(currentMode), inline = true },
            { name = "New", value = tostring(newMode), inline = true },
        },
    })

    -- Clients need to re-fetch so stock pages/blips reflect the new state.
    TriggerClientEvent('pickle_dealerships:reloadWorld', -1)

    return { success = true, newMode = newMode, message = _L("admin_mode_set_to", newMode) }
end)

--- Toggle seize mode for a dealership
lib.callback.register("pickle_dealerships:adminToggleSeize", function(source, data)
    if not IsPlayerAdmin(source) then
        return { success = false, message = _L("admin_no_permission") }
    end

    local dealershipId = data.dealershipId
    if not dealershipId then
        return { success = false, message = _L("admin_missing_dealership_id") }
    end

    local dealership = GetDealership(dealershipId)
    if not dealership then
        return { success = false, message = _L("dealership_not_found") }
    end

    local current = (dealership.seize_enabled == 1 or dealership.seize_enabled == true) and 1 or 0
    local newValue = current == 1 and 0 or 1

    MySQL.update.await("UPDATE pickle_dealerships SET seize_enabled = ? WHERE id = ?", { newValue, dealershipId })
    UpdateDealershipCache(dealershipId, { seize_enabled = newValue })

    local adminName = GetPlayerCharacterName(source) or GetPlayerName(source)
    AddLedgerEntry(dealershipId, "admin", 0, "Seize mode " .. (newValue == 1 and "enabled" or "disabled") .. " by admin " .. adminName, GetIdentifier(source))

    -- Notify all clients to refresh their seize dealership cache
    TriggerClientEvent('pickle_dealerships:refreshSeizeCache', -1)

    return { success = true, seizeEnabled = newValue == 1, message = _L("admin_seize_set_to", newValue == 1 and "enabled" or "disabled") }
end)

--- Create a new dealership from admin panel
lib.callback.register("pickle_dealerships:adminCreateDealership", function(source, data)
    if not IsPlayerAdmin(source) then
        return { success = false, message = _L("admin_no_permission") }
    end

    if not data.label or data.label == "" then
        return { success = false, message = _L("admin_name_required") }
    end

    -- Generate a location key from the DB id (set after insert)
    local mode = data.mode or "player-owned"
    local dealershipType = data.type or "car"

    -- Optional positions placed inline in the create dialog (same pattern as depot create).
    -- Each is { x, y, z, w } or nil. Coords is required for the dealership to be functional,
    -- but we accept creation without it so admins can still place later on the positions tab.
    local metadata = {}
    if type(data.coords) == "table" and data.coords.x then
        metadata.coords = { x = data.coords.x, y = data.coords.y, z = data.coords.z, w = data.coords.w or 0.0 }
    end
    if type(data.spawnPoint) == "table" and data.spawnPoint.x then
        metadata.spawnPoint = { x = data.spawnPoint.x, y = data.spawnPoint.y, z = data.spawnPoint.z, w = data.spawnPoint.w or 0.0 }
    end
    if type(data.deliveryPoint) == "table" and data.deliveryPoint.x then
        metadata.deliveryPoint = { x = data.deliveryPoint.x, y = data.deliveryPoint.y, z = data.deliveryPoint.z, w = data.deliveryPoint.w or 0.0 }
    end

    -- Interaction points (management / sales / showroom). Stored under
    -- metadata.interactionPoints keyed by point type, matching the positions tab.
    local function collectInteraction(key, pt)
        if type(pt) ~= "table" or not pt.x then return end
        metadata.interactionPoints = metadata.interactionPoints or {}
        metadata.interactionPoints[key] = { x = pt.x, y = pt.y, z = pt.z, w = pt.w or 0.0 }
    end
    collectInteraction("management", data.managementPoint)
    collectInteraction("sales", data.salesPoint)
    collectInteraction("showroom", data.showroomPoint)

    -- Display spots placed inline during creation. Each carries an id so the
    -- positions tab can remove individual spots later.
    if type(data.displaySpots) == "table" and #data.displaySpots > 0 then
        metadata.displaySpots = {}
        metadata._nextSpotId = 0
        for _, s in ipairs(data.displaySpots) do
            if type(s) == "table" and s.x then
                metadata._nextSpotId = metadata._nextSpotId + 1
                metadata.displaySpots[#metadata.displaySpots + 1] = {
                    x = s.x, y = s.y, z = s.z, w = s.w or 0.0, id = metadata._nextSpotId,
                }
            end
        end
    end

    -- NPC spawn points placed inline during creation.
    if type(data.npcSpawnPoints) == "table" and #data.npcSpawnPoints > 0 then
        metadata.npcSpawnPoints = {}
        for _, p in ipairs(data.npcSpawnPoints) do
            if type(p) == "table" and p.x then
                metadata.npcSpawnPoints[#metadata.npcSpawnPoints + 1] = {
                    x = p.x, y = p.y, z = p.z, w = p.w or 0.0,
                }
            end
        end
    end

    -- Framework faction (job OR gang). Faction name goes in the top-level `job` column;
    -- the type disambiguator lives in metadata.factionType.
    local factionName = data.factionName
    if factionName == "" then factionName = nil end
    local factionType = data.factionType
    if factionType ~= "gang" then factionType = "job" end
    if factionName then metadata.factionType = factionType end

    -- Owner is only honored for player-owned mode. Tier column is preserved at
    -- the DB default for legacy/rollback reasons but no longer drives anything.
    local ownerIdentifier = nil
    if mode == "player-owned" and type(data.ownerIdentifier) == "string" and data.ownerIdentifier ~= "" then
        ownerIdentifier = data.ownerIdentifier
    end

    local metaJson = next(metadata) and json.encode(metadata) or nil

    local id = MySQL.insert.await(
        "INSERT INTO pickle_dealerships (name, location, type, mode, balance, reputation, owner_identifier, job, metadata) VALUES (?, ?, ?, ?, 0, 0, ?, ?, ?)",
        { data.label, "pending", dealershipType, mode, ownerIdentifier, factionName, metaJson }
    )

    if id then
        -- Set location to the DB id so it's always unique
        local location = "dealership_" .. id
        MySQL.update.await("UPDATE pickle_dealerships SET location = ? WHERE id = ?", { location, id })

        -- Group assignments. If the admin picked specific groups in the create
        -- form, honor them. Otherwise, default to all four seeded groups so a
        -- fresh dealership has a sensible starting catalog.
        local groupIds = data.groupIds
        if type(groupIds) ~= "table" or #groupIds == 0 then
            groupIds = getDefaultGroupIds()
        end
        setDealershipGroups(id, groupIds)

        -- NPC-operated dealerships get auto-seeded infinite stock based on the
        -- groups they're assigned to. Owners/admins tune prices in the stock tab.
        if mode == "managed" then
            seedManagedDealershipStock(id, dealershipType)
        end

        LoadDealerships()
        -- Tell every client to re-fetch and set up the new dealership in-world.
        -- Without this, blips/zones/interactions only appear after a resource restart.
        TriggerClientEvent('pickle_dealerships:reloadWorld', -1)

        local adminName = GetPlayerCharacterName(source) or GetPlayerName(source)
        debugPrint("Admin " .. adminName .. " created dealership #" .. id .. " (" .. data.label .. ")")

        LogDiscord("admin", {
            title = "Dealership Created",
            actor = source,
            dealershipId = id,
            fields = {
                { name = "Name", value = tostring(data.label or "?"), inline = true },
                { name = "Mode", value = tostring(mode), inline = true },
                { name = "Type", value = tostring(dealershipType), inline = true },
                { name = "Owner", value = "`" .. tostring(ownerIdentifier or "none") .. "`", inline = true },
                { name = "Faction", value = tostring(factionName or "none"), inline = true },
                { name = "Groups", value = tostring(#groupIds), inline = true },
            },
        })

        return { success = true, dealershipId = id, message = _L("admin_dealership_created_msg", data.label) }
    else
        return { success = false, message = _L("admin_db_create_failed") }
    end
end)

--- Save dealership position data from gizmo placement
lib.callback.register("pickle_dealerships:adminSavePosition", function(source, data)
    if not IsPlayerAdmin(source) then
        return { success = false, message = _L("admin_no_permission") }
    end

    local dealershipId = data.dealershipId
    if not dealershipId then
        return { success = false, message = _L("admin_missing_dealership_id") }
    end

    local dealership = GetDealership(dealershipId)
    if not dealership then
        return { success = false, message = _L("dealership_not_found") }
    end

    -- Get existing metadata or start fresh
    local metadata = dealership.metadata
    if type(metadata) == "string" then
        metadata = json.decode(metadata) or {}
    elseif type(metadata) ~= "table" then
        metadata = {}
    end

    -- Update the specific field
    local field = data.field
    local value = data.value

    if field == "coords" or field == "spawnPoint" or field == "deliveryPoint" then
        metadata[field] = value
    elseif field == "displaySpot" then
        if not metadata.displaySpots then
            metadata.displaySpots = {}
        end
        -- Give each spot a unique ID for reliable deletion
        value.id = (metadata._nextSpotId or #metadata.displaySpots) + 1
        metadata._nextSpotId = value.id
        metadata.displaySpots[#metadata.displaySpots + 1] = value
    elseif field == "interactionPoint" then
        if not metadata.interactionPoints then
            metadata.interactionPoints = {}
        end
        metadata.interactionPoints[data.pointType] = value
    elseif field == "npcSpawnPoint" then
        if not metadata.npcSpawnPoints then
            metadata.npcSpawnPoints = {}
        end
        metadata.npcSpawnPoints[#metadata.npcSpawnPoints + 1] = value
    elseif field == "zone" then
        if not metadata.zones then
            metadata.zones = {}
        end
        metadata.zones[#metadata.zones + 1] = value
    end

    MySQL.update.await("UPDATE pickle_dealerships SET metadata = ? WHERE id = ?", { json.encode(metadata), dealershipId })
    UpdateDealershipCache(dealershipId, { metadata = metadata })

    -- Tell clients exactly what changed so they can surgically update
    local location = dealership.location
    TriggerClientEvent('pickle_dealerships:positionUpdated', -1, location, data.field, data.pointType)

    -- Adding an NPC spawn point after an employee is already on duty means
    -- their spawn loop was holding a stale (possibly empty) point list — push
    -- the refreshed config so the new location comes into play immediately.
    if data.field == "npcSpawnPoint" and RefreshNpcDutyForDealership then
        RefreshNpcDutyForDealership(dealershipId)
    end

    return { success = true, metadata = metadata, message = _L("admin_position_saved") }
end)

--- Remove a position from dealership metadata
lib.callback.register("pickle_dealerships:adminRemovePosition", function(source, data)
    if not IsPlayerAdmin(source) then
        return { success = false, message = _L("admin_no_permission") }
    end

    local dealershipId = data.dealershipId
    if not dealershipId then
        return { success = false, message = _L("admin_missing_dealership_id") }
    end

    local dealership = GetDealership(dealershipId)
    if not dealership then
        return { success = false, message = _L("dealership_not_found") }
    end

    -- Always re-read metadata fresh from DB to avoid stale cache references
    local row = MySQL.single.await("SELECT metadata FROM pickle_dealerships WHERE id = ?", { dealershipId })
    local metadata = {}
    if row and row.metadata then
        if type(row.metadata) == "string" then
            metadata = json.decode(row.metadata) or {}
        elseif type(row.metadata) == "table" then
            metadata = row.metadata
        end
    end

    local field = data.field

    if field == "coords" or field == "spawnPoint" or field == "deliveryPoint" then
        metadata[field] = nil
    elseif field == "displaySpot" and metadata.displaySpots then
        local spotId = tonumber(data.spotId)
        debugPrint("[RemovePosition] Removing spotId=" .. tostring(spotId) .. " from " .. tostring(#metadata.displaySpots) .. " spots")

        -- Rebuild the array without the target spot
        local newSpots = {}
        local removedIndex = nil
        for i, spot in ipairs(metadata.displaySpots) do
            debugPrint("[RemovePosition]   Spot " .. i .. " id=" .. tostring(spot.id) .. " target=" .. tostring(spotId))
            if tonumber(spot.id) == spotId then
                removedIndex = i
            else
                newSpots[#newSpots + 1] = spot
            end
        end

        if removedIndex then
            -- Unassign any vehicle on this spot (by spot ID, not array index)
            MySQL.update.await(
                'UPDATE pickle_dealership_stock SET display_spot = NULL WHERE dealership_id = ? AND (display_spot = ? OR display_spot = ?)',
                { dealershipId, spotId, tostring(spotId) }
            )
            metadata.displaySpots = newSpots
        else
            debugPrint("[RemovePosition] Spot not found!")
            return { success = false, message = _L("admin_display_spot_not_found") }
        end
    elseif field == "interactionPoint" and data.pointType and metadata.interactionPoints then
        metadata.interactionPoints[data.pointType] = nil
    elseif field == "npcSpawnPoint" and data.index and metadata.npcSpawnPoints then
        local idx = math.floor(tonumber(data.index))
        if idx >= 1 and idx <= #metadata.npcSpawnPoints then
            table.remove(metadata.npcSpawnPoints, idx)
        end
    end

    MySQL.update.await("UPDATE pickle_dealerships SET metadata = ? WHERE id = ?", { json.encode(metadata), dealershipId })
    UpdateDealershipCache(dealershipId, { metadata = metadata })

    local location = dealership.location
    TriggerClientEvent('pickle_dealerships:positionUpdated', -1, location, data.field, data.pointType)

    return { success = true, metadata = metadata, message = _L("admin_position_removed") }
end)

-- ─── Catalog Management ─────────────────────────────────────────────────────

--- Get all catalog vehicles
lib.callback.register("pickle_dealerships:adminGetCatalog", function(source, data)
    if not IsPlayerAdmin(source) then DenyAccess(source, "admin_no_permission") return nil end

    local page = tonumber(data and data.page) or 1
    local pageSize = tonumber(data and data.pageSize) or 50
    local search = data and data.search or ""
    local typeFilter = data and data.typeFilter or "all"
    local offset = (page - 1) * pageSize

    local where = {}
    local params = {}

    if typeFilter ~= "all" then
        where[#where + 1] = "vehicle_type = ?"
        params[#params + 1] = typeFilter
    end

    if search ~= "" then
        where[#where + 1] = "(label LIKE ? OR model LIKE ?)"
        local pattern = "%" .. search .. "%"
        params[#params + 1] = pattern
        params[#params + 1] = pattern
    end

    local whereClause = #where > 0 and ("WHERE " .. table.concat(where, " AND ")) or ""

    local countParams = { table.unpack(params) }
    local countResult = MySQL.scalar.await(
        ("SELECT COUNT(*) FROM pickle_wholesale_catalog %s"):format(whereClause),
        countParams
    )

    params[#params + 1] = pageSize
    params[#params + 1] = offset

    local results = MySQL.query.await(
        ("SELECT * FROM pickle_wholesale_catalog %s ORDER BY vehicle_type ASC, wholesale ASC LIMIT ? OFFSET ?"):format(whereClause),
        params
    )

    -- Attach groupIds per vehicle so the catalog UI can render the assigned
    -- group chips without a follow-up callback per row. Single bulk query
    -- keyed by the page's catalog ids.
    if results and #results > 0 then
        local ids = {}
        for _, row in ipairs(results) do ids[#ids + 1] = row.id end
        local marks = string.rep('?,', #ids):sub(1, -2)
        local junctionRows = MySQL.query.await(
            ("SELECT catalog_id, group_id FROM pickle_catalog_vehicle_groups WHERE catalog_id IN (%s)"):format(marks),
            ids
        ) or {}
        local byCatalog = {}
        for _, jr in ipairs(junctionRows) do
            byCatalog[jr.catalog_id] = byCatalog[jr.catalog_id] or {}
            byCatalog[jr.catalog_id][#byCatalog[jr.catalog_id] + 1] = jr.group_id
        end
        for _, row in ipairs(results) do
            row.groupIds = byCatalog[row.id] or {}
        end
    end

    return {
        items = results or {},
        total = countResult or 0,
        page = page,
        pageSize = pageSize,
    }
end)

--- Add a vehicle to the catalog
lib.callback.register("pickle_dealerships:adminAddCatalogVehicle", function(source, data)
    if not IsPlayerAdmin(source) then
        return { success = false, message = _L("admin_no_permission") }
    end

    if not data.model or data.model == "" then
        return { success = false, message = _L("admin_vehicle_model_required") }
    end
    if not data.label or data.label == "" then
        return { success = false, message = _L("admin_vehicle_label_required") }
    end

    local existing = MySQL.single.await("SELECT id FROM pickle_wholesale_catalog WHERE model = ?", { data.model })
    if existing then
        return { success = false, message = _L("admin_vehicle_exists", data.model) }
    end

    -- Tier column dropped from the writable column set when catalog access
    -- moved to many-to-many groups. The DB default ('basic') still satisfies
    -- the NOT NULL constraint for legacy schemas.
    local id = MySQL.insert.await(
        "INSERT INTO pickle_wholesale_catalog (model, label, wholesale, class, vehicle_type) VALUES (?, ?, ?, ?, ?)",
        {
            data.model,
            data.label,
            tonumber(data.wholesale) or 0,
            data.class or "sedan",
            data.vehicleType or "car",
        }
    )

    if id then
        -- Optional groupIds in the create payload: seed the junction in the
        -- same callback so the new vehicle is immediately visible in the
        -- groups the admin picked.
        if type(data.groupIds) == "table" then
            for _, gid in ipairs(data.groupIds) do
                local n = tonumber(gid)
                if n then
                    MySQL.insert.await(
                        "INSERT IGNORE INTO pickle_catalog_vehicle_groups (catalog_id, group_id) VALUES (?, ?)",
                        { id, n }
                    )
                end
            end
        end
        return { success = true, id = id, message = _L("admin_vehicle_added", data.label) }
    end
    return { success = false, message = _L("admin_failed_add_vehicle") }
end)

--- Update a catalog vehicle (metadata only; group assignments are saved via
--- adminSetVehicleGroups so the catalog edit dialog can manage them as a
--- separate step the same way photo uploads work).
lib.callback.register("pickle_dealerships:adminUpdateCatalogVehicle", function(source, data)
    if not IsPlayerAdmin(source) then
        return { success = false, message = _L("admin_no_permission") }
    end

    if not data.id then
        return { success = false, message = _L("admin_missing_vehicle_id") }
    end

    MySQL.update.await(
        "UPDATE pickle_wholesale_catalog SET label = ?, wholesale = ?, class = ?, vehicle_type = ? WHERE id = ?",
        {
            data.label,
            tonumber(data.wholesale) or 0,
            data.class or "sedan",
            data.vehicleType or "car",
            data.id,
        }
    )

    return { success = true, message = _L("admin_vehicle_updated") }
end)

--- Remove a vehicle from the catalog
lib.callback.register("pickle_dealerships:adminRemoveCatalogVehicle", function(source, data)
    if not IsPlayerAdmin(source) then
        return { success = false, message = _L("admin_no_permission") }
    end

    if not data.id then
        return { success = false, message = _L("admin_missing_vehicle_id") }
    end

    MySQL.update.await("DELETE FROM pickle_wholesale_catalog WHERE id = ?", { data.id })
    return { success = true, message = _L("admin_vehicle_removed") }
end)

--- Stock a dealership with every catalog vehicle that lives in any of its
--- assigned groups. The admin supplies a single `quantity` applied to every
--- inserted row. Models already present (unsold) on this lot are skipped, so
--- re-running after adding new catalog entries just fills in the new ones.
lib.callback.register("pickle_dealerships:adminStockAllFromCatalog", function(source, data)
    if not IsPlayerAdmin(source) then
        return { success = false, message = _L("admin_no_permission") }
    end

    local dealershipId = tonumber(data and data.dealershipId)
    if not dealershipId then
        return { success = false, message = _L("admin_missing_dealership_id") }
    end

    local quantity = math.max(1, math.floor(tonumber(data and data.quantity) or 1))

    local dealership = GetDealership(dealershipId)
    if not dealership then
        return { success = false, message = _L("dealership_not_found") }
    end

    local vehicleType = dealership.type
    local types = {}
    if vehicleType == 'mixed' or not vehicleType or vehicleType == '' then
        types = { 'car', 'boat', 'air' }
    else
        types = { vehicleType }
    end

    if #types == 0 then
        return { success = false, message = _L("admin_no_catalog_vehicles") }
    end

    local typeMarks = string.rep('?,', #types):sub(1, -2)
    -- Group-membership join: vehicle is eligible iff it shares at least one
    -- group with the dealership. Same shape as seedManagedDealershipStock.
    local sql = ([[
        INSERT INTO pickle_dealership_stock
            (dealership_id, vehicle_model, vehicle_label, wholesale_cost, retail_price, quantity, ordered_at, delivered_at, acquired_from)
        SELECT ?, wc.model, wc.label, wc.wholesale, ROUND(wc.wholesale * (1 + ?)), ?, NOW(), NOW(), 'admin_seed'
        FROM pickle_wholesale_catalog wc
        WHERE wc.vehicle_type IN (%s)
          AND EXISTS (
              SELECT 1
              FROM pickle_catalog_vehicle_groups vg
              JOIN pickle_dealership_groups dg ON dg.group_id = vg.group_id
              WHERE vg.catalog_id = wc.id AND dg.dealership_id = ?
          )
          AND NOT EXISTS (
              SELECT 1 FROM pickle_dealership_stock ds
              WHERE ds.dealership_id = ?
                AND ds.vehicle_model = wc.model
                AND ds.sold_at IS NULL
          )
    ]]):format(typeMarks)

    local params = { dealershipId, 0.30, quantity } -- retail = wholesale * 1.3 by default
    for _, tval in ipairs(types) do params[#params + 1] = tval end
    params[#params + 1] = dealershipId
    params[#params + 1] = dealershipId

    local inserted = MySQL.update.await(sql, params) or 0

    local adminName = GetPlayerCharacterName(source) or GetPlayerName(source)
    AddLedgerEntry(dealershipId, "admin", 0,
        ("Seeded %d catalog vehicles into stock by admin %s"):format(inserted, adminName),
        GetIdentifier(source))

    LogDiscord("admin", {
        title = "Catalog Stocked",
        actor = source,
        dealershipId = dealershipId,
        fields = {
            { name = "Dealership", value = dealership.name or "?", inline = true },
            { name = "Rows Inserted", value = tostring(inserted), inline = true },
        },
    })

    return { success = true, inserted = inserted, message = _L("admin_stockall_complete", inserted, dealershipId) }
end)

--- Set dealership faction (job OR gang). `factionType` must be "job" or "gang".
--- The faction name is stored in `pickle_dealerships.job` (legacy column kept for back-compat);
--- the type lives in metadata.factionType.
lib.callback.register("pickle_dealerships:adminSetFaction", function(source, data)
    if not IsPlayerAdmin(source) then
        return { success = false, message = _L("admin_no_permission") }
    end

    local dealershipId = data.dealershipId
    if not dealershipId then
        return { success = false, message = _L("admin_missing_dealership_id") }
    end

    local dealership = GetDealership(dealershipId)
    if not dealership then
        return { success = false, message = _L("dealership_not_found") }
    end

    local factionName = data.name
    if factionName == "" then factionName = nil end

    local factionType = data.factionType
    if factionType ~= "gang" then factionType = "job" end

    local meta = dealership.metadata
    if type(meta) == "string" then meta = json.decode(meta) or {} end
    if type(meta) ~= "table" then meta = {} end
    if factionName then
        meta.factionType = factionType
    else
        meta.factionType = nil
    end

    MySQL.update.await("UPDATE pickle_dealerships SET job = ?, metadata = ? WHERE id = ?", { factionName, json.encode(meta), dealershipId })
    UpdateDealershipCache(dealershipId, { job = factionName, metadata = meta })

    return { success = true, message = _L("admin_faction_set_to", factionType, factionName or "none") }
end)


--- Admin sets customer access rules for a dealership. Stored in metadata.
--- mode: 'public' | 'faction' (only faction members can enter/purchase)
--- minGrade: only enforced when mode = 'faction'
lib.callback.register("pickle_dealerships:adminSetAccess", function(source, data)
    if not IsPlayerAdmin(source) then
        return { success = false, message = _L("admin_no_permission") }
    end

    local dealershipId = data.dealershipId
    if not dealershipId then
        return { success = false, message = _L("admin_missing_dealership_id") }
    end

    local dealership = GetDealership(dealershipId)
    if not dealership then
        return { success = false, message = _L("dealership_not_found") }
    end

    local mode = data.mode
    if mode ~= "faction" then mode = "public" end

    local meta = dealership.metadata
    if type(meta) == "string" then meta = json.decode(meta) or {} end
    if type(meta) ~= "table" then meta = {} end

    meta.accessMode = mode
    if mode == "faction" then
        meta.accessMinGrade = math.max(0, math.floor(tonumber(data.minGrade) or 0))
    else
        meta.accessMinGrade = nil
    end

    MySQL.update.await("UPDATE pickle_dealerships SET metadata = ? WHERE id = ?", { json.encode(meta), dealershipId })
    UpdateDealershipCache(dealershipId, { metadata = meta })

    return { success = true, message = _L("admin_access_set_to", mode) }
end)

-- ─── Photo Booth ────────────────────────────────────────────────────────────

--- Get image upload config for the client
lib.callback.register("pickle_dealerships:adminGetUploadConfig", function(source)
    if not IsPlayerAdmin(source) then
        return nil
    end

    local cfg = ServerConfig.ImageUpload
    if not cfg or not cfg.provider then
        print("[PhotoBooth:Server] ERROR: ServerConfig.ImageUpload is not configured")
        return nil
    end

    if cfg.provider == "fivemanage" then
        if not cfg.token or cfg.token == "" or cfg.token == "TOKEN_HERE" then
            print("[PhotoBooth:Server] ERROR: FiveManage token is not set in config_sv.lua (still the placeholder 'TOKEN_HERE').")
            return nil
        end
        return {
            url = "https://api.fivemanage.com/api/image",
            field = "image",
            headers = { ["Authorization"] = cfg.token },
        }
    elseif cfg.provider == "custom" then
        local custom = cfg.custom
        if not custom or not custom.url or custom.url == "" then
            print("[PhotoBooth:Server] ERROR: Custom upload URL is not set in config_sv.lua")
            return nil
        end
        return {
            url = custom.url,
            field = custom.field or "image",
            headers = custom.headers or {},
            returnPathKey = custom.returnPathKey or "url",
        }
    end

    print(("[PhotoBooth:Server] ERROR: Unknown image upload provider '%s'"):format(cfg.provider))
    return nil
end)

--- Save a catalog vehicle image URL
lib.callback.register("pickle_dealerships:adminSaveCatalogImage", function(source, data)
    if not IsPlayerAdmin(source) then
        return { success = false, message = _L("admin_no_permission") }
    end

    if not data.catalogId or not data.imageUrl then
        return { success = false, message = _L("admin_missing_catalog_data") }
    end

    MySQL.update.await("UPDATE pickle_wholesale_catalog SET image = ? WHERE id = ?", { data.imageUrl, data.catalogId })
    return { success = true, message = _L("admin_vehicle_image_saved") }
end)

--- Remove a catalog vehicle image
lib.callback.register("pickle_dealerships:adminRemoveCatalogImage", function(source, data)
    if not IsPlayerAdmin(source) then
        return { success = false, message = _L("admin_no_permission") }
    end

    if not data.catalogId then
        return { success = false, message = _L("admin_missing_dealership_id") }
    end

    MySQL.update.await("UPDATE pickle_wholesale_catalog SET image = NULL WHERE id = ?", { data.catalogId })
    return { success = true, message = _L("admin_vehicle_image_removed") }
end)

--- Set player routing bucket for photo booth isolation
lib.callback.register("pickle_dealerships:adminSetPhotoBucket", function(source, data)
    if not IsPlayerAdmin(source) then
        return { success = false, message = _L("admin_no_permission") }
    end

    local bucket = tonumber(data.bucket) or 0
    SetPlayerRoutingBucket(source, bucket)
    return { success = true }
end)

-- ─── Catalog Groups ─────────────────────────────────────────────────────────
-- Many-to-many replacement for the legacy tier hierarchy. A vehicle is visible
-- in a dealership's catalog when (vehicle.groups ∩ dealership.groups) is
-- non-empty. Default groups (basic / expanded / full / exclusive) are seeded
-- on first boot in core/server.lua's BackfillCatalogGroups; admins create and
-- manage additional groups through these callbacks.

--- List every group with its current vehicle count (cheap join used by the
--- admin UI to show e.g. "Premium · 12 vehicles").
lib.callback.register("pickle_dealerships:adminGetGroups", function(source)
    if not IsPlayerAdmin(source) then DenyAccess(source, "admin_no_permission") return {} end

    local rows = MySQL.query.await([[
        SELECT g.id, g.name, g.label, g.description, g.is_default,
               (SELECT COUNT(*) FROM pickle_catalog_vehicle_groups vg WHERE vg.group_id = g.id) AS vehicle_count,
               (SELECT COUNT(*) FROM pickle_dealership_groups dg WHERE dg.group_id = g.id) AS dealership_count
        FROM pickle_catalog_groups g
        ORDER BY g.is_default DESC, g.name ASC
    ]]) or {}
    return rows
end)

--- Create a new admin-defined group. `name` is the stable machine key (used by
--- driver-progression configs and any external integrations); `label` is the
--- player-facing display string. Both required; name must be unique.
lib.callback.register("pickle_dealerships:adminCreateGroup", function(source, data)
    if not IsPlayerAdmin(source) then
        return { success = false, message = _L("admin_no_permission") }
    end
    local name = data and data.name and tostring(data.name):gsub("^%s*(.-)%s*$", "%1") or ""
    local label = data and data.label and tostring(data.label):gsub("^%s*(.-)%s*$", "%1") or ""
    if name == "" or label == "" then
        return { success = false, message = _L("admin_group_name_label_required") }
    end

    local existing = MySQL.scalar.await(
        "SELECT id FROM pickle_catalog_groups WHERE name = ? LIMIT 1",
        { name }
    )
    if existing then
        return { success = false, message = _L("admin_group_name_taken", name) }
    end

    local id = MySQL.insert.await(
        "INSERT INTO pickle_catalog_groups (name, label, description, is_default) VALUES (?, ?, ?, 0)",
        { name, label, data.description }
    )
    if not id then
        return { success = false, message = _L("admin_group_create_failed") }
    end
    return { success = true, id = id, message = _L("admin_group_created", label) }
end)

--- Update an existing group. Name, label, and description are all editable
--- — even on seeded groups. Renaming a group that's referenced by a
--- driver-progression entry (e.g. "basic"/"expanded") will break that
--- reference, but that's the admin's call to make.
lib.callback.register("pickle_dealerships:adminUpdateGroup", function(source, data)
    if not IsPlayerAdmin(source) then
        return { success = false, message = _L("admin_no_permission") }
    end
    local id = tonumber(data and data.id)
    if not id then
        return { success = false, message = _L("admin_group_missing_id") }
    end
    local label = data.label and tostring(data.label):gsub("^%s*(.-)%s*$", "%1") or ""
    if label == "" then
        return { success = false, message = _L("admin_group_label_required") }
    end

    -- Optional rename. Only applied when a non-empty string different from
    -- the existing name is provided, so older clients that omit the field
    -- keep working.
    local newName = data.name and tostring(data.name):gsub("^%s*(.-)%s*$", "%1") or nil
    if newName and newName ~= "" then
        local conflict = MySQL.scalar.await(
            "SELECT id FROM pickle_catalog_groups WHERE name = ? AND id != ? LIMIT 1",
            { newName, id }
        )
        if conflict then
            return { success = false, message = _L("admin_group_name_taken", newName) }
        end
        MySQL.update.await(
            "UPDATE pickle_catalog_groups SET name = ?, label = ?, description = ? WHERE id = ?",
            { newName, label, data.description, id }
        )
    else
        MySQL.update.await(
            "UPDATE pickle_catalog_groups SET label = ?, description = ? WHERE id = ?",
            { label, data.description, id }
        )
    end
    return { success = true, message = _L("admin_group_updated") }
end)

--- Delete a group + cascade junction rows. Every group is deletable,
--- including seeded ones — the DB is the source of truth, nothing in code
--- requires a specific group name to exist.
lib.callback.register("pickle_dealerships:adminDeleteGroup", function(source, data)
    if not IsPlayerAdmin(source) then
        return { success = false, message = _L("admin_no_permission") }
    end
    local id = tonumber(data and data.id)
    if not id then
        return { success = false, message = _L("admin_group_missing_id") }
    end
    local row = MySQL.single.await(
        "SELECT id, label FROM pickle_catalog_groups WHERE id = ?",
        { id }
    )
    if not row then
        return { success = false, message = _L("admin_group_not_found") }
    end

    MySQL.update.await("DELETE FROM pickle_catalog_vehicle_groups WHERE group_id = ?", { id })
    MySQL.update.await("DELETE FROM pickle_dealership_groups WHERE group_id = ?", { id })
    MySQL.update.await("DELETE FROM pickle_catalog_groups WHERE id = ?", { id })
    return { success = true, message = _L("admin_group_deleted", row.label or "") }
end)

--- Replace a vehicle's group assignments with the given list. Sent by the
--- catalog edit dialog after metadata save. Empty list = vehicle becomes
--- invisible to every dealership.
lib.callback.register("pickle_dealerships:adminSetVehicleGroups", function(source, data)
    if not IsPlayerAdmin(source) then
        return { success = false, message = _L("admin_no_permission") }
    end
    local catalogId = tonumber(data and data.catalogId)
    if not catalogId then
        return { success = false, message = _L("admin_missing_vehicle_id") }
    end
    MySQL.update.await(
        "DELETE FROM pickle_catalog_vehicle_groups WHERE catalog_id = ?",
        { catalogId }
    )
    if type(data.groupIds) == "table" then
        for _, gid in ipairs(data.groupIds) do
            local n = tonumber(gid)
            if n then
                MySQL.insert.await(
                    "INSERT IGNORE INTO pickle_catalog_vehicle_groups (catalog_id, group_id) VALUES (?, ?)",
                    { catalogId, n }
                )
            end
        end
    end
    return { success = true, message = _L("admin_vehicle_groups_saved") }
end)

--- Replace a dealership's group assignments with the given list. Same shape as
--- adminSetVehicleGroups; empty list = dealership has no catalog (visible
--- empty state for the customer).
lib.callback.register("pickle_dealerships:adminSetDealershipGroups", function(source, data)
    if not IsPlayerAdmin(source) then
        return { success = false, message = _L("admin_no_permission") }
    end
    local dealershipId = tonumber(data and data.dealershipId)
    if not dealershipId then
        return { success = false, message = _L("admin_missing_dealership_id") }
    end
    setDealershipGroups(dealershipId, data.groupIds)
    -- Refresh customer-facing list immediately so a player standing in the
    -- showroom sees the catalog change without re-entering the zone.
    local d = GetDealership(dealershipId)
    if d and d.location then
        TriggerClientEvent('pickle_dealerships:refreshDisplay', -1, d.location)
    end
    return { success = true, message = _L("admin_dealership_groups_saved") }
end)

--- List the group ids currently assigned to a single dealership. Used by the
--- admin "Set Groups" dialog to seed its checked state.
lib.callback.register("pickle_dealerships:adminGetDealershipGroups", function(source, data)
    if not IsPlayerAdmin(source) then DenyAccess(source, "admin_no_permission") return {} end
    local dealershipId = tonumber(data and data.dealershipId)
    if not dealershipId then return {} end
    local rows = MySQL.query.await(
        "SELECT group_id FROM pickle_dealership_groups WHERE dealership_id = ?",
        { dealershipId }
    ) or {}
    local ids = {}
    for _, r in ipairs(rows) do ids[#ids + 1] = r.group_id end
    return ids
end)

--- Admin command to open admin panel
RegisterCommand(Config.AdminCommand or "dealerships", function(source, args, rawCommand)
    if source == 0 then
        print("This command cannot be used from the console.")
        return
    end

    if not IsPlayerAdmin(source) then
        ShowNotification(source, _L("admin_no_command_permission"))
        return
    end

    TriggerClientEvent("pickle_dealerships:openAdminPanel", source)
end, false)
