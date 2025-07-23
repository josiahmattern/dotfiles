-- ~/.config/nvim/lua/plugins/pywal-reload.lua
local uv              = vim.loop
local wal_colors_path = vim.fn.expand("~/.cache/wal/colors.json")

-- libuv FS watcher -----------------------------------------------------------
local function apply_pywal()
  -- hop back onto Neovim’s main thread before touching the UI
  vim.schedule(function()
    vim.cmd.colorscheme("pywal16")
    vim.notify("🌈  Pywal colorscheme reloaded!", vim.log.levels.INFO, { title = "Neovim" })
  end)
end

-- one global handle so the watcher survives a reload
_G.__pywal_watch_handle = _G.__pywal_watch_handle or uv.new_fs_event()

-- watch the *directory* so we catch file recreations, then filter for the file
_G.__pywal_watch_handle:start(
  vim.fn.fnamemodify(wal_colors_path, ":h"),   -- directory to watch
  {},                                          -- {} == follow moves+renames
  vim.schedule_wrap(function(err, filename)
    if err then return end                     -- be chill about errors
    if filename == "colors.json" then
      apply_pywal()
    end
  end)
)

return true
