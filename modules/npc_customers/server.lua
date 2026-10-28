local npcSessions = {}
local function activeNPCSession(src)
    local session = npcSessions[src]
    if not session or session.owner ~= DealerIdentity(src) or os.time()-session.created > 600 then return end
    local dealer = GetDealership(session.dealershipId)
    if not dealer or not CanPlayerSell(src, dealer.id) then return end
    return session
end
AddEventHandler('playerDropped', function() npcSessions[source] = nil end)

-- =============================================
--  pickle_dealerships | modules/npc_customers/server.lua
--  NPC customer generation, evaluation, negotiation & sale
-- =============================================

--- Check if current time is within business hours
---@return boolean
local function IsWithinBusinessHours()
    local hours = Config.NPCCustomers.businessHours
    if not hours then return true end -- nil = always open
    local currentHour = tonumber(os.date("%H"))
    return currentHour >= (hours.start or 0) and currentHour < (hours.stop or 24)
end

--- Generate an NPC customer profile based on dealership tier & reputation
---@param dealershipId number
---@return table|nil npcProfile
local function GenerateNPCProfile(dealershipId)
    local dealership = GetDealership(dealershipId)
    if not dealership then return nil end

    local tier = dealership.tier or 1

    -- Aggregate classes server-side so we don't ship every stock row across the
    -- wire just to count distinct classes. One row per class.
    local classRows = MySQL.query.await(
        [[
            SELECT LOWER(wc.class) AS class, COUNT(*) AS cnt
            FROM pickle_dealership_stock ds
            LEFT JOIN pickle_wholesale_catalog wc ON wc.model = ds.vehicle_model
            WHERE ds.dealership_id = ?
              AND ds.sold_at IS NULL
              AND ds.unlisted = 0
              AND ds.auction_id IS NULL
              AND ds.delivered_at IS NOT NULL
              AND ds.delivered_at <= NOW()
              AND wc.class IS NOT NULL
              AND wc.class <> ''
            GROUP BY LOWER(wc.class)
        ]],
        { dealershipId }
    )

    if not classRows or #classRows == 0 then return nil end

    local availableClasses = {}
    for _, row in ipairs(classRows) do
        availableClasses[#availableClasses + 1] = row.class
    end

    -- Pick type preference from what's actually in stock
    local typePreference = availableClasses[math.random(#availableClasses)]

    -- Pick a random wholesale cost from the chosen class. Single-row result,
    -- no client-side filtering needed.
    local targetRow = MySQL.single.await(
        [[
            SELECT ds.wholesale_cost
            FROM pickle_dealership_stock ds
            LEFT JOIN pickle_wholesale_catalog wc ON wc.model = ds.vehicle_model
            WHERE ds.dealership_id = ?
              AND ds.sold_at IS NULL
              AND ds.unlisted = 0
              AND ds.auction_id IS NULL
              AND ds.delivered_at IS NOT NULL
              AND ds.delivered_at <= NOW()
              AND LOWER(wc.class) = ?
              AND ds.wholesale_cost > 0
            ORDER BY RAND()
            LIMIT 1
        ]],
        { dealershipId, typePreference }
    )

    local targetMSRP = targetRow and tonumber(targetRow.wholesale_cost) or 0

    if targetMSRP <= 0 then
        -- Fallback: any in-stock row with a positive cost (class data missing).
        local fallback = MySQL.single.await(
            [[
                SELECT ds.wholesale_cost
                FROM pickle_dealership_stock ds
                WHERE ds.dealership_id = ?
                  AND ds.sold_at IS NULL
                  AND ds.unlisted = 0
                  AND ds.auction_id IS NULL
                  AND ds.delivered_at IS NOT NULL
                  AND ds.delivered_at <= NOW()
                  AND ds.wholesale_cost > 0
                ORDER BY RAND()
                LIMIT 1
            ]],
            { dealershipId }
        )
        targetMSRP = fallback and tonumber(fallback.wholesale_cost) or 0
    end

    if targetMSRP <= 0 then return nil end

    -- Budget = target vehicle MSRP + 5-15% random margin so they can afford it
    local budget = math.floor(targetMSRP * (1.05 + math.random() * 0.10))

    local personality = WeightedRandom(Config.NPCCustomers.personalityWeights)

    local flexRange = Config.NPCCustomers.flexibilityRange
    local flexibility = flexRange.min + math.random() * (flexRange.max - flexRange.min)

    local colorPreference = nil
    if math.random() <= 0.5 and Config.DefaultColorPalette and #Config.DefaultColorPalette > 0 then
        colorPreference = Config.DefaultColorPalette[math.random(#Config.DefaultColorPalette)]
    end

    local priorityStats = { "speed", "style", "practicality", "price" }
    local priorityStat = priorityStats[math.random(#priorityStats)]

    -- Budget tier label for ped model selection
    local budgetTier = "economy"
    if budget >= 200000 then budgetTier = "luxury"
    elseif budget >= 80000 then budgetTier = "premium"
    elseif budget >= 30000 then budgetTier = "midrange"
    end

    local pedModels = Config.NPCCustomers.pedModels
    local pedPool = pedModels[budgetTier] or pedModels["economy"] or pedModels[next(pedModels)]
    local pedModel = pedPool[math.random(#pedPool)]

    -- Patience time based on personality
    local patienceTimes = {
        haggler       = math.random(60, 120),
        impulse_buyer = math.random(30, 60),
        researcher    = math.random(90, 150),
        skeptic       = math.random(60, 100),
        walkaway      = math.random(30, 60),
    }
    local patienceTime = patienceTimes[personality] or math.random(60, 120)

    -- Max negotiation rounds based on personality
    local maxRoundsByPersonality = {
        haggler       = 6,
        impulse_buyer = 3,
        researcher    = 5,
        skeptic       = 5,
        walkaway      = 3,
    }

    local profile = {
        budgetTier      = budgetTier,
        budget          = budget,
        personality     = personality,
        typePreference  = typePreference,
        flexibility     = flexibility,
        colorPreference = colorPreference,
        priorityStat    = priorityStat,
        pedModel        = pedModel,
        patienceTime    = patienceTime,
        dealershipId    = dealershipId,
        maxPresentations = Config.NPCCustomers.maxPresentations or 3,
        maxRounds       = maxRoundsByPersonality[personality] or (Config.NPCCustomers.maxNegotiationRounds or 5),
    }

    return profile
end

-- ─── Callbacks ──────────────────────────────────────────────────────────────

--- Generate NPC customer profile
lib.callback.register("pickle_dealerships:generateNPCCustomer", function(source, dealershipId)
    local dealer = GetDealership(tonumber(dealershipId))
    if not dealer or not CanPlayerSell(source, dealer.id) then return nil end
    -- Enforce business hours
    if not IsWithinBusinessHours() then return nil end

    local profile = GenerateNPCProfile(dealer.id)
    npcSessions[source] = {profile=profile, dealershipId=dealer.id, owner=DealerIdentity(source), created=os.time()}
    return profile
end)

--- Evaluate how well a vehicle matches an NPC's preferences
lib.callback.register("pickle_dealerships:evaluateVehicleMatch", function(source, data)
    if type(data) ~= 'table' then return {success=false, message='Invalid request.'} end
    local session = activeNPCSession(source)
    local stockId = type(data.stockItem) == 'table' and tonumber(data.stockItem.id)
    if not session or not DealerInt(stockId, 1, 2147483647) then return {quality='terrible', score=0, dialogue='...'} end
    data.npcProfile = session.profile
    data.stockItem = MySQL.single.await('SELECT * FROM pickle_dealership_stock WHERE id=? AND dealership_id=? AND sold_at IS NULL AND auction_id IS NULL', {stockId, session.dealershipId})
    local profile = data.npcProfile
    local stockItem = data.stockItem
    if not profile or not stockItem then
        return { quality = "terrible", score = 0, dialogue = "..." }
    end

    local score = 0
    local maxScore = 100

    -- Type match (40 pts — most important)
    local itemClass = stockItem.class or stockItem.vehicle_class or ""
    local itemClassLower = string.lower(itemClass)
    local prefLower = string.lower(profile.typePreference or "")
    if itemClassLower == prefLower then
        score = score + 40
    elseif itemClass ~= "" then
        score = score + 5
    end

    -- Budget fit (35 pts)
    local price = tonumber(stockItem.retail_price) or tonumber(stockItem.price) or 0
    local budget = profile.budget or 0
    local maxBudget = budget * (1 + (profile.flexibility or 0))
    if price <= budget then
        local ratio = price / math.max(budget, 1)
        if ratio >= 0.6 then
            score = score + 35
        elseif ratio >= 0.4 then
            score = score + 25
        else
            score = score + 10
        end
    elseif price <= maxBudget then
        score = score + 20
    else
        -- Over max budget — small penalty but not zero if type matches
        score = score + 5
    end

    -- Color match (10 pts)
    if profile.colorPreference then
        score = score + 5
    else
        score = score + 10
    end

    -- Priority stat (15 pts)
    if profile.priorityStat == "price" and price <= budget * 0.8 then
        score = score + 15
    elseif profile.priorityStat == "style" then
        score = score + 10
    elseif profile.priorityStat == "practicality" and (itemClassLower == "suv" or itemClassLower == "sedan") then
        score = score + 15
    elseif profile.priorityStat == "speed" and (itemClassLower == "sports" or itemClassLower == "super") then
        score = score + 15
    else
        score = score + 5
    end

    local pct = score / maxScore
    local quality
    if pct >= 0.75 then quality = "great"
    elseif pct >= 0.50 then quality = "good"
    elseif pct >= 0.30 then quality = "poor"
    else quality = "terrible" end

    -- Reaction dialogue from config
    local pool = Config.NPCCustomers.reactions and Config.NPCCustomers.reactions[quality]
    local dialogue = pool and pool[math.random(#pool)] or "Hmm..."

    -- Calculate opening offer based on score
    local openingOfferPct = 0.5 + (pct * 0.45) -- 50% to 95% of asking price
    if profile.personality == "impulse_buyer" then openingOfferPct = openingOfferPct + 0.1 end
    if profile.personality == "haggler" then openingOfferPct = openingOfferPct - 0.15 end

    local openingOffer = math.floor(price * math.min(openingOfferPct, 1.0))
    -- Clamp to budget
    if openingOffer > budget * (1 + profile.flexibility) then
        openingOffer = math.floor(budget * (1 + profile.flexibility))
    end

    return { quality = quality, score = score, dialogue = dialogue, openingOffer = openingOffer }
end)

--- Evaluate a player's price offer against the NPC's secret max willingness
--- Returns stress increase, whether they accept, and dialogue
--- Minimum sale price that still leaves the dealership with its target profit
--- margin after paying commission. Commission is charged on PROFIT, not on the
--- sale price (see modules/sales/server.lua), so the floor is:
---
---   profit          = finalPrice - wholesale
---   netProfit       = profit * (1 - commissionRate)   -- commission off profit
---   netProfit       >= wholesale * minProfitMargin    -- dealership's cut
---   => finalPrice   >= wholesale * (1 + minProfitMargin / (1 - commissionRate))
---
--- minProfitMargin lives in Config.NPCCustomers.minProfitMargin (see config.lua)
--- so servers can tune how aggressive this floor is without touching code.
local function MinimumAcceptableOffer(wholesaleCost, commissionRate)
    local cost = tonumber(wholesaleCost) or 0
    if cost <= 0 then return 0 end
    local commission = tonumber(commissionRate) or Config.DefaultCommission or 0.08
    local minProfit = tonumber(Config.NPCCustomers and Config.NPCCustomers.minProfitMargin) or 0.05
    -- Clamp commission to leave at least 10% of profit for the dealership —
    -- otherwise a 100% commission rate would make the floor unreachable.
    if commission >= 0.9 then commission = 0.9 end
    local markup = minProfit / (1 - commission)
    return math.ceil(cost * (1 + markup))
end

lib.callback.register("pickle_dealerships:evaluateOffer", function(source, data)
    if type(data) ~= 'table' then return {success=false, message='Invalid request.'} end
    local session = activeNPCSession(source)
    if not session or not DealerInt(tonumber(data.offerPrice), 0, 2147483647) or not DealerInt(tonumber(data.stockId), 1, 2147483647) then
        return {accepted=false, walkaway=true, stress=100, dialogue='Invalid negotiation.'}
    end
    local stock = MySQL.single.await('SELECT * FROM pickle_dealership_stock WHERE id=? AND dealership_id=? AND sold_at IS NULL AND auction_id IS NULL', {data.stockId, session.dealershipId})
    if not stock then return {accepted=false, walkaway=true, stress=100, dialogue='Vehicle is unavailable.'} end
    data.npcProfile = session.profile
    data.currentStress = session.stress or 0
    local function negotiate()
        local npcProfile = data.npcProfile
        local offerPrice = tonumber(data.offerPrice) or 0
        local currentStress = tonumber(data.currentStress) or 0

        if not npcProfile then
            return { accepted = false, walkaway = true, stress = 100, dialogue = "Something went wrong." }
        end

        -- Dealership-side floor: refuse any accept that would leave the shop with
        -- less than `minProfitMargin` after commission. Rejection bumps stress like
        -- any other push-back, but the NPC doesn't walk away — the player can still
        -- raise their ask.
        if data.stockId then
            local stock = MySQL.single.await(
                "SELECT wholesale_cost FROM pickle_dealership_stock WHERE id = ? LIMIT 1",
                { tonumber(data.stockId) }
            )
            if stock then
                local floor = MinimumAcceptableOffer(stock.wholesale_cost)
                if offerPrice > 0 and offerPrice < floor then
                    local bump = 12
                    local newStress = currentStress + bump
                    -- If a below-floor rejection pushes the NPC past 100% stress,
                    -- they walk out the same as any other stress-out. Previously
                    -- this path clamped to 100 without setting walkaway, so the
                    -- customer could sit pinned at 100% indefinitely.
                    local walkaway = newStress >= 100
                    return {
                        accepted = false,
                        walkaway = walkaway,
                        stress = math.min(100, newStress),
                        stressIncrease = bump,
                        dialogue = walkaway
                            and "Forget it — the price keeps coming in below what they'll take. I'm done."
                            or "The dealership won't accept that — it's below what they need to break even.",
                        belowFloor = true,
                        floor = floor,
                    }
                end
            end
        end

        local budget = npcProfile.budget or 0
        local flexibility = npcProfile.flexibility or 0.3
        local personality = npcProfile.personality or "researcher"
        -- Max willingness is budget + 5-15% based on flexibility (tight range, not 2x)
        local maxWillPay = math.floor(budget * (1 + 0.05 + flexibility * 0.10))

        -- Personality stress multipliers (how easily stressed)
        local stressMultiplier = {
            haggler = 0.6,       -- hard to stress, expects tough negotiation
            impulse_buyer = 1.4, -- stresses quickly, wants a quick deal
            researcher = 0.8,    -- patient, moderate stress
            skeptic = 1.2,       -- gets stressed easily
            walkaway = 1.5,      -- very easily stressed
        }
        local personalityMult = stressMultiplier[personality] or 1.0

        local dialogue = ""
        local stressIncrease = 0
        local accepted = false

        if offerPrice <= maxWillPay then
            -- Offer is within their willingness — they accept!
            accepted = true
            stressIncrease = 0

            if offerPrice <= budget * 0.8 then
                dialogue = "That's a great deal! I'll take it!"
            elseif offerPrice <= budget then
                dialogue = "That works for me. You've got a deal."
            else
                dialogue = "It's a stretch, but okay — deal."
            end
        else
            -- Over their max — calculate stress based on how far over
            local overAmount = offerPrice - maxWillPay
            local overPct = overAmount / math.max(maxWillPay, 1)

            -- Base stress: 20-50% per offer depending on how far over
            stressIncrease = math.floor((20 + overPct * 300) * personalityMult)
            stressIncrease = math.max(10, math.min(70, stressIncrease)) -- clamp 10-70 per offer

            -- Add small random variance
            stressIncrease = stressIncrease + math.random(-5, 5)

            local newStress = currentStress + stressIncrease

            if newStress >= 100 then
                -- Walked away
                local walkawayDialogues = {
                    "That's way too much. I'm done here.",
                    "You're not serious with that price. Goodbye.",
                    "I can't deal with this. I'm leaving.",
                    "Forget it, this isn't going to work.",
                }
                dialogue = walkawayDialogues[math.random(#walkawayDialogues)]
                return { accepted = false, walkaway = true, stress = 100, stressIncrease = stressIncrease, dialogue = dialogue }
            else
                -- Still negotiating but stressed
                if newStress >= 70 then
                    local highStress = {
                        "You're really pushing it...",
                        "I'm about to walk out of here.",
                        "This is getting ridiculous.",
                        "Last chance to give me a real price.",
                    }
                    dialogue = highStress[math.random(#highStress)]
                elseif newStress >= 40 then
                    local midStress = {
                        "That's too high. Can you do better?",
                        "Come on, be reasonable.",
                        "I like the car but not at that price.",
                        "You're going to have to come down.",
                    }
                    dialogue = midStress[math.random(#midStress)]
                else
                    local lowStress = {
                        "Hmm, that's a bit more than I was thinking.",
                        "Can we work on the price a little?",
                        "I was hoping for something lower.",
                        "Not bad, but can you do a bit better?",
                    }
                    dialogue = lowStress[math.random(#lowStress)]
                end
            end
        end

        return {
            accepted = accepted,
            walkaway = false,
            stress = math.min(100, currentStress + stressIncrease),
            stressIncrease = stressIncrease,
            dialogue = dialogue,
        }
    end
    local result = negotiate()
    session.stress = result.stress
    session.accepted = result.accepted == true
    session.price = tonumber(data.offerPrice)
    session.stockId = tonumber(data.stockId)
    if result.walkaway then npcSessions[source] = nil end
    return result
end)

--- Complete an NPC sale
lib.callback.register("pickle_dealerships:completeNPCSale", function(source, data)
    if type(data) ~= 'table' then return {success=false, message='Invalid request.'} end
    return DealerTransaction(source, function()
        local session = activeNPCSession(source)
        if not session or session.consumed or not session.accepted or session.stockId ~= tonumber(data.stockId) then
            return {success=false, message='Invalid or expired negotiation.'}
        end
        local stock = MySQL.single.await('SELECT * FROM pickle_dealership_stock WHERE id=? AND dealership_id=? AND sold_at IS NULL AND auction_id IS NULL', {session.stockId, session.dealershipId})
        if not stock then return {success=false, message='Vehicle is unavailable.'} end
        session.consumed = true
        data.dealershipId, data.saleAmount, data.npcProfile = session.dealershipId, session.price, session.profile
        local dealershipId = data.dealershipId
        local stockId      = data.stockId
        local saleAmount   = data.saleAmount
        local npcProfile   = data.npcProfile

        if not dealershipId or not stockId or not saleAmount then
            return { success = false, message = _L("npc_invalid_sale_data") }
        end

        local dealership = GetDealership(dealershipId)
        if not dealership then
            return { success = false, message = _L("dealership_not_found") }
        end

        local identifier = GetIdentifier(source)
        if not identifier then
            return { success = false, message = _L("npc_player_identifier_not_found") }
        end

        -- Credit the full negotiated price. The old silent `npcSaleMultiplier`
        -- scaled what we credited, which made negotiated offers mysteriously
        -- produce losses — the floor check below (matching the one in
        -- evaluateOffer) is the right way to keep sales profitable.
        local adjustedAmount = math.floor(tonumber(saleAmount) or 0)

        -- Server-side floor safety net: never persist a sale below the dealership's
        -- minimum profitable price, regardless of what the client sent.
        local sourceRowCheck = MySQL.single.await(
            "SELECT wholesale_cost FROM pickle_dealership_stock WHERE id = ? LIMIT 1",
            { stockId }
        )
        if sourceRowCheck then
            local floor = MinimumAcceptableOffer(sourceRowCheck.wholesale_cost)
            if adjustedAmount < floor then
                return { success = false, message = _L("npc_sale_below_floor") or "Offer is below the dealership's minimum sale price." }
            end
        end

        -- Commission is a percentage of PROFIT (sale - wholesale), matching the
        -- player-sale flow in modules/sales/server.lua. Losses yield no commission.
        local commissionRate = Config.DefaultCommission or 0.08
        local wholesaleForComm = tonumber(sourceRowCheck and sourceRowCheck.wholesale_cost) or 0
        local profitForComm = math.max(0, adjustedAmount - wholesaleForComm)
        local commission = math.floor(profitForComm * commissionRate)
        local netToDealership = adjustedAmount - commission

        local newBalance = (dealership.balance or 0) + netToDealership
        MySQL.update.await("UPDATE pickle_dealerships SET balance=balance+? WHERE id=?",{netToDealership,dealershipId})
        UpdateDealershipCache(dealershipId, { balance = newBalance })

        if commission > 0 then
            AddMoney(source, commission, "bank")
            -- Success toast is delivered by the NUI wrapper via result.message; no server dupe.
        end

        -- Satisfaction bonus reputation
        local bonusRep = 0
        if npcProfile then
            local budgetRatio = adjustedAmount / math.max(npcProfile.budget or 1, 1)
            if budgetRatio >= 0.9 then
                bonusRep = 1
            end
        end

        -- Record the sale so the dashboard picks it up. We need a *row* with
        -- sold_at set (the dashboard aggregates by row, not by quantity), so:
        --   - multi-quantity source rows are decremented AND a historical sold
        --     row is inserted at the negotiated price
        --   - single-quantity source rows are marked sold with the negotiated price
        --   - npc_seed rows stay intact (infinite inventory) but we still insert a
        --     historical sold row so revenue/transaction counts reflect the sale
        local sourceRow = MySQL.single.await(
            "SELECT vehicle_model, vehicle_label, wholesale_cost, acquired_from, quantity FROM pickle_dealership_stock WHERE id = ?",
            { stockId }
        )
        if sourceRow then
            local insertSoldRow = function()
                MySQL.insert.await([[
                    INSERT INTO pickle_dealership_stock
                        (dealership_id, vehicle_model, vehicle_label, wholesale_cost, retail_price, quantity,
                         ordered_at, delivered_at, sold_at, sold_to, sold_by, acquired_from)
                    VALUES (?, ?, ?, ?, ?, 1, NOW(), NOW(), NOW(), 'NPC', ?, 'npc_sale')
                ]], {
                    dealershipId,
                    sourceRow.vehicle_model,
                    sourceRow.vehicle_label or sourceRow.vehicle_model,
                    tonumber(sourceRow.wholesale_cost) or 0,
                    adjustedAmount,
                    identifier,
                })
            end

            if sourceRow.acquired_from == 'npc_seed' then
                insertSoldRow()
            elseif (tonumber(sourceRow.quantity) or 1) > 1 then
                MySQL.update.await("UPDATE pickle_dealership_stock SET quantity = quantity - 1 WHERE id = ?", { stockId })
                insertSoldRow()
            else
                MySQL.update.await(
                    "UPDATE pickle_dealership_stock SET sold_at = NOW(), sold_to = 'NPC', sold_by = ?, retail_price = ? WHERE id = ?",
                    { identifier, adjustedAmount, stockId }
                )
            end
        end

        -- Ledger entries so the Finances tab and commission totals pick up NPC sales too.
        local vehLabel = sourceRow and (sourceRow.vehicle_label or sourceRow.vehicle_model) or "vehicle"
        AddLedgerEntry(dealershipId, "sale", adjustedAmount,
            ("NPC sale: %s for %s"):format(vehLabel, GetCurrencyString(adjustedAmount)),
            identifier
        )
        if commission > 0 then
            AddLedgerEntry(dealershipId, "commission", -commission,
                ("NPC sale commission: %s"):format(vehLabel),
                identifier
            )
        end

        -- -- Add XP if pickle_xp is available
        -- if Config.XPEnabled and GetResourceState("pickle_xp") == "started" then
        --     local xpAmount = Config.NPCCustomers.xpPerSale or 15
        --     exports["pickle_xp"]:AddPlayerXP(source, xpAmount)
        -- end

        -- Update dealership reputation
        local repGain = (Config.NPCCustomers.reputationPerSale or 1) + bonusRep
        local newRep = (dealership.reputation or 0) + repGain
        MySQL.update.await("UPDATE pickle_dealerships SET reputation = ? WHERE id = ?", { newRep, dealershipId })
        UpdateDealershipCache(dealershipId, { reputation = newRep })

        -- Add ledger entry
        local playerName = GetPlayerCharacterName(source) or "Unknown"
        -- The sale and commission were already recorded above.

        -- Progression XP for the dealership (NPC sales are worth less than real-player sales).
        if AwardDealershipXP then
            local cfg = Config.DealershipProgression or {}
            AwardDealershipXP(dealershipId, cfg.xpPerNpcSale or 0)
        end

        return {
            success    = true,
            saleAmount = adjustedAmount,
            commission = commission,
            message    = _L("npc_sale_complete_message", GetCurrencyString(commission)),
        }
    end)
end)
