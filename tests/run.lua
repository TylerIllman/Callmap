-- Run with: nvim --headless -u NONE -l tests/run.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.cmd("runtime plugin/callgraph.lua")

local failures = 0
local function check(name, cond)
  if cond then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name)
  end
end

local cg = require("callgraph")

local file = root .. "/lua/callgraph/init.lua"
vim.cmd("edit " .. file)
local uri = vim.uri_from_fname(file)

local function item(name, line)
  return {
    name = name,
    uri = uri,
    range = { start = { line = line, character = 0 }, ["end"] = { line = line + 5, character = 0 } },
    selectionRange = {
      start = { line = line, character = 0 },
      ["end"] = { line = line, character = 3 },
    },
  }
end

local graph = {
  incoming = {
    target = { item("callerA", 10), item("callerB", 30) },
    callerA = { item("top", 50) },
  },
  outgoing = {
    target = { item("calleeX", 60), item("fetch", 61) },
    calleeX = { item("calleeY", 80), item("target", 5) }, -- calls back into target: recursion
  },
}

-- A fake language server answering call hierarchy requests from the table above.
local client = { offset_encoding = "utf-16" }
function client:request(method, params, handler)
  local dir = method:match("incoming") and "incoming" or "outgoing"
  local result = {}
  for _, it in ipairs(graph[dir][params.item.name] or {}) do
    result[#result + 1] = dir == "incoming" and { from = it } or { to = it }
  end
  vim.schedule(function()
    handler(nil, result)
  end)
end

local function press(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
  vim.wait(100)
end

local function text()
  return table.concat(vim.api.nvim_buf_get_lines(cg._state().buf, 0, -1, false), "\n")
end

cg._open_item(
  client,
  item("target", 5),
  vim.api.nvim_get_current_win(),
  vim.api.nvim_get_current_buf()
)
vim.wait(200)

check("popup windows open", cg._state() ~= nil and vim.api.nvim_win_is_valid(cg._state().win))
check("callers drawn", text():find("callerA", 1, true) and text():find("callerB", 1, true))
check("callees drawn", text():find("calleeX", 1, true) and text():find("fetch", 1, true))
check("root selected first", cg._state().sel.item.name == "target")

press("l")
check("l moves to first callee", cg._state().sel.item.name == "calleeX")

press("<Space>")
check("space opens callees of selection", text():find("calleeY", 1, true) ~= nil)
check("selection stays put after space", cg._state().sel.item.name == "calleeX")
check("recursive call is marked", text():find("↻", 1, true) ~= nil)

press("<Space>")
check("space again folds", text():find("calleeY", 1, true) == nil)

press("h")
check("h goes back toward the middle", cg._state().sel.item.name == "target")
press("h")
check("h from the middle enters callers", cg._state().sel.item.name == "callerA")

press("<Tab>")
check("tab focuses preview", vim.api.nvim_get_current_win() == cg._state().pv_win)
press("<Tab>")
check("tab returns to graph", vim.api.nvim_get_current_win() == cg._state().win)

local wins_before = #vim.api.nvim_list_wins()
press("q")
check("q closes the popup", cg._state() == nil and #vim.api.nvim_list_wins() == wins_before - 2)

-- Duplicates are removed and functions outside the workspace are hidden.
do
  local external = item("print", 1)
  external.uri = vim.uri_from_fname("/usr/lib/python3/builtins.pyi")
  graph.outgoing.dup_root = { item("same", 70), item("same", 70), external, item("other", 71) }
  client.root_dir = root
  cg._open_item(
    client,
    item("dup_root", 5),
    vim.api.nvim_get_current_win(),
    vim.api.nvim_get_current_buf()
  )
  vim.wait(200)
  local drawn = text()
  local _, count = drawn:gsub("same", "")
  check("duplicate callees are drawn once", count == 1)
  check(
    "external callees are hidden",
    drawn:find("print", 1, true) == nil and drawn:find("other", 1, true) ~= nil
  )
  press("q")

  cg.setup({ hide_external = false })
  cg._open_item(
    client,
    item("dup_root", 5),
    vim.api.nvim_get_current_win(),
    vim.api.nvim_get_current_buf()
  )
  vim.wait(200)
  check("hide_external = false shows them", text():find("print", 1, true) ~= nil)
  press("q")
  cg.setup({ hide_external = true })
  client.root_dir = nil
end

-- Options.
cg.setup({ mappings = { toggle = "<CR>" }, max_label = 10 })
check(
  "setup merges options",
  cg.config.mappings.toggle == "<CR>" and cg.config.mappings.left == "h"
)

if failures > 0 then
  print(failures .. " test(s) failed")
  os.exit(1)
end
print("all tests passed")
