-- luacheck: globals expect
require("tests.busted_setup")

describe("trouble integration", function()
  local integrations
  local visual_commands

  local current_win
  local cursor_row
  local views

  -- A Trouble item row maps to its item and node, a group row to its node alone (trouble.view.render)
  local function item_row(filename)
    local item = { filename = filename }
    return { item = item, node = { item = item } }
  end

  local function group_row(filenames)
    local items = {}
    for _, filename in ipairs(filenames) do
      table.insert(items, { filename = filename })
    end
    return {
      node = {
        flatten = function()
          return items
        end,
      },
    }
  end

  -- A view whose list shows `rows` in window `win`, with the shape trouble.view.get() returns
  local function make_view(win, rows)
    return {
      view = {
        win = { win = win },
        renderer = {
          at = function(_, row)
            return rows[row] or {}
          end,
        },
      },
    }
  end

  local function set_trouble(view_list)
    views = view_list
    package.loaded["trouble.view"] = {
      get = function(filter)
        expect(filter).to_be_table()
        expect(filter.open).to_be_true()
        return views
      end,
    }
  end

  before_each(function()
    package.loaded["claudecode.integrations"] = nil
    package.loaded["claudecode.visual_commands"] = nil
    package.loaded["claudecode.trouble"] = nil
    package.loaded["claudecode.logger"] = {
      debug = function() end,
      warn = function() end,
      error = function() end,
    }
    package.loaded["trouble.view"] = nil

    current_win = 1000
    cursor_row = 1

    _G.vim = {
      bo = { filetype = "trouble" },
      api = {
        nvim_get_current_win = function()
          return current_win
        end,
        nvim_win_get_cursor = function(win)
          expect(win).to_be(current_win)
          return { cursor_row, 0 }
        end,
      },
    }

    integrations = require("claudecode.integrations")
    visual_commands = require("claudecode.visual_commands")
  end)

  describe("get_selected_files_from_tree", function()
    it("gives the file of the item row under the cursor", function()
      set_trouble({
        make_view(1000, {
          item_row("/project/a.lua"),
          item_row("/project/b.lua"),
        }),
      })
      cursor_row = 2

      local files, err = integrations.get_selected_files_from_tree()

      expect(err).to_be_nil()
      assert.are.same({ "/project/b.lua" }, files)
    end)

    it("gives each file under a group row once, in list order", function()
      set_trouble({
        make_view(1000, {
          group_row({ "/project/a.lua", "/project/b.lua", "/project/a.lua" }),
        }),
      })

      local files, err = integrations.get_selected_files_from_tree()

      expect(err).to_be_nil()
      assert.are.same({ "/project/a.lua", "/project/b.lua" }, files)
    end)

    it("gives no file on a row past the list", function()
      set_trouble({ make_view(1000, { item_row("/project/a.lua") }) })
      cursor_row = 5

      local files, err = integrations.get_selected_files_from_tree()

      expect(err).to_be_nil()
      assert.are.same({}, files)
    end)

    it("reads the list in the current window, not another open one", function()
      set_trouble({
        make_view(2000, { item_row("/other/list.lua") }),
        make_view(1000, { item_row("/project/a.lua") }),
      })

      local files, err = integrations.get_selected_files_from_tree()

      expect(err).to_be_nil()
      assert.are.same({ "/project/a.lua" }, files)
    end)

    it("errors when no Trouble list shows in the current window", function()
      set_trouble({ make_view(2000, { item_row("/other/list.lua") }) })

      local files, err = integrations.get_selected_files_from_tree()

      expect(err).to_be("No Trouble list in the current window")
      assert.are.same({}, files)
    end)

    it("errors when trouble.nvim is not installed", function()
      package.preload["trouble.view"] = function()
        error("module 'trouble.view' not found")
      end

      local files, err = integrations.get_selected_files_from_tree()

      package.preload["trouble.view"] = nil
      expect(err).to_be("trouble.nvim not available")
      assert.are.same({}, files)
    end)
  end)

  describe("get_files_from_visual_selection", function()
    it("gives the files of every row in the range, each once, in list order", function()
      set_trouble({
        make_view(1000, {
          group_row({ "/project/a.lua", "/project/b.lua" }),
          item_row("/project/a.lua"),
          item_row("/project/b.lua"),
          item_row("/project/c.lua"),
          item_row("/project/d.lua"),
        }),
      })

      local tree_state, tree_type = visual_commands.get_tree_state()
      local files, err = visual_commands.get_files_from_visual_selection({
        tree_state = tree_state,
        tree_type = tree_type,
        start_pos = 1,
        end_pos = 4,
      })

      expect(tree_type).to_be("trouble")
      expect(err).to_be_nil()
      assert.are.same({ "/project/a.lua", "/project/b.lua", "/project/c.lua" }, files)
    end)
  end)
end)
