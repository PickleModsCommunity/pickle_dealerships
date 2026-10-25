-- =============================================
--  pickle_dealerships | modules/sales/client.lua
--  Client-side sales, test drives, vehicle spawn
-- =============================================

-- ─── Test Drive State ───────────────────────────────────────────────────────

local testDriveActive = false
local testDriveVehicle = nil
local testDriveTimer = 0
local testDriveBlip = nil
local testDriveRadiusBlip = nil
local testDriveDealershipId = nil
local testDriveOrigin = nil
local testDriveReturnCoords = nil -- coords to teleport the player to on drive end
-- Edge-triggered boundary warning. Monitor ticks every second, so without
-- this flag we'd spam the "approaching boundary" toast every tick the
-- player lingers near the edge.
local testDriveNearBoundary = false

-- ─── Vehicle Spawn Helper ───────────────────────────────────────────────────

function SpawnPurchasedVehicle(model, spawnPoint, color, secondaryColor, properties, plate)
    local modelHash = type(model) == "number" and model or joaat(model)
    RequestModel(modelHash)
    local timeout = 0
    while not HasModelLoaded(modelHash) and timeout < 5000 do
        Wait(10)
        timeout = timeout + 10
    end
    if not HasModelLoaded(modelHash) then
        ShowNotification(_L("sales_load_failed"))
        return nil
    end

    local coords = spawnPoint
    local heading = coords.w or 0.0
    -- Spawn slightly above ground to avoid clipping
    local veh = CreateVeh(modelHash, coords.x, coords.y, coords.z + 0.5, heading, true, false)

    -- Immediately freeze and protect from damage until placed properly
    FreezeEntityPosition(veh, true)
    SetEntityInvincible(veh, true)
    SetVehicleOnGroundProperly(veh)

    -- Pre-owned: apply full captured properties (overrides color-only path)
    if properties then
        if type(properties) == "string" then properties = json.decode(properties) end
        if type(properties) == "table" then
            lib.setVehicleProperties(veh, properties)
        end
    elseif color then
        -- Route the chosen color through lib.setVehicleProperties so the keys
        -- match what ProcessSale persists server-side (customPrimaryColor /
        -- customSecondaryColor for RGB, color1/color2 for paletted). Keeping
        -- the client and server shapes identical means the in-world car at
        -- spawn matches the very first garage respawn.
        local applyProps = {}
        if type(color) == "table" then
            if color.r and color.g and color.b then
                local primary = { color.r, color.g, color.b }
                local secondary
                if type(secondaryColor) == "table" and secondaryColor.r then
                    secondary = { secondaryColor.r, secondaryColor.g, secondaryColor.b }
                elseif type(color.secondary) == "table" and color.secondary.r then
                    secondary = { color.secondary.r, color.secondary.g, color.secondary.b }
                else
                    secondary = primary
                end
                applyProps.customPrimaryColor = primary
                applyProps.customSecondaryColor = secondary
            elseif color.colorId then
                applyProps.color1 = color.colorId
                applyProps.color2 = color.colorId
            elseif color.primary ~= nil or color.secondary ~= nil then
                local p = tonumber(color.primary)
                local s = tonumber(color.secondary) or p
                if p then applyProps.color1 = p end
                if s then applyProps.color2 = s end
            end
        elseif type(color) == "number" then
            applyProps.color1 = color
            applyProps.color2 = color
        end
        if next(applyProps) ~= nil then
            lib.setVehicleProperties(veh, applyProps)
        end
    end

    -- Apply the DB-assigned plate so the in-world vehicle matches ownership records
    if plate and plate ~= '' then
        SetVehicleNumberPlateText(veh, plate)
    end

    -- Warp player in, then unfreeze
    local ped = PlayerPedId()
    TaskWarpPedIntoVehicle(ped, veh, -1)
    SetVehicleEngineOn(veh, true, true, false)

    -- Small delay to let ground placement settle, then release
    Wait(100)
    FreezeEntityPosition(veh, false)
    SetEntityInvincible(veh, false)

    GiveVehicleKeys(veh)

    return veh
end

-- ─── NUI Callbacks ──────────────────────────────────────────────────────────

RegisterNUICallback("purchaseVehicle", function(data, cb)
    -- Fetch stock details first so we know whether this is a pre-owned unit
    local details = lib.callback.await("pickle_dealerships:getVehicleDetails", false, { stockId = data.stockId })

    local result = lib.callback.await("pickle_dealerships:purchaseVehicle", false, {
        dealershipId = data.dealershipId,
        stockId = data.stockId,
        paymentMethod = data.paymentMethod or "cash",
        color = data.color,
        couponCode = data.couponCode,
        couponItemSlot=data.couponItemSlot,
        addons = data.addons,
    })

    if result and result.success then
        -- Resolve spawn point from the dealership this sale is actually
        -- for. DealershipConfigs is keyed by location, so prefer the
        -- location the UI passed us, then the one the server echoed back
        -- in the result. The old fallback iterated the table and picked
        -- the FIRST config with a spawnPoint, which is what made players
        -- spawn at a different dealership's lot.
        local location = data.location or result.location
        local cfg = location and DealershipConfigs[location]
        local spawnPoint = cfg and cfg.spawnPoint

        if data.spawnPoint then
            spawnPoint = vector4(data.spawnPoint.x, data.spawnPoint.y, data.spawnPoint.z, data.spawnPoint.w or 0.0)
        end

        if spawnPoint then
            local color = data.color
            if color and type(color) == "string" then
                color = json.decode(color)
            end
            local secColor = data.secondaryColor
            if secColor and type(secColor) == "string" then
                secColor = json.decode(secColor)
            end
            local props = nil
            if details and details.isUsed then
                props = details.properties
                if result.plate and type(props) == "table" then
                    props.plate = result.plate
                end
            end
            SpawnPurchasedVehicle(result.model, spawnPoint, color, secColor, props, result.plate)
        end

        ShowNotification(_L("sales_purchase_success", result.label or result.model))
    else
        ShowNotification(result and result.message or _L("sales_purchase_failed"))
    end

    cb(result or { success = false })
end)

-- Preview-only coupon validation for the purchase dialog. Does NOT consume
-- the coupon — the live sale path calls ValidateCoupon server-side, which is
-- the one that increments uses.
RegisterNUICallback("validateCouponPreview", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:validateCoupon", false, {
        dealershipId   = data.dealershipId,
        code           = data.code,
        purchaseAmount = data.purchaseAmount,
        vehicleModel   = data.vehicleModel,
    })
    cb(result or { valid = false })
end)

RegisterNUICallback("getStockDetails", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:getVehicleDetails", false, {
        stockId = data.stockId,
    })
    cb(result or {})
end)

RegisterNUICallback("getAltPaymentOptions", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:getAltPaymentOptions", false, {
        dealershipId = data.dealershipId,
        price = data.price,
    })
    cb({ options = result or {} })
end)

-- ─── Tablet / Direct Sale ──────────────────────────────────────────────────

--- "Sell to Customer" entry from the SalesPage employee UI. The server reuses
--- the existing employeeSale → confirmPurchase → confirmEmployeeSale pipeline
--- so the customer still gets the same alert prompt regardless of whether the
--- sale was started at the front desk or through the tablet.
RegisterNUICallback("employeeSale", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:employeeSale", false, {
        dealershipId    = data.dealershipId,
        stockId         = data.stockId,
        targetPlayerId  = tonumber(data.targetPlayerId),
        price           = tonumber(data.price),
        couponCode      = data.couponCode,
    })
    if result and result.message then ShowNotification(result.message) end
    cb(result or { success = false })
end)

RegisterNUICallback("listNearbyPlayers", function(data, cb)
    local rows = lib.callback.await("pickle_dealerships:listNearbyPlayers", false, {
        dealershipId = data.dealershipId,
        radius       = data.radius,
    })
    cb({ players = rows or {} })
end)

RegisterNUICallback("listOnlinePlayersForSale", function(data, cb)
    local rows = lib.callback.await("pickle_dealerships:listOnlinePlayersForSale", false, {
        dealershipId = data.dealershipId,
    })
    cb({ players = rows or {} })
end)

--- Opens the SalesPage NUI for an arbitrary dealership without requiring the
--- player to be standing at the front desk. Used by /dealertablet. Always
--- routes to the regular sales tablet UI (skips the immersive showroom path
--- since the operator is using a tablet, not walking the lot).
local function OpenRemoteSalesTablet(locationKey)
    local data = lib.callback.await('pickle_dealerships:getDealershipData', false, locationKey)
    if not data then
        ShowNotification(_L("error_access_denied"))
        return
    end
    local role = lib.callback.await('pickle_dealerships:getPlayerRole', false, locationKey)
    if not role or role == 'customer' then
        ShowNotification(_L("no_permission"))
        return
    end
    OpenNui('sales', {
        dealershipId = data.id,
        dealershipName = data.name,
        role = role,
        tier = data.tier,
        location = locationKey,
        disableSelfPurchase = data.disableSelfPurchase or false,
        tabletMode = true,
    })
end

RegisterCommand("dealertablet", function()
    local rows = lib.callback.await("pickle_dealerships:listEmployeeDealerships", false)
    if type(rows) ~= 'table' or #rows == 0 then
        ShowNotification(_L("tablet_no_dealerships"))
        return
    end

    if #rows == 1 then
        OpenRemoteSalesTablet(rows[1].location)
        return
    end

    local options = {}
    for _, d in ipairs(rows) do
        options[#options + 1] = { label = d.name .. ' (' .. d.role .. ')', value = d.location }
    end
    local choice = lib.inputDialog(_L("tablet_pick_dealership"), {
        { type = 'select', label = _L("label_dealership"), options = options, required = true },
    })
    if not choice or not choice[1] then return end
    OpenRemoteSalesTablet(choice[1])
end, false)
TriggerEvent("chat:addSuggestion", "/dealertablet", _L("tablet_command_desc") or "Open the dealership sales tablet from anywhere")

RegisterNetEvent("pickle_dealerships:openSalesTablet", function()
    ExecuteCommand("dealertablet")
end)

-- ─── Test Drive System ──────────────────────────────────────────────────────

local function EndTestDrive()
    if not testDriveActive then return end
    testDriveActive = false

    -- useNuiEvent in the React overlay dispatches on `type`, not `action`,
    -- so this payload must use `type` or the subtitle stays stuck on
    -- screen (or never shows at all, depending on which path fired).
    SendNUIMessage({ type = "testDriveSubtitle", data = { visible = false } })

    local ped = PlayerPedId()

    -- Fade out first so the yank-out / teleport / bucket swap isn't visible
    -- to the driver. All the state mutations happen while the screen is
    -- black so the return feels like a single instant transition.
    DoScreenFadeOut(400)
    while not IsScreenFadedOut() do Wait(0) end

    -- Delete the test-drive vehicle BEFORE leaving the routing bucket.
    -- Once the bucket change lands the entity is no longer on this client
    -- (each drive runs in its own per-player bucket), so DeleteEntity
    -- would silently no-op and the car would strand in the old bucket —
    -- matching the user-reported "previous vehicles scattered around"
    -- behaviour. Eject the player first, flag the car as a mission
    -- entity (required for DeleteEntity to cooperate on network-owned
    -- vehicles), then delete.
    if testDriveVehicle and DoesEntityExist(testDriveVehicle) then
        if GetVehiclePedIsIn(ped, false) == testDriveVehicle then
            TaskLeaveVehicle(ped, testDriveVehicle, 0)
            Wait(800)
        end
        SetEntityAsMissionEntity(testDriveVehicle, true, true)
        DeleteEntity(testDriveVehicle)
    end
    testDriveVehicle = nil

    -- Return the player to the dealership. Prefer the pre-drive coords we
    -- captured at start-time (that's exactly where they kicked the drive
    -- off); fall back to the dealership origin so we never leave them
    -- stranded wherever the drive ended.
    local dest = testDriveReturnCoords or testDriveOrigin
    if dest then
        -- Drop 1u below the saved Z so the ped settles onto the ground as
        -- collision streams in, rather than spawning a metre in the air
        -- and visibly falling on fade-in. Same trick CleanupShowroom uses.
        SetEntityCoords(ped, dest.x, dest.y, dest.z - 1.0, false, false, false, false)
    end

    -- Now hand the player back to the default bucket. The vehicle is
    -- already gone so no cross-bucket cleanup needed.
    TriggerServerEvent('pickle_dealerships:leaveTestDriveBucket')
    Wait(200)

    DoScreenFadeIn(400)

    if testDriveBlip then
        RemoveBlip(testDriveBlip)
        testDriveBlip = nil
    end
    if testDriveRadiusBlip then
        RemoveBlip(testDriveRadiusBlip)
        testDriveRadiusBlip = nil
    end

    testDriveTimer = 0
    testDriveDealershipId = nil
    testDriveOrigin = nil
    testDriveReturnCoords = nil
    testDriveNearBoundary = false

    ShowNotification(_L("sales_test_drive_ended"))
end

RegisterNUICallback("startTestDrive", function(data, cb)
    if testDriveActive then
        ShowNotification(_L("sales_test_drive_active"))
        cb({ success = false, message = "Already on a test drive." })
        return
    end

    local dealershipId = data.dealershipId
    local model = data.model
    local color = data.color

    if not model then
        cb({ success = false, message = "No vehicle model specified." })
        return
    end

    -- Resolve spawn point and origin from the specific dealership this
    -- test drive is for, not the first one we happen to find.
    local location = data.location
    local cfg = location and DealershipConfigs[location]
    local spawnPoint = cfg and cfg.spawnPoint
    local originCoords = cfg and cfg.coords

    if data.spawnPoint then
        spawnPoint = vector4(data.spawnPoint.x, data.spawnPoint.y, data.spawnPoint.z, data.spawnPoint.w or 0.0)
    end
    if data.originCoords then
        originCoords = vector3(data.originCoords.x, data.originCoords.y, data.originCoords.z)
    end

    if not spawnPoint then
        cb({ success = false, message = "No spawn point available." })
        return
    end

    -- Parse color
    if color and type(color) == "string" then
        color = json.decode(color)
    end

    -- Capture where to return the player at drive end. The showroom's
    -- CleanupShowroom (invoked next) stashes the player's pre-showroom
    -- coords in ShowroomState.savedCoords, but by the time EndTestDrive
    -- runs that state is long gone. Read the player's current position
    -- here — this is the spot they triggered the test drive from —
    -- before any teleport/bucket work happens.
    local prePlayerCoords = GetEntityCoords(PlayerPedId())

    -- Tear the showroom scene down FIRST (ped restoration, camera, fade). If
    -- we spawn the vehicle and warp the player while the showroom still has
    -- them frozen off-world, CleanupShowroom runs afterwards and teleports
    -- them back to the interaction point — clobbering the warp. Running it
    -- inline here serializes the transition cleanly.
    if CleanupShowroom then
        CleanupShowroom(true) -- skip fade-in; we'll handle it after the spawn
        Wait(100)
        -- After showroom cleanup, the ped is back at its pre-showroom
        -- position — more accurate than the position captured above,
        -- which was the frozen showroom-camera origin.
        prePlayerCoords = GetEntityCoords(PlayerPedId())
    end

    -- Move the player to a dedicated routing bucket BEFORE spawning so the
    -- test-drive vehicle is created in the same instance. Everyone else at
    -- the dealership stays in the default bucket — no cross-player collisions
    -- during the drive.
    if not lib.callback.await('pickle_dealerships:authorizeTestDrive',false,{dealershipId=dealershipId,model=model}) then
        cb({success=false,message='Test drive authorization failed.'}); return
    end
    TriggerServerEvent('pickle_dealerships:enterTestDriveBucket')
    Wait(200) -- let the server-side bucket change take effect

    -- Spawn test drive vehicle
    local veh = SpawnPurchasedVehicle(model, spawnPoint, color)
    if not veh then
        TriggerServerEvent('pickle_dealerships:leaveTestDriveBucket')
        DoScreenFadeIn(300)
        cb({ success = false, message = "Failed to spawn test drive vehicle." })
        return
    end

    -- Force the player into the driver seat. SpawnPurchasedVehicle already
    -- issues TaskWarpPedIntoVehicle, but SetPedIntoVehicle is the synchronous
    -- "just put them there" call — run both and retry a couple of times, since
    -- bucket transitions can drop the first assignment.
    local ped = PlayerPedId()
    local attempts = 0
    while attempts < 5 and GetVehiclePedIsIn(ped, false) ~= veh do
        local vc = GetEntityCoords(veh)
        SetEntityCoords(ped, vc.x, vc.y, vc.z, false, false, false, false)
        SetPedIntoVehicle(ped, veh, -1)
        Wait(100)
        attempts = attempts + 1
    end
    DoScreenFadeIn(400)

    -- Lock vehicle so only the player can enter
    SetVehicleDoorsLocked(veh, 2)
    SetVehicleDoorsLockedForAllPlayers(veh, true)
    SetVehicleDoorsLockedForPlayer(veh, PlayerId(), false)

    -- SpawnPurchasedVehicle already handed out keys; re-issue here so the
    -- test driver still owns the plate after any lock/bucket reshuffle above.
    GiveVehicleKeys(veh)

    testDriveActive = true
    testDriveVehicle = veh
    testDriveTimer = Config.TestDriveTime or 120
    testDriveDealershipId = dealershipId
    testDriveOrigin = originCoords or GetEntityCoords(PlayerPedId())
    -- Where to put the player when the drive ends. Use the captured
    -- pre-drive ped coords (the spot they kicked the drive off from) and
    -- fall back to the dealership origin if that's somehow missing.
    testDriveReturnCoords = prePlayerCoords or testDriveOrigin
    testDriveNearBoundary = false

    -- Create radius blip
    if testDriveOrigin then
        local radius = Config.TestDriveRadius or 500.0
        testDriveRadiusBlip = AddBlipForRadius(testDriveOrigin.x, testDriveOrigin.y, testDriveOrigin.z, radius)
        SetBlipColour(testDriveRadiusBlip, 1)
        SetBlipAlpha(testDriveRadiusBlip, 80)
        SetBlipHighDetail(testDriveRadiusBlip, true)

        testDriveBlip = AddBlipForCoord(testDriveOrigin.x, testDriveOrigin.y, testDriveOrigin.z)
        SetBlipSprite(testDriveBlip, 326)
        SetBlipColour(testDriveBlip, 1)
        SetBlipScale(testDriveBlip, 0.8)
        SetBlipRoute(testDriveBlip, false)
        BeginTextCommandSetBlipName("STRING")
        AddTextComponentString(_L("blip_test_drive_area"))
        EndTextCommandSetBlipName(testDriveBlip)
    end

    ShowNotification(_L("sales_test_drive_started", testDriveTimer))
    SendNUIMessage({
        type = "testDriveSubtitle",
        data = { visible = true, text = _L("sales_test_drive_end_hint") },
    })
    cb({ success = true })
end)

-- NUI-driven subtitle. Lua fires one message on start/end; the React overlay
-- (components/TestDriveSubtitle.tsx) handles the actual drawing. Keybind
-- listener runs at per-frame cadence only while a drive is active.
CreateThread(function()
    while true do
        if testDriveActive then
            if IsControlJustReleased(0, 177) then -- INPUT_FRONTEND_CANCEL (Backspace on PC)
                EndTestDrive()
            end
            Wait(0)
        else
            Wait(500)
        end
    end
end)

-- ─── Test Drive Monitor Thread ──────────────────────────────────────────────

CreateThread(function()
    while true do
        if testDriveActive then
            local wait = 1000
            testDriveTimer = testDriveTimer - 1

            -- Check timer expiry
            if testDriveTimer <= 0 then
                ShowNotification(_L("sales_test_drive_expired"))
                EndTestDrive()
            else
                -- Check distance from dealership
                if testDriveOrigin then
                    local playerCoords = GetEntityCoords(PlayerPedId())
                    local dist = #(playerCoords - testDriveOrigin)
                    local radius = Config.TestDriveRadius or 500.0

                    if dist > radius then
                        ShowNotification(_L("sales_test_drive_too_far"))
                        EndTestDrive()
                    elseif dist > radius * 0.85 then
                        -- Edge-trigger the warning — only when the driver
                        -- crosses into the outer 15% for the first time.
                        -- Without this the monitor's 1-second tick would
                        -- spam the same toast for every second the driver
                        -- hovers near the edge.
                        if not testDriveNearBoundary then
                            testDriveNearBoundary = true
                            ShowNotification(_L("sales_test_drive_boundary"))
                        end
                    else
                        -- Back inside the safe zone — rearm so a later
                        -- approach fires the warning again.
                        testDriveNearBoundary = false
                    end
                end

                -- Check if vehicle still exists
                if testDriveVehicle and not DoesEntityExist(testDriveVehicle) then
                    ShowNotification(_L("sales_test_drive_lost"))
                    EndTestDrive()
                end

                -- Show remaining time every 30 seconds
                if testDriveTimer > 0 and testDriveTimer % 30 == 0 then
                    ShowNotification(_L("sales_test_drive_remaining", testDriveTimer))
                end
            end

            Wait(wait)
        else
            Wait(1000)
        end
    end
end)

-- ─── Employee Sale Confirmation ─────────────────────────────────────────────

RegisterNetEvent("pickle_dealerships:confirmPurchase", function(data)
    local function declineToSeller(reason)
        TriggerServerEvent("pickle_dealerships:saleDeclined", {
            soldBy = data.soldBy,
            label = data.label or data.model,
            reason = reason,
        })
    end

    local alert = lib.alertDialog({
        header = _L("sales_confirm_header"),
        content = _L("sales_confirm_body",
            data.sellerName or "A salesperson",
            data.label or data.model,
            GetCurrencyString(data.price)
        ),
        centered = true,
        cancel = true,
    })

    if alert ~= "confirm" then
        ShowNotification(_L("sales_purchase_declined"))
        declineToSeller("declined")
        return
    end

    -- Ask payment method. inputDialog returns nil on cancel/close — treat
    -- that as a decline rather than silently defaulting to bank.
    local input = lib.inputDialog(_L("sales_payment_method"), {
        { type = "select", label = _L("sales_payment_method"), options = {
            { value = "cash", label = _L("sales_payment_cash") },
            { value = "bank", label = _L("sales_payment_bank") },
        }, default = "bank" },
    })

    if not input or not input[1] then
        ShowNotification(_L("sales_purchase_declined"))
        declineToSeller("declined")
        return
    end
    local paymentMethod = input[1]

    local result = lib.callback.await("pickle_dealerships:confirmEmployeeSale", false, {
        dealershipId = data.dealershipId,
        stockId = data.stockId,
        paymentMethod = paymentMethod,
        couponCode = data.couponCode,
        couponItemSlot=data.couponItemSlot,
        soldBy = data.soldBy,
        price = data.price,
    })

    if result and result.success then
        -- Resolve spawn point from the specific dealership the
        -- employee was selling at — the server trigger carries the
        -- location key, and the server callback echoes it back.
        local location = data.location or result.location
        local cfg = location and DealershipConfigs[location]
        local spawnPoint = cfg and cfg.spawnPoint
        if spawnPoint then
            SpawnPurchasedVehicle(result.model, spawnPoint, nil)
        end
        ShowNotification(_L("sales_purchase_success", result.label or result.model))
        -- Server notifies the seller on its end (it knows the final price /
        -- buyer name) so we don't need to do it here.
    else
        ShowNotification(result and result.message or _L("sales_purchase_failed"))
        declineToSeller(result and result.message or "failed")
    end
end)


-- ─── Cleanup ────────────────────────────────────────────────────────────────

AddEventHandler("onResourceStop", function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    if testDriveActive then
        EndTestDrive()
    end
end)
