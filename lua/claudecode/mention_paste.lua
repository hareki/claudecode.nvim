--- Delivers @ mentions as a paste into the managed Claude terminal instead of an `at_mentioned`
--- broadcast (#249).
---
--- The CLI hands `at_mentioned` to whichever prompt registered for it last and never unregisters
--- it. Opening the agents view (left arrow on an empty prompt) gives it to that view's composer for
--- the rest of the process, and a session opened from there runs in a background worker with no
--- IDE connection (the CLI strips CLAUDE_CODE_SSE_PORT from worker environments), so mentions pile
--- up in the hidden composer. A paste lands in whatever prompt is on screen.
---
--- init.lua falls back to the broadcast whenever `paste` returns false, and keeps it for the flush
--- right after a new connection: that client is a freshly started chat whose own prompt holds the
--- registration, and unlike a paste the WebSocket does not need that prompt to take input yet.
--- Kept out of init.lua so upstream changes there merge without conflicts.
---@module 'claudecode.mention_paste'

local M = {}

---Format an @ mention the way Claude Code's prompt parses it: `#L<start>` or `#L<start>-<end>`
---with 1-based lines, quoted when the path contains whitespace, which would otherwise end it.
---@param file_path string The path as Claude receives it (see _format_path_for_at_mention)
---@param start_line number|nil Start line (0-indexed for Claude)
---@param end_line number|nil End line (0-indexed for Claude)
---@return string mention The mention text, without surrounding whitespace
function M.format(file_path, start_line, end_line)
  -- File names are untrusted and reach the pty: an ESC could end the bracketed paste early and
  -- have the rest of a crafted name read as keystrokes (a CR submits). An explicit byte range,
  -- since %c is locale-dependent above 0x7F and must not touch UTF-8 continuation bytes.
  local mention = file_path:gsub("[\1-\31\127]", "")
  -- Like Claude's own insertion, a range needs both ends
  if start_line and end_line then
    if start_line == end_line then
      mention = string.format("%s#L%d", mention, start_line + 1)
    else
      mention = string.format("%s#L%d-%d", mention, start_line + 1, end_line + 1)
    end
  end

  if mention:find("%s") then
    return string.format('@"%s"', mention)
  end
  return "@" .. mention
end

---Paste @ mentions into the managed Claude terminal as one bracketed paste.
---@param mentions { file_path: string, start_line: number|nil, end_line: number|nil }[]
---@return boolean pasted False when there is no managed terminal to paste into or the write failed
function M.paste(mentions)
  local terminal = require("claudecode.terminal")
  -- Checked here because send_to_terminal warns when no terminal is running, which is routine
  -- whenever Claude runs outside Neovim. The existence checks keep partial terminal stubs working.
  local bufnr = terminal.get_active_terminal_bufnr and terminal.get_active_terminal_bufnr()
  if not bufnr or not terminal.send_to_terminal then
    return false
  end

  local mention_texts = {}
  for _, mention in ipairs(mentions) do
    table.insert(mention_texts, M.format(mention.file_path, mention.start_line, mention.end_line))
  end

  -- Claude pads its own insertion with a leading space unless the character before the cursor is
  -- whitespace. The prompt is not observable from here, so there is no leading pad: an unconditional
  -- one doubles the space users type before a mention. The trailing pad separates the next mention.
  local text = table.concat(mention_texts, " ") .. " "
  -- Wrapped here because send_to_terminal only pastes multi-line text: a single line would be typed
  -- as keystrokes, which vim-mode NORMAL runs as commands.
  return terminal.send_to_terminal("\27[200~" .. text .. "\27[201~", { submit = false })
end

return M
