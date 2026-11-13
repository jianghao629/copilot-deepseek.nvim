---@class (exact) DeepSeekConfig
---@field api_key string|nil DeepSeek API key, falls back to the DEEPSEEK_API_KEY environment variable
---@field endpoint string DeepSeek FIM API endpoint
---@field model string DeepSeek FIM capable model

local deepseek = {
  ---@type DeepSeekConfig
  default = {
    api_key = nil,
    endpoint = "https://api.deepseek.com/beta/completions",
    model = "deepseek-flash",
  },
}

function deepseek.validate(config)
  vim.validate("api_key", config.api_key, { "string", "nil" })
  vim.validate("endpoint", config.endpoint, "string")
  vim.validate("model", config.model, "string")
end

return deepseek
