-- =============================================
--  pickle_dealerships | modules/auction/server.lua
--  Auction lifecycle: listing, bidding (escrow), anti-snipe, finalize, claim
-- =============================================

local function NormalizeStatus(row)
    if not row then return row end
    row.reserve_met = (row.reserve_price == nil) or (tonumber(row.current_bid or 0) >= tonumber(row.reserve_price))
    return row
end

local function FetchAuction(auctionId)
    local row = MySQL.single.await(
        [[SELECT a.*, s.vehicle_model, s.vehicle_label, s.plate, s.condition, s.metadata AS stock_metadata,
                 d.name AS dealership_name
          FROM `pickle_dealership_auctions` a
          JOIN `pickle_dealership_stock` s ON s.id = a.stock_id
          JOIN `pickle_dealerships` d ON d.id = a.dealership_id
          WHERE a.id = ?]],
        { tonumber(auctionId) }
    )
    return NormalizeStatus(row)
end

local function FetchActiveAuctions()
    local rows = MySQL.query.await(
        [[SELECT a.*, s.vehicle_model, s.vehicle_label, s.plate, s.condition,
                 d.name AS dealership_name,
                 (SELECT COUNT(*) FROM pickle_dealership_auction_bids b WHERE b.auction_id = a.id) AS bid_count
          FROM `pickle_dealership_auctions` a
          JOIN `pickle_dealership_stock` s ON s.id = a.stock_id
          JOIN `pickle_dealerships` d ON d.id = a.dealership_id
          WHERE a.status = 'active'
          ORDER BY a.ends_at ASC]],
        {}
    ) or {}
    for _, r in ipairs(rows) do NormalizeStatus(r) end
    return rows
end

local function UnlockStock(stockId)
    MySQL.update.await("UPDATE `pickle_dealership_stock` SET `auction_id` = NULL WHERE `id` = ?", { tonumber(stockId) })
end

local function RefundBidder(identifier,amount,note,method,auctionId)
    if not identifier or not DealerInt(tonumber(amount),1,2147483647) then return false end
    -- The caller runs under the mutation lock, so the current unrefunded bid uniquely identifies the credit.
    local bid=MySQL.single.await('SELECT id FROM pickle_dealership_auction_bids WHERE auction_id=? AND bidder_identifier=? AND amount=? ORDER BY id DESC LIMIT 1',{auctionId,identifier,amount})
    return DealerCredit(identifier,amount,method=='cash' and 'money' or 'bank','auction-refund:'..tostring(bid and bid.id or identifier..':'..amount..':'..os.time()))
end

local function AddDealershipBalance(dealershipId, amount)
    MySQL.update.await(
        "UPDATE `pickle_dealerships` SET `balance` = `balance` + ? WHERE `id` = ?",
        { tonumber(amount), tonumber(dealershipId) }
    )
    local fresh = MySQL.scalar.await("SELECT `balance` FROM `pickle_dealerships` WHERE `id` = ?", { tonumber(dealershipId) })
    if fresh and UpdateDealershipCache then UpdateDealershipCache(dealershipId, { balance = tonumber(fresh) }) end
end

local function BroadcastAuctionUpdate(auctionId)
    TriggerClientEvent('pickle_dealerships:auctionUpdate', -1, tonumber(auctionId))
end

-- ─── Listing ────────────────────────────────────────────────────────────────

lib.callback.register("pickle_dealerships:createAuction", function(source, data)
    return DealerTransaction(source, function()
        if type(data) ~= 'table' then return false, 'Invalid request.' end
        local stockId = tonumber(data and data.stockId)
        if not stockId then return false, "Invalid stock id." end

        local stock = MySQL.single.await("SELECT * FROM `pickle_dealership_stock` WHERE `id` = ?", { stockId })
        if not stock then return false, "Stock not found." end
        if stock.sold_at then return false, "Stock already sold." end
        if stock.auction_id then return false, "Already at auction." end
        if not (stock.is_used == 1 or stock.is_used == true) then return false, "Only pre-owned vehicles can be auctioned." end

        -- Permission: owner / manager / admin on the owning dealership
        local role = GetPlayerDealershipRole(source, stock.dealership_id)
        if role ~= 'owner' and role ~= 'manager' and role ~= 'admin' then
            return false, "You do not have permission."
        end

        local startingBid = math.max(1, math.floor(tonumber(data.startingBid) or 0))
        local minIncrement = math.max(Config.Auction.minIncrementFloor, math.floor(tonumber(data.minIncrement) or Config.Auction.minIncrementFloor))
        local reserve = data.reservePrice and math.max(0, math.floor(tonumber(data.reservePrice))) or nil
        local buyout = data.buyoutPrice and math.max(0, math.floor(tonumber(data.buyoutPrice))) or nil
        if reserve == 0 then reserve = nil end
        if buyout == 0 then buyout = nil end
        if buyout and buyout < startingBid then return false, "Buyout must be ≥ starting bid." end
        if reserve and reserve < startingBid then return false, "Reserve must be ≥ starting bid." end

        local duration = tonumber(data.durationMinutes) or Config.Auction.defaultDuration
        local validDuration = false
        for _, d in ipairs(Config.Auction.durations) do if d == duration then validDuration = true break end end
        if not validDuration then return false, "Invalid duration." end

        -- Timer doesn't start until the first bid is placed; ends_at stays NULL until then.
        local id = MySQL.insert.await(
            [[INSERT INTO `pickle_dealership_auctions`
              (stock_id, dealership_id, seller_identifier, starting_bid, min_increment, reserve_price, buyout_price, duration_minutes, ends_at)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)]],
            { stockId, stock.dealership_id, GetIdentifier(source), startingBid, minIncrement, reserve, buyout, duration }
        )
        if not id then return false, "Failed to create auction." end

        -- Also clear display_spot so the car is physically taken off the lot for
        -- the duration of the auction; nobody should be able to walk up and buy
        -- a vehicle that's currently being auctioned.
        MySQL.update.await(
            "UPDATE `pickle_dealership_stock` SET `auction_id` = ?, `unlisted` = 0, `display_spot` = NULL WHERE `id` = ?",
            { id, stockId }
        )
        local dealership = GetDealership(stock.dealership_id)
        if dealership and dealership.location then
            TriggerClientEvent('pickle_dealerships:refreshDisplay', -1, dealership.location)
        end

        BroadcastAuctionUpdate(id)
        return true, id
    end, true)
end)

-- ─── Bidding ────────────────────────────────────────────────────────────────

lib.callback.register('pickle_dealerships:placeBid',function(src,data)
    return DealerTransaction(src, function()
        if type(data) ~= 'table' then return false, 'Invalid request.' end
        local id=tonumber(data and data.auctionId); local amount=tonumber(data and data.amount)
        if not DealerInt(id,1,2147483647) or not DealerInt(amount,1,2147483647) then return false,'Invalid bid' end
        local a=FetchAuction(id)
        if not a or a.status~='active' or a.current_bidder and a.ends_at and DealerDate(a.ends_at)<=os.time() then return false,'Auction has ended' end
        local current=tonumber(a.current_bid) or 0
        local floor=a.current_bidder and current+tonumber(a.min_increment or 1) or tonumber(a.starting_bid or 0)
        if amount<floor then return false,'Bid is below the current minimum' end
        local buyout=a.buyout_price and tonumber(a.buyout_price)>0 and amount>=tonumber(a.buyout_price)
        if buyout then amount=tonumber(a.buyout_price) end
        local currency=data.paymentMethod=='cash' and 'money' or 'bank'
        local owner=GetIdentifier(src)
        if RemoveMoney(src,amount,currency)~=true then return false,'Insufficient funds' end
        local queries={
            {query='INSERT INTO pickle_dealership_auction_bids (auction_id,bidder_identifier,amount,payment_method) VALUES (?,?,?,?)',values={id,owner,amount,data.paymentMethod=='cash' and 'cash' or 'bank'}},
            {query=[[
                UPDATE pickle_dealership_auctions SET
                  ends_at=CASE WHEN ?=1 THEN NOW() WHEN ?=1 THEN DATE_ADD(NOW(),INTERVAL ? MINUTE)
                     WHEN TIMESTAMPDIFF(SECOND,NOW(),ends_at)<? THEN DATE_ADD(NOW(),INTERVAL ? SECOND) ELSE ends_at END,
                  current_bid=?,current_bidder=?,current_payment_method=? WHERE id=? AND status='active'
            ]],values={buyout and 1 or 0,a.current_bidder and 0 or 1,tonumber(a.duration_minutes) or Config.Auction.defaultDuration,
                Config.Auction.antiSnipeSeconds or 0,Config.Auction.antiSnipeSeconds or 0,amount,owner,data.paymentMethod=='cash' and 'cash' or 'bank',id}},
        }
        local previous
        if a.current_bidder and current>0 then
            previous=MySQL.single.await('SELECT id FROM pickle_dealership_auction_bids WHERE auction_id=? AND bidder_identifier=? AND amount=? ORDER BY id DESC LIMIT 1',{id,a.current_bidder,current})
            if not previous then AddMoney(src,amount,currency); return false,'Previous escrow receipt is unavailable' end
            queries[#queries+1]={query="INSERT IGNORE INTO pickle_dealership_credits (credit_key,identifier,amount,currency,state) VALUES (?,?,?,?,'pending')",values={'auction-refund:'..previous.id,a.current_bidder,current,a.current_payment_method=='cash' and 'money' or 'bank'}}
            queries[#queries+1]={query='UPDATE pickle_dealership_auction_bids SET refunded=1 WHERE id=?',values={previous.id}}
        end
        if not MySQL.transaction.await(queries) then AddMoney(src,amount,currency); return false,'Bid could not be committed' end
        if previous then DealerCredit(a.current_bidder,current,a.current_payment_method=='cash' and 'money' or 'bank','auction-refund:'..previous.id) end
        BroadcastAuctionUpdate(id)
        return true,{amount=amount,buyout=buyout,timerStarted=not a.current_bidder}
    end, true)
end)

lib.callback.register("pickle_dealerships:cancelAuction", function(source, data)
    return DealerTransaction(source, function()
        if type(data) ~= 'table' then return false, 'Invalid request.' end
        local auctionId = tonumber(data and data.auctionId)
        if not auctionId then return false, "Invalid auction id." end

        local auction = FetchAuction(auctionId)
        if not auction then return false, "Auction not found." end
        if auction.status ~= 'active' then return false, "Auction is not active." end

        local role = GetPlayerDealershipRole(source, auction.dealership_id)
        if role ~= 'owner' and role ~= 'manager' and role ~= 'admin' then
            return false, "You do not have permission."
        end

        if auction.current_bid and auction.current_bid > 0 then
            return false, "Cannot cancel after bids have been placed."
        end

        MySQL.update.await(
            "UPDATE `pickle_dealership_auctions` SET `status` = 'cancelled', `ended_at` = NOW() WHERE `id` = ?",
            { auctionId }
        )
        UnlockStock(auction.stock_id)
        BroadcastAuctionUpdate(auctionId)
        return true
    end, true)
end)

-- ─── Claim ───────────────────────────────────────────────────────────────────

lib.callback.register("pickle_dealerships:getPendingPickups", function(source)
    local identifier = GetIdentifier(source)
    if not identifier then return {} end

    local rows = MySQL.query.await(
        [[SELECT a.*, s.vehicle_model, s.vehicle_label, s.metadata AS stock_metadata, s.plate,
                 d.name AS dealership_name, d.location AS dealership_location
          FROM `pickle_dealership_auctions` a
          JOIN `pickle_dealership_stock` s ON s.id = a.stock_id
          JOIN `pickle_dealerships` d ON d.id = a.dealership_id
          WHERE a.status = 'won' AND a.winner_identifier = ? AND a.claimed_at IS NULL]],
        { identifier }
    ) or {}
    return rows
end)

lib.callback.register("pickle_dealerships:claimAuctionVehicle", function(source, data)
    return DealerTransaction(source, function()
        if type(data) ~= 'table' then return false, 'Invalid request.' end
        local auctionId = tonumber(data and data.auctionId)
        if not auctionId then return false, "Invalid auction id." end

        local identifier = GetIdentifier(source)
        if not identifier then return false, "Could not identify player." end

        local row = MySQL.single.await(
            [[SELECT a.*, s.vehicle_model, s.vehicle_label, s.metadata AS stock_metadata, s.plate, s.dealership_id AS dsid,
                     d.location AS dealership_location
              FROM `pickle_dealership_auctions` a
              JOIN `pickle_dealership_stock` s ON s.id = a.stock_id
              JOIN `pickle_dealerships` d ON d.id = s.dealership_id
              WHERE a.id = ?]],
            { auctionId }
        )
        if not row then return false, "Auction not found." end
        if row.status ~= 'won' then return false, "Auction has no winner." end
        if row.winner_identifier ~= identifier then return false, "You are not the winner." end
        if row.claimed_at then return false, "Already claimed." end

        if MySQL.update.await("UPDATE pickle_dealership_auctions SET claimed_at=NOW() WHERE id=? AND claimed_at IS NULL AND status='won'",{auctionId})~=1 then return false,"Already claimed" end
        MySQL.update.await(
            "UPDATE `pickle_dealership_stock` SET `sold_at` = NOW(), `sold_to` = ?, `sold_by` = ?, `auction_id` = NULL WHERE `id` = ?",
            { identifier, 'auction', row.stock_id }
        )

        -- Parse properties for ownership registration
        local props = row.stock_metadata
        if props and type(props) == "string" then props = json.decode(props) or {} end
        if type(props) ~= "table" then props = {} end

        -- Use a single authoritative plate so GetOwnedVehicleFromPlate resolves correctly
        -- (matches the sales / financing flow). Falls back to generating one if the stock
        -- row somehow has no plate.
        local plate = row.plate
        if not plate or plate == '' then
            plate = GeneratePlate()
        end
        props.plate = plate

        if AddOwnedVehicleWithProps(source,row.vehicle_model,plate,props)~=true then
            MySQL.update.await("UPDATE pickle_dealership_auctions SET claimed_at=NULL WHERE id=?",{auctionId})
            return false,'Vehicle ownership insert failed'
        end


        -- If caller requested garage-only delivery, skip spawn
        local toGarage = data.toGarage == true
        if toGarage then
            return true, { toGarage = true, label = row.vehicle_label or row.vehicle_model }
        end

        return true, {
            stockId = row.stock_id,
            model = row.vehicle_model,
            label = row.vehicle_label,
            plate = plate,
            properties = props,
            dealershipId = row.dsid,
            dealershipLocation = row.dealership_location,
        }
    end, true)
end)

-- ─── Read-only lookups ───────────────────────────────────────────────────────

lib.callback.register("pickle_dealerships:getActiveAuctions", function(_, data)
    local dealershipId = data and tonumber(data.dealershipId) or nil
    if dealershipId then
        local rows = MySQL.query.await(
            [[SELECT a.*, s.vehicle_model, s.vehicle_label, s.plate, s.condition,
                     d.name AS dealership_name,
                     (SELECT COUNT(*) FROM pickle_dealership_auction_bids b WHERE b.auction_id = a.id) AS bid_count
              FROM `pickle_dealership_auctions` a
              JOIN `pickle_dealership_stock` s ON s.id = a.stock_id
              JOIN `pickle_dealerships` d ON d.id = a.dealership_id
              WHERE a.status = 'active' AND a.dealership_id = ?
              ORDER BY a.ends_at ASC]],
            { dealershipId }
        ) or {}
        for _, r in ipairs(rows) do NormalizeStatus(r) end
        return rows
    end
    return FetchActiveAuctions()
end)

lib.callback.register("pickle_dealerships:getAuctionState", function(_, data)
    local auctionId = tonumber(data and data.auctionId)
    if not auctionId then return nil end
    local row = FetchAuction(auctionId)
    if not row then return nil end
    local bids = MySQL.query.await(
        "SELECT id, bidder_identifier, amount, placed_at, refunded FROM `pickle_dealership_auction_bids` WHERE `auction_id` = ? ORDER BY id DESC LIMIT 20",
        { auctionId }
    ) or {}
    row.bids = bids
    return row
end)

-- Return the caller's identifier (used by UI to highlight own bids as "you")
lib.callback.register("pickle_dealerships:getMyIdentifier", function(source)
    return GetIdentifier(source)
end)

lib.callback.register("pickle_dealerships:getMyCharacterName", function(source)
    return GetPlayerCharacterName(source) or "Player"
end)

-- ─── Viewer routing bucket (per-player showcase isolation) ──────────────────

lib.callback.register("pickle_dealerships:auctionSetViewerBucket", function(source, data)
    local base = tonumber(Config.Auction.viewerBucketBase) or 5000
    local enter = data and data.enter == true
    local bucket = enter and (base + source) or 0
    SetPlayerRoutingBucket(source, bucket)
    return true
end)

-- ─── Finalizer thread ────────────────────────────────────────────────────────

local function FinalizeAuctionUnsafe(row)
    local bid=tonumber(row.current_bid) or 0
    local won=bid>0 and (not row.reserve_price or bid>=tonumber(row.reserve_price))
    local queries={{query='INSERT INTO pickle_dealership_auction_receipts (auction_id) VALUES (?)',values={row.id}}}
    local creditKey
    local net=0
    if won then
        local cut=math.max(0,math.min(1,tonumber(Config.Auction.houseCutPct) or 0))
        net=bid-math.floor(bid*cut)
        queries[#queries+1]={query='UPDATE pickle_dealerships SET balance=balance+? WHERE id=?',values={net,row.dealership_id}}
        queries[#queries+1]={query="UPDATE pickle_dealership_auctions SET status='won',ended_at=NOW(),winner_identifier=?,winning_bid=? WHERE id=?",values={row.current_bidder,bid,row.id}}
    else
        queries[#queries+1]={query="UPDATE pickle_dealership_auctions SET status='no_sale',ended_at=NOW() WHERE id=?",values={row.id}}
        queries[#queries+1]={query='UPDATE pickle_dealership_stock SET auction_id=NULL WHERE id=?',values={row.stock_id}}
        if bid>0 and row.current_bidder then
            creditKey='auction-reserve:'..row.id
            queries[#queries+1]={query="INSERT IGNORE INTO pickle_dealership_credits (credit_key,identifier,amount,currency,state) VALUES (?,?,?,?,'pending')",values={creditKey,row.current_bidder,bid,row.current_payment_method or 'bank'}}
            queries[#queries+1]={query='UPDATE pickle_dealership_auction_bids SET refunded=1 WHERE auction_id=? AND bidder_identifier=? AND refunded=0',values={row.id,row.current_bidder}}
        end
    end
    if not MySQL.transaction.await(queries) then return false end
    if creditKey then DealerCredit(row.current_bidder,bid,row.current_payment_method or 'bank',creditKey) end
    if won then
        local dealer=GetDealership(row.dealership_id)
        if dealer then dealer.balance=tonumber(MySQL.scalar.await('SELECT balance FROM pickle_dealerships WHERE id=?',{row.dealership_id})) or dealer.balance end
        local ok,err=pcall(AddLedgerEntry,row.dealership_id,'auction_sale',net,'Auction #'..row.id,row.current_bidder)
        if not ok then print('[pickle_dealerships] Auction ledger reconciliation required: '..tostring(err)) end
        local winner=GetSourceFromIdentifier(row.current_bidder)
        if winner then TriggerClientEvent('pickle_dealerships:notify',winner,('You won auction #%d for $%d.'):format(row.id,bid)) end
    end
    BroadcastAuctionUpdate(row.id)
    return true
end

local function FinalizeAuction(row)
    if not DealerReady then return false end
    return DealerRunMutation(function()
        local fresh=FetchAuction(row.id)
        if not fresh or fresh.status~='active' then return end
        return FinalizeAuctionUnsafe(fresh)
    end)
end

CreateThread(function()
    -- Boot-time sweep: process any rows that expired while resource was down.
    Wait(3000)  -- let DB settle
    while true do
        local expired = MySQL.query.await(
            [[SELECT * FROM `pickle_dealership_auctions`
              WHERE `status` = 'active' AND `ends_at` <= NOW()]],
            {}
        ) or {}
        for _, row in ipairs(expired) do
            local ok, err = pcall(FinalizeAuction, row)
            if not ok then
                print(('[pickle_dealerships] auction finalize error for #%s: %s'):format(tostring(row.id), tostring(err)))
            end
        end
        Wait(Config.Auction.finalizerTickMs or 1000)
    end
end)
