-- =============================================
--  pickle_dealerships | modules/financing/server.lua
--  Vehicle financing system — per-dealership settings, create/pay/repo
-- =============================================

-- ─── Helpers ────────────────────────────────────────────────────────────────

local function GetStockItem(stockId)
    local rows = MySQL.query.await(
        "SELECT * FROM `pickle_dealership_stock` WHERE `id` = ? LIMIT 1",
        { tonumber(stockId) }
    )
    local row=rows and rows[1]
    if row and row.auction_id then return nil end
    return row
end

local function MarkStockSold(stockId,buyer,seller)
    local stock=MySQL.single.await('SELECT * FROM pickle_dealership_stock WHERE id=?',{stockId})
    if not stock or stock.sold_at or stock.auction_id then error('Stock is no longer available') end
    if tonumber(stock.quantity or 1)>1 then
        local ok=MySQL.transaction.await({
            {query='UPDATE pickle_dealership_stock SET quantity=quantity-1 WHERE id=? AND sold_at IS NULL AND quantity>1',values={stockId}},
            {query=[[
                INSERT INTO pickle_dealership_stock (dealership_id,vehicle_model,vehicle_label,wholesale_cost,retail_price,quantity,ordered_at,delivered_at,sold_at,sold_to,sold_by,acquired_from)
                VALUES (?,?,?,?,?,1,NOW(),NOW(),NOW(),?,?,?)
            ]],values={stock.dealership_id,stock.vehicle_model,stock.vehicle_label,stock.wholesale_cost,stock.retail_price,buyer,seller or buyer,stock.acquired_from or 'finance_sale'}},
        })
        if not ok then error('Stock split failed') end
    else
        local rows=MySQL.update.await('UPDATE pickle_dealership_stock SET sold_at=NOW(),sold_to=?,sold_by=? WHERE id=? AND sold_at IS NULL AND auction_id IS NULL',{buyer,seller,stockId})
        if rows~=1 then error('Stock claim failed') end
    end
    return true
end

local function AddDealershipBalance(dealershipId, amount)
    MySQL.update.await(
        "UPDATE `pickle_dealerships` SET `balance` = `balance` + ? WHERE `id` = ?",
        { tonumber(amount), tonumber(dealershipId) }
    )
    local freshBalance = MySQL.scalar.await(
        "SELECT `balance` FROM `pickle_dealerships` WHERE `id` = ?",
        { tonumber(dealershipId) }
    )
    if freshBalance then
        UpdateDealershipCache(dealershipId, { balance = tonumber(freshBalance) })
    end
end

-- ─── Per-Dealership Financing Settings ──────────────────────────────────────

local DEFAULT_SETTINGS = {
    financingEnabled = true,
    minDownPercent = 30,
    interestRate = 5,
    paymentIntervalHours = 24,
    maxMissedPayments = 3,
    installmentOptions = { 4, 8, 12 },
    -- Credit score gate. The per-dealership toggle is meaningful only when
    -- Config.CreditScore.enabled is true on the server; otherwise the check
    -- silently no-ops. minCreditScore clamps to the typical FICO range.
    requireCreditScore = false,
    minCreditScore = 600,
}

local function GetFinancingSettings(dealershipId)
    local dealership = GetDealership(dealershipId)
    if not dealership then return DEFAULT_SETTINGS end

    -- Merge DB-stored settings over defaults
    local settings = {}
    for k, v in pairs(DEFAULT_SETTINGS) do settings[k] = v end

    local stored = dealership.financing_settings
    if stored then
        if type(stored) == "string" then stored = json.decode(stored) end
        if type(stored) == "table" then
            for k, v in pairs(stored) do
                if DEFAULT_SETTINGS[k] ~= nil then settings[k] = v end
            end
        end
    end

    -- Override with global Config as fallbacks (for legacy compat)
    if not dealership.financing_settings then
        settings.minDownPercent = (Config.FinancingMinDown or 0.30) * 100
        settings.interestRate = (Config.FinancingInterest or 0.05) * 100
        settings.paymentIntervalHours = Config.FinancingPaymentInterval or 24
        settings.maxMissedPayments = Config.FinancingMaxMissed or 3
    end

    -- Backfill any keys still missing (e.g. row exists but has a partial blob).
    -- Prevents the customer UI from receiving nil for fields like minDownPercent
    -- and rendering $0 down payments.
    for k, v in pairs(DEFAULT_SETTINGS) do
        if settings[k] == nil then settings[k] = v end
    end

    return settings
end

lib.callback.register("pickle_dealerships:getFinancingSettings", function(_, data)
    local dealershipId = tonumber(data and data.dealershipId)
    if not dealershipId then return nil end

    local dealership = GetDealership(dealershipId)
    if not dealership then return nil end

    -- Financing used to be tier-gated; it's now available to every dealership.
    -- The owner can still toggle financing off via updateFinancingSettings, and
    -- the customer-facing UI reads `financingEnabled` off the returned blob.
    local blob = GetFinancingSettings(dealershipId)
    -- Surface whether a real credit-score provider is wired up so the
    -- settings UI can grey out / annotate the toggle instead of letting an
    -- owner enable a requirement that will never run.
    blob.creditScoreProviderActive = IsCreditScoreProviderActive()
    return blob
end)

lib.callback.register("pickle_dealerships:updateFinancingSettings", function(source, data)
    local dealershipId = tonumber(data and data.dealershipId)
    if not dealershipId then return false, "Invalid request." end

    local role = GetPlayerDealershipRole(source, dealershipId)
    if role ~= 'owner' and not IsPlayerAdmin(source) then
        return false, "Only owners can change financing settings."
    end

    local settings = data.settings
    if type(settings) ~= "table" then return false, "Invalid settings." end

    -- Validate ranges
    local validated = {}
    validated.financingEnabled = settings.financingEnabled ~= false
    validated.minDownPercent = math.max(10, math.min(90, tonumber(settings.minDownPercent) or 30))
    validated.interestRate = math.max(0, math.min(50, tonumber(settings.interestRate) or 5))
    validated.paymentIntervalHours = math.max(1, math.min(168, tonumber(settings.paymentIntervalHours) or 24))
    validated.maxMissedPayments = math.max(1, math.min(10, tonumber(settings.maxMissedPayments) or 3))
    validated.requireCreditScore = settings.requireCreditScore == true
    validated.minCreditScore = math.max(300, math.min(850, tonumber(settings.minCreditScore) or 600))

    local opts = settings.installmentOptions
    if type(opts) == "table" and #opts > 0 then
        local validOpts = {}
        for _, v in ipairs(opts) do
            local n = tonumber(v)
            if n and n >= 2 and n <= 48 then validOpts[#validOpts + 1] = n end
        end
        table.sort(validOpts)
        validated.installmentOptions = #validOpts > 0 and validOpts or { 4, 8, 12 }
    else
        validated.installmentOptions = { 4, 8, 12 }
    end

    MySQL.update.await(
        "UPDATE `pickle_dealerships` SET `financing_settings` = ? WHERE `id` = ?",
        { json.encode(validated), dealershipId }
    )

    -- Refresh cache
    UpdateDealershipCache(dealershipId, { financing_settings = json.encode(validated) })

    return true
end)

-- ─── Create Financing ───────────────────────────────────────────────────────

--- Returns the player's cash + bank balances (for the financing dialog's pre-flight funds check)
lib.callback.register("pickle_dealerships:getPlayerBalances", function(source)
    return {
        cash = GetMoney(source, "money") or 0,
        bank = GetMoney(source, "bank") or 0,
    }
end)

lib.callback.register("pickle_dealerships:createFinancing", function(source, data)
    return DealerTransaction(source, function(transaction)
        if type(data) ~= 'table' then return {success=false, message='Invalid request.'} end
        local dealershipId = tonumber(data.dealershipId)
        local stockId = tonumber(data.stockId)
        local downPayment = tonumber(data.downPayment) or 0
        local installments = tonumber(data.installments) or 12
        local paymentMethod = data.paymentMethod == "cash" and "money" or "bank"

        if not dealershipId or not stockId then
            return { success = false, message = "Invalid request." }
        end

        local dealership = GetDealership(dealershipId)
        if not dealership then
            return { success = false, message = "Dealership not found." }
        end

        -- Financing is no longer tier-gated. The dealership-level toggle below
        -- (settings.financingEnabled) is the only remaining gate, so owners can
        -- still opt out per-shop without admin intervention.
        local settings = GetFinancingSettings(dealershipId)
        if not settings.financingEnabled then
            return { success = false, message = "Financing is currently disabled at this dealership." }
        end

        -- Same self-purchase gate as the cash/bank path. Customers must talk to an
        -- employee when this toggle is on; the employee uses the tablet flow.
        local meta = dealership.metadata
        if type(meta) == "string" then meta = json.decode(meta) or {} end
        if type(meta) == "table" and meta.disableSelfPurchase == true and not CanPlayerSell(source, dealershipId) then
            return { success = false, message = _L("error_self_purchase_disabled") }
        end

        if not AcquireStockLock(stockId, transaction) then
            return { success = false, message = "Vehicle has already been sold." }
        end

        local stockItem = GetStockItem(stockId)
        if not stockItem then
            ReleaseStockLock(stockId, transaction)
            return { success = false, message = "Vehicle not found in stock." }
        end
        if stockItem.dealership_id ~= dealershipId then
            ReleaseStockLock(stockId, transaction)
            return { success = false, message = "Vehicle does not belong to this dealership." }
        end
        if not stockItem.delivered_at then
            ReleaseStockLock(stockId, transaction)
            return { success = false, message = "Vehicle has not been delivered yet." }
        end
        if stockItem.sold_at then
            ReleaseStockLock(stockId, transaction)
            return { success = false, message = "Vehicle has already been sold." }
        end
        if stockItem.auction_id then
            ReleaseStockLock(stockId, transaction)
            return { success = false, message = "Vehicle is currently at auction." }
        end

        -- Validate installment count is in the allowed options
        local validInstallments = false
        for _, opt in ipairs(settings.installmentOptions or { 4, 8, 12 }) do
            if opt == installments then validInstallments = true break end
        end
        if not validInstallments then
            ReleaseStockLock(stockId, transaction)
            return { success = false, message = "Invalid installment plan." }
        end

        -- Coupon: applied to the vehicle's retail price BEFORE the down/financed
        -- split, so the minimum-down% is calculated on the discounted price and
        -- interest accrues on the lower financed balance. ValidateCoupon atomically
        -- increments the uses counter, so we only call it once we know the rest of
        -- the deal is going through (after stock + installment validation).
        local price = stockItem.retail_price
        local couponDiscount = 0
        local couponRow = nil
        if data.couponCode and data.couponCode ~= "" then
            couponDiscount, couponRow = ValidateCoupon(dealershipId, data.couponCode, price, GetIdentifier(source), stockItem, transaction)
            if not couponDiscount or couponDiscount <= 0 then
                ReleaseStockLock(stockId, transaction)
                return { success = false, message = _L("coupon_invalid") or "Invalid coupon code." }
            end
            price = math.max(0, price - couponDiscount)
        end
        if not DealerInt(downPayment,0,2147483647) or downPayment>=price then ReleaseStockLock(stockId, transaction); return {success=false,message="Down payment must leave a positive loan balance"} end
        local minDown = math.floor(price * settings.minDownPercent / 100)

        if downPayment < minDown then
            ReleaseStockLock(stockId, transaction)
            return { success = false, message = ("Minimum down payment is %s (%d%%)."):format(GetCurrencyString(minDown), settings.minDownPercent) }
        end

        -- Resolve add-ons. The add-on cost is charged on top of the down payment
        -- (paid upfront at signing) — it does NOT get rolled into the loan
        -- balance, otherwise the customer would pay interest on personalization.
        -- Pre-owned units keep their existing plate, so the custom-plate add-on
        -- is silently dropped for them.
        local isUsedForAddon = stockItem.is_used == true or tonumber(stockItem.is_used) == 1
        local addonsCleaned = data.addons
        if isUsedForAddon and type(addonsCleaned) == "table" and addonsCleaned.customPlate then
            local tmp = {}
            for k, v in pairs(addonsCleaned) do tmp[k] = v end
            tmp.customPlate = nil
            addonsCleaned = tmp
        end
        local addonOk, addonCost, customPlate, addonErr = ResolvePurchaseAddons(price, addonsCleaned)
        if not addonOk then
            ReleaseStockLock(stockId, transaction)
            return { success = false, message = addonErr }
        end
        addonCost = addonCost or 0

        local identifier = GetIdentifier(source)
        if not identifier then
            ReleaseStockLock(stockId, transaction)
            return { success = false, message = "Could not identify player." }
        end

        -- Credit score gate. Only runs when both (a) the dealership opted in and
        -- (b) Config.CreditScore.enabled makes GetPlayerCreditScore return a real
        -- value. A nil score here means the provider is off/missing or doesn't
        -- know this player — fail closed so missing data can't be used to bypass
        -- the minimum.
        if settings.requireCreditScore and IsCreditScoreProviderActive() then
            local score = GetPlayerCreditScore(identifier)
            if not score then
                ReleaseStockLock(stockId, transaction)
                return { success = false, message = _L("financing_credit_score_unavailable") }
            end
            local required = tonumber(settings.minCreditScore) or 600
            if score < required then
                ReleaseStockLock(stockId, transaction)
                return { success = false, message = _L("financing_credit_score_too_low", required, score) }
            end
        end

        local upfrontTotal = downPayment + addonCost
        local playerMoney = GetMoney(source, paymentMethod)
        if playerMoney < upfrontTotal then
            ReleaseStockLock(stockId, transaction)
            return { success = false, message = "Insufficient funds for down payment." }
        end

        -- Calculate financing details
        local remainingBalance = price - downPayment
        local interestRate = settings.interestRate / 100
        local totalWithInterest = remainingBalance + math.floor(remainingBalance * interestRate)
        local installmentAmount = math.ceil(totalWithInterest / installments)

        -- Deduct down payment + addon cost from the selected account
        if RemoveMoney(source,upfrontTotal,paymentMethod)~=true then ReleaseStockLock(stockId, transaction); return {success=false,message="Payment rejected"} end

        -- Register vehicle with a single, authoritative plate (matches the sales flow
        -- so GetOwnedVehicleFromPlate resolves correctly for repossession / seize).
        local isUsed = stockItem.is_used == 1 or stockItem.is_used == true
        local plate
        local properties
        if isUsed and stockItem.plate and stockItem.plate ~= '' then
            plate = stockItem.plate
            properties = stockItem.metadata
            if type(properties) == "string" then properties = json.decode(properties) or {} end
            if type(properties) ~= "table" then properties = {} end
            properties.plate = plate
        else
            plate = customPlate or GeneratePlate()
            properties = { plate = plate }
        end
        if AddOwnedVehicleWithProps(source,stockItem.vehicle_model,plate,properties)~=true then
            if GetIdentifier(source) == identifier then AddMoney(source, upfrontTotal, paymentMethod) end
            return {success=false, message='Vehicle ownership insert rejected.'}
        end



        -- Sales tax
        local salesTax = math.floor(price * (Config.SalesTax or 0))
        local netDownPayment = downPayment - math.floor(downPayment * (Config.SalesTax or 0))

        -- Add-on revenue (custom plate fee, etc.) goes straight to the
        -- dealership balance — no commission, no sales tax handling.
        AddDealershipBalance(dealershipId, netDownPayment + addonCost)
        MarkStockSold(stockId, identifier, nil)
        ReleaseStockLock(stockId, transaction)

        -- Calculate next payment time
        local paymentIntervalSeconds = (settings.paymentIntervalHours or 24) * 3600
        local nextPaymentTimestamp = os.time() + paymentIntervalSeconds

        MySQL.insert.await(
            "INSERT INTO `pickle_dealership_financing` (`dealership_id`, `identifier`, `vehicle_plate`, `total_amount`, `amount_paid`, `installment_amount`, `interest_rate`, `next_payment`, `status`) VALUES (?, ?, ?, ?, ?, ?, ?, FROM_UNIXTIME(?), 'active')",
            {
                dealershipId,
                identifier,
                string.upper(plate),
                totalWithInterest,
                0,
                installmentAmount,
                settings.interestRate,
                nextPaymentTimestamp,
            }
        )

        AddLedgerEntry(dealershipId, "sale", price, ("Financed vehicle: %s (down: %s)"):format(stockItem.vehicle_label or stockItem.vehicle_model, GetCurrencyString(downPayment)), identifier)
        if salesTax > 0 then
            AddLedgerEntry(dealershipId, "tax", -salesTax, ("Sales tax on financed %s"):format(stockItem.vehicle_label or stockItem.vehicle_model), nil)
        end
        if couponRow then
            AddLedgerEntry(dealershipId, "discount", -couponDiscount, ("Coupon %s applied to financed %s"):format(couponRow.code or "?", stockItem.vehicle_label or stockItem.vehicle_model), identifier)
        end

        -- Burn the inventory coupon item, if the customer redeemed one from the
        -- picker rather than typing a raw code. The discount itself was already
        -- consumed atomically inside ValidateCoupon.
        if data.couponCode and data.couponCode ~= "" and data.couponItemSlot then
            ConsumeCouponItem(source, data.couponItemSlot)
        end

        return {
            success = true,
            plate = plate,
            model = stockItem.vehicle_model,
            label = stockItem.vehicle_label or stockItem.vehicle_model,
            isUsed = isUsed,
            properties = isUsed and stockItem.metadata or nil,
            downPayment = downPayment,
            installmentAmount = installmentAmount,
            totalInstallments = installments,
            totalWithInterest = totalWithInterest,
            location = dealership.location,
        }
    end)
end)

-- ─── Make Payment ───────────────────────────────────────────────────────────

lib.callback.register("pickle_dealerships:makePayment", function(source, data)
    return DealerTransaction(source, function(transaction)
        if type(data) ~= 'table' then return {success=false, message='Invalid request.'} end
        local financingId = tonumber(data.financingId)
        if not financingId then
            return { success = false, message = "Invalid request." }
        end

        local identifier = GetIdentifier(source)
        if not identifier then
            return { success = false, message = "Could not identify player." }
        end

        local rows = MySQL.query.await(
            "SELECT * FROM `pickle_dealership_financing` WHERE `id` = ? AND `identifier` = ? AND `status` = 'active' LIMIT 1",
            { financingId, identifier }
        )
        local financing = rows and rows[1] or nil
        if not financing then
            return { success = false, message = "Financing agreement not found or already completed." }
        end

        local paymentAmount = financing.installment_amount
        local remaining = financing.total_amount - financing.amount_paid

        if paymentAmount > remaining then
            paymentAmount = remaining
        end

        local playerMoney = GetMoney(source, "bank")
        if playerMoney < paymentAmount then
            return { success = false, message = "Insufficient funds for payment." }
        end

        RemoveMoney(source, paymentAmount, "bank")

        local newAmountPaid = financing.amount_paid + paymentAmount
        local fullyPaid = newAmountPaid >= financing.total_amount

        local netPayment = paymentAmount - math.floor(paymentAmount * (Config.SalesTax or 0))
        AddDealershipBalance(financing.dealership_id, netPayment)

        local settings = GetFinancingSettings(financing.dealership_id)
        local paymentIntervalSeconds = (settings.paymentIntervalHours or 24) * 3600
        local nextPaymentTimestamp = os.time() + paymentIntervalSeconds

        if fullyPaid then
            MySQL.update.await(
                "UPDATE `pickle_dealership_financing` SET `amount_paid` = ?, `status` = 'paid', `missed_payments` = 0 WHERE `id` = ?",
                { newAmountPaid, financingId }
            )
            AddLedgerEntry(financing.dealership_id, "financing_payment", paymentAmount, ("Final financing payment for plate %s"):format(financing.vehicle_plate), identifier)
        else
            MySQL.update.await(
                "UPDATE `pickle_dealership_financing` SET `amount_paid` = ?, `next_payment` = FROM_UNIXTIME(?), `missed_payments` = 0 WHERE `id` = ?",
                { newAmountPaid, nextPaymentTimestamp, financingId }
            )
            AddLedgerEntry(financing.dealership_id, "financing_payment", paymentAmount, ("Financing payment for plate %s"):format(financing.vehicle_plate), identifier)
        end

        return {
            success = true,
            amountPaid = paymentAmount,
            totalPaid = newAmountPaid,
            remaining = financing.total_amount - newAmountPaid,
            fullyPaid = fullyPaid,
        }
    end)
end)

-- ─── Get My Financing ───────────────────────────────────────────────────────

lib.callback.register("pickle_dealerships:getMyFinancing", function(source)
    local identifier = GetIdentifier(source)
    if not identifier then return {} end

    local rows = MySQL.query.await(
        "SELECT f.*, d.name AS dealership_name FROM `pickle_dealership_financing` f LEFT JOIN `pickle_dealerships` d ON f.dealership_id = d.id WHERE f.identifier = ? AND f.status = 'active' ORDER BY f.created_at DESC",
        { identifier }
    )
    if not rows then return {} end

    local results = {}
    for i = 1, #rows do
        local row = rows[i]
        results[#results + 1] = {
            id = row.id,
            dealershipId = row.dealership_id,
            dealershipName = row.dealership_name,
            vehiclePlate = row.vehicle_plate,
            totalAmount = row.total_amount,
            amountPaid = row.amount_paid,
            remaining = row.total_amount - row.amount_paid,
            installmentAmount = row.installment_amount,
            interestRate = row.interest_rate,
            nextPayment = row.next_payment,
            missedPayments = row.missed_payments,
            status = row.status,
            createdAt = row.created_at,
        }
    end

    return results
end)

-- ─── Owner: Get Dealership Agreements ──────────────────────────────────────

lib.callback.register("pickle_dealerships:getDealershipFinancingAgreements", function(source, data)
    local dealershipId = tonumber(data and data.dealershipId)
    if not dealershipId then return {} end

    local role = GetPlayerDealershipRole(source, dealershipId)
    if role ~= 'owner' and not IsPlayerAdmin(source) then return {} end

    local rows = MySQL.query.await(
        "SELECT * FROM `pickle_dealership_financing` WHERE `dealership_id` = ? ORDER BY `status` ASC, `created_at` DESC",
        { dealershipId }
    ) or {}

    return rows
end)

-- ─── Owner: Forgive Loan ───────────────────────────────────────────────────

lib.callback.register("pickle_dealerships:forgiveLoan", function(source, data)
    return DealerTransaction(source, function(transaction)
        if type(data) ~= 'table' then return false, 'Invalid request.' end
        local financingId = tonumber(data and data.financingId)
        local dealershipId = tonumber(data and data.dealershipId)
        if not financingId or not dealershipId then return false, "Invalid request." end

        local role = GetPlayerDealershipRole(source, dealershipId)
        if role ~= 'owner' and not IsPlayerAdmin(source) then
            return false, "Only owners can forgive loans."
        end

        local rows = MySQL.query.await(
            "SELECT * FROM `pickle_dealership_financing` WHERE `id` = ? AND `dealership_id` = ? AND `status` = 'active' LIMIT 1",
            { financingId, dealershipId }
        )
        if not rows or not rows[1] then return false, "Agreement not found." end

        MySQL.update.await(
            "UPDATE `pickle_dealership_financing` SET `status` = 'paid', `amount_paid` = `total_amount`, `missed_payments` = 0 WHERE `id` = ?",
            { financingId }
        )

        AddLedgerEntry(dealershipId, "loan_forgiven", 0, ("Loan forgiven for plate %s by owner"):format(rows[1].vehicle_plate), GetIdentifier(source))

        return true
    end, true)
end)

-- ─── Financing Check Thread (Overdue Payments) ─────────────────────────────

--- Repossess a single financing row. Used by the auto-missed-payment thread
--- below AND by the public bridge export so an external repo/tow tablet can
--- run the same pipeline. `opts.reason`/`opts.actor`/`opts.note` flow into
--- the ledger entry. Idempotent: a row that's already in 'repossessed'
--- status is left alone and reported as a no-op.
function PerformRepossession(financing, opts)
    if not financing or not financing.id then
        return false, "Missing financing row."
    end
    if financing.status == 'repossessed' then
        return false, "Already repossessed."
    end
    opts = opts or {}
    local newMissed = tonumber(opts.missedPayments)
        or (tonumber(financing.missed_payments) or 0) + (opts.fromAutoCheck and 1 or 0)
        or 0

    MySQL.update.await(
        "UPDATE `pickle_dealership_financing` SET `status` = 'repossessed', `missed_payments` = ? WHERE `id` = ?",
        { newMissed, financing.id }
    )
    RemoveOwnedVehicle(financing.identifier, financing.vehicle_plate)

    local note = opts.note
        or (opts.reason and ("Vehicle repossessed: plate %s (%s)"):format(financing.vehicle_plate, tostring(opts.reason)))
        or ("Vehicle repossessed: plate %s after %d missed payments"):format(financing.vehicle_plate, newMissed)
    AddLedgerEntry(financing.dealership_id, "repossession", 0, note, financing.identifier)

    LogDiscord("financing", {
        title = "Vehicle Repossessed",
        dealershipId = financing.dealership_id,
        fields = {
            { name = "Identifier", value = "`" .. tostring(financing.identifier) .. "`", inline = true },
            { name = "Plate", value = "`" .. tostring(financing.vehicle_plate) .. "`", inline = true },
            { name = "Missed Payments", value = tostring(newMissed), inline = true },
            { name = "Total", value = GetCurrencyString(tonumber(financing.total_amount) or 0), inline = true },
            { name = "Paid", value = GetCurrencyString(tonumber(financing.amount_paid) or 0), inline = true },
            { name = "Reason", value = tostring(opts.reason or "auto"), inline = true },
            opts.actor and { name = "Actor", value = "`" .. tostring(opts.actor) .. "`", inline = true } or nil,
        },
    })

    local playerSource = GetSourceFromIdentifier(financing.identifier)
    if playerSource then
        TriggerClientEvent("pickle_dealerships:vehicleRepossessed", playerSource, {
            plate = financing.vehicle_plate,
            missedPayments = newMissed,
            reason = opts.reason or "auto",
        })
    end

    return true, nil
end

CreateThread(function()
    Wait(10000)

    while true do
        Wait(5 * 60 * 1000) -- Every 5 minutes

        local now = os.time()
        local rows = MySQL.query.await(
            "SELECT * FROM `pickle_dealership_financing` WHERE `status` = 'active' AND `next_payment` IS NOT NULL AND `next_payment` < NOW()"
        )

        if rows then
            for i = 1, #rows do
                local financing = rows[i]
                local settings = GetFinancingSettings(financing.dealership_id)
                local maxMissed = settings.maxMissedPayments or 3
                local newMissed = financing.missed_payments + 1

                if newMissed >= maxMissed then
                    PerformRepossession(financing, {
                        missedPayments = newMissed,
                        reason = "missed_payments_auto",
                    })
                else
                    local paymentIntervalSeconds = (settings.paymentIntervalHours or 24) * 3600
                    local nextPaymentTimestamp = now + paymentIntervalSeconds

                    MySQL.update.await(
                        "UPDATE `pickle_dealership_financing` SET `missed_payments` = ?, `next_payment` = FROM_UNIXTIME(?) WHERE `id` = ?",
                        { newMissed, nextPaymentTimestamp, financing.id }
                    )

                    local playerSource = GetSourceFromIdentifier(financing.identifier)
                    if playerSource then
                        TriggerClientEvent("pickle_dealerships:financingReminder", playerSource, {
                            plate = financing.vehicle_plate,
                            missedPayments = newMissed,
                            maxMissed = maxMissed,
                            installmentAmount = financing.installment_amount,
                            remaining = financing.total_amount - financing.amount_paid,
                        })
                    end
                end
            end
        end
    end
end)
