local golist = require('go.list').list
local util = require('go.utils')
local log = util.log
local vfn = vim.fn
local api = vim.api

-- a table of paths (e.g. './...' and the corresponding full package name)
local path_to_pkg = {}

-- a collection of known packages
local pkgs = {}

local complete = function(sep)
  log('complete', sep)
  sep = sep or '\n'
  -- local ok, l = golist(false, { util.all_pkgs() })
  local ok, l = golist { util.all_pkgs() }
  if not ok then
    log('Failed to find all packages for current module/project.')
    return
  end

  log(l)
  local curpkgmatch = false
  local curpkg = vfn.fnamemodify(vfn.expand('%'), ':h:.')
  local pf = function()
    for _, p in ipairs(l or {}) do
      local d = vfn.fnamemodify(p.Dir, ':.')
      if curpkg ~= d then
        if d ~= vfn.getcwd() then
          table.insert(pkgs, util.relative_to_cwd(d))
        end
      else
        curpkgmatch = true
      end
    end
    table.sort(pkgs)
    table.insert(pkgs, util.all_pkgs())
    table.insert(pkgs, '.')
    if curpkgmatch then
      table.insert(pkgs, util.relative_to_cwd(curpkg))
    end
  end
  if vim.fn.empty(pkgs) == 0 then
    vim.defer_fn(function()
                   pf()
                 end, 1)
    return pkgs
  else
    pf()
    return pkgs
  end
end

local all_pkgs = function()
  local ok, l = golist { util.all_pkgs() }
  if not ok then
    log('Failed to find all packages for current module/project.')
  end
  return l
end

-- short form of go list
local all_pkgs2 = function()
  local l = require('go.list').list_pkgs()
  if not l then
    log('Failed to find all packages for current module/project.')
  end
  return l
end

local pkg_from_path = function(pkg, bufnr)
  local cmd = { 'go', 'list' }
  if pkg ~= nil then
    table.insert(cmd, pkg)
  end
  log(cmd)
  return util.exec_in_path(cmd, bufnr)
end

local show_float = function(result)
  local textview = util.load_plugin('guihua.lua', 'guihua.textview')
  if not textview then
    util.log('Failed to load guihua.textview')

    vim.fn.setloclist(0, {}, 'r', {
      title = 'go package outline',
      lines = result,
    })
    util.quickfix('lopen')
    return
  end
  local win = textview:new({
    relative = 'cursor',
    syntax = 'lua',
    rect = { height = math.min(40, #result), pos_x = 0, pos_y = 10 },
    data = result,
  })
  log('draw data', result)
  vim.api.nvim_buf_set_option(win.buf, 'filetype', 'go')
  return win:on_draw(result)
end

local defs
local render_outline = function(result)
  if not result then
    log('result nil', debug.traceback())
    return
  end
  local fname = vim.fn.tempname() .. '._go' -- avoid lsp activation
  log('tmp: ' .. fname)
  local uri = vim.uri_from_fname(fname)
  local bufnr = vim.uri_to_bufnr(uri)
  vim.fn.writefile(result, fname)
  vfn.bufload(bufnr)
  defs = require('go.ts.utils').list_definitions_toc(bufnr)
  if vfn.empty(defs) == 1 then
    vim.notify('No definitions found in package.')
    return
  end
  return bufnr, fname
end

local outline
local render
local show_panel = function(result, pkg, rerender)
  local bufnr, fname = render_outline(result)
  if rerender or not defs then
    return true -- just re-gen the outline
  end

  log('defs 1', defs and defs[1])
  local panel = util.load_plugin('guihua.lua', 'guihua.panel')
  local pkg_name = pkg or 'pkg'
  pkg_name = vfn.split(pkg_name, '/')
  pkg_name = pkg_name[#pkg_name] or 'pkg'
  log('create panel')
  if panel then
    local p = panel:new({
      header = '❒ ' .. pkg_name,
      render = function(b)
        log('render for ', bufnr, b)
        -- log(debug.traceback())
        -- outline("-r")
        render()
        return defs
      end,
      on_confirm = function(n)
        log('on_confirm symbol ', n)
        if not n or not n.symbol then
          log('info missing: symbol ', n)
          return
        end
        -- need to change to main window first to enable gopls
        local wins = api.nvim_list_wins()
        local panel_win = api.nvim_get_current_win()
        log(wins, panel_win)
        local cur_win
        for _, w in ipairs(wins) do
          if w ~= panel_win then
            api.nvim_set_current_win(w)
            local cur = api.nvim_win_get_cursor(w)
            api.nvim_win_set_cursor(w, cur)
            cur_win = w
            break
          end
        end

        vim.lsp.buf_request(
          0,
          'workspace/symbol',
          { query = "'" .. n.symbol },
          function(e, lsp_result, ctx)
            local filtered = {}
            for _, r in pairs(lsp_result) do
              local container = r.containerName
              if pkg == container and r.name == n.symbol then
                table.insert(filtered, r)
              end
            end
            log('filtered', filtered)
            if #filtered == 0 then
              log('nothing found fallback to result', pkg, n.symbol)
              filtered = lsp_result
            end

            if vfn.empty(filtered) == 1 then
              log(e, lsp_result, ctx)
              vim.notify('no symbol found for ' .. vim.inspect(pkg))
              return false
            end
            if #filtered == 1 then
              -- jump to pos
              local loc = filtered[1].location
              local buf = vim.uri_to_bufnr(loc.uri)
              vfn.bufload(buf)
              api.nvim_set_current_win(cur_win)
              api.nvim_set_current_buf(buf)
              api.nvim_win_set_buf(cur_win, buf)
              api.nvim_win_set_cursor(
                cur_win,
                { loc.range.start.line + 1, loc.range.start.character }
              )
            else
              -- lets just call workspace/symbol handler
              vim.lsp.handlers['workspace/symbol'](e, filtered, ctx)
            end
          end
        )
        -- vim.lsp.buf.workspace_symbol("'" .. n.symbol)
        return n.symbol
      end,
    })
    p:open(true)
  else
    vim.fn.setloclist(0, {}, 'r', {
      title = 'go package outline',
      lines = defs,
    })
    util.quickfix('lopen')
  end
  log('cleanup')
  vim.api.nvim_buf_delete(bufnr, { unload = true })
  os.remove(fname)
end

local pkg_info = {}
-- get package info
local function handle_data_out(_, data, ev)
  data = util.handle_job_data(data)
  if not data then
    return
  end
  pkg_info = {}
  local types = { 'CONSTANTS', 'FUNCTIONS', 'TYPES', 'VARIABLES' }
  local pkg_docs = true
  local in_docs = false

  for i, val in ipairs(data) do
    if i > 1 then
      -- first strip the filename
      if vim.tbl_contains(types, val) then
        if pkg_docs then
          val = '{{__DOC_END__}}'
          pkg_docs = false
        else
          val = ''
        end
      end

      if pkg_docs then
        val = '//' .. val
      end

      local sp = string.match(val, '^(%s*)')
      if sp and #sp == 4 then
        if not in_docs then
          table.insert(pkg_info, '{{__DOC_START__}}')
          in_docs = true
        end
        val = '//' .. val
      else
        if in_docs then
          table.insert(pkg_info, '{{__DOC_END__}}')
          in_docs = false
        end
      end

      local f = string.match(val, '^func ')
      if f then
        -- incase the func def is mulilines
        local next_line = data[i + 1]
        if next_line then
          local next_sp = string.match(next_line, '^(%s*)') -- one tab in front
          if next_sp and #next_sp == 1 then                 -- tab size 1
            next_line = next_line .. '{}'
            data[i + 1] = next_line
          else
            val = val .. '{}'
          end
        else
          val = val .. '{}'
        end
      end
      table.insert(pkg_info, val)
    else
      table.insert(pkg_info, val)
      table.insert(pkg_info, '{{__DOC_START__}}')
    end
  end

  local fname = vim.fn.tempname() .. '.txt'
  print(fname)
  local uri = vim.uri_from_fname(fname)
  local bufnr = vim.uri_to_bufnr(uri)
  vim.fn.writefile(pkg_info, fname)
end

local gen_pkg_info = function(cmd, pkg, arg, rerender)
  log('gen_pkg_info', cmd, pkg, rerender)
  vfn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = handle_data_out,
    on_exit = function(e, data, _)
      if data ~= 0 then
        local info = string.format(
          'no packege (%s) \n errcode %s \n cmd: %s \n code %s',
          vim.inspect(pkg),
          e,
          vim.inspect(cmd),
          tostring(data)
        )
        vim.notify(info)
        log(cmd, info, data)
        return
      end
      if arg == '-f' then
        return show_float(pkg_info)
      end
      show_panel(pkg_info, pkg[1], rerender)
    end,
  })
end

outline = function(...)
  -- log(debug.traceback())
  local arg = select(1, ...)
  local path = vim.fn.expand('%:p:h')
  path = vfn.fnamemodify(path, ':p')

  if arg == '-p' then
    local pkg = select(2, ...)
    if pkg ~= nil then
      path = pkg
    else
      vim.notify('no package provided')
    end
  else
    path = '.' .. util.sep() .. '...' -- how about window?
  end

  local re_render = false
  if arg == '-r' then
    re_render = true
  end
  local pkg = path_to_pkg[path]
  log(path, pkg)
  if not pkg then
    pkg = pkg_from_path(path) -- return list of all packages only check first one
    path_to_pkg[path] = pkg
  end
  if pkg and pkg[1] and pkg[1]:find('does not contain') then
    util.log('no package found for ' .. vim.inspect(path))
    pkg = { '' }
    path_to_pkg[path] = pkg
  end
  if vfn.empty(pkg) == 1 then
    vim.notify('no package found ' .. pkg .. ' in path' .. path)
    util.log('No package found in current directory.')
    local setup = { 'go', 'doc', '-all', '-u', '-cmd' }
    gen_pkg_info(setup, pkg, arg, re_render)
    return
  end

  local current_pkg = path_to_pkg['./...']
  local setup = { 'go', 'doc', '-all', '-cmd', pkg[1] }

  if current_pkg ~= nil then
    if current_pkg[1] == pkg[1] then
      setup = { 'go', 'doc', '-all', '-u', '-cmd', pkg[1] }
    end
  end

  gen_pkg_info(setup, pkg, arg, re_render)
end

render = function(bufnr)
  util.log(debug.traceback())
  local fpath = vfn.fnamemodify(vfn.bufname(bufnr or 0), ':p')
  local pkg = path_to_pkg[fpath]
  if not pkg then
    pkg = pkg_from_path('.' .. util.sep() .. '...', bufnr) -- return list of all packages only check first one
    path_to_pkg[fpath] = pkg
  end
  if vfn.empty(pkg) == 1 then
    util.log('No package found in current directory.')
    return nil
  end

  local current_pkg = path_to_pkg['./...']
  local cmd = { 'go', 'doc', '-all', '-cmd', pkg[1] }

  if current_pkg ~= nil then
    if current_pkg[1] == pkg[1] then
      cmd = { 'go', 'doc', '-all', '-u', '-cmd', pkg[1] }
    end
  end

  log('gen_pkg_info', cmd, pkg)
  vfn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = handle_data_out,
    on_exit = function(e, data, _)
      if data ~= 0 then
        log('no packege info data ' .. e .. tostring(data))
        return
      end
      local buf, fname = render_outline()
      log(buf, fname)
    end,
  })
  return defs
end

return {
  complete = complete,
  all_pkgs = all_pkgs,
  all_pkgs2 = all_pkgs2,
  pkg_from_path = pkg_from_path,
  outline = outline,
}

--[[
result of workspacesymbol
{ {
    containerName = "github.com/vendor/packagename/internal/aws",
    kind = 12,
    location = {
      range = {
        end = {
          character = 23,
          line = 39
        },
        start = {
          character = 5,
          line = 39
        }
      },
      uri = "file:///go_home/src/vendor/packagename/internal/aws/aws.go"
    },
    name = "S3EndpointResolver"
  } }
]]
