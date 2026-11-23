--- Reads the files on rows of a trouble.nvim list, for :ClaudeCodeTreeAdd and :ClaudeCodeSend. An item
--- row gives its own file and a group row (a file, a directory, a source) the file of each item under it.
--- Kept out of integrations.lua and visual_commands.lua so upstream changes there merge without conflicts.
---@module 'claudecode.trouble'

local M = {}

---The files on rows `first` to `last` of the Trouble list in the current window, in list order, each once
---@param first integer|nil 1-based row, the cursor's by default
---@param last integer|nil 1-based row, `first` by default
---@return string[] files
---@return string|nil error Error message if operation failed
function M.files(first, last)
  local ok, trouble_view = pcall(require, "trouble.view")
  if not ok then
    return {}, "trouble.nvim not available"
  end

  local win = vim.api.nvim_get_current_win()
  local view
  for _, entry in ipairs(trouble_view.get({ open = true })) do
    if entry.view.win.win == win then
      view = entry.view
      break
    end
  end
  if not view then
    return {}, "No Trouble list in the current window"
  end

  first = first or vim.api.nvim_win_get_cursor(win)[1]
  local files, seen = {}, {}
  for row = first, last or first do
    -- A group row holds no item of its own, only the node its items hang under
    local location = view.renderer:at(row)
    local items = location.item and { location.item } or location.node and location.node:flatten() or {}
    for _, item in ipairs(items) do
      if not seen[item.filename] then
        seen[item.filename] = true
        table.insert(files, item.filename)
      end
    end
  end
  return files, nil
end

return M
