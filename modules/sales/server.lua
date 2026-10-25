-- =============================================
--  pickle_dealerships | modules/sales/server.lua
--  Vehicle sales to players
-- =============================================

-- ─── Test drive routing buckets ─────────────────────────────────────────────
-- Each test drive runs in its own bucket so the driver can't crash into other
-- players, other players' vehicles, or traffic. Bucket IDs are derived from
-- server ID so concurrent drives don't collide. Restored on test drive end,
-- player disconnect, or resource stop.

local TEST_DRIVE_BUCKET_BASE = 90000
local testDriveVersions = {}
local originalBuckets = {} -- [src] = previous bucket id

local function EnterTestDriveBucket(source)
    local src = tonumber(source)
    if not src or originalBuckets[src] then return end
    local key = tostring(src)
    originalBuckets[src] = GetPlayerRoutingBucket(key)
    SetPlayerRoutingBucket(key, TEST_DRIVE_BUCKET_BASE + src)
    testDriveVersions[src]=(testDriveVersions[src] or 0)+1
    local version=testDriveVersions[src]
    local owner=DealerIdentity(src)
    SetTimeout(((tonumber(Config.TestDriveTime) or 120)+30)*1000,function()
        if testDriveVersions[src]~=version or DealerIdentity(src)~=owner then return end
        local previous=originalBuckets[src]
        if previous~=nil then
            if GetPlayerRoutingBucket(src)==TEST_DRIVE_BUCKET_BASE+src then SetPlayerRoutingBucket(src,previous) end
            originalBuckets[src]=nil
        end
    end)
end

local function LeaveTestDriveBucket(source)
    local src = tonumber(source)
    if not src then return end
    local prev = originalBuckets[src]
    if prev == nil then return end
    SetPlayerRoutingBucket(tostring(src), prev)
    originalBuckets[src] = nil
    testDriveVersions[src]=(testDriveVersions[src] or 0)+1
end

RegisterNetEvent('pickle_dealerships:enterTestDriveBucket', function()
    EnterTestDriveBucket(source)
end)

RegisterNetEvent('pickle_dealerships:leaveTestDriveBucket', function()
    LeaveTestDriveBucket(source)
end)

AddEventHandler('playerDropped', function()
    LeaveTestDriveBucket(source)
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    for src, prev in pairs(originalBuckets) do
        pcall(SetPlayerRoutingBucket, tostring(src), prev)
    end
    originalBuckets = {}
end)

-- ─── Helpers ────────────────────────────────────────────────────────────────

--- Removes 1 copy of the configured coupon item from `slot` if ox_inventory is
--- the active inventory, otherwise falls back to the framework helper which
--- pops "any" copy. No-ops if the bridge is missing.
function ConsumeCouponItem(source, slot)
    if not Config or type(Config.CouponItem) ~= 'string' or Config.CouponItem == '' then return end
    local itemName = Config.CouponItem
    if GetResourceState("ox_inventory") == "started" then
        local ok = pcall(function()
            exports.ox_inventory:RemoveItem(source, itemName, 1, nil, slot)
        end)
        if ok then return end
    end
    if Inventory and Inventory.RemoveItem then
        Inventory.RemoveItem(source, itemName, 1)
    end
end

local function GetStockItem(stockId)
    local rows = MySQL.query.await(
        "SELECT * FROM `pickle_dealership_stock` WHERE `id` = ? LIMIT 1",
        { tonumber(stockId) }
    )
    local row=rows and rows[1]
    if row and row.auction_id then return nil end
    return row
end

-- Global so other modules (financing, etc.) can reuse the same validation +
-- atomic uses-counter increment without duplicating the logic.
-- `identifier` is the buyer's stable player id; when provided we also enforce
-- the per-player cap (`max_uses_per_player`) and record the redemption in
-- pickle_dealership_coupon_uses so the next redemption sees the new total.
function ValidateCoupon(dealershipId, code, purchasePrice, identifier)
    if not code or code == "" then return nil end
    local rows = MySQL.query.await(
        "SELECT * FROM `pickle_dealership_coupons` WHERE `dealership_id` = ? AND `code` = ? LIMIT 1",
        { tonumber(dealershipId), tostring(code) }
    )
    local coupon = rows and rows[1] or nil
    if not coupon then return nil end
    -- max_uses = 0 means unlimited; only enforce the cap when a positive
    -- limit is set, otherwise every unlimited coupon would fail (0 >= 0).
    if coupon.max_uses and coupon.max_uses > 0 and coupon.uses >= coupon.max_uses then return nil end
    if coupon.expires_at and os.time() > DealerDate(coupon.expires_at) then return nil end
    if coupon.min_purchase > 0 and purchasePrice < coupon.min_purchase then return nil end

    -- Per-player cap. Only meaningful when we know which player is buying;
    -- callers that lack an identifier (rare) skip this check.
    local perPlayerCap = tonumber(coupon.max_uses_per_player) or 0
    if perPlayerCap > 0 and identifier then
        local used = MySQL.scalar.await(
            "SELECT `uses` FROM `pickle_dealership_coupon_uses` WHERE `coupon_id` = ? AND `identifier` = ?",
            { coupon.id, identifier }
        ) or 0
        if used >= perPlayerCap then return nil end
    end

    local discount = 0
    local value = tonumber(coupon.discount_value) or 0
    if (coupon.discount_type == "percent" or coupon.discount_type == "percentage") then
        -- Clamp percent to [0, 100] so a bad row can't produce a negative
        -- discount (which would inflate the price) or exceed the vehicle cost.
        local pct = math.max(0, math.min(100, value))
        discount = math.floor(purchasePrice * (pct / 100))
    else
        discount = math.floor(math.max(0, value))
    end
    -- Belt and braces: never let the discount exceed the price itself.
    if discount > purchasePrice then discount = purchasePrice end

    if not DealerCouponAllowed(coupon,DealerCurrentStock()) then return nil end
    DealerQueueCoupon(coupon,identifier)

    return discount, coupon
end

local function MarkStockSold(stockId, identifier, soldBy)
    local stock = MySQL.single.await(
        "SELECT `quantity`, `acquired_from` FROM `pickle_dealership_stock` WHERE `id` = ?",
        { tonumber(stockId) }
    )
    -- NPC-seeded stock is intentionally infinite — don't decrement or mark sold
    -- so the automated dealership keeps offering the vehicle.
    if stock and stock.acquired_from == 'npc_seed' then
        return
    end
    if stock and stock.quantity > 1 then
        MySQL.update.await(
            "UPDATE `pickle_dealership_stock` SET `quantity` = `quantity` - 1 WHERE `id` = ?",
            { tonumber(stockId) }
        )
    else
        MySQL.update.await(
            "UPDATE `pickle_dealership_stock` SET `sold_at` = NOW(), `sold_to` = ?, `sold_by` = ? WHERE `id` = ?",
            { identifier, soldBy, tonumber(stockId) }
        )
    end
end

local function AddDealershipBalance(dealershipId, amount)
    MySQL.update.await(
        "UPDATE `pickle_dealerships` SET `balance` = `balance` + ? WHERE `id` = ?",
        { tonumber(amount), tonumber(dealershipId) }
    )
    -- Read fresh balance from DB to keep cache accurate
    local freshBalance = MySQL.scalar.await(
        "SELECT `balance` FROM `pickle_dealerships` WHERE `id` = ?",
        { tonumber(dealershipId) }
    )
    if freshBalance then
        UpdateDealershipCache(dealershipId, { balance = tonumber(freshBalance) })
    end
end

--- Returns the matched allowlist entry for this player against the dealership's
--- society allowlist, or nil if they do not qualify.
local function MatchSocietyAllowlist(source, dealership)
    local meta = dealership and dealership.metadata
    if type(meta) == "string" then meta = json.decode(meta) or {} end
    if type(meta) ~= "table" then return nil end

    local allowlist = meta.societyAllowlist
    if type(allowlist) ~= "table" or #allowlist == 0 then return nil end

    local jobName = GetPlayerJobName and GetPlayerJobName(source) or nil
    local jobGrade = GetPlayerJobGrade and GetPlayerJobGrade(source) or 0
    local gangName = GetPlayerGangName and GetPlayerGangName(source) or nil
    local gangGrade = GetPlayerGangGrade and GetPlayerGangGrade(source) or 0

    for _, entry in ipairs(allowlist) do
        local minGrade = tonumber(entry.minGrade) or 0
        if entry.type == "job" and entry.name and entry.name == jobName and jobGrade >= minGrade then
            return entry
        elseif entry.type == "gang" and entry.name and entry.name == gangName and gangGrade >= minGrade then
            return entry
        end
    end
    return nil
end

--- Returns true if the player meets the stock item's min-grade requirement.
--- Grade is matched against the dealership's configured faction (job or gang).
local function PlayerMeetsMinGrade(source, dealership, stockItem)
    local stockMeta = stockItem and stockItem.metadata
    if type(stockMeta) == "string" then stockMeta = json.decode(stockMeta) or {} end
    if type(stockMeta) ~= "table" then return true end

    local minGrade = tonumber(stockMeta.minGrade)
    if not minGrade or minGrade <= 0 then return true end

    local faction = GetDealershipFaction(dealership)
    if not faction.name or faction.name == "" then return true end

    if faction.type == "gang" then
        local gangName = GetPlayerGangName and GetPlayerGangName(source) or nil
        if gangName ~= faction.name then return false end
        return (GetPlayerGangGrade and GetPlayerGangGrade(source) or 0) >= minGrade
    else
        local jobName = GetPlayerJobName and GetPlayerJobName(source) or nil
        if jobName ~= faction.name then return false end
        return (GetPlayerJobGrade and GetPlayerJobGrade(source) or 0) >= minGrade
    end
end

local function ProcessSale(source, dealershipId, stockItem, paymentMethod, couponCode, soldByCitizenid, addons)
    local identifier = GetIdentifier(source)
    if not identifier then return false, "Could not identify player." end

    local dealership = GetDealership(dealershipId)
    if not dealership then return false, "Dealership not found." end

    if not PlayerCanAccessDealership(source, dealership) then
        return false, _L("error_access_denied")
    end

    if not PlayerMeetsMinGrade(source, dealership, stockItem) then
        return false, _L("error_grade_too_low")
    end

    local price = stockItem.retail_price
    local discount = 0
    if couponCode and couponCode ~= "" then
        discount = ValidateCoupon(dealershipId, couponCode, price, identifier) or 0
    end
    local finalPrice = math.max(0, price - discount)

    -- Add-ons (custom plate, etc.) are validated up front. Pre-owned units
    -- carry their existing plate through and can't be re-plated at sale, so
    -- skip the custom-plate addon for those.
    local isUsedForAddon = stockItem.is_used == true or tonumber(stockItem.is_used) == 1
    local addonsCleaned = addons
    if isUsedForAddon and type(addons) == "table" and addons.customPlate then
        addonsCleaned = {}
        for k, v in pairs(addons) do addonsCleaned[k] = v end
        addonsCleaned.customPlate = nil
    end
    local addonOk, addonCost, customPlate, addonErr = ResolvePurchaseAddons(finalPrice, addonsCleaned)
    if not addonOk then return false, addonErr end
    finalPrice = finalPrice + (addonCost or 0)

    local societyEntry = nil
    local altCurrencyUsed = nil -- populated when paymentMethod begins with "alt:"
    if type(paymentMethod) == "string" and paymentMethod:sub(1, 4) == "alt:" then
        local key = paymentMethod:sub(5)
        local def = GetAltCurrency and GetAltCurrency(key) or nil
        if not def then
            return false, _L("error_alt_currency_unavailable")
        end

        -- Dealership must opt into this currency.
        local meta = dealership.metadata
        if type(meta) == "string" then meta = json.decode(meta) or {} end
        local accepted = type(meta) == "table" and meta.acceptedAltCurrencies or {}
        local ok = false
        for _, k in ipairs(accepted) do if k == key then ok = true; break end end
        if not ok then
            return false, _L("error_alt_currency_not_accepted")
        end

        local native = AltCurrencyNativeAmount(def, finalPrice)
        local balance = tonumber(def.get(source)) or 0
        if balance < native then
            return false, _L("error_alt_currency_insufficient", def.label or key)
        end
        if not def.remove(source, native) then
            return false, _L("error_alt_currency_insufficient", def.label or key)
        end
        altCurrencyUsed = { key = key, label = def.label or key, native = native }
    elseif paymentMethod == "society" then
        societyEntry = MatchSocietyAllowlist(source, dealership)
        if not societyEntry then
            return false, _L("error_not_in_allowlist")
        end

        local societyName = societyEntry.name
        local balance = 0
        local done = false
        GetSocietyBalance(societyName, function(b) balance = tonumber(b) or 0; done = true end)
        local waited = 0
        while not done and waited < 3000 do
            Wait(25); waited = waited + 25
        end
        if balance < finalPrice then
            return false, _L("error_society_insufficient")
        end
        if RemoveSocietyMoney(societyName,finalPrice)~=true then return false,"Society debit could not be confirmed" end
    else
        -- Cash / bank. Dealerships can disable either to force alt-currency sales
        -- (e.g. donator-only shops). Default both on when the flag is unset.
        local basePaymentMeta = dealership.metadata
        if type(basePaymentMeta) == "string" then basePaymentMeta = json.decode(basePaymentMeta) or {} end
        local baseCfg = type(basePaymentMeta) == "table" and basePaymentMeta.acceptedBasePayments or nil
        local cashOn = not baseCfg or baseCfg.cash ~= false
        local bankOn = not baseCfg or baseCfg.bank ~= false
        if paymentMethod == "bank" and not bankOn then
            return false, _L("error_payment_method_disabled") or "This dealership doesn't accept bank payments."
        end
        if (paymentMethod == "cash" or paymentMethod == "money") and not cashOn then
            return false, _L("error_payment_method_disabled") or "This dealership doesn't accept cash payments."
        end

        local currency = "money"
        if paymentMethod == "bank" then
            currency = "bank"
        end

        -- Check funds
        local playerMoney = GetMoney(source, currency)
        if playerMoney < finalPrice then
            return false, "Insufficient funds."
        end

        -- Deduct money
        if RemoveMoney(source,finalPrice,currency)~=true then return false,"Payment rejected" end
    end

    -- Register vehicle with a single, authoritative plate
    local isUsed = stockItem.is_used == true or tonumber(stockItem.is_used) == 1
    local plate
    local props
    if isUsed and stockItem.plate and stockItem.plate ~= '' then
        plate = stockItem.plate
        props = stockItem.metadata
        if type(props) == 'string' then props = json.decode(props) or {} end
        if type(props) ~= 'table' then props = {} end
        props.plate = plate

        -- Strip paint-related keys so qbx_garages doesn't override LS Customs
        -- paint on every respawn. The customer is buying the pre-owned car
        -- with whatever colors were captured, but going forward we let the
        -- player's paint shop changes survive normal garage round-trips.
        -- (modSmokeEnabled is a tire-smoke flag; safe to strip together.)
        local PAINT_KEYS = {
            'color1', 'color2', 'pearlescentColor', 'wheelColor',
            'interiorColor', 'dashboardColor', 'xenonColor', 'tyreSmokeColor',
            'modSmokeEnabled', 'windowTint', 'paintType',
            'customPrimaryColor', 'customSecondaryColor',
        }
        for _, k in ipairs(PAINT_KEYS) do props[k] = nil end
    else
        plate = customPlate or GeneratePlate()
        props = { plate = plate }

        -- Persist the customer-chosen color so the first garage store/respawn
        -- keeps the paint they picked at the dealership. `stockItem.color` is
        -- written by stock/server.lua as JSON; getVehicleDetails has already
        -- decoded it here. Two shapes supported:
        --   1) RGB table:   { r,g,b, secondary = { r,g,b } | nil }
        --   2) Paletted:    a number, or { primary = N, secondary = N }
        local chosen = stockItem.color
        if type(chosen) == 'string' then chosen = json.decode(chosen) end
        if type(chosen) == 'table' then
            if chosen.r ~= nil and chosen.g ~= nil and chosen.b ~= nil then
                local primary = { tonumber(chosen.r) or 0, tonumber(chosen.g) or 0, tonumber(chosen.b) or 0 }
                local secondary = primary
                if type(chosen.secondary) == 'table' and chosen.secondary.r ~= nil then
                    secondary = { tonumber(chosen.secondary.r) or 0, tonumber(chosen.secondary.g) or 0, tonumber(chosen.secondary.b) or 0 }
                end
                props.customPrimaryColor = primary
                props.customSecondaryColor = secondary
            elseif chosen.primary ~= nil or chosen.secondary ~= nil then
                local p = tonumber(chosen.primary)
                local s = tonumber(chosen.secondary) or p
                if p then props.color1 = p end
                if s then props.color2 = s end
            end
        elseif type(chosen) == 'number' then
            props.color1 = chosen
            props.color2 = chosen
        end
    end
    if AddOwnedVehicleWithProps(source,stockItem.vehicle_model,plate,props)~=true then error('Vehicle ownership insert rejected') end
    DealerGrantedVehicle(source,plate)


    -- Mark stock as sold
    MarkStockSold(stockItem.id, identifier, soldByCitizenid)

    -- Calculate tax and net revenue
    local salesTax = math.floor(finalPrice * Config.SalesTax)
    local netRevenue = finalPrice - salesTax

    -- Add revenue to dealership balance
    AddDealershipBalance(dealershipId, netRevenue)

    -- Ledger: sale
    local ledgerDesc = ("Vehicle sold: %s for %s"):format(stockItem.vehicle_label or stockItem.vehicle_model, GetCurrencyString(finalPrice))
    if societyEntry then
        ledgerDesc = ledgerDesc .. (" (society: %s:%s)"):format(societyEntry.type, societyEntry.name)
    elseif altCurrencyUsed then
        ledgerDesc = ledgerDesc .. (" (alt: %s x%d)"):format(altCurrencyUsed.key, altCurrencyUsed.native)
    end
    AddLedgerEntry(dealershipId, "sale", finalPrice, ledgerDesc, identifier)

    -- Ledger: tax
    if salesTax > 0 then
        AddLedgerEntry(dealershipId, "tax", -salesTax, ("Sales tax on %s"):format(stockItem.vehicle_label or stockItem.vehicle_model), nil)
    end

    -- Commission
    if soldByCitizenid and soldByCitizenid~=identifier then
        -- Lookup priority: per-employee override → dealership grade-based rate (using the seller's
        -- REAL framework job grade, never a synthetic role label) → Config.DefaultCommission.
        local empRow = MySQL.single.await(
            "SELECT `commission_rate` FROM `pickle_dealership_employees` WHERE `dealership_id` = ? AND `identifier` = ? LIMIT 1",
            { tonumber(dealershipId), soldByCitizenid }
        )

        local commissionRate = Config.DefaultCommission or 0.08
        local empOverride = empRow and tonumber(empRow.commission_rate)
        if empOverride and empOverride > 0 then
            -- DB stores percentage (0-100); normalise to decimal.
            commissionRate = empOverride / 100
        else
            local meta = dealership and dealership.metadata
            if type(meta) == "string" then meta = json.decode(meta) or {} end
            if dealership and type(meta) == "table" and type(meta.commissionRates) == "table" and dealership.job and dealership.job ~= "" then
                local sellerSource = GetSourceFromIdentifier(soldByCitizenid)
                local sellerGrade = sellerSource and GetPlayerJobGrade and GetPlayerJobGrade(sellerSource) or nil
                if sellerGrade then
                    -- commissionRates is stored with string keys (JSON normalisation) keyed by level.
                    local gradeRate = meta.commissionRates[tostring(sellerGrade)] or meta.commissionRates[sellerGrade]
                    if gradeRate then
                        commissionRate = tonumber(gradeRate) / 100
                    end
                end
            end
        end

        -- Commission is a percentage of PROFIT (sale price minus what the
        -- dealership paid for the unit), not of the sale price itself. Losses
        -- on a sale yield no commission.
        local wholesaleCost = tonumber(stockItem.wholesale_cost) or 0
        local profit = math.max(0, finalPrice - wholesaleCost)
        local commission = math.floor(profit * commissionRate)
        if commission > 0 then
            -- Deduct commission from dealership balance
            AddDealershipBalance(dealershipId, -commission)

            -- Pay the salesperson
            local sellerSource = GetSourceFromIdentifier(soldByCitizenid)
            DealerCredit(soldByCitizenid,commission,"bank","commission:"..stockItem.id..":"..identifier)

            AddLedgerEntry(dealershipId, "commission", -commission, ("Commission to salesperson for %s"):format(stockItem.vehicle_label or stockItem.vehicle_model), soldByCitizenid)
        end
    end

    -- Notify
    -- Award dealership XP (progression / auto-tier).
    if AwardDealershipXP then
        local cfg = Config.DealershipProgression or {}
        local xp = (cfg.xpPerSale or 0) + math.floor(finalPrice * (cfg.xpPerSaleRevenueRate or 0))
        AwardDealershipXP(dealershipId, xp)
    end

    -- Purchase success toast is delivered by the NUI wrapper on the buyer's client
    -- (sales_purchase_success); skip the server-side dupe.

    debugPrint(("[Sales] Player %s purchased %s (stock #%d) for %s"):format(identifier, stockItem.vehicle_model, stockItem.id, GetCurrencyString(finalPrice)))

    LogDiscord("sales", {
        title = isUsed and "Pre-Owned Sale" or "Vehicle Sale",
        actor = source,
        dealershipId = dealershipId,
        fields = {
            { name = "Dealership", value = dealership and dealership.name or "?", inline = true },
            { name = "Vehicle", value = (stockItem.vehicle_label or stockItem.vehicle_model) .. " (`" .. (stockItem.vehicle_model or "?") .. "`)", inline = true },
            { name = "Plate", value = "`" .. tostring(plate or "?") .. "`", inline = true },
            { name = "Price", value = GetCurrencyString(finalPrice), inline = true },
            { name = "Payment", value = tostring(altCurrencyUsed and altCurrencyUsed.key or paymentMethod or "?"), inline = true },
            { name = "Salesperson", value = tostring(soldByCitizenid and ("`" .. soldByCitizenid .. "`") or "self-service"), inline = true },
        },
    })

    return true, plate, finalPrice
end

-- ─── Callbacks ──────────────────────────────────────────────────────────────

-- Optional usable item that opens the dealership sales tablet for an employee
-- from anywhere on the map. Item name is set via Config.SalesTabletItem; if
-- nil/empty, the command-only path (/dealertablet) is the only entry point.
CreateThread(function()
    Wait(0) -- let the bridge load
    if not Config or type(Config.SalesTabletItem) ~= 'string' or Config.SalesTabletItem == '' then return end
    if not RegisterUsableItem then return end
    RegisterUsableItem(Config.SalesTabletItem, function(source)
        TriggerClientEvent("pickle_dealerships:openSalesTablet", source)
    end)
end)

--- Powers the /dealertablet remote entry point. Returns every dealership the
--- caller can sell at — owners, managers, and salespersons. Admins see every
--- dealership so they can support any operator. Used by the NUI tablet picker.
lib.callback.register("pickle_dealerships:listEmployeeDealerships", function(source)
    local identifier = GetIdentifier(source)
    if not identifier then return {} end

    local out = {}
    local seen = {}

    if IsPlayerAdmin(source) then
        local rows = MySQL.query.await(
            "SELECT id, name, location FROM pickle_dealerships ORDER BY name ASC"
        ) or {}
        for _, r in ipairs(rows) do
            seen[r.id] = true
            out[#out + 1] = { id = r.id, name = r.name, location = r.location, role = "admin" }
        end
        return out
    end

    -- Owner rows
    local ownerRows = MySQL.query.await(
        "SELECT id, name, location FROM pickle_dealerships WHERE owner_identifier = ? ORDER BY name ASC",
        { identifier }
    ) or {}
    for _, r in ipairs(ownerRows) do
        if not seen[r.id] then
            seen[r.id] = true
            out[#out + 1] = { id = r.id, name = r.name, location = r.location, role = "owner" }
        end
    end

    -- Employee rows
    local empRows = MySQL.query.await([[
        SELECT d.id, d.name, d.location, e.role
          FROM pickle_dealership_employees e
          JOIN pickle_dealerships d ON d.id = e.dealership_id
         WHERE e.identifier = ?
         ORDER BY d.name ASC
    ]], { identifier }) or {}
    for _, r in ipairs(empRows) do
        if not seen[r.id] then
            seen[r.id] = true
            out[#out + 1] = { id = r.id, name = r.name, location = r.location, role = r.role }
        end
    end

    return out
end)

--- All online players, returned to a dealership employee for the tablet's
--- "send invoice" search box. Employee-only at the requested dealership.
--- Identifier is included so the search box can match against IDs / cid as
--- well as character name (mirrors the admin-panel transfer-owner UX).
lib.callback.register("pickle_dealerships:listOnlinePlayersForSale", function(source, data)
    local dealershipId = tonumber(data and data.dealershipId)
    if not dealershipId or not CanPlayerSell(source, dealershipId) then return {} end

    local out = {}
    for _, pid in ipairs(GetPlayers()) do
        local pidNum = tonumber(pid)
        if pidNum and pidNum ~= source then
            local charName = GetPlayerCharacterName and GetPlayerCharacterName(pidNum) or nil
            out[#out + 1] = {
                source = pidNum,
                name = charName or GetPlayerName(pidNum),
                identifier = GetIdentifier and GetIdentifier(pidNum) or "",
            }
        end
    end
    table.sort(out, function(a, b) return (a.name or "") < (b.name or "") end)
    return out
end)

--- Returns nearby player IDs so the tablet's "send invoice" picker can list
--- candidates without exposing the whole server roster. Employee-only.
lib.callback.register("pickle_dealerships:listNearbyPlayers", function(source, data)
    local dealershipId = tonumber(data and data.dealershipId)
    if not dealershipId or not CanPlayerSell(source, dealershipId) then return {} end

    local srcPed = GetPlayerPed(source)
    if not srcPed or srcPed == 0 then return {} end
    local srcCoords = GetEntityCoords(srcPed)

    local radius = tonumber(data and data.radius) or 25.0
    local out = {}
    for _, pid in ipairs(GetPlayers()) do
        local pidNum = tonumber(pid)
        if pidNum and pidNum ~= source then
            local ped = GetPlayerPed(pidNum)
            if ped and ped ~= 0 then
                local coords = GetEntityCoords(ped)
                local dist = #(srcCoords - coords)
                if dist <= radius then
                    out[#out + 1] = {
                        id = pidNum,
                        name = GetPlayerCharacterName and GetPlayerCharacterName(pidNum) or GetPlayerName(pidNum),
                        distance = math.floor(dist + 0.5),
                    }
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.distance < b.distance end)
    return out
end)

lib.callback.register("pickle_dealerships:purchaseVehicle", function(source, data)
    local dealershipId = tonumber(data.dealershipId)
    local stockId = tonumber(data.stockId)
    local paymentMethod = data.paymentMethod or "cash"
    local couponCode = data.couponCode
    if not dealershipId or not stockId then
        return { success = false, message = "Invalid request." }
    end

    if not AcquireStockLock(stockId) then
        return { success = false, message = "Vehicle has already been sold." }
    end

    local dealership = GetDealership(dealershipId)
    if not dealership then
        ReleaseStockLock(stockId)
        return { success = false, message = "Dealership not found." }
    end

    -- "Speak to an employee" mode: when the owner has disabled customer
    -- self-purchase, only employees may run a purchase through this callback.
    -- Employee-driven sales go through `confirmEmployeeSale` and are unaffected.
    local meta = dealership.metadata
    if type(meta) == "string" then meta = json.decode(meta) or {} end
    if type(meta) == "table" and meta.disableSelfPurchase == true and not CanPlayerSell(source, dealershipId) then
        ReleaseStockLock(stockId)
        return { success = false, message = _L("error_self_purchase_disabled") }
    end

    local stockItem = GetStockItem(stockId)
    if not stockItem then
        ReleaseStockLock(stockId)
        return { success = false, message = "Vehicle not found in stock." }
    end
    if stockItem.dealership_id ~= dealershipId then
        ReleaseStockLock(stockId)
        return { success = false, message = "Vehicle does not belong to this dealership." }
    end
    if not stockItem.delivered_at then
        ReleaseStockLock(stockId)
        return { success = false, message = "Vehicle has not been delivered yet." }
    end
    if stockItem.sold_at then
        ReleaseStockLock(stockId)
        return { success = false, message = "Vehicle has already been sold." }
    end
    if stockItem.unlisted == 1 or stockItem.unlisted == true then
        ReleaseStockLock(stockId)
        return { success = false, message = "This vehicle is not available for purchase." }
    end

    local success, plate, finalPrice = ProcessSale(source, dealershipId, stockItem, paymentMethod, couponCode, nil, data.addons)
    ReleaseStockLock(stockId)
    if not success then
        return { success = false, message = plate } -- plate holds error message on failure
    end

    -- If the customer redeemed an inventory coupon item via the picker, burn
    -- one copy. The discount itself was already applied inside ProcessSale.
    if couponCode and couponCode ~= "" and data.couponItemSlot then
        ConsumeCouponItem(source, data.couponItemSlot)
    end

    return {
        success = true,
        plate = plate,
        price = finalPrice,
        model = stockItem.vehicle_model,
        label = stockItem.vehicle_label or stockItem.vehicle_model,
        -- Surface the dealership's location key so the client picks up
        -- the correct spawnPoint from DealershipConfigs instead of the
        -- first dealership it happens to iterate over.
        location = dealership.location,
    }
end)

lib.callback.register("pickle_dealerships:employeeSale", function(source, data)
    local dealershipId = tonumber(data.dealershipId)
    local stockId = tonumber(data.stockId)
    local targetPlayerId = tonumber(data.targetPlayerId)
    local couponCode = data.couponCode
    if not dealershipId or not stockId or not targetPlayerId then
        return { success = false, message = "Invalid request." }
    end

    -- Verify the employee can sell
    if not CanPlayerSell(source, dealershipId) then
        return { success = false, message = "You do not have permission to sell vehicles." }
    end

    if not AcquireStockLock(stockId) then
        return { success = false, message = "Vehicle has already been sold." }
    end

    local dealership = GetDealership(dealershipId)
    if not dealership then
        ReleaseStockLock(stockId)
        return { success = false, message = "Dealership not found." }
    end

    local stockItem = GetStockItem(stockId)
    if not stockItem then
        ReleaseStockLock(stockId)
        return { success = false, message = "Vehicle not found in stock." }
    end
    if stockItem.dealership_id ~= dealershipId then
        ReleaseStockLock(stockId)
        return { success = false, message = "Vehicle does not belong to this dealership." }
    end
    if not stockItem.delivered_at then
        ReleaseStockLock(stockId)
        return { success = false, message = "Vehicle has not been delivered yet." }
    end
    if stockItem.sold_at then
        ReleaseStockLock(stockId)
        return { success = false, message = "Vehicle has already been sold." }
    end

    -- Verify target player exists
    local targetName = GetPlayerName(targetPlayerId)
    if not targetName then
        ReleaseStockLock(stockId)
        return { success = false, message = "Target player not found." }
    end

    local sellerCitizenid = GetIdentifier(source)

    -- Use custom price if provided, otherwise use retail price
    local salePrice = data.price and tonumber(data.price) or stockItem.retail_price
    if salePrice and salePrice ~= stockItem.retail_price then
        -- Update the retail price temporarily for this sale
        stockItem.retail_price = salePrice
    end

    DealerOffers[targetPlayerId]={dealershipId=dealershipId,stockId=stockId,price=stockItem.retail_price,couponCode=couponCode,
        soldBy=sellerCitizenid,buyer=GetIdentifier(targetPlayerId),expires=os.time()+120}
    -- Trigger confirmation on the target player's client
    TriggerClientEvent("pickle_dealerships:confirmPurchase", targetPlayerId, {
        dealershipId = dealershipId,
        stockId = stockId,
        model = stockItem.vehicle_model,
        label = stockItem.vehicle_label or stockItem.vehicle_model,
        price = stockItem.retail_price,
        couponCode = couponCode,
        soldBy = sellerCitizenid,
        sellerName = GetPlayerCharacterName(source),
        -- Dealership location key so the customer's client resolves the
        -- correct spawnPoint on its own DealershipConfigs.
        location = dealership.location,
    })

    -- Release the inflight lock — the actual claim happens when the
    -- customer confirms via confirmEmployeeSale, which re-acquires it.
    ReleaseStockLock(stockId)
    return { success = true, message = "Purchase confirmation sent to customer." }
end)

-- Handle confirmed employee sale from the target player
lib.callback.register("pickle_dealerships:confirmEmployeeSale", function(source, data)
    local dealershipId = tonumber(data.dealershipId)
    local stockId = tonumber(data.stockId)
    local paymentMethod = data.paymentMethod or "bank"
    local couponCode = data.couponCode
    local soldBy = data.soldBy

    if not dealershipId or not stockId then
        return { success = false, message = "Invalid request." }
    end

    if not AcquireStockLock(stockId) then
        return { success = false, message = "Vehicle has already been sold." }
    end

    local stockItem = GetStockItem(stockId)
    if not stockItem then
        ReleaseStockLock(stockId)
        return { success = false, message = "Vehicle no longer available." }
    end
    if stockItem.sold_at then
        ReleaseStockLock(stockId)
        return { success = false, message = "Vehicle has already been sold." }
    end

    -- Override retail price if custom price was set
    if data.price then
        stockItem.retail_price = tonumber(data.price)
    end

    local dealership = GetDealership(dealershipId)
    if not dealership then
        ReleaseStockLock(stockId)
        return { success = false, message = "Dealership not found." }
    end

    local success, plate, finalPrice = ProcessSale(source, dealershipId, stockItem, paymentMethod, couponCode, soldBy, data.addons)
    ReleaseStockLock(stockId)
    if not success then
        -- Server-authored decline notification to the seller — the customer
        -- failed payment or hit some other gate during ProcessSale.
        if soldBy then
            local sellerSrc = GetSourceFromIdentifier and GetSourceFromIdentifier(soldBy) or nil
            if sellerSrc then
                ShowNotification(sellerSrc, _L("sales_seller_declined",
                    GetPlayerCharacterName and GetPlayerCharacterName(source) or GetPlayerName(source) or "Customer",
                    stockItem.vehicle_label or stockItem.vehicle_model
                ))
            end
        end
        return { success = false, message = plate }
    end

    if couponCode and couponCode ~= "" and data.couponItemSlot then
        ConsumeCouponItem(source, data.couponItemSlot)
    end

    -- Notify the seller their pending sale closed successfully.
    if soldBy then
        local sellerSrc = GetSourceFromIdentifier and GetSourceFromIdentifier(soldBy) or nil
        if sellerSrc then
            ShowNotification(sellerSrc, _L("sales_seller_success",
                GetPlayerCharacterName and GetPlayerCharacterName(source) or GetPlayerName(source) or "Customer",
                stockItem.vehicle_label or stockItem.vehicle_model,
                GetCurrencyString(finalPrice)
            ))
        end
    end

    return {
        success = true,
        plate = plate,
        price = finalPrice,
        model = stockItem.vehicle_model,
        label = stockItem.vehicle_label or stockItem.vehicle_model,
        location = dealership.location,
    }
end)

--- Customer-fired event when they cancel the confirm or payment dialog.
--- Server resolves the seller's source and notifies them so the salesperson
--- knows the prompt was rejected. Trusting `soldBy` from the client is fine
--- here because the only effect is a localized toast at the seller; the
--- player can't escalate it into anything else.
RegisterNetEvent("pickle_dealerships:saleDeclined", function(data)
    local source = source
    local offer=DealerOffers[source]
    if not offer or offer.buyer~=GetIdentifier(source) then return end
    DealerOffers[source]=nil
    local soldBy = offer.soldBy
    if type(soldBy) ~= "string" or soldBy == "" then return end
    local sellerSrc = GetSourceFromIdentifier and GetSourceFromIdentifier(soldBy) or nil
    if not sellerSrc then return end
    ShowNotification(sellerSrc, _L("sales_seller_declined",
        GetPlayerCharacterName and GetPlayerCharacterName(source) or GetPlayerName(source) or "Customer",
        data.label or "the vehicle"
    ))
end)

--- Returns the alt payment methods this dealership accepts, including the
--- calling player's balance and the native amount needed for `price`. Called
--- by the sales UI to render dynamic payment tabs.
lib.callback.register("pickle_dealerships:getAltPaymentOptions", function(source, data)
    local dealershipId = tonumber(data and data.dealershipId)
    local price = tonumber(data and data.price) or 0
    if not dealershipId then return {} end

    local dealership = GetDealership(dealershipId)
    if not dealership then return {} end

    local meta = dealership.metadata
    if type(meta) == "string" then meta = json.decode(meta) or {} end
    local accepted = type(meta) == "table" and meta.acceptedAltCurrencies or {}

    local out = {}
    for _, key in ipairs(accepted) do
        local def = GetAltCurrency and GetAltCurrency(key) or nil
        if def then
            local native = AltCurrencyNativeAmount(def, price)
            local balance = tonumber(def.get(source)) or 0
            out[#out + 1] = {
                key = key,
                label = def.label or key,
                type = def.type,
                valuePerUnit = def.valuePerUnit,
                balance = balance,
                required = native,
                canAfford = balance >= native,
            }
        end
    end
    return out
end)

lib.callback.register("pickle_dealerships:getVehicleDetails", function(source, data)
    local stockId = tonumber(data.stockId)
    if not stockId then return nil end

    local stockItem = GetStockItem(stockId)
    if not stockItem then return nil end
    if stockItem.unlisted == 1 or stockItem.unlisted == true then return nil end

    -- Parse color JSON if stored as string
    local color = stockItem.color
    if color and type(color) == "string" then
        color = json.decode(color)
    end

    -- Pre-owned units store the full vehicle property blob in `metadata`
    local isUsed = stockItem.is_used == true or tonumber(stockItem.is_used) == 1
    local properties = nil
    if isUsed then
        properties = stockItem.metadata
        if properties and type(properties) == "string" then
            properties = json.decode(properties)
        end
    end

    return {
        id = stockItem.id,
        dealershipId = stockItem.dealership_id,
        model = stockItem.vehicle_model,
        label = stockItem.vehicle_label or stockItem.vehicle_model,
        price = stockItem.retail_price,
        wholesaleCost = stockItem.wholesale_cost,
        color = color,
        condition = stockItem.condition,
        displaySpot = stockItem.display_spot,
        delivered = stockItem.delivered_at ~= nil,
        sold = stockItem.sold_at ~= nil,
        soldTo = stockItem.sold_to,
        soldBy = stockItem.sold_by,
        orderedAt = stockItem.ordered_at,
        deliveredAt = stockItem.delivered_at,
        soldAt = stockItem.sold_at,
        isUsed = isUsed,
        plate = stockItem.plate,
        acquiredFrom = stockItem.acquired_from,
        properties = properties,
    }
end)

lib.callback.register("pickle_dealerships:getPickleFax", function(_, data)
    local stockId = tonumber(data and data.stockId)
    if not stockId then return nil end

    local stockItem = GetStockItem(stockId)
    if not stockItem then return nil end

    local isUsed = stockItem.is_used == true or tonumber(stockItem.is_used) == 1
    if not isUsed then return nil end

    local properties = stockItem.metadata
    if properties and type(properties) == "string" then
        properties = json.decode(properties)
    end

    return {
        id = stockItem.id,
        model = stockItem.vehicle_model,
        label = stockItem.vehicle_label or stockItem.vehicle_model,
        isUsed = true,
        condition = tonumber(stockItem.condition) or 0,
        plate = stockItem.plate,
        acquiredFrom = stockItem.acquired_from,
        orderedAt = stockItem.ordered_at,
        deliveredAt = stockItem.delivered_at,
        retailPrice = stockItem.retail_price,
        wholesaleCost = stockItem.wholesale_cost,
        properties = properties,
    }
end)
