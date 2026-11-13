local config = require("copilot.config")
local logger = require("copilot.logger")
local util = require("copilot.util")

local M = {
  initialization_failed = false,
}

local function get_api_key()
  return config.deepseek.api_key or os.getenv("DEEPSEEK_API_KEY")
end

---Resolve the buffer a request belongs to. Requests made through the LSP client
---only carry the document URI, so fall back to the buffer the URI maps to.
---@param params table
---@return integer
local function resolve_bufnr(params)
  if params.bufnr and vim.api.nvim_buf_is_valid(params.bufnr) then
    return params.bufnr
  end

  local doc = params.doc or {}
  if doc.uri then
    local bufnr = vim.fn.bufnr(vim.uri_to_fname(doc.uri))
    if bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr) then
      return bufnr
    end
  end

  return vim.api.nvim_get_current_buf()
end

---@param dispatchers vim.lsp.rpc.Dispatchers
---@return vim.lsp.rpc.PublicClient
function M.start(dispatchers)
  local closing = false
  local message_id = 0

  local function next_id()
    message_id = message_id + 1
    return message_id
  end

  ---@param payload table
  ---@param callback fun(err: string|nil, result: table|nil)
  local function deepseek_request(payload, callback)
    local api_key = get_api_key()
    if not api_key then
      callback("DeepSeek API key not found, set `deepseek.api_key` or `DEEPSEEK_API_KEY`", nil)
      return
    end

    local body = vim.json.encode(payload)
    vim.system({
      "curl",
      "-s",
      "-X",
      "POST",
      config.deepseek.endpoint,
      "-H",
      "Content-Type: application/json",
      "-H",
      "Authorization: Bearer " .. api_key,
      "-d",
      body,
    }, {
      text = true,
    }, function(out)
      if out.code ~= 0 then
        callback("DeepSeek API request failed: " .. (out.stderr or "unknown error"), nil)
        return
      end

      local ok, result = pcall(vim.json.decode, out.stdout)
      if not ok then
        callback("Failed to decode DeepSeek API response: " .. tostring(result), nil)
        return
      end

      if result.error then
        callback("DeepSeek API error: " .. (result.error.message or "unknown error"), nil)
        return
      end

      callback(nil, result)
    end)
  end

  ---@param params table
  ---@param callback fun(err: string|nil, data: table|nil)
  local function handle_get_completions(params, callback)
    local bufnr = resolve_bufnr(params)
    local prefix, suffix = util.get_fim_context(bufnr, params.doc.position)
    local extra_context = util.get_related_files_context(bufnr, 1024)

    local payload = {
      model = config.deepseek.model,
      prompt = extra_context .. "\n" .. prefix,
      suffix = suffix,
      max_tokens = 1024,
      temperature = 0,
      n = 1,
    }

    deepseek_request(payload, function(err, result)
      if err then
        vim.schedule(function()
          callback(err, nil)
        end)
        return
      end

      local completions = {}
      for i, choice in ipairs(result.choices or {}) do
        table.insert(completions, {
          text = choice.text,
          displayText = choice.text,
          uuid = "deepseek-" .. tostring(result.id or next_id()) .. "-" .. i,
          range = {
            start = params.doc.position,
            ["end"] = params.doc.position,
          },
        })
      end

      logger.debug("DeepSeek completions received:", completions)
      vim.schedule(function()
        callback(nil, { completions = completions })
      end)
    end)
  end

  ---@param params table
  ---@param callback fun(err: string|nil, data: table|nil)
  local function handle_get_panel_completions(params, callback)
    local bufnr = resolve_bufnr(params)
    local prefix, suffix = util.get_fim_context(bufnr, params.doc.position)
    local extra_context = util.get_related_files_context(bufnr, 1024)

    local payload = {
      model = config.deepseek.model,
      prompt = extra_context .. "\n" .. prefix,
      suffix = suffix,
      max_tokens = 1024,
      temperature = 0.7,
      n = 1,
    }

    vim.schedule(function()
      callback(nil, { solutionCountTarget = 1 })
    end)

    deepseek_request(payload, function(err, result)
      vim.schedule(function()
        if err then
          dispatchers.notification("PanelSolutionsDone", {
            panelId = params.panelId,
            status = "Error",
            message = err,
          })
          return
        end

        logger.debug("DeepSeek panel solutions received:", result.choices)

        for i, choice in ipairs(result.choices or {}) do
          dispatchers.notification("PanelSolution", {
            panelId = params.panelId,
            solutionId = "deepseek-panel-" .. tostring(result.id or next_id()) .. "-" .. i,
            displayText = choice.text,
            completionText = choice.text,
            range = {
              start = params.doc.position,
              ["end"] = params.doc.position,
            },
            score = 0,
          })
        end

        dispatchers.notification("PanelSolutionsDone", {
          panelId = params.panelId,
          status = "OK",
        })
      end)
    end)
  end

  return {
    request = function(method, params, callback)
      if method == "initialize" then
        vim.schedule(function()
          callback(nil, {
            capabilities = {
              textDocumentSync = 1,
            },
            serverInfo = {
              name = "DeepSeek FIM",
              version = "1.0.0",
            },
          })
        end)
        return true, next_id()
      elseif method == "initialized" then
        return true, next_id()
      elseif method == "checkStatus" then
        local has_api_key = get_api_key() ~= nil
        vim.schedule(function()
          callback(nil, {
            status = has_api_key and "OK" or "NotAuthorized",
            user = has_api_key and "DeepSeek User" or nil,
          })
        end)
        return true, next_id()
      elseif method == "getCompletions" or method == "getCompletionsCycling" then
        handle_get_completions(params, callback)
        return true, next_id()
      elseif method == "getPanelCompletions" then
        handle_get_panel_completions(params, callback)
        return true, next_id()
      elseif method == "signInInitiate" or method == "signInConfirm" then
        vim.schedule(function()
          callback("DeepSeek backend does not support GitHub sign-in", nil)
        end)
        return true, next_id()
      elseif method == "getVersion" then
        vim.schedule(function()
          callback(nil, { version = "deepseek-v1" })
        end)
        return true, next_id()
      elseif method == "copilot/models" then
        vim.schedule(function()
          callback(nil, {
            {
              id = config.deepseek.model,
              modelName = config.deepseek.model,
              scopes = { "completion" },
              default = true,
            },
          })
        end)
        return true, next_id()
      elseif method == "shutdown" then
        vim.schedule(function()
          callback(nil, nil)
        end)
        return true, next_id()
      elseif method == "exit" then
        return true, next_id()
      end

      vim.schedule(function()
        callback("Method not implemented: " .. tostring(method), nil)
      end)
      return true, next_id()
    end,
    notify = function()
      return true
    end,
    is_closing = function()
      return closing
    end,
    terminate = function()
      closing = true
    end,
  }
end

function M.setup()
  return true
end

function M.init()
  return true
end

function M.get_server_info()
  return "DeepSeek FIM Backend (" .. config.deepseek.model .. ")"
end

function M.get_execute_command()
  return M.start
end

return M
