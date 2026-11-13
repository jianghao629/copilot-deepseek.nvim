---@class (exact) DeepSeekConfig
---@field api_key string|nil DeepSeek API key, falls back to the DEEPSEEK_API_KEY environment variable
---@field endpoint string DeepSeek FIM API endpoint
---@field model string DeepSeek FIM capable model
---@field max_tokens integer Upper bound for a single completion
---@field temperature number Sampling temperature for completions
---@field context_chars integer Characters of prefix/suffix context sent to the FIM API
---@field related_context_chars integer Characters of same-filetype buffer context sent with the request
---@field related_context_lines integer Lines read from each related buffer

local deepseek = {
  ---@type DeepSeekConfig
  default = {
    api_key = nil,
    endpoint = "https://api.deepseek.com/beta/completions",
    model = "deepseek-flash",
    max_tokens = 1024,
    temperature = 0,
    context_chars = 2048,
    related_context_chars = 1024,
    related_context_lines = 100,
  },
}

function deepseek.validate(config)
  vim.validate("api_key", config.api_key, { "string", "nil" })
  vim.validate("endpoint", config.endpoint, "string")
  vim.validate("model", config.model, "string")
  vim.validate("max_tokens", config.max_tokens, function(value)
    return type(value) == "number" and value > 0 and value % 1 == 0
  end, false, "positive integer")
  vim.validate("temperature", config.temperature, function(value)
    return type(value) == "number" and value >= 0 and value <= 2
  end, false, "number between 0 and 2")
  vim.validate("context_chars", config.context_chars, "number")
  vim.validate("related_context_chars", config.related_context_chars, "number")
  vim.validate("related_context_lines", config.related_context_lines, "number")
end

return deepseek
