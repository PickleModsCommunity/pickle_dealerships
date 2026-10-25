if GetResourceState('es_extended') == 'started' then return end
if GetResourceState('qb-core') == 'started' then return end
if GetResourceState('qbx_core') == 'started' then return end

function AddAlcohol(source, amount)
    -- No-op when no framework; implement in custom bridge if needed.
end

function AddOwnedVehicleWithProps(source, model, plate, properties)
    return false
end

function RemoveOwnedVehicle(identifier, plate)
    return false
end

--- No framework → no identifier-keyed name store. Callers treat nil as
--- "fall back to the raw identifier string" so standalone installs still
--- produce readable ledger entries.
function GetCharacterNameByIdentifier(_)
    return nil
end

print("STANDALONE IS NOT SUPPORTED, PLEASE CODE YOUR OWN BRIDGE.")