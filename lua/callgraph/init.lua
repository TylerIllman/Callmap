--- callgraph.nvim: explore LSP call hierarchies as a left-to-right graph with a source preview.
local M = {}

M.config = {
  -- Popup size as a fraction of the editor, and the share of its width used by the graph.
  width = 0.94,
  height = 0.9,
  graph_ratio = 0.56,
  border = "rounded",
  -- Limits for "expand all" so recursive code cannot run away.
  max_expand_depth = 6,
  max_expand_nodes = 400,
  -- Hide functions defined outside the workspace, such as the standard library and installed
  -- packages. Set to false to see them.
  hide_external = true,
  -- Function names longer than this are shortened in the graph.
  max_label = 34,
  -- Keys inside the popup.
  mappings = {
    left = "h",
    right = "l",
    down = "j",
    up = "k",
    toggle = "<Space>",
    expand_all = "E",
    focus_preview = "<Tab>",
    open = "<CR>",
    close = "q",
    scroll_down = "<C-d>",
    scroll_up = "<C-u>",
  },
}

--- Optional configuration. The plugin works without calling this.
---@param opts table|nil
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

local pv_ns = vim.api.nvim_create_namespace("callgraph_preview")
local hl_ns = vim.api.nvim_create_namespace("callgraph_graph")

local function footer()
  local m = M.config.mappings
  local parts = {
    string.format("%s/%s move", m.left, m.right),
    string.format("%s/%s siblings", m.down, m.up),
    string.format("%s open/fold", m.toggle),
    string.format("%s expand all", m.expand_all),
    string.format("%s preview", m.focus_preview),
    string.format("%s source", m.open),
    string.format("%s quit", m.close),
  }
  return " " .. table.concat(parts, "  ") .. " "
end

local state

vim.api.nvim_set_hl(0, "CallgraphCaller", { link = "String", default = true })
vim.api.nvim_set_hl(0, "CallgraphCallee", { link = "Function", default = true })
vim.api.nvim_set_hl(0, "CallgraphRoot", { link = "Title", default = true })
vim.api.nvim_set_hl(0, "CallgraphPath", { bold = true, underline = true, default = true })
vim.api.nvim_set_hl(0, "CallgraphSel", { reverse = true, bold = true, default = true })
vim.api.nvim_set_hl(0, "CallgraphEdge", { link = "Comment", default = true })

local function key_of(item)
  local pos = item.selectionRange.start
  return table.concat({ item.uri, pos.line, pos.character, item.name }, ":")
end

local function new_node(item, parent, dir)
  local node = { item = item, parent = parent, dir = dir, expanded = false, loading = false }
  local up = parent
  while up do
    if key_of(up.item) == key_of(item) then
      node.cycle = true
      break
    end
    up = up.parent
  end
  return node
end

-- True when the item lives in a file outside the language server's workspace folders.
local function is_external(client, item)
  local roots = {}
  for _, folder in ipairs(client.workspace_folders or {}) do
    roots[#roots + 1] = vim.uri_to_fname(folder.uri)
  end
  if client.root_dir then
    roots[#roots + 1] = client.root_dir
  end
  if #roots == 0 then
    return false
  end
  local path = vim.fs.normalize(vim.uri_to_fname(item.uri))
  for _, root in ipairs(roots) do
    root = vim.fs.normalize(root)
    if path == root or vim.startswith(path, root .. "/") then
      return false
    end
  end
  return true
end

local function load_children(node, cb)
  if node.children then
    return cb()
  end
  if node.cycle then
    node.children = {}
    return cb()
  end
  if node.loading then
    return
  end
  node.loading = true
  local method = node.dir == "incoming" and "callHierarchy/incomingCalls"
    or "callHierarchy/outgoingCalls"
  state.client:request(method, { item = node.item }, function(_, result)
    node.loading = false
    node.children = {}
    local seen = {}
    for _, call in ipairs(result or {}) do
      local item = node.dir == "incoming" and call.from or call.to
      local key = key_of(item)
      if not seen[key] and not (M.config.hide_external and is_external(state.client, item)) then
        seen[key] = true
        node.children[#node.children + 1] = new_node(item, node, node.dir)
      end
    end
    table.sort(node.children, function(a, b)
      if a.item.uri ~= b.item.uri then
        return a.item.uri < b.item.uri
      end
      return a.item.selectionRange.start.line < b.item.selectionRange.start.line
    end)
    vim.schedule(cb)
  end, state.lsp_buf)
end

local function visible_children(node)
  if node.expanded and node.children then
    return node.children
  end
  return {}
end

local function label_of(node, is_root)
  local name = node.item.name
  if vim.fn.strchars(name) > M.config.max_label then
    name = vim.fn.strcharpart(name, 0, M.config.max_label - 1) .. "…"
  end
  if is_root then
    return name
  end
  local before, after = "", ""
  if node.cycle then
    before = "↻ "
  elseif node.loading then
    after = node.dir == "incoming" and "" or " …"
    before = node.dir == "incoming" and "… " or ""
  elseif not node.children then
    if node.dir == "incoming" then
      before = "‹ "
    else
      after = " ›"
    end
  end
  return before .. name .. after
end

-- Assigns each visible node a depth and a row, with parents centred on their children.
local function assign_rows(node, depth, counter)
  node.depth = depth
  local kids = visible_children(node)
  if #kids == 0 then
    node.row = counter.n
    counter.n = counter.n + 1
  else
    for _, kid in ipairs(kids) do
      assign_rows(kid, depth + 1, counter)
    end
    node.row = math.floor((kids[1].row + kids[#kids].row) / 2)
  end
end

local function shift_rows(node, delta)
  node.row = node.row + delta
  for _, kid in ipairs(visible_children(node)) do
    shift_rows(kid, delta)
  end
end

local function collect(node, out)
  out[#out + 1] = node
  for _, kid in ipairs(visible_children(node)) do
    collect(kid, out)
  end
end

local JUNCTION = {
  ["0101"] = "┌",
  ["1001"] = "└",
  ["1101"] = "├",
  ["0111"] = "┬",
  ["1011"] = "┴",
  ["1111"] = "┼",
  ["1100"] = "│",
  ["1110"] = "┤",
  ["0110"] = "┐",
  ["1010"] = "┘",
  ["0011"] = "─",
}

local function junction(up, down, left, right)
  local function b(v)
    return v and "1" or "0"
  end
  return JUNCTION[b(up) .. b(down) .. b(left) .. b(right)] or "─"
end

local function path_set(sel)
  local set = {}
  local n = sel
  while n do
    set[n] = true
    n = n.parent
  end
  -- Roots stand for the same function.
  if set[state.root_in] or set[state.root_out] then
    set[state.root_in], set[state.root_out] = true, true
  end
  return set
end

local function scroll_to(node)
  local win = state.win
  if not vim.api.nvim_win_is_valid(win) or not node.cell then
    return
  end
  local line = vim.api.nvim_buf_get_lines(state.buf, node.row, node.row + 1, false)[1] or ""
  local byte = vim.fn.byteidx(line, node.cell)
  vim.api.nvim_win_set_cursor(win, { node.row + 1, math.max(byte, 0) })
  local width = vim.api.nvim_win_get_width(win)
  vim.api.nvim_win_call(win, function()
    -- A graph that fits in the window is padded to sit in the middle, so leave the view alone.
    if not state.fits_v then
      vim.cmd("normal! zz")
    end
    vim.fn.winrestview({
      leftcol = state.fits_h and 0 or math.max(0, node.cell - math.floor(width / 2) + 6),
    })
  end)
end

local show_preview

local function render()
  if not state or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  local rin, rout = state.root_in, state.root_out
  local cin, cout = { n = 0 }, { n = 0 }
  assign_rows(rin, 0, cin)
  assign_rows(rout, 0, cout)
  local target = math.max(rin.row, rout.row)
  shift_rows(rin, target - rin.row)
  shift_rows(rout, target - rout.row)

  local in_nodes, out_nodes = {}, {}
  collect(rin, in_nodes)
  collect(rout, out_nodes)
  local labels = {}
  local function lab(node)
    if not labels[node] then
      labels[node] = label_of(node, node == rin or node == rout)
    end
    return labels[node]
  end
  local function len(node)
    return vim.fn.strchars(lab(node))
  end

  local win_in, win_out = {}, {}
  for _, n in ipairs(in_nodes) do
    win_in[n.depth] = math.max(win_in[n.depth] or 0, len(n))
  end
  for _, n in ipairs(out_nodes) do
    win_out[n.depth] = math.max(win_out[n.depth] or 0, len(n))
  end
  local root_len = vim.fn.strchars(label_of(rout, true))
  win_in[0], win_out[0] = root_len, root_len

  -- Column geometry, relative to the root's left edge at x = 0.
  local right_start, left_start, left_end = { [0] = 0 }, { [0] = 0 }, { [0] = root_len - 1 }
  local max_out, max_in = 0, 0
  for d in pairs(win_out) do
    max_out = math.max(max_out, d)
  end
  for d in pairs(win_in) do
    max_in = math.max(max_in, d)
  end
  for d = 1, max_out do
    right_start[d] = right_start[d - 1] + (win_out[d - 1] or 0) + 5
  end
  for d = 1, max_in do
    local spine = left_start[d - 1] - 3
    left_end[d] = spine - 3
    left_start[d] = left_end[d] - (win_in[d] or 0) + 1
  end
  local min_x = 0
  for d = 1, max_in do
    min_x = math.min(min_x, left_start[d])
  end

  local rows = target + 1
  for _, n in ipairs(in_nodes) do
    rows = math.max(rows, n.row + 1)
  end
  for _, n in ipairs(out_nodes) do
    rows = math.max(rows, n.row + 1)
  end
  local graph_width = -min_x + right_start[max_out] + (win_out[max_out] or 0) + 1

  -- Pad so a graph smaller than the window sits in the middle of it.
  local win_h, win_w = vim.api.nvim_win_get_height(state.win), vim.api.nvim_win_get_width(state.win)
  local pad_top = math.max(0, math.floor((win_h - rows) / 2))
  local pad_left = math.max(0, math.floor((win_w - graph_width) / 2))
  state.fits_v, state.fits_h = rows <= win_h, graph_width <= win_w
  shift_rows(rin, pad_top)
  shift_rows(rout, pad_top)
  rows = rows + pad_top
  local shift = -min_x + pad_left
  local width = shift + right_start[max_out] + (win_out[max_out] or 0) + 2
  local grid = {}
  for r = 1, rows do
    grid[r] = {}
    for c = 1, width do
      grid[r][c] = " "
    end
  end
  local function put(row, col, ch)
    if grid[row + 1] and col + shift >= 0 and col + shift < width then
      grid[row + 1][col + shift + 1] = ch
    end
  end
  local function put_str(row, col, str)
    for i, ch in ipairs(vim.fn.split(str, "\\zs")) do
      put(row, col + i - 1, ch)
    end
  end

  -- Positions of every label (x relative to root).
  local function place(node, side)
    local d, text = node.depth, lab(node)
    local l = len(node)
    if node == rout or node == rin then
      node.x = 0
    elseif side == "out" then
      node.x = right_start[d]
    else
      node.x = left_end[d] - l + 1
    end
    node.len = l
    put_str(node.row, node.x, text)
  end
  for _, n in ipairs(out_nodes) do
    place(n, "out")
  end
  for _, n in ipairs(in_nodes) do
    if n ~= rin then
      place(n, "in")
    end
  end
  rin.x, rin.len = 0, root_len

  local function edges(parent, side)
    local kids = visible_children(parent)
    if #kids == 0 then
      return
    end
    local d = parent.depth
    local spine, top, bottom
    if side == "out" then
      spine = right_start[d] + (win_out[d] or 0) + 2
      for x = parent.x + parent.len + 1, spine - 1 do
        if x > parent.x + parent.len then
          put(parent.row, x, "─")
        end
      end
    else
      spine = left_start[d] - 3
      for x = spine + 1, parent.x - 2 do
        put(parent.row, x, "─")
      end
    end
    top = math.min(parent.row, kids[1].row)
    bottom = math.max(parent.row, kids[#kids].row)
    local kid_rows = {}
    for _, k in ipairs(kids) do
      kid_rows[k.row] = true
    end
    for r = top, bottom do
      local toward_root, toward_leaf = r == parent.row, kid_rows[r] == true
      local left, right = toward_leaf, toward_root
      if side == "out" then
        left, right = toward_root, toward_leaf
      end
      put(r, spine, junction(r > top, r < bottom, left, right))
      if toward_leaf then
        put(r, side == "out" and spine + 1 or spine - 1, "─")
      end
    end
    for _, k in ipairs(kids) do
      edges(k, side)
    end
  end
  edges(rout, "out")
  edges(rin, "in")

  local lines = {}
  for r = 1, rows do
    lines[r] = table.concat(grid[r])
  end

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(state.buf, hl_ns, 0, -1)

  for r = 1, rows do
    vim.api.nvim_buf_set_extmark(
      state.buf,
      hl_ns,
      r - 1,
      0,
      { end_col = #lines[r], hl_group = "CallgraphEdge", priority = 50 }
    )
  end

  local on_path = path_set(state.sel)
  local function mark(node, group)
    node.cell = node.x + shift
    local line = lines[node.row + 1]
    local s = vim.fn.byteidx(line, node.cell)
    local e = vim.fn.byteidx(line, node.cell + node.len)
    vim.api.nvim_buf_set_extmark(
      state.buf,
      hl_ns,
      node.row,
      s,
      { end_col = e, hl_group = group, priority = 100 }
    )
    if on_path[node] then
      vim.api.nvim_buf_set_extmark(
        state.buf,
        hl_ns,
        node.row,
        s,
        { end_col = e, hl_group = "CallgraphPath", priority = 110 }
      )
    end
    if node == state.sel or (node == rin and state.sel == rout) then
      vim.api.nvim_buf_set_extmark(
        state.buf,
        hl_ns,
        node.row,
        s,
        { end_col = e, hl_group = "CallgraphSel", priority = 120 }
      )
    end
  end
  for _, n in ipairs(out_nodes) do
    mark(n, n == rout and "CallgraphRoot" or "CallgraphCallee")
  end
  for _, n in ipairs(in_nodes) do
    if n ~= rin then
      mark(n, "CallgraphCaller")
    end
  end
  rin.cell = rout.cell

  state.nodes = { out_nodes, in_nodes }
  scroll_to(state.sel)
  show_preview(state.sel.item)
end

show_preview = function(item)
  if not state or not vim.api.nvim_win_is_valid(state.pv_win) then
    return
  end
  if state.pv_buf and vim.api.nvim_buf_is_valid(state.pv_buf) then
    vim.api.nvim_buf_clear_namespace(state.pv_buf, pv_ns, 0, -1)
  end
  local buf = vim.uri_to_bufnr(item.uri)
  vim.fn.bufload(buf)
  state.pv_buf = buf
  vim.api.nvim_win_set_buf(state.pv_win, buf)
  if vim.bo[buf].filetype ~= "" then
    pcall(vim.treesitter.start, buf)
  end
  local count = vim.api.nvim_buf_line_count(buf)
  local first = math.min(item.range.start.line, count - 1)
  local last = math.min(item.range["end"].line, count - 1, first + 300)
  for l = first, last do
    vim.api.nvim_buf_set_extmark(buf, pv_ns, l, 0, { line_hl_group = "CursorLine", priority = 10 })
  end
  vim.api.nvim_win_set_cursor(state.pv_win, { first + 1, 0 })
  vim.api.nvim_win_call(state.pv_win, function()
    vim.cmd("normal! zt")
  end)
  local cfg = state.pv_cfg
  cfg.title = " "
    .. item.name
    .. "  —  "
    .. vim.fn.fnamemodify(vim.uri_to_fname(item.uri), ":~:.")
    .. ":"
    .. (item.selectionRange.start.line + 1)
    .. " "
  vim.api.nvim_win_set_config(state.pv_win, cfg)
end

local function close()
  if not state then
    return
  end
  local s = state
  state = nil
  if s.pv_buf and vim.api.nvim_buf_is_valid(s.pv_buf) then
    vim.api.nvim_buf_clear_namespace(s.pv_buf, pv_ns, 0, -1)
  end
  for _, win in ipairs({ s.win, s.pv_win }) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  if vim.api.nvim_win_is_valid(s.origin_win) then
    vim.api.nvim_set_current_win(s.origin_win)
  end
end

local function pick(node)
  state.sel = node
  render()
end

-- Moves into a node's children on its own side, loading them if needed.
local function descend(node)
  if node.cycle then
    return
  end
  node.expanded = true
  load_children(node, function()
    node.expanded = #node.children > 0
    if #node.children > 0 then
      state.sel = node.children[1]
    end
    render()
  end)
  if node.children == nil then
    render()
  end
end

local function move_right()
  local sel = state.sel
  if sel == state.root_out or sel.dir == "outgoing" then
    descend(sel)
  elseif sel.parent == state.root_in then
    pick(state.root_out)
  elseif sel.parent then
    pick(sel.parent)
  end
end

local function move_left()
  local sel = state.sel
  if sel == state.root_out then
    descend(state.root_in)
  elseif sel.dir == "incoming" then
    descend(sel)
  elseif sel.parent == state.root_out then
    pick(state.root_out)
  elseif sel.parent then
    pick(sel.parent)
  end
end

local function move_vertical(delta)
  local sel = state.sel
  if sel == state.root_out then
    return
  end
  local best
  for _, list in ipairs(state.nodes) do
    for _, n in ipairs(list) do
      if
        n.dir == sel.dir
        and n.depth == sel.depth
        and n ~= state.root_in
        and n ~= state.root_out
      then
        local dr = (n.row - sel.row) * delta
        if dr > 0 and (not best or dr < (best.row - sel.row) * delta) then
          best = n
        end
      end
    end
  end
  if best then
    pick(best)
  end
end

-- Opens (loading if needed) or folds the callers/callees of the selected node, keeping it selected.
local function toggle()
  local sel = state.sel
  local targets = { sel }
  if sel == state.root_out then
    targets = { state.root_out, state.root_in }
  end
  for _, node in ipairs(targets) do
    if node.cycle then
      -- Recursive calls have nothing further to open.
    elseif node.children == nil then
      node.expanded = true
      load_children(node, function()
        node.expanded = #node.children > 0
        if #node.children == 0 then
          vim.notify(
            "Callgraph: "
              .. node.item.name
              .. " has no "
              .. (node.dir == "incoming" and "callers" or "callees")
          )
        end
        render()
      end)
    elseif #node.children > 0 then
      node.expanded = not node.expanded
    end
  end
  render()
end

local function expand_all()
  local budget = { n = M.config.max_expand_nodes }
  local function go(n, depth)
    if depth > M.config.max_expand_depth or budget.n <= 0 or n.cycle then
      return
    end
    n.expanded = true
    load_children(n, function()
      n.expanded = #n.children > 0
      budget.n = budget.n - #n.children
      for _, child in ipairs(n.children) do
        go(child, depth + 1)
      end
      render()
    end)
  end
  local sel = state.sel
  if sel == state.root_out then
    go(state.root_out, 0)
    go(state.root_in, 0)
  else
    go(sel, 0)
  end
end

local function open_item()
  local s = state
  local item = s.sel.item
  close()
  vim.lsp.util.show_document(
    { uri = item.uri, range = item.selectionRange },
    s.client.offset_encoding,
    { focus = true }
  )
end

-- Moves into the preview window so it can be scrolled and searched; <Tab>, <Esc> or q come back.
local function focus_preview()
  local buf, win = state.pv_buf, state.pv_win
  if not buf or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local lhs_list = { M.config.mappings.focus_preview, "<Esc>", M.config.mappings.close }
  local function back()
    if state and vim.api.nvim_win_is_valid(state.win) then
      vim.api.nvim_set_current_win(state.win)
    end
  end
  for _, lhs in ipairs(lhs_list) do
    vim.keymap.set("n", lhs, back, { buffer = buf, nowait = true, desc = "Back to call graph" })
  end
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function()
      for _, lhs in ipairs(lhs_list) do
        pcall(vim.keymap.del, "n", lhs, { buffer = buf })
      end
      if vim.api.nvim_win_is_valid(win) then
        vim.wo[win].cursorline = false
      end
    end,
  })
  vim.wo[win].cursorline = true
  vim.api.nvim_set_current_win(win)
end

local function scroll_preview(key)
  vim.api.nvim_win_call(state.pv_win, function()
    vim.cmd("normal! " .. vim.keycode(key))
  end)
end

local function build(client, item, origin_win, buf)
  local total_h = vim.o.lines - vim.o.cmdheight
  local W = math.floor(vim.o.columns * M.config.width)
  local H = math.floor(total_h * M.config.height)
  local row0 = math.floor((total_h - H) / 2)
  local col0 = math.floor((vim.o.columns - W) / 2)
  local gw = math.floor(W * M.config.graph_ratio)

  local function cfg(col, width, title)
    return {
      relative = "editor",
      row = row0,
      col = col,
      width = width,
      height = H - 2,
      style = "minimal",
      border = M.config.border,
      title = title,
      title_pos = "center",
      zindex = 50,
    }
  end

  state = { client = client, lsp_buf = buf, origin_win = origin_win }
  state.root_in = new_node(item, nil, "incoming")
  state.root_out = new_node(item, nil, "outgoing")
  state.root_in.expanded, state.root_out.expanded = true, true
  state.sel = state.root_out

  local gbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[gbuf].bufhidden = "wipe"
  vim.bo[gbuf].filetype = "callgraph"
  vim.bo[gbuf].modifiable = false
  local gcfg = cfg(col0, gw - 2, " callers  ←  " .. item.name .. "  →  callees ")
  gcfg.footer, gcfg.footer_pos = footer(), "center"
  state.win = vim.api.nvim_open_win(gbuf, true, gcfg)
  local graph_buf = gbuf
  state.buf = graph_buf
  vim.wo[state.win].wrap = false
  vim.wo[state.win].cursorline = false
  vim.wo[state.win].number = false
  vim.wo[state.win].signcolumn = "no"
  vim.wo[state.win].sidescrolloff = 0

  state.pv_cfg = cfg(col0 + gw, W - gw - 2, " Preview ")
  local pv_buf = vim.api.nvim_create_buf(false, true)
  state.pv_win = vim.api.nvim_open_win(pv_buf, false, state.pv_cfg)
  vim.wo[state.pv_win].number = true
  vim.wo[state.pv_win].wrap = false
  vim.wo[state.pv_win].cursorline = false
  vim.wo[state.pv_win].foldenable = false

  local function map(lhs, fn, desc)
    if not lhs then
      return
    end
    vim.keymap.set("n", lhs, fn, { buffer = graph_buf, nowait = true, desc = desc })
  end
  local m = M.config.mappings
  map(m.right, move_right, "Right")
  map("<Right>", move_right, "Right")
  map(m.left, move_left, "Left")
  map("<Left>", move_left, "Left")
  map(m.down, function()
    move_vertical(1)
  end, "Next sibling")
  map("<Down>", function()
    move_vertical(1)
  end, "Next sibling")
  map(m.up, function()
    move_vertical(-1)
  end, "Previous sibling")
  map("<Up>", function()
    move_vertical(-1)
  end, "Previous sibling")
  map(m.toggle, toggle, "Open or fold callers/callees")
  map(m.expand_all, expand_all, "Expand all")
  map(m.focus_preview, focus_preview, "Focus preview")
  map(m.open, open_item, "Open in editor")
  map(m.close, close, "Close")
  map("<Esc>", close, "Close")
  map(m.scroll_down, function()
    scroll_preview("<C-d>")
  end, "Scroll preview down")
  map(m.scroll_up, function()
    scroll_preview("<C-u>")
  end, "Scroll preview up")

  local group = vim.api.nvim_create_augroup("CallgraphWindows", { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = { tostring(state.win), tostring(state.pv_win) },
    callback = function()
      vim.schedule(close)
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", { group = group, callback = close })

  render()
  for _, root in ipairs({ state.root_in, state.root_out }) do
    load_children(root, function()
      render()
    end)
  end
end

-- Opens the explorer for a prepared call hierarchy item (exposed for testing).
function M._open_item(client, item, origin_win, buf)
  if state then
    close()
  end
  build(client, item, origin_win, buf)
end

function M._state()
  return state
end

function M.open()
  if state then
    close()
  end
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  local clients = vim.lsp.get_clients({ bufnr = buf, method = "textDocument/prepareCallHierarchy" })
  if #clients == 0 then
    vim.notify("Callgraph: no attached LSP server supports call hierarchy", vim.log.levels.WARN)
    return
  end
  local client = clients[1]
  local params = vim.lsp.util.make_position_params(win, client.offset_encoding)
  client:request("textDocument/prepareCallHierarchy", params, function(_, result)
    if not result or #result == 0 then
      vim.notify("Callgraph: no function under the cursor", vim.log.levels.WARN)
      return
    end
    vim.schedule(function()
      build(client, result[1], win, buf)
    end)
  end, buf)
end

return M
