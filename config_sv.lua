if not IsDuplicityVersion() then return end

ServerConfig = {}
-- Explicit server resource allowlist for repossession exports.
ServerConfig.RepoResources = {}

-- Discord Webhooks
-- Lives in config_sv.lua (never replicated to clients). Set per-category URLs
-- below; leave a URL blank to disable that category. Fallback URL is used if a
-- category has no specific URL set.
ServerConfig.Webhooks = {
    enabled = false,
    botName = "Pickle Dealerships",
    avatar = "", -- optional icon URL
    fallback = "", -- used when a category URL is empty
    urls = {
        sales = "",            -- Player / NPC purchases, financing start
        stock = "",            -- Stock orders, deliveries, imports
        admin = "",            -- Dealership create/delete, transfers, admin overrides
        finances = "",         -- Withdrawals, deposits, balance adjustments
        employees = "",        -- Hires / fires / role changes
        financing = "",        -- Installment payments, defaults, repossessions
        security = "",         -- Denied actions, suspicious payloads
    },
    -- Threshold above which a withdrawal is flagged as "large" in the finances log.
    largeWithdrawalThreshold = 100000,
}

-- Image Upload Provider
-- Supported: "fivemanage", "custom"
ServerConfig.ImageUpload = {
    provider = "fivemanage",
    token = "TOKEN_HERE", -- Your FiveManage API token (https://www.fivemanage.com)

    -- Custom provider (only used when provider = "custom")
    custom = {
        url = "",              -- Upload endpoint URL
        field = "image",       -- Form field name for the image
        headers = {},          -- Additional headers, e.g. { ["Authorization"] = "Bearer ..." }
        returnPathKey = "url", -- Key in the JSON response that contains the image URL
    },
}
