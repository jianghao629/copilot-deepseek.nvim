local eq = MiniTest.expect.equality
local child_helper = require("tests.child_helper")
local child = child_helper.new_child_neovim("test_deepseek")

local function wait_until(fn, timeout)
  return vim.wait(timeout or 5000, fn, 50)
end

---Start the plugin with the DeepSeek backend and a mocked curl response.
---@param response table
local function setup_with_mocked_api(response)
  child.lua(
    string.format(
      [[
        local response = vim.json.decode(%q)
        _G.curl_calls = {}
        vim.system = function(cmd, _, on_exit)
          table.insert(_G.curl_calls, cmd)
          if on_exit then
            on_exit({ code = 0, stdout = vim.json.encode(response), stderr = "" })
          end
          return {
            wait = function()
              return { code = 0, stdout = "", stderr = "" }
            end,
            kill = function() end,
          }
        end
        M.setup({ backend = "deepseek", deepseek = { api_key = "test-key" } })
      ]],
      vim.json.encode(response)
    )
  )

  return wait_until(function()
    return child.lua("return require('copilot.client').initialized and require('copilot.client').get() ~= nil")
  end)
end

---@param lines string[]
local function set_buffer_lines(lines)
  child.lua(
    string.format(
      [[
        local lines = vim.json.decode(%q)
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_set_current_buf(buf)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        _G.done = false
        _G.request_error = nil
        _G.request_data = nil
        local client = require("copilot.client").get()
        local params = require("copilot.util").get_doc_params()
        require("copilot.api").get_completions(client, params, function(err, data)
          _G.request_error = err
          _G.request_data = data
          _G.done = true
        end)
      ]],
      vim.json.encode(lines)
    )
  )

  return wait_until(function()
    return child.lua("return _G.done")
  end)
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.run_pre_case(true)
      -- Use the real copilot.lsp module: the DeepSeek backend is an
      -- in-process LSP client and does not need a mocked language server.
      child.lua([[
        for name in pairs(package.loaded) do
          if name == "copilot" or name:match("^copilot%.") then
            package.loaded[name] = nil
          end
        end
        M = require("copilot")
      ]])
    end,
    post_once = child.stop,
  },
})

T["deepseek"] = MiniTest.new_set()

T["deepseek"]["configures the backend and the server type"] = function()
  child.lua([[
    M.setup({ backend = "deepseek", deepseek = { api_key = "test-key" } })
  ]])

  eq(child.lua("return require('copilot.config').backend"), "deepseek")
  eq(child.lua("return require('copilot.config').server.type"), "deepseek")
end

T["deepseek"]["starts an in-process LSP provider"] = function()
  local response = { id = "test-id", choices = { { text = " hello world" } } }

  eq(setup_with_mocked_api(response), true)
  eq(child.lua("return require('copilot.client').get().name"), "copilot")

  local server_info = child.lua("return require('copilot.lsp').get_server_info(require('copilot.client').get())")
  eq(server_info:find("DeepSeek FIM Backend", 1, true) ~= nil, true)
end

T["deepseek"]["returns completions from the FIM API"] = function()
  local response = { id = "test-id", choices = { { text = " hello world" } } }

  eq(setup_with_mocked_api(response), true)
  eq(set_buffer_lines({ "local function add(a, b)", "  re" }), true)
  eq(child.lua("return _G.request_error == nil"), true)
  eq(child.lua("return _G.request_data.completions[1].text"), " hello world")

  local request = child.lua([[
    local call = _G.curl_calls[#_G.curl_calls]
    local body
    for i, value in ipairs(call) do
      if value == "-d" then
        body = vim.json.decode(call[i + 1])
      end
    end
    return { call = call, body = body }
  ]])

  eq(type(request.body.prompt), "string")
  eq(type(request.body.suffix), "string")
  eq(request.body.model, "deepseek-flash")
  eq(vim.tbl_contains(request.call, "https://api.deepseek.com/beta/completions"), true)
end

T["deepseek"]["includes related files context in the prompt"] = function()
  local response = { id = "test-id", choices = { { text = " done" } } }

  eq(setup_with_mocked_api(response), true)

  child.lua([[
    vim.cmd("edit shared.lua")
    local shared = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(shared, 0, -1, false, { "-- shared logic" })
    vim.api.nvim_set_option_value("filetype", "lua", { buf = shared })
    vim.cmd("edit main.lua")
    local main = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(main, 0, -1, false, { "local x = 1" })
    _G.done = false
    local client = require("copilot.client").get()
    local params = require("copilot.util").get_doc_params()
    require("copilot.api").get_completions(client, params, function(_, data)
      _G.request_data = data
      _G.done = true
    end)
  ]])

  eq(wait_until(function()
    return child.lua("return _G.done")
  end), true)

  local prompt = child.lua([[
    local call = _G.curl_calls[#_G.curl_calls]
    for i, value in ipairs(call) do
      if value == "-d" then
        return vim.json.decode(call[i + 1]).prompt
      end
    end
    return ""
  ]])

  eq(prompt:find("shared.lua", 1, true) ~= nil, true)
  eq(prompt:find("-- shared logic", 1, true) ~= nil, true)
end

T["deepseek"]["reports a missing API key as an error"] = function()
  child.lua([[
    vim.env.DEEPSEEK_API_KEY = nil
    M.setup({ backend = "deepseek" })
  ]])
  eq(wait_until(function()
    return child.lua("return require('copilot.client').initialized and require('copilot.client').get() ~= nil")
  end), true)

  child.lua([[
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local x = 1" })
    _G.done = false
    _G.request_error = nil
    local client = require("copilot.client").get()
    local params = require("copilot.util").get_doc_params()
    require("copilot.api").get_completions(client, params, function(err)
      _G.request_error = err
      _G.done = true
    end)
  ]])

  eq(wait_until(function()
    return child.lua("return _G.done")
  end), true)
  eq(child.lua("return type(_G.request_error) == 'string'"), true)
end

return T
