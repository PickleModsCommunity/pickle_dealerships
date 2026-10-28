-- Explicit dealership transaction and data helpers.
DealerOffers, DealerContexts = {}, {}
DealerReady=false
local mutationOwner
function DealerInt(n,min,max) return type(n)=='number' and n%1==0 and n>=min and n<=max end
function DealerPlate(plate) return string.upper(tostring(plate):match('^%s*(.-)%s*$')) end
function DealerIdentity(src)
    if not GetPlayerName(src) then return end
    local ok,id=pcall(GetIdentifier,src); return ok and id or nil
end
function DealerDate(value)
    if type(value)=='number' then return value>100000000000 and math.floor(value/1000) or value end
    if type(value)=='string' then
        local y,m,d,h,n,s=value:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)[ T](%d%d):(%d%d):(%d%d)')
        if y then return os.time({year=tonumber(y),month=tonumber(m),day=tonumber(d),hour=tonumber(h),min=tonumber(n),sec=tonumber(s)}) end
    end
    return 0
end
-- Nested operations pass their token explicitly; unrelated writes wait/retry.
function DealerRunMutation(fn, operation)
    if mutationOwner and operation ~= mutationOwner then
        return false, 'Another operation is in progress; retry.'
    end
    local outer = mutationOwner == nil
    operation = operation or {stockLocks={}}
    mutationOwner = operation
    local result = table.pack(xpcall(fn, debug.traceback, operation))
    if outer then
        ReleaseDealerOperationLocks(operation)
        mutationOwner = nil
    end
    if not result[1] then
        print('[pickle_dealerships] mutation failed: '..tostring(result[2]))
        return false, tostring(result[2])
    end
    return table.unpack(result, 2, result.n)
end
function DealerQueueCoupon(context, coupon, identifier)
    if context then context.coupon={id=coupon.id, identifier=identifier} end
end
function DealerCouponAllowed(coupon,stock)
    if not coupon.vehicle_filter or coupon.vehicle_filter=='' or coupon.vehicle_filter=='[]' then return true end
    local filter=coupon.vehicle_filter
    if type(filter)=='string' then local ok,v=pcall(json.decode,filter); filter=ok and v or nil end
    if type(filter)~='table' or not stock then return false end
    if not next(filter) then return true end
    for _,model in pairs(filter) do if model==stock.vehicle_model then return true end end
    return false
end
function DealerGrantedVehicle(src,plate)
    local ctx=DealerContexts[src]
    if ctx then ctx.vehicleGranted=true; ctx.plate=plate end
end
local function commitCoupon(ctx)
    if not ctx.coupon then return end
    MySQL.transaction.await({
        {query='UPDATE pickle_dealership_coupons SET uses=uses+1 WHERE id=?',values={ctx.coupon.id}},
        {query='INSERT INTO pickle_dealership_coupon_uses (coupon_id,identifier,uses) VALUES (?,?,1) ON DUPLICATE KEY UPDATE uses=uses+1,last_used=CURRENT_TIMESTAMP',values={ctx.coupon.id,ctx.coupon.identifier}},
    })
end
local moneyRemove=RemoveMoney
RemoveMoney=function(src,count,currency)
    if not DealerInt(count,0,2147483647) or not DealerIdentity(src) then return false end
    local ok=moneyRemove(src,count,currency)==true
    local ctx=DealerContexts[src]
    if ok and ctx then ctx.debits[#ctx.debits+1]={owner=DealerIdentity(src),amount=count,currency=currency} end
    return ok
end
-- Called explicitly by callbacks that move money or ownership. This does not
-- intercept callback registration, transport events, or unrelated requests.
function DealerTransaction(src, fn, booleanResponse)
    local results = table.pack(DealerRunMutation(function(context)
        context.source, context.owner, context.debits = src, DealerIdentity(src), {}
        DealerContexts[src] = context
        local result = table.pack(xpcall(fn, debug.traceback, context))
        DealerContexts[src] = nil
        local value = result[2]
        if result[1] and (value == true or type(value) == 'table' and value.success == true) then
            local ok, err = pcall(commitCoupon, context)
            if not ok then print('[pickle_dealerships] coupon commit failed: '..tostring(err)) end
        elseif not result[1] and not context.vehicleGranted then
            for i, debit in ipairs(context.debits) do
                DealerCredit(debit.owner, debit.amount, debit.currency,
                    'rollback:'..src..':'..GetGameTimer()..':'..i)
            end
        end
        if not result[1] then
            print('[pickle_dealerships] transaction failed: '..tostring(value))
            return false, 'Operation failed; recorded payments were queued for recovery.'
        end
        return table.unpack(result, 2, result.n)
    end))
    if results[1] == false and not booleanResponse then
        return {success=false, message=results[2] or 'Operation failed.'}
    end
    return table.unpack(results, 1, results.n)
end

function DealerRefreshBalance(dealer)
    local row = MySQL.single.await('SELECT balance,owner_identifier FROM pickle_dealerships WHERE id=?', {dealer.id})
    if row then dealer.balance=tonumber(row.balance) or 0; dealer.owner_identifier=row.owner_identifier end
end
