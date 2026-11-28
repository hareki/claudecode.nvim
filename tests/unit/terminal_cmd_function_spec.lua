require("tests.busted_setup")
require("tests.mocks.vim")

describe("a function-valued terminal_cmd", function()
  local terminal
  local opened

  local function provider()
    return {
      setup = function() end,
      open = function(cmd_string)
        table.insert(opened, cmd_string)
      end,
      close = function() end,
      simple_toggle = function(cmd_string)
        table.insert(opened, cmd_string)
      end,
      focus_toggle = function(cmd_string)
        table.insert(opened, cmd_string)
      end,
      get_active_bufnr = function()
        return nil
      end,
      is_available = function()
        return true
      end,
    }
  end

  before_each(function()
    opened = {}
    package.loaded["claudecode.terminal"] = nil
    package.loaded["claudecode.server.init"] = { state = { port = 12345 } }
    package.loaded["claudecode.logger"] = {
      debug = function() end,
      warn = function() end,
      error = function() end,
    }
    terminal = require("claudecode.terminal")
  end)

  after_each(function()
    package.loaded["claudecode.terminal"] = nil
    package.loaded["claudecode.server.init"] = nil
    package.loaded["claudecode.logger"] = nil
  end)

  it("is asked for the command on every open and toggle", function()
    local asked = 0
    terminal.setup({ provider = provider() }, function()
      asked = asked + 1
      return asked == 1 and "claude --resume abc" or "claude"
    end, {})

    terminal.open()
    terminal.simple_toggle()
    terminal.focus_toggle()

    assert.are.same({ "claude --resume abc", "claude", "claude" }, opened)
  end)

  it("takes the arguments of the call after its own", function()
    terminal.setup({ provider = provider() }, function()
      return "claude --resume abc"
    end, {})

    terminal.open({}, "--model opus")

    assert.are.same({ "claude --resume abc --model opus" }, opened)
  end)

  it("falls back to claude when it returns nothing", function()
    terminal.setup({ provider = provider() }, function() end, {})

    terminal.open()

    assert.are.same({ "claude" }, opened)
  end)

  it("passes the config validation, where a number does not", function()
    package.loaded["claudecode.config"] = nil
    local config = require("claudecode.config")

    local applied = config.apply({
      terminal_cmd = function()
        return "claude"
      end,
    })
    assert.are.equal("function", type(applied.terminal_cmd))

    assert.has_error(function()
      config.apply({ terminal_cmd = 42 })
    end)
  end)
end)
