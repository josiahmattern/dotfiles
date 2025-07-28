-- formatting stuff
vim.cmd("set expandtab")
vim.cmd("set tabstop=2")
vim.cmd("set softtabstop=2")
vim.cmd("set shiftwidth=2")
vim.cmd("set conceallevel=3")

vim.cmd("set cmdheight=0")
-- get rid of the "INSERT" under lualine
vim.opt.showmode = false

-- weird pasting in open vim buffers
vim.cmd("set t_RS=")

-- open current directory in finder
vim.api.nvim_create_user_command("Rfinder", function()
	local path = vim.api.nvim_buf_get_name(0)
	os.execute("open -R " .. path)
end, {})

-- system clipboard
vim.cmd("set clipboard=unnamedplus")

-- pywal reload without reopening nvim
require("pywal-reload")

-- lazy setup
require("config.lazy")
