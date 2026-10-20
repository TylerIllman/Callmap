if vim.g.loaded_callgraph then
  return
end
vim.g.loaded_callgraph = true

vim.api.nvim_create_user_command("Callgraph", function()
  require("callgraph").open()
end, { desc = "Open the call graph for the function under the cursor" })
