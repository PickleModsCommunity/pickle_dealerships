-- =============================================
--  pickle_dealerships | bridge/repo/server.lua
--  Public exports for external tow / repo tablet integrations.
--
--  These let another resource read which dealership-financed vehicles are
--  delinquent and complete a repossession through the same pipeline the
--  built-in 5-minute auto-check uses (PerformRepossession in
--  modules/financing/server.lua). No tow logic — just data + a hook.
--
--  Usage from an external resource:
--    local rows = exports.pickle_dealerships:getRepoCandidates({
--        minMissed = 1,        -- default 1; 0 returns all active financings
--        dealershipId = nil,   -- optional filter
--    })
--    for _, r in ipairs(rows) do print(r.plate, r.missedPayments) end
--
--    local row = exports.pickle_dealerships:getFinancingByPlate("ABC123")
--
--    local ok, msg = exports.pickle_dealerships:repossessVehicle("ABC123", {
--        actor = src,           -- player who triggered the repo (optional)
--        reason = "tow_tablet", -- short stable string for the ledger / log
--    })
-- =============================================

--- Returns delinquent financing rows so a tow tablet can render a job board.
--- Default returns rows with at least one missed payment that are still
--- 'active'; pass minMissed=0 to surface every active financing.
local function getRepoCandidates(filter)
    filter = filter or {}
    local minMissed = tonumber(filter.minMissed)
    if minMissed == nil then minMissed = 1 end
    local dealershipId = tonumber(filter.dealershipId)

    local where = "f.status = 'active' AND f.missed_payments >= ?"
    local params = { minMissed }
    if dealershipId then
        where = where .. " AND f.dealership_id = ?"
        params[#params + 1] = dealershipId
    end

    local rows = MySQL.query.await(
        ("SELECT f.id, f.dealership_id, f.identifier, f.vehicle_plate, f.total_amount, f.amount_paid, f.installment_amount, f.missed_payments, UNIX_TIMESTAMP(f.next_payment) AS next_payment_ts, d.name AS dealership_name FROM pickle_dealership_financing f LEFT JOIN pickle_dealerships d ON d.id = f.dealership_id WHERE %s ORDER BY f.missed_payments DESC, f.next_payment ASC"):format(where),
        params
    ) or {}

    local out = {}
    for _, r in ipairs(rows) do
        local total = tonumber(r.total_amount) or 0
        local paid = tonumber(r.amount_paid) or 0
        out[#out + 1] = {
            financingId = r.id,
            dealershipId = r.dealership_id,
            dealershipName = r.dealership_name,
            identifier = r.identifier,
            plate = r.vehicle_plate,
            totalAmount = total,
            amountPaid = paid,
            remainingBalance = math.max(0, total - paid),
            installmentAmount = tonumber(r.installment_amount) or 0,
            missedPayments = tonumber(r.missed_payments) or 0,
            nextPaymentTs = tonumber(r.next_payment_ts),
        }
    end
    return out
end

--- Returns the active financing row for a plate, or nil. Tow tablets call
--- this to validate a plate they scanned before initiating a repo.
local function getFinancingByPlate(plate)
    if type(plate) ~= 'string' or plate == '' then return nil end
    local row = MySQL.single.await(
        "SELECT f.*, d.name AS dealership_name, UNIX_TIMESTAMP(f.next_payment) AS next_payment_ts FROM pickle_dealership_financing f LEFT JOIN pickle_dealerships d ON d.id = f.dealership_id WHERE f.vehicle_plate = ? AND f.status = 'active' LIMIT 1",
        { plate }
    )
    if not row then return nil end
    local total = tonumber(row.total_amount) or 0
    local paid = tonumber(row.amount_paid) or 0
    return {
        financingId = row.id,
        dealershipId = row.dealership_id,
        dealershipName = row.dealership_name,
        identifier = row.identifier,
        plate = row.vehicle_plate,
        totalAmount = total,
        amountPaid = paid,
        remainingBalance = math.max(0, total - paid),
        installmentAmount = tonumber(row.installment_amount) or 0,
        missedPayments = tonumber(row.missed_payments) or 0,
        nextPaymentTs = tonumber(row.next_payment_ts),
    }
end

--- Marks the financed vehicle for `plate` as repossessed. Removes ownership,
--- writes a ledger entry, and notifies the owner via the existing
--- `pickle_dealerships:vehicleRepossessed` net event. Returns
--- (success, message) so the calling resource can surface failures.
local function repossessVehicle(plate, opts)
    if type(plate) ~= 'string' or plate == '' then
        return false, "Invalid plate."
    end
    local financing = MySQL.single.await(
        "SELECT * FROM pickle_dealership_financing WHERE vehicle_plate = ? AND status = 'active' LIMIT 1",
        { plate }
    )
    if not financing then return false, "No active financing for that plate." end

    if not PerformRepossession then
        return false, "Repo pipeline not available."
    end
    return PerformRepossession(financing, opts or {})
end

local function authorized(fn)
    return function(...)
        local caller=GetInvokingResource()
        if not caller or not ServerConfig.RepoResources[caller] then return nil,'Resource is not authorized for repossession access.' end
        local args=table.pack(...)
        return DealerRunMutation(function() return fn(table.unpack(args,1,args.n)) end)
    end
end
exports('getRepoCandidates', authorized(getRepoCandidates))
exports('getFinancingByPlate', authorized(getFinancingByPlate))
exports('repossessVehicle', authorized(repossessVehicle))
