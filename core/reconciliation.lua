function DealerCommitOrders(ids,owner)
    if type(ids)~='table' or #ids==0 or #ids>1000 then return false end
    local queries={}; local seen={}
    for _,id in ipairs(ids) do
        if not DealerInt(tonumber(id),1,2147483647) or seen[id] then return false end
        seen[id]=true
        local row=MySQL.single.await('SELECT * FROM pickle_dealership_orders WHERE id=?',{id})
        if not row or not DealerInt(tonumber(row.quantity),1,1000) then return false end
        if owner and row.claimed_by~=owner then return false end
        if not owner and (row.claimed_by or not row.delivered_at or DealerDate(row.delivered_at)>os.time()) then return false end
        queries[#queries+1]={query='INSERT INTO pickle_dealership_order_receipts (order_id) VALUES (?)',values={id}}
        queries[#queries+1]={query=[[
            INSERT INTO pickle_dealership_stock (dealership_id,vehicle_model,vehicle_label,wholesale_cost,retail_price,ordered_at,delivered_at,quantity)
            SELECT dealership_id,vehicle_model,vehicle_label,wholesale_cost,retail_price,ordered_at,NOW(),quantity FROM pickle_dealership_orders WHERE id=?
        ]],values={id}}
        queries[#queries+1]={query='DELETE FROM pickle_dealership_orders WHERE id=?',values={id}}
    end
    return MySQL.transaction.await(queries)==true
end
function DealerMarkStockSold(stockId,buyer,seller)
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
function DealerCredit(identifier,amount,currency,key)
    if not identifier or not DealerInt(tonumber(amount),1,2147483647) then return false end
    MySQL.insert.await('INSERT IGNORE INTO pickle_dealership_credits (credit_key,identifier,amount,currency,state) VALUES (?,?,?,?,\'pending\')',{key,identifier,amount,currency or 'bank'})
    local row=MySQL.single.await('SELECT * FROM pickle_dealership_credits WHERE credit_key=?',{key})
    if not row or row.state=='paid' then return row~=nil end
    if row.state~='pending' then return false end
    local src=GetSourceFromIdentifier(identifier)
    if not src or DealerIdentity(src)~=identifier then return false end
    if MySQL.update.await('UPDATE pickle_dealership_credits SET state=\'paying\' WHERE credit_key=? AND state=\'pending\'',{key})~=1 then return false end
    local ok,result=pcall(AddMoney,src,tonumber(row.amount),row.currency)
    if not ok then print('[pickle_dealerships] Credit '..key..' requires operator reconciliation'); return false end
    MySQL.update.await('UPDATE pickle_dealership_credits SET state=? WHERE credit_key=?',{result==true and 'paid' or 'pending',key})
    return result==true
end
function DealerRecoverCredits(src)
    local identity=DealerIdentity(src)
    if not identity then return end
    return DealerRunMutation(function()
        local rows=MySQL.query.await('SELECT * FROM pickle_dealership_credits WHERE identifier=? AND state=\'pending\' ORDER BY id LIMIT 100',{identity}) or {}
        for _,row in ipairs(rows) do DealerCredit(identity,tonumber(row.amount),row.currency,row.credit_key) end
        local iterator=StartFindKvp('vehicleRestore:'..identity..':')
        while true do
            local key=FindKvp(iterator); if not key then break end
            local ok,data=pcall(json.decode,GetResourceKvpString(key))
            if ok and DealerRestoreVehicle(identity,data.model,data.plate,data.properties) then DeleteResourceKvp(key) end
        end
        EndFindKvp(iterator)
    end)
end
function DealerRestoreVehicle(identifier,model,plate,properties)
    local key='vehicleRestore:'..identifier..':'..plate
    SetResourceKvp(key,json.encode({model=model,plate=plate,properties=properties}))
    local existing=GetOwnedVehicleFromPlate(plate)
    if existing then
        if existing.owner==identifier then DeleteResourceKvp(key); return true end
        return false
    end
    local src=GetSourceFromIdentifier(identifier)
    if not src or DealerIdentity(src)~=identifier then return false end
    local ok,result=pcall(AddOwnedVehicleWithProps,src,model,plate,properties)
    if ok and result==true then DeleteResourceKvp(key); return true end
    return false
end
function DealerEstateEmpty(id)
    local dealer=GetDealership(id)
    if not dealer or tonumber(dealer.balance or 0)~=0 then return false end
    for _,spec in ipairs({
        {'pickle_dealership_stock','sold_at IS NULL'},
        {'pickle_dealership_orders','1=1'},
        {'pickle_dealership_financing',"status='active'"},
        {'pickle_dealership_auctions',"status IN ('active','won') AND claimed_at IS NULL"},
    }) do
        local count=MySQL.scalar.await('SELECT COUNT(*) FROM '..spec[1]..' WHERE dealership_id=? AND '..spec[2],{id})
        if tonumber(count or 0)>0 then return false end
    end
    return true
end
-- Existing ownership adapters are wrapped after framework selection has finished.
local addOwned=AddOwnedVehicleWithProps
AddOwnedVehicleWithProps=function(src,model,plate,properties)
    local ctx=DealerContexts[coroutine.running()]
    if ctx and ctx.source==src and ctx.owner~=DealerIdentity(src) then return false end
    return addOwned(src,model,DealerPlate(plate),properties)==true
end
local addMoney=AddMoney
AddMoney=function(src,amount,currency)
    if not DealerInt(amount,0,2147483647) or not DealerIdentity(src) then return false end
    currency=currency or 'money'
    local before=GetMoney(src,currency)
    addMoney(src,amount,currency)
    return GetMoney(src,currency)==before+amount
end
local removeMoney=RemoveMoney
RemoveMoney=function(src,amount,currency)
    local ctx=DealerContexts[coroutine.running()]
    if ctx and ctx.source==src and ctx.owner~=DealerIdentity(src) then return false end
    currency=currency or 'money'
    if not DealerInt(amount,0,2147483647) or GetMoney(src,currency)<amount then return false end
    return removeMoney(src,amount,currency)==true
end
CreateThread(function()
    while not DealerBaseReady do Wait(100) end
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS pickle_dealership_order_receipts (order_id INT PRIMARY KEY,created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)]])
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS pickle_dealership_credits (
        id BIGINT AUTO_INCREMENT PRIMARY KEY,credit_key VARCHAR(191) UNIQUE NOT NULL,identifier VARCHAR(100) NOT NULL,
        amount BIGINT NOT NULL,currency VARCHAR(20) NOT NULL,state VARCHAR(20) NOT NULL DEFAULT 'pending',created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )]])
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS pickle_dealership_auction_receipts (auction_id INT PRIMARY KEY,created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)]])
    DealerReady=true
    while true do
        Wait(10000)
        for _,src in ipairs(GetPlayers()) do DealerRecoverCredits(tonumber(src)) end
    end
end)

local modelNames
function DealerModelName(hash)
    if not modelNames then
        modelNames={}
        for _,row in ipairs(MySQL.query.await('SELECT model FROM pickle_wholesale_catalog') or {}) do modelNames[joaat(row.model)]=row.model end
    end
    return modelNames[hash]
end
