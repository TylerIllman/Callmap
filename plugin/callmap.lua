if vim.g.loaded_callmap then
  return
end
vim.g.loaded_callmap = true

vim.api.nvim_create_user_command("Callmap", function()
  require("callmap").open()
end, { desc = "Open the call graph for the function under the cursor" })
