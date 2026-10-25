-- =============================================
--  pickle_dealerships | modules/employees/client.lua
--  Employee management NUI callbacks
-- =============================================

RegisterNUICallback("hireEmployee", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:hireEmployee", false, data)
    if result and result.message then ShowNotification(result.message) end
    cb(result)
end)

RegisterNUICallback("fireEmployee", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:fireEmployee", false, {
        dealershipId = data.dealershipId,
        targetServerId = data.targetServerId or data.serverId,
        targetIdentifier = data.targetIdentifier or data.identifier,
    })
    if result and result.message then ShowNotification(result.message) end
    cb(result)
end)

RegisterNUICallback("getEmployees", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:getEmployees", false, data)
    cb(result)
end)

RegisterNUICallback("setEmployeeRole", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:setEmployeeRole", false, {
        dealershipId = data.dealershipId,
        targetServerId = data.targetServerId or data.serverId,
        role = data.role,
    })
    cb(result)
end)

RegisterNUICallback("setEmployeeCommissionOverride", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:setEmployeeCommissionOverride", false, {
        dealershipId = data.dealershipId,
        identifier   = data.identifier,
        rate         = data.rate,
    })
    cb(result)
end)

RegisterNUICallback("getNearbyPlayers", function(data, cb)
    local myPed = PlayerPedId()
    local myCoords = GetEntityCoords(myPed)
    local myServerId = GetPlayerServerId(PlayerId())
    local maxDistance = 50.0
    local players = {}

    for _, playerId in ipairs(GetActivePlayers()) do
        local serverId = GetPlayerServerId(playerId)
        if serverId ~= myServerId then
            local targetPed = GetPlayerPed(playerId)
            if targetPed and DoesEntityExist(targetPed) then
                local targetCoords = GetEntityCoords(targetPed)
                local dist = #(myCoords - targetCoords)
                if dist <= maxDistance then
                    players[#players + 1] = {
                        serverId = serverId,
                        name = GetPlayerName(playerId),
                        distance = math.floor(dist),
                    }
                end
            end
        end
    end

    -- Sort by distance
    table.sort(players, function(a, b) return a.distance < b.distance end)
    cb({ players = players })
end)

RegisterNetEvent("pickle_dealerships:customerArrived", function(data)
    ShowNotification(_L("employee_customer_arrived"))
end)

lib.callback.register('pickle_dealerships:confirmEmployment',function(data)
    return lib.alertDialog({header='Employment offer',content='Join '..tostring(data.name)..' at grade '..tostring(data.grade)..'?',cancel=true})=='confirm'
end)
