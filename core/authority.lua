DealerOffers, DealerContexts, DealerNPCSessions = {}, {}, {}
DealerReady=false
local mutationOwner
local rate,buckets,testPermits={},{},{}
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
function DealerMetadata(dealer)
    local meta=dealer and dealer.metadata
    if type(meta)=='string' then local ok,v=pcall(json.decode,meta); return ok and type(v)=='table' and v or {} end
    return type(meta)=='table' and meta or {}
end
function DealerNear(src,dealer,radius)
    local resolved=dealer and ResolveDealershipConfig and ResolveDealershipConfig(dealer)
    local point=DealerMetadata(dealer).coords or (resolved and resolved.coords)
    local ped=GetPlayerPed(src)
    return point and ped~=0 and #(GetEntityCoords(ped)-vector3(point.x,point.y,point.z))<=(radius or 100)
end
function DealerRunMutation(fn)
    local owner=coroutine.running()
    if mutationOwner and mutationOwner~=owner then return false,'Another operation is in progress; retry.' end
    local outer=not mutationOwner
    mutationOwner=owner
    local result=table.pack(pcall(fn))
    if outer then mutationOwner=nil; ReleaseDealerOperationLocks() end
    if not result[1] then print('[pickle_dealerships] mutation failed: '..tostring(result[2])); return false,tostring(result[2]) end
    return table.unpack(result,2,result.n)
end
function DealerCurrentStock()
    local ctx=DealerContexts[coroutine.running()]
    return ctx and ctx.stock
end
function DealerQueueCoupon(coupon,identifier)
    local ctx=DealerContexts[coroutine.running()]
    if ctx then ctx.coupon={id=coupon.id,identifier=identifier} end
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
    local ctx=DealerContexts[coroutine.running()]
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
    local ctx=DealerContexts[coroutine.running()]
    if ok and ctx then ctx.debits[#ctx.debits+1]={owner=DealerIdentity(src),amount=count,currency=currency} end
    return ok
end
local function clean(value,depth,state,key)
    local kind=type(value)
    if kind=='number' then
        if value~=value or math.abs(value)>2147483647 then return false end
    elseif kind=='string' then if #value>4096 or value:find('%z') then return false end
    elseif kind=='table' then
        if depth>8 then return false end
        for k,v in pairs(value) do
            state.n=state.n+1
            if state.n>2500 or not clean(v,depth+1,state,k) then return false end
        end
    elseif kind~='nil' and kind~='boolean' and kind~='vector3' and kind~='vector4' then return false end
    if type(key)=='string' and value~=nil then
        local field=key:lower():gsub('_','')
        if field=='amount' or field=='price' or field=='saleamount' or field=='offerprice' or field=='buyprice' or field=='retailprice' or field=='wholesaleprice' or field=='downpayment' then
            return DealerInt(tonumber(value),0,2147483647)
        end
        if field=='stockid' or field=='dealershipid' or field=='auctionid' or field=='financingid' or field=='targetserverid' or field=='targetplayerid' then
            return DealerInt(tonumber(value),1,2147483647)
        end
        if field=='installments' then return DealerInt(tonumber(value),1,120) end
        if field=='quantity' or field=='orderquantity' then return DealerInt(tonumber(value),0,1000) end
    end
    return true
end
local function findDealer(value)
    if type(value)=='table' then value=value.dealershipId or value.locationKey or value.location or value.id end
    local byId=tonumber(value)
    if byId and GetDealership(byId) then return GetDealership(byId) end
    for _,d in pairs(DealershipCache) do if d.location==value then return d end end
end
local function restoreBucket(src)
    if buckets[src]~=nil then SetPlayerRoutingBucket(src,buckets[src]); buckets[src]=nil end
end
local function changeBucket(src,enter,base)
    if not enter then restoreBucket(src); return end
    if buckets[src]==nil then buckets[src]=GetPlayerRoutingBucket(src) end
    SetPlayerRoutingBucket(src,base+src)
end
local function reject(message) return {success=false,message=message or 'Invalid or stale request.'} end
local function guard(name,fn,src,...)
    local identity=DealerIdentity(src)
    if not DealerReady or not identity then return reject('Player or database is not ready.') end
    local args=table.pack(...)
    if not clean(args,0,{n=0}) then return reject('Invalid input.') end
    local action=name:match('([^:]+)$'); local key=src..':'..name; local now=GetGameTimer()
    if rate[key] and now-rate[key]<250 then return reject('Please wait before retrying.') end
    rate[key]=now
    local data=type(args[1])=='table' and args[1] or nil
    local tableRequired={confirmEmployeeSale=true,evaluateOffer=true,evaluateVehicleMatch=true,completeNPCSale=true,createFinancing=true,purchaseVehicle=true,employeeSale=true,fireEmployee=true,hireEmployee=true,setEmployeeGrade=true}
    if tableRequired[action] and not data then return reject('A request object is required.') end
    if data then
        if data.pageSize then data.pageSize=math.min(100,math.max(1,math.floor(tonumber(data.pageSize) or 50))) end
        if data.page then data.page=math.min(10000,math.max(1,math.floor(tonumber(data.page) or 1))) end
    end
    local dealer=findDealer(args[1])
    if action=='getStock' and type(args[2])=='table' then
        local opts=args[2]
        opts.scope=dealer and CanPlayerManageOps(src,dealer.id) and opts.scope or 'public'
        opts.pageSize=math.min(100,math.max(1,math.floor(tonumber(opts.pageSize) or 50)))
    end
    if action=='orderVehicle' then
        if not DealerInt(tonumber(args[3]),0,2147483647) or not DealerInt(tonumber(args[4] or 1),1,100) then return false,'Invalid order.' end
        if args[5]~=nil and args[5]~='local' and args[5]~='expedited' then return false,'Only local or expedited orders are permitted.' end
    elseif action=='confirmEmployeeSale' then
        local offer=DealerOffers[src]
        if not offer or offer.buyer~=identity or offer.expires<os.time() or offer.stockId~=tonumber(data.stockId) then return reject() end
        args[1]={dealershipId=offer.dealershipId,stockId=offer.stockId,price=offer.price,couponCode=offer.couponCode,
            soldBy=offer.soldBy,paymentMethod=data.paymentMethod,addons=data.addons,couponItemSlot=data.couponItemSlot}
        data=args[1]; dealer=GetDealership(offer.dealershipId)
    elseif action=='generateNPCCustomer' then
        if not dealer or not CanPlayerSell(src,dealer.id) or not DealerNear(src,dealer) then return nil end
        local session=DealerNPCSessions[src]
        if session and os.time()-session.created<30 then return nil end
    elseif action=='evaluateOffer' or action=='evaluateVehicleMatch' or action=='completeNPCSale' then
        local session=DealerNPCSessions[src]
        if not session or session.owner~=identity or os.time()-session.created>600 then return reject() end
        dealer=GetDealership(session.dealershipId)
        if not dealer or not CanPlayerSell(src,dealer.id) or not DealerNear(src,dealer) then return reject() end
        data.npcProfile=session.profile; data.currentStress=session.stress or 0
        if action=='evaluateVehicleMatch' then
            local stockId=data.stockItem and tonumber(data.stockItem.id)
            data.stockItem=stockId and MySQL.single.await('SELECT * FROM pickle_dealership_stock WHERE id=? AND dealership_id=? AND sold_at IS NULL AND auction_id IS NULL',{stockId,dealer.id})
            if not data.stockItem then return reject() end
        elseif action=='evaluateOffer' then
            local stock=MySQL.single.await('SELECT * FROM pickle_dealership_stock WHERE id=? AND dealership_id=? AND sold_at IS NULL AND auction_id IS NULL',{data.stockId,dealer.id})
            if not stock then return reject() end
        else
            if session.consumed or not session.accepted or session.stockId~=tonumber(data.stockId) then return reject() end
            data.saleAmount=session.price; data.dealershipId=session.dealershipId
            -- The session is consumed only after acquiring the mutation lock.
        end
    elseif action=='createFinancing' or action=='purchaseVehicle' or action=='employeeSale' then
        if not dealer or not PlayerCanAccessDealership(src,dealer) or not DealerNear(src,dealer) then return reject('You must be at the dealership.') end
        if action=='createFinancing' then
            local meta=DealerMetadata(dealer)
            if meta.disableSelfPurchase and not CanPlayerSell(src,dealer.id) then return reject() end
            local options=GetFinancingSettings and GetFinancingSettings(dealer.id)
            if data.paymentMethod and data.paymentMethod~='bank' and data.paymentMethod~='money' and data.paymentMethod~='cash' then return reject() end
        end
    elseif action=='seizeVehicle' or action=='tradeInVehicle' then
        local payload=action=='tradeInVehicle' and args[2] or data
        if type(payload)~='table' or not payload.plate then return false,'Vehicle required.' end
        local plate=DealerPlate(payload.plate); local found
        for _,v in ipairs(GetAllVehicles()) do
            if DealerPlate(GetVehicleNumberPlateText(v))==plate and #(GetEntityCoords(v)-GetEntityCoords(GetPlayerPed(src)))<=8
                and GetEntityRoutingBucket(v)==GetPlayerRoutingBucket(src) then found=v; break end
        end
        if not found then return false,'Vehicle must be nearby.' end
        local owned=GetOwnedVehicleFromPlate(plate)
        if not owned or not owned.owner then return false,'Owned vehicle required.' end
        local props=owned.properties or owned.props or owned.mods
        if type(props)=='string' then props=json.decode(props) end
        if type(props)~='table' then return false,'Trusted vehicle properties are unavailable.' end
        local model=owned.model or props.model
        if type(model)=='string' and joaat(model)~=GetEntityModel(found) then return false,'Vehicle model mismatch.' end
        if type(model)=='number' then model=DealerModelName(model) end
        if type(model)~='string' or joaat(model)~=GetEntityModel(found) then return false,'Vehicle model is not in the trusted catalog.' end
        payload.netId=NetworkGetNetworkIdFromEntity(found)
        payload.properties=props; payload.modelName=model; payload.plate=plate
    elseif action=='fireEmployee' or action=='hireEmployee' or action=='setEmployeeGrade' then
        if not dealer or not CanPlayerManageOps(src,dealer.id) then return reject() end
        local target=tonumber(data.targetServerId or data.targetId)
        local targetId=target and DealerIdentity(target) or data.targetIdentifier
        if targetId==dealer.owner_identifier then return reject('Cannot alter the owner.') end
        if action=='fireEmployee' and not MySQL.scalar.await('SELECT 1 FROM pickle_dealership_employees WHERE dealership_id=? AND identifier=?',{dealer.id,targetId}) then return reject('Not a roster employee.') end
        if action=='hireEmployee' and (not target or #(GetEntityCoords(GetPlayerPed(target))-GetEntityCoords(GetPlayerPed(src)))>5) then return reject('Player must be nearby.') end
        if action=='hireEmployee' and lib.callback.await('pickle_dealerships:confirmEmployment',target,{name=dealer.name,grade=data.grade})~=true then return reject('Employment was declined.') end
    elseif action:lower():find('resetdealership') or action:lower():find('deletedealership') or action=='sellDealership' then
        if not dealer or not DealerEstateEmpty(dealer.id) then return reject('Settle funds, stock, financing and escrow first.') end
    elseif action=='auctionSetViewerBucket' then
        changeBucket(src,data and data.enter==true,tonumber(Config.Auction.viewerBucketBase) or 5000); return true
    elseif action=='adminSetPhotoBucket' then
        if not IsPlayerAdmin(src) then return reject() end
        changeBucket(src,data and tonumber(data.bucket)~=0,tonumber(Config.PhotoBooth and Config.PhotoBooth.routingBucket) or 80000)
        return {success=true}
    end
    local mutation=not action:match('^get') and not action:match('^list') and not action:match('^can') and not action:match('^is') and not action:match('^validate')
    local function invoke()
    if dealer then
        local fresh=MySQL.single.await('SELECT balance,owner_identifier FROM pickle_dealerships WHERE id=?',{dealer.id})
        if fresh then dealer.balance=tonumber(fresh.balance) or 0; dealer.owner_identifier=fresh.owner_identifier end
    end
        if action=="completeNPCSale" then DealerNPCSessions[src].consumed=true end
        local context={source=src,owner=identity,debits={},action=action}
        DealerContexts[coroutine.running()]=context
        if data and data.stockId then
            context.stock=MySQL.single.await('SELECT * FROM pickle_dealership_stock WHERE id=?',{tonumber(data.stockId)})
            if context.stock and context.stock.auction_id and (action=='purchaseVehicle' or action=='employeeSale' or action=='confirmEmployeeSale' or action=='createFinancing' or action=='completeNPCSale') then DealerContexts[coroutine.running()]=nil; return reject('Vehicle is at auction.') end
        end
        local result=table.pack(pcall(fn,src,table.unpack(args,1,args.n)))
        local value=result[2]
        local success=result[1] and (type(value)=='table' and value.success==true or value==true)
        if success then commitCoupon(context); if action=='confirmEmployeeSale' then DealerOffers[src]=nil end end
        if not result[1] and not context.vehicleGranted then
            for i,debit in ipairs(context.debits) do DealerCredit(debit.owner,debit.amount,debit.currency,'rollback:'..src..':'..now..':'..i) end
        end
        DealerContexts[coroutine.running()]=nil
        if not result[1] then print('[pickle_dealerships] '..name..': '..tostring(value)); return reject('Operation failed; recorded payments were queued for recovery.') end
        if action=='generateNPCCustomer' and type(value)=='table' then DealerNPCSessions[src]={profile=value,dealershipId=dealer.id,owner=identity,created=os.time()} end
        if action=='evaluateOffer' then
            local session=DealerNPCSessions[src]
            if type(value)=='table' then session.stress=value.stress; session.accepted=value.accepted==true; session.price=tonumber(data.offerPrice); session.stockId=tonumber(data.stockId) end
        end
        if (action=='getDealershipData' or action=='getStock' or action=='getPickleFax') and type(value)=='table' and not (dealer and CanPlayerManageOps(src,dealer.id)) then
            local private={owner_identifier=true,balance=true,wholesale_cost=true,wholesaleCost=true,acquired_from=true,acquiredFrom=true,sold_to=true}
            local function redact(t)
                for k,v in pairs(t) do if private[k] then t[k]=nil elseif type(v)=='table' then redact(v) end end
            end
            -- These endpoints return detached response tables, not shared dealership cache entries.
            redact(value)
        end
        return table.unpack(result,2,result.n)
    end
    if mutation then return DealerRunMutation(invoke) end
    return invoke()
end
local register=lib.callback.register
lib.callback.register=function(name,fn) register(name,function(src,...) return guard(name,fn,src,...) end) end
local event=RegisterNetEvent
RegisterNetEvent=function(name,fn)
    if type(fn)~='function' then return event(name,fn) end
    event(name,function(...)
        local src=source
        if name=='pickle_dealerships:enterTestDriveBucket' then
            local permit=testPermits[src]
            if not permit or permit.owner~=DealerIdentity(src) or permit.expires<os.time() then return end
            testPermits[src]=nil
        end
        return guard(name,function(_,...) return fn(...) end,src,...)
    end)
end
AddEventHandler('playerDropped',function() restoreBucket(source); DealerOffers[source]=nil; DealerNPCSessions[source]=nil end)
AddEventHandler('onResourceStop',function(name)
    if name==GetCurrentResourceName() then for src in pairs(buckets) do restoreBucket(src) end end
end)
-- Character loads trigger pending credits after the framework has hydrated the character.
event('pickle_dealerships:initializePlayer',function()
    local src=source
    if not DealerReady or not DealerIdentity(src) then return end
    DealerRecoverCredits(src)
    TriggerClientEvent('pickle_dealerships:setupInventory',src,{items=Inventory and Inventory.Items or {}})
end)

register('pickle_dealerships:authorizeTestDrive',function(src,data)
    if not DealerReady or type(data)~='table' then return false end
    local dealer=GetDealership(tonumber(data.dealershipId))
    if not dealer or not DealerNear(src,dealer) or not PlayerCanAccessDealership(src,dealer) or not DealerIdentity(src) then return false end
    local model=type(data.model)=='string' and data.model or ''
    if #model>100 or not MySQL.scalar.await('SELECT 1 FROM pickle_dealership_stock WHERE dealership_id=? AND vehicle_model=? AND sold_at IS NULL AND auction_id IS NULL LIMIT 1',{dealer.id,model}) then return false end
    testPermits[src]={owner=DealerIdentity(src),expires=os.time()+30}
    return true
end)
