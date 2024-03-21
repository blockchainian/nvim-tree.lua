local view = require "nvim-tree.view"
local utils = require "nvim-tree.utils"
local Iterator = require "nvim-tree.iterators.node-iterator"

local M = {
  filter = nil,
}

local function redraw()
  require("nvim-tree.renderer").draw()
end

local function reset_filter(node_)
  node_ = node_ or TreeExplorer
  Iterator.builder(node_.nodes)
      :hidden()
      :applier(function(node)
        node.hidden = false
      end)
      :iterate()
end

local overlay_bufnr = nil
local overlay_winnr = nil

local function remove_overlay()
  vim.cmd "stopinsert"

  if view.View.float.enable and view.View.float.quit_on_focus_loss then
    -- return to normal nvim-tree float behaviour when filter window is closed
    vim.api.nvim_create_autocmd("WinLeave", {
      pattern = "NvimTree_*",
      group = vim.api.nvim_create_augroup("NvimTree", { clear = false }),
      callback = function()
        if utils.is_nvim_tree_buf(0) then
          view.close()
        end
      end,
    })
  end

  vim.api.nvim_win_close(overlay_winnr, { force = true })
  overlay_bufnr = nil
  overlay_winnr = nil

  M.clear_filter()
end

local function filtered_nodes()
  local nodes = {}

  Iterator.builder(TreeExplorer.nodes)
      :applier(function(node)
        if node.type == 'file' then
          table.insert(nodes, node)
        end
      end)
      :iterate()

  return nodes
end

local function select(node_)
  local _, line = utils.find_node(require("nvim-tree.core").get_explorer().nodes, function(node)
    return node.absolute_path == node_.absolute_path
  end)

  view.set_cursor { line + 1, 0 }
  vim.cmd "redraw"
end

local function find_default_node()
  local current = require("nvim-tree.lib").get_node_at_cursor()
  local nodes = filtered_nodes()

  for i, node in ipairs(nodes) do
    if current and current.absolute_path == node.absolute_path then
      return node
    end
  end

  return nodes[1]
end

local function find_prev_node()
  local current = require("nvim-tree.lib").get_node_at_cursor()
  local nodes = filtered_nodes()

  for i, node in ipairs(nodes) do
    if current.absolute_path == node.absolute_path and i > 1 then
      return nodes[i - 1]
    end
  end

  return nodes[#nodes]
end

local function find_next_node()
  local current = require("nvim-tree.lib").get_node_at_cursor()
  local nodes = filtered_nodes()

  for i, node in ipairs(nodes) do
    if current.absolute_path == node.absolute_path then
      return nodes[i % #nodes + 1]
    end
  end

  return nodes[1]
end

local function select_default()
  local node = find_default_node()
  if node then
    select(node)
  end
end

local function select_prev()
  local node = find_prev_node()
  if node then
    select(node)
  end
end

local function select_next()
  local node = find_next_node()
  if node then
    select(node)
  end
end

local function activate()
  remove_overlay()

  local node = require("nvim-tree.lib").get_node_at_cursor()

  if not node then
    return
  elseif node.name == ".." then
    require("nvim-tree.actions.root.change-dir").fn ".."
  elseif node.nodes then
    require("nvim-tree.lib").expand_or_collapse(node)
  else
    local path = node.absolute_path
    if node.link_to and not node.nodes then
      path = node.link_to
    end
    require("nvim-tree.actions.node.open-file").fn('edit', path)
  end
end

local function matches(node)
  local patterns = vim.split(M.filter, "%s+")

  for _, pattern in ipairs(patterns) do
    if vim.regex('\\c' .. pattern):match_str(node.absolute_path) == nil then
      return false
    end
  end

  return true
end

function M.apply_filter(node_)
  if not M.filter or M.filter == "" then
    reset_filter(node_)
    return
  end

  -- TODO(kiyan): this iterator cannot yet be refactored with the Iterator module
  -- since the node mapper is based on its children
  local function iterate(node)
    local filtered_nodes = 0
    local nodes = node.group_next and { node.group_next } or node.nodes

    if nodes then
      for _, n in pairs(nodes) do
        iterate(n)
        if n.hidden then
          filtered_nodes = filtered_nodes + 1
        end
      end
    end

    local has_nodes = nodes and (M.always_show_folders or #nodes > filtered_nodes)
    local ok, is_match = pcall(matches, node)
    node.hidden = not (has_nodes or (ok and is_match))
  end

  iterate(node_ or TreeExplorer)
  select_default()
end

local function record_char()
  vim.schedule(function()
    M.filter = vim.api.nvim_buf_get_lines(overlay_bufnr, 0, -1, false)[1]
    M.apply_filter()
    redraw()
  end)
end

local function configure_buffer_overlay()
  overlay_bufnr = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_buf_attach(overlay_bufnr, true, {
    on_lines = record_char,
  })

  vim.keymap.set('i', '<C-J>', select_next, { silent = true, buffer = overlay_bufnr })
  vim.keymap.set('i', '<C-K>', select_prev, { silent = true, buffer = overlay_bufnr })
  vim.keymap.set('i', '<CR>', activate, { silent = true, buffer = overlay_bufnr })
  vim.keymap.set('i', '<ESC>', remove_overlay, { silent = true, buffer = overlay_bufnr })
end

local function create_overlay()
  local min_width = 20
  if view.View.float.enable then
    -- don't close nvim-tree float when focus is changed to filter window
    vim.api.nvim_clear_autocmds {
      event = "WinLeave",
      pattern = "NvimTree_*",
      group = vim.api.nvim_create_augroup("NvimTree", { clear = false }),
    }

    min_width = min_width - 2
  end

  configure_buffer_overlay()
  overlay_winnr = vim.api.nvim_open_win(overlay_bufnr, true, {
    col = 0,
    row = 0,
    relative = "win",
    width = math.max(min_width, vim.api.nvim_win_get_width(view.get_winnr()) - #M.prefix),
    height = 1,
    border = "none",
    style = "minimal",
  })
  vim.api.nvim_buf_set_option(overlay_bufnr, "modifiable", true)
  vim.api.nvim_buf_set_lines(overlay_bufnr, 0, -1, false, { M.filter })
  vim.cmd "startinsert"
  vim.api.nvim_win_set_cursor(overlay_winnr, { 1, #M.filter + 1 })
end

function M.start_filtering()
  view.View.live_filter.prev_focused_node = require("nvim-tree.lib").get_node_at_cursor()
  M.filter = M.filter or ""

  redraw()
  vim.schedule(create_overlay)
end

function M.clear_filter()
  local node = require("nvim-tree.lib").get_node_at_cursor()
  local last_node = view.View.live_filter.prev_focused_node

  M.filter = nil
  reset_filter()
  redraw()

  if node then
    utils.focus_file(node.absolute_path)
  elseif last_node then
    utils.focus_file(last_node.absolute_path)
  end
end

function M.setup(opts)
  M.prefix = opts.live_filter.prefix
  M.always_show_folders = opts.live_filter.always_show_folders
end

return M
