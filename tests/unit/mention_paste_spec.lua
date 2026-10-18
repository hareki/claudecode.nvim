require("tests.busted_setup")
require("tests.mocks.vim")

-- #249: while a managed Claude terminal is running, @ mentions are pasted into it rather than
-- broadcast as at_mentioned, which the CLI routes to the agents view's hidden composer once
-- that view has been opened (even while a session opened from it is on screen).

describe("mention_paste.format", function()
  local format = require("claudecode.mention_paste").format

  it("formats a whole file", function()
    assert.are.equal("@src/foo.lua", format("src/foo.lua", nil, nil))
  end)

  it("formats a range with 1-based lines", function()
    assert.are.equal("@src/foo.lua#L3-5", format("src/foo.lua", 2, 4))
  end)

  it("formats a single line without a range", function()
    assert.are.equal("@src/foo.lua#L3", format("src/foo.lua", 2, 2))
  end)

  it("drops the range when an end is missing, like Claude's own insertion", function()
    assert.are.equal("@src/foo.lua", format("src/foo.lua", 2, nil))
  end)

  it("keeps a directory's trailing slash", function()
    assert.are.equal("@lua/", format("lua/", nil, nil))
  end)

  it("quotes a path containing whitespace, range included", function()
    assert.are.equal('@"my dir/foo.lua#L3-5"', format("my dir/foo.lua", 2, 4))
  end)

  it("strips control characters so a crafted file name cannot end the paste early", function()
    assert.are.equal("@x[201~y.lua", format("x\27[201~y\r.lua", nil, nil))
  end)

  it("keeps multi-byte characters intact", function()
    assert.are.equal("@tệp.lua", format("tệp.lua", nil, nil))
  end)
end)

describe("@ mention delivery through the Claude terminal (#249)", function()
  local saved_require
  local saved_getcwd
  local saved_isdirectory
  local claudecode
  local mock_terminal
  local mock_server

  ---@param text string
  local function assert_pasted(text)
    assert.spy(mock_terminal.send_to_terminal).was_called_with("\27[200~" .. text .. "\27[201~", { submit = false })
  end

  ---@param file_path string
  ---@param line_start number?
  ---@param line_end number?
  local function assert_broadcast(file_path, line_start, line_end)
    assert.spy(mock_server.broadcast).was_called_with("at_mentioned", {
      filePath = file_path,
      lineStart = line_start,
      lineEnd = line_end,
    })
  end

  ---@param opts { bufnr?: integer, paste_ok?: boolean }?
  local function setup(opts)
    opts = opts or {}

    mock_terminal = {
      ensure_visible = function() end,
      get_active_terminal_bufnr = function()
        return opts.bufnr
      end,
      send_to_terminal = spy.new(function()
        return opts.paste_ok ~= false
      end),
    }

    mock_server = {
      broadcast = spy.new(function()
        return true
      end),
    }

    local mock_logger = {
      setup = function() end,
      debug = function() end,
      info = function() end,
      warn = function() end,
      error = function() end,
    }

    local mock_config = {
      apply = function()
        return { queue_timeout = 5000 }
      end,
    }

    saved_require = _G.require
    _G.require = function(mod)
      if mod == "claudecode.config" then
        return mock_config
      elseif mod == "claudecode.logger" then
        return mock_logger
      elseif mod == "claudecode.diff" then
        return { setup = function() end }
      elseif mod == "claudecode.terminal" then
        return mock_terminal
      elseif mod == "claudecode.server.init" then
        return {
          get_status = function()
            return { running = true, client_count = 1 }
          end,
        }
      else
        return saved_require(mod)
      end
    end

    saved_getcwd = vim.fn.getcwd
    saved_isdirectory = vim.fn.isdirectory
    vim.fn.getcwd = function()
      return "/Users/test/project"
    end
    vim.fn.isdirectory = function()
      return 0
    end

    package.loaded["claudecode"] = nil
    claudecode = require("claudecode")
    claudecode.setup({})
    claudecode.state.server = mock_server
  end

  after_each(function()
    _G.require = saved_require
    vim.fn.getcwd = saved_getcwd
    vim.fn.isdirectory = saved_isdirectory
    package.loaded["claudecode"] = nil
  end)

  describe("send_at_mention", function()
    it("pastes into the managed terminal instead of broadcasting", function()
      setup({ bufnr = 7 })

      local ok = claudecode.send_at_mention("/Users/test/project/src/foo.lua", 2, 4, "test")

      assert.is_true(ok)
      assert_pasted(" @src/foo.lua#L3-5 ")
      assert.spy(mock_server.broadcast).was_not_called()
    end)

    it("broadcasts at_mentioned when no managed terminal is running", function()
      setup()

      claudecode.send_at_mention("/Users/test/project/src/foo.lua", 2, 4, "test")

      assert.spy(mock_terminal.send_to_terminal).was_not_called()
      assert_broadcast("src/foo.lua", 2, 4)
    end)

    it("falls back to the broadcast when the paste fails", function()
      setup({ bufnr = 7, paste_ok = false })

      claudecode.send_at_mention("/Users/test/project/src/foo.lua", 2, 4, "test")

      assert.spy(mock_terminal.send_to_terminal).was_called()
      assert_broadcast("src/foo.lua", 2, 4)
    end)
  end)

  describe("process_mention_queue", function()
    before_each(function()
      setup({ bufnr = 7 })
      -- Queue through the real send path. The mock debounce timer never fires, so tests flush by hand.
      claudecode.state.config.enable_broadcast_debouncing_in_tests = true
    end)

    it("pastes a debounced batch as a single paste", function()
      claudecode.send_at_mention("/Users/test/project/a.lua", nil, nil, "test")
      claudecode.send_at_mention("/Users/test/project/b.lua", 0, 1, "test")

      claudecode.process_mention_queue()

      assert.spy(mock_terminal.send_to_terminal).was_called(1)
      assert_pasted(" @a.lua @b.lua#L1-2 ")
      assert.spy(mock_server.broadcast).was_not_called()
      assert.are.equal(0, #claudecode.state.mention_queue)
    end)

    it("keeps the WebSocket for the flush that follows a new connection", function()
      claudecode.send_at_mention("/Users/test/project/a.lua", nil, nil, "test")

      claudecode.process_mention_queue(true)

      assert.spy(mock_terminal.send_to_terminal).was_not_called()
      assert_broadcast("a.lua")
    end)
  end)
end)

-- paste adds the bracketed-paste markers itself because send_to_terminal only adds them to
-- multi-line text. Pin the bytes that reach the pty so an upstream change to that rule fails here
-- instead of double-wrapping mentions or typing them as keystrokes.
describe("mention_paste.paste through the real send_to_terminal", function()
  local BUF = 4242
  local saved_server
  local saved_chansend
  local written

  before_each(function()
    -- terminal.lua requires the server at load, and the real one loads the whole plugin
    saved_server = package.loaded["claudecode.server.init"]
    package.loaded["claudecode.server.init"] = {}
    package.loaded["claudecode.terminal"] = nil
    require("claudecode.terminal").get_active_terminal_bufnr = function()
      return BUF
    end
    vim._buffers[BUF] = { lines = {}, options = {}, b_vars = { terminal_job_id = 42 } }

    written = {}
    saved_chansend = vim.fn.chansend
    vim.fn.chansend = function(_, data)
      table.insert(written, data)
      return #data
    end
  end)

  after_each(function()
    vim.fn.chansend = saved_chansend
    vim._buffers[BUF] = nil
    package.loaded["claudecode.terminal"] = nil
    package.loaded["claudecode.server.init"] = saved_server
  end)

  it("writes one bracketed paste without a submit, even for a crafted file name", function()
    assert.is_true(require("claudecode.mention_paste").paste({ { file_path = "x\27[201~y\r.lua" } }))
    assert.are.same({ "\27[200~ @x[201~y.lua \27[201~" }, written)
  end)
end)
