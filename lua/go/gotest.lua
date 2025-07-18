-- run `go test`
local M = {}
local utils = require('go.utils')
local log = utils.log
local trace = utils.trace
local empty = utils.empty
local ginkgo = require('go.ginkgo')
local getopt = require('go.alt_getopt')
local install = require('go.install').install
local vfn = vim.fn

local long_opts = {
  verbose = 'v',
  compile = 'c',
  coverprofile = 'C',
  count = 'n',
  tags = 't',
  fuzz = 'f',
  run = 'r',
  bench = 'b',
  metric = 'm',
  select = 's',
  args = 'a',
  package = 'p',
  floaterm = 'F',
}

local sep = require('go.utils').sep()
-- local short_opts = 'a:cC:b:fFmn:pst:rv'
local short_opts = 'a:cC:b:fFmn:pst:r:v'
local bench_opts = { '-test.benchmem', '-test.cpuprofile', 'profile.out' }

local is_windows = utils.is_windows()
local is_git_shell = is_windows
  and (vim.fn.exists('$SHELL') and vim.fn.expand('$SHELL'):find('bash.exe') ~= nil)
M.efm = function()
  local indent = [[%\\%(    %\\)]]
  local efm = [[%-G=== RUN   %.%#]]
  efm = efm .. [[,%-G]] .. indent .. [[%#--- PASS: %.%#]]
  efm = efm .. [[,%G--- FAIL: %\\%(Example%\\)%\\@=%m (%.%#)]]
  efm = efm .. [[,%G]] .. indent .. [[%#--- FAIL: %m (%.%#)]]
  efm = efm .. [[,%A]] .. indent .. [[%\\+%[%^:]%\\+: %f:%l: %m]]
  efm = efm .. [[,%+Gpanic: test timed out after %.%\\+]]
  efm = efm .. ',%+Afatal error: %.%# [recovered]'
  efm = efm .. [[,%+Afatal error: %.%#]]
  efm = efm .. [[,%+Apanic: %.%#]]
  --
  -- -- exit
  efm = efm .. ',%-Cexit status %[0-9]%\\+'
  efm = efm .. ',exit status %[0-9]%\\+'
  -- -- failed lines
  efm = efm .. ',%-CFAIL%\\t%.%#'
  efm = efm .. ',FAIL%\\t%.%#'
  -- compiling error

  efm = efm .. ',%A%f:%l:%c: %m'
  efm = efm .. ',%A%f:%l: %m'
  efm = efm .. ',%f:%l +0x%[0-9A-Fa-f]%\\+' -- pannic with adress
  efm = efm .. ',%-G%\\t%\\f%\\+:%\\d%\\+ +0x%[0-9A-Fa-f]%\\+' -- test failure, address invalid inside
  -- multi-line
  efm = efm .. ',%+G%\\t%m'
  efm = efm .. ',%-C%.%#' -- ignore rest of unmatched lines
  efm = efm .. ',%-G%.%#'

  efm = string.gsub(efm, ' ', [[\ ]])
  -- log(efm)
  return efm
end
local parse = vim.treesitter.query.parse

-- return "-tags=tag1,tag2"
M.get_build_tags = function(args, tbl)
  args = args or {}
  local tags = {}
  if _GO_NVIM_CFG.build_tags ~= '' then
    table.insert(tags, _GO_NVIM_CFG.build_tags)
  end

  local optarg, _, reminder = getopt.get_opts(args, short_opts, long_opts)
  log('build tags', optarg, reminder)
  if optarg['t'] then
    table.insert(tags, optarg['t'])
  end

  local rt = utils.get_build_tags()
  if not utils.empty(rt) then
    vim.list_extend(tags, rt)
  end

  local t = '-tags'
  if _GO_NVIM_CFG.test_runner == 'dlv' then
    t = '--build-flags'
  end
  if #tags > 0 then
    if tbl then
      return { t, table.concat(tags, ',') }, reminder, optarg
    end
    return t .. '=' .. table.concat(tags, ','), reminder, optarg
  end
end

function M.get_test_path()
  local path = vim.fn.expand('%:p:h')
  local relative_path = vim.fn.fnamemodify(path, ':.')
  if path == relative_path then
    return path
  end
  return '.' .. sep .. relative_path
end

local function get_test_filebufnr()
  local fn = vfn.expand('%')
  trace(fn)

  local bufnr = vim.api.nvim_get_current_buf()
  if not fn:find('test%.go$') then
    fn = require('go.alternate').alternate()
    fn = vfn.fnamemodify(fn, ':p') -- expand to full path
    -- check if file exists
    if vfn.filereadable(fn) == 0 then
      vim.notify('no test file found for ' .. fn, vim.log.levels.WARN)
      return 0, 'no test file'
    end
    local uri = vim.uri_from_fname(fn)
    bufnr = vim.uri_to_bufnr(uri)
    log(fn, bufnr, uri)
    if not vim.api.nvim_buf_is_loaded(bufnr) then
      vfn.bufload(bufnr)
    end
  end
  return bufnr
end

local function cmd_builder(path, args)
  log('builder args', args)
  local compile = false
  local bench = false
  local extra_args = ''
  for i, arg in ipairs(args) do
    --check if it is bench test
    if arg:find('-bench') then
      bench = true
      table.remove(args, i)
      break
    end
  end
  local optarg, oid, reminder = getopt.get_opts(args, short_opts, long_opts)
  trace('cmd_builder', optarg, oid, reminder)
  if optarg['c'] then
    path = utils.rel_path(true) -- vfn.expand("%:p:h") can not resolve releative path
    compile = true
  end

  if reminder and #reminder > 0 then
    --if % in args expand to current file
    for i, v in ipairs(reminder) do
      if v == '%' then
        reminder[i] = vim.fn.expand('%:p')
      end
    end
  end

  if next(reminder) then
    path = reminder[1]
    table.remove(reminder, 1)
  end
  local test_runner = _GO_NVIM_CFG.go
  if _GO_NVIM_CFG.test_runner ~= test_runner then
    test_runner = _GO_NVIM_CFG.test_runner
    if not install(test_runner) then
      vim.notify('test runner not found', vim.log.levels.INFO)
      test_runner = 'go'
    end
  end

  local tags = M.get_build_tags(args)

  log('tags', tags)
  local cmd = { test_runner or 'go' }

  if cmd[1] == 'go' then
    table.insert(cmd, 'test')
  end

  if cmd[1] == 'gotestsum' then
    table.insert(cmd, '--format')
    table.insert(cmd, 'testname')
    table.insert(cmd, '--')
  end

  local run_in_floaterm = optarg['F'] or _GO_NVIM_CFG.run_in_floaterm
  if run_in_floaterm then
    -- cmd[1] = test_runner or 'go'
  end

  if not empty(tags) then
    cmd = vim.list_extend(cmd, { tags })
  end

  if optarg['c'] then
    compile = true
  end
  if optarg['n'] then
    table.insert(cmd, '-count=' .. optarg['n'])
  end

  if (optarg['v'] or _GO_NVIM_CFG.verbose_tests) and _GO_NVIM_CFG.test_runner == 'go' then
    table.insert(cmd, '-v')
  end

  if optarg['f'] then
    log('fuzz test')
    table.insert(cmd, '-fuzz')
  end

  if optarg['P'] then
    table.insert(cmd, '-parallel')
    table.insert(cmd, optarg['P'])
  end

  log('optargs', optarg)
  if optarg['r'] then
    log('run test', optarg['r'])
    table.insert(cmd, '-test.run')
    table.insert(cmd, optarg['r'])
  end

  if optarg['b'] and optarg['b'] ~= '' then
    log('build test flags', optarg['b'])
    assert(type(optarg['b']) == 'string', 'build flags must be string')
    table.insert(cmd, optarg['b'])
  end

  if compile == true then
    if path ~= '' then
      table.insert(cmd, '-c')
      table.insert(cmd, path)
    end
  elseif bench == true then
    if path ~= '' then
      table.insert(cmd, '-test.bench=' .. path)
    else
      table.insert(cmd, '-test.bench=.')
    end
    vim.list_extend(cmd, bench_opts)
  else
    if path ~= '' then
      table.insert(cmd, path)
    else
      local argsstr = '.' .. utils.sep() .. '...'
      table.insert(cmd, argsstr)
    end
  end

  if optarg['C'] then
    table.insert(cmd, '-coverprofile=' .. optarg['C'])
  end

  if not empty(reminder) then
    cmd = vim.list_extend(cmd, reminder)
    log('****', reminder, cmd)
  end
  if optarg['a'] then
    table.insert(cmd, '-args')
    table.insert(cmd, optarg['a'])
  end
  log(cmd, optarg, tags)
  return cmd, optarg, tags
end

-- {-c: compile, -v: verbose, -t: tags, -b: bench, -s: select}
local function run_test(path, args)
  log('run test', args)
  local cmd, optarg = cmd_builder(path, args)
  log(cmd, args)
  local run_in_floaterm = _GO_NVIM_CFG.run_in_floaterm or optarg['F']
  if run_in_floaterm then
    local term = require('go.term').run
    log(cmd)
    term({ cmd = cmd, autoclose = false })
    return cmd
  end

  utils.log('test cmd', cmd)
  local asyncmake = require('go.asyncmake')
  return asyncmake.runjob(cmd, 'go test', args)
end

M.test = function(...)
  local args = { ... }
  log(args)

  local test_opts = {
    verbose = 'v',
    compile = 'c',
    coverprofile = 'C',
    tags = 't',
    bench = 'b',
    metrics = 'm',
    floaterm = 'F',
    nearest = 'n',
    file = 'f',
    args = 'a',
    package = 'p',
  }

  local parallel = 0
  for i, arg in ipairs(args) do
    --check if it is bench test
    if arg:find('-parallel') then
      parallel = args[i + 1]:match('%d+')
      table.remove(args, i)
      table.remove(args, i)
      break
    end
  end
  local test_short_opts = 'a:vcC:t:bsfmnpF'
  local optarg, _, reminder = getopt.get_opts(args, test_short_opts, test_opts)
  if parallel ~= 0 then
    optarg['P'] = parallel
    table.insert(args, '-P')
    table.insert(args, parallel)
  end

  -- if % in reminder expand to current file
  for i, v in ipairs(reminder) do
    if v == '%' then
      reminder[i] = vim.fn.expand('%')
      optarg['f'] = true
    end
  end
  vfn.setqflist({})

  if optarg['n'] then --nearest
    optarg['n'] = nil
    local opts = getopt.rebuid_args(optarg, reminder) or {}
    return M.test_func(unpack(opts))
  end

  if optarg['f'] then -- currentfile
    optarg['f'] = nil
    local opts = getopt.rebuid_args(optarg, reminder) or {}
    return M.test_file(unpack(opts))
  end
  if optarg['p'] then -- current package
    optarg['p'] = nil
    local opts = getopt.rebuid_args(optarg, reminder) or {}
    return M.test_package(unpack(opts))
  end

  if optarg['a'] then -- current package
    log('args', optarg['a'])
  end
  local workfolder = utils.work_path()
  if workfolder == nil then
    workfolder = '.'
  end

  local fpath = workfolder .. utils.sep() .. '...'

  if #reminder > 0 then
    -- check if reminder is a directory
    local r = reminder[1]
    if string.find(r, '%.%.%.') or vim.fn.isdirectory(r) == 1 then
      fpath = reminder[1]
    end
  end

  utils.log('fpath :' .. fpath)
  run_test(fpath, args)
end

M.test_suit = function(...)
  local args = { ... }
  log(args)

  local workfolder = utils.work_path()
  utils.log(args)
  local fpath = workfolder .. utils.sep() .. '...'

  utils.log('fpath' .. fpath)

  run_test(fpath, args)
end

M.test_package = function(...)
  local args = { ... }
  log('test pkg', args)
  local fpath = M.get_test_path() .. sep .. '...'
  utils.log('fpath: ' .. fpath)
  return run_test(fpath, args)
end

M.get_test_func_name = function()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row, col = row, col + 1
  local ns = require('go.ts.go').get_func_method_node_at_pos()
  if empty(ns) then
    return nil
  end
  if ns == nil or ns.name == nil then
    return nil
  end
  if not string.find(ns.name, '[T|t]est') then
    -- not in a test function
    local fns = M.get_testfunc()
    for _, fn in ipairs(fns) do
      log(fn, ns.name)
      if string.find(fn:lower(), ns.name:lower()) then
        ns = { name = fn }
        return ns
      end
    end
  end
  return ns
end

local function spaceto(testcase_name)
  -- convert 'test name' to 'test_name'
  return string.gsub(testcase_name, ' ', '_')
end

M.get_testcase_name = function()
  local tc_name = require('go.ts.go').get_tbl_testcase_node_name()
  if not empty(tc_name) then
    log('tc name', tc_name)
    return spaceto(tc_name)
  end
  tc_name = require('go.ts.go').get_sub_testcase_name()
  if not empty(tc_name) then
    log('sub name', tc_name)
    return spaceto(tc_name)
  end
  return nil
end

local function format_test_name(name)
  name = name:gsub('"', '')
  if not _GO_NVIM_CFG.gotest_case_exact_match then
    return name
  end
  return string.format([['^\Q%s\E$']], name)
end

local function run_tests_with_ts_node(args, func_node, tblcase_ns)
  local fpath = M.get_test_path()
  local cmd, optarg, tags = cmd_builder(fpath, args)

  local test_runner = _GO_NVIM_CFG.test_runner or 'go'

  if test_runner ~= 'go' then
    if not install(test_runner) then
      test_runner = 'go'
    end
  end

  if test_runner == 'ginkgo' or ginkgo.is_ginkgo_file() then
    return ginkgo.test_func(args)
  end

  if optarg['s'] then
    return M.select_tests(args)
  end
  if func_node == nil or func_node.name == nil then
    return
  end

  local test_name_path = format_test_name(func_node.name)

  log(test_name_path, tblcase_ns)
  if tblcase_ns then
    test_name_path = string.format([['^\Q%s\E/\Q%s\E$']], func_node.name, tblcase_ns)
  end
  log(test_name_path)

  if func_node.name:find('Bench') then
    local bench = '-test.bench=' .. test_name_path
    for i, v in ipairs(cmd) do
      if v:find('-test.bench') then
        cmd[i] = bench
        break
      end
      if i == #cmd then
        table.insert(cmd, bench)
      end
    end
    vim.list_extend(cmd, bench_opts)
  elseif func_node.name:find('Fuzz') then
    table.insert(cmd, '-test.fuzz=' .. func_node.name)
  else
    table.insert(cmd, '-test.run=' .. test_name_path)
  end

  if test_runner == 'dlv' then
    local runflag = string.format('-test.run=%s', test_name_path)
    table.insert(cmd, 3, fpath)
    table.insert(cmd, '--')
    table.insert(cmd, runflag)
    log(cmd)
    local term = require('go.term').run
    term({ cmd = cmd, autoclose = false })
    return
  end
  local run_in_floaterm = optarg['F'] or _GO_NVIM_CFG.run_in_floaterm

  if run_in_floaterm then
    utils.log(cmd)
    local term = require('go.term').run
    term({ cmd = cmd, autoclose = false })
    return
  end

  -- set_efm()
  utils.log('test cmd', cmd)

  return require('go.asyncmake').runjob(cmd, 'go test', args)
end

--options {s:select, F: floaterm}
M.test_func = function(...)
  local args = { ... } or {}
  log(args)
  local bufnr = get_test_filebufnr()
  local p = vim.treesitter.get_parser(bufnr, 'go')
  if not p then
    --   require('nvim-treesitter.install').commands.TSInstallSync['run!']('go')
    vim.notify(
      'go treesitter parser not found for file '
        .. vim.fn.bufname()
        .. ' please Run `:TSInstallSync go` ',
      vim.log.levels.WARN
    )
  end
  local ns = M.get_test_func_name()
  if empty(ns) then
    return M.select_tests(args)
  end
  return run_tests_with_ts_node(args, ns)
end

--options {s:select, F: floaterm}
M.test_tblcase = function(...)
  local args = { ... }

  local ns = M.get_test_func_name()
  if empty(ns) then
    vim.notify('put cursor on test case name string')
  end

  local tblcase_ns = M.get_testcase_name()
  if empty(tblcase_ns) then
    vim.notify('put cursor on test case name string')
  end
  return run_tests_with_ts_node(args, ns, tblcase_ns)
end

M.get_test_cases = function()
  local fpath = '.' .. sep .. vfn.fnamemodify(vfn.expand('%:p'), ':.')
  local is_test = fpath:find('_test%.go$')
  if not is_test then
    fpath = '.' .. sep .. vfn.fnamemodify(vfn.expand('%:p'), ':.:r') .. '_test.go'
  end
  -- utils.log(args)
  -- check if test file exists
  if vfn.filereadable(fpath) == 0 then
    return
  end
  local tests = M.get_testfunc()
  if vim.fn.empty(tests) == 1 then
    -- TODO maybe with treesitter or lsp list all functions in current file and regex with Test
    if vfn.executable('sed') == 0 then
      vim.notify('sed not found', vim.log.levels.WARN)
      return
    end
    local cmd = [[cat ]]
      .. fpath
      .. [[| sed -n 's/func\s\+\(Test.*\)(.*/\1/p' | xargs | sed 's/ /\\|/g']]
    local tests_results = vfn.systemlist(cmd)
    if vim.v.shell_error ~= 0 then
      utils.warn('go test failed' .. cmd .. vim.inspect(tests_results))
      return
    end

    log(cmd, vim.v.shell_error, tests_results)
    return tests_results[1]
  end
  local testsstr = vim.fn.join(tests, '|')
  log('test test cases', tests, testsstr)
  return testsstr, tests
end

M.test_file = function(...)
  local args = { ... }
  log('test file', args)

  -- require sed
  local tests = M.get_test_cases()
  if not tests then
    vim.notify('no test found fallback to package test', vim.log.levels.DEBUG)
    return M.test_package(...)
  end

  if vfn.empty(tests) == 1 then
    vim.notify('no test found fallback to package test', vim.log.levels.DEBUG)
    M.test_package(...)
    return
  end

  -- local test_runner = _GO_NVIM_CFG.go
  -- if _GO_NVIM_CFG.test_runner ~= 'go' then
  --   test_runner = _GO_NVIM_CFG.test_runner
  --   if not install(test_runner) then
  --     test_runner = 'go'
  --   end
  --   if test_runner == 'ginkgo' or ginkgo.is_ginkgo_file() then
  --     ginkgo.test_file(...)
  --   end
  -- end
  --
  local relpath = utils.rel_path(true)
  log(relpath)
  --
  -- local optarg, _, reminder = getopt.get_opts(args, short_opts, long_opts)
  --
  -- local run_in_floaterm = optarg['F'] or _GO_NVIM_CFG.run_in_floaterm
  -- local tags = M.get_build_tags(args)
  --
  -- local cmd_args = { 'go', 'test' }
  -- if run_in_floaterm then
  --   cmd_args[1] = test_runner or 'go'
  -- end
  --
  -- if (optarg['v'] or _GO_NVIM_CFG.verbose_tests) and _GO_NVIM_CFG.test_runner == 'go' then
  --   table.insert(cmd_args, '-v')
  -- end
  --
  -- if tags ~= nil then
  --   table.insert(cmd_args, tags)
  -- end
  --
  -- if next(reminder) then
  --   vim.list_extend(cmd_args, reminder)
  -- end
  -- if optarg['n'] then
  --   table.insert(cmd_args, '-count=' .. (optarg['n'] or '1'))
  --   table.insert(cmd_args, optarg['n'] or '1')
  -- end
  --
  -- if optarg['C'] then
  --   table.insert(cmd_args, '-coverprofile=' .. optarg['C'])
  -- end
  --
  local cmd_args, optarg = cmd_builder(relpath, args)

  table.insert(cmd_args, '-test.run')

  if is_windows then
    tests = '"' .. tests .. '"'
  else
    tests = "'" .. tests .. "'"
  end
  table.insert(cmd_args, tests) -- shell script | is a pipe

  if optarg['F'] or _GO_NVIM_CFG.run_in_floaterm then
    local term = require('go.term').run
    local cmd_args_str = table.concat(cmd_args, ' ')
    log(cmd_args)
    term({ cmd = cmd_args_str, autoclose = false })
    return cmd_args
  end

  if _GO_NVIM_CFG.test_runner == 'dlv' then
    cmd_args = { 'dlv', 'test', relpath, '--', '-test.run', tests }
    local term = require('go.term').run
    term({ cmd = table.concat(cmd_args, ' '), autoclose = false })
    log(cmd_args)
    return cmd_args
  end
  log(cmd_args)
  local cmdret = require('go.asyncmake').runjob(cmd_args, 'go test', args)

  utils.log('test cmd: ', cmdret, ' finished')
  return cmdret
end

-- TS based run func
-- https://github.com/rentziass/dotfiles/blob/master/vim/.config/nvim/lua/rentziass/lsp/go_tests.lua
M.run_file = function()
  local bufnr = vim.api.nvim_get_current_buf()
  local parser = vim.treesitter.get_parser(bufnr, 'go')
  if not parser then
    vim.notify('go treesitter parser not found for ' .. vim.fn.bufname(), vim.log.levels.WARN)
    return log('no ts parser found')
  end
  local tree = parser:parse()[1]
  local query = parse('go', require('go.ts.textobjects').query_test_func)

  local test_names = {}
  local get_node_text = vim.treesitter.get_node_text
  for id, node in query:iter_captures(tree:root(), bufnr, 0, -1) do
    local name = query.captures[id] -- name of the capture in the query
    if name == 'test_name' then
      table.insert(test_names, utils.get_node_text(node, bufnr))
    end
  end

  vim.schedule(function()
    vim.lsp.buf.execute_command({
      command = 'gopls.run_tests',
      arguments = { { URI = vim.uri_from_bufnr(0), Tests = test_names } },
    })
  end)
end

M.get_testfunc = function()
  local bufnr = get_test_filebufnr()

  -- Note: the buffer may not be loaded yet
  local parser = vim.treesitter.get_parser(bufnr, 'go')
  if not parser then
    vim.notify('go treesitter parser not found for ' .. vim.fn.bufname(), vim.log.levels.WARN)
    return log('no parser found')
  end
  local tree = parser:parse()[1]
  local query = parse('go', require('go.ts.go').query_test_func)

  local test_names = {}

  local get_node_text = vim.treesitter.get_node_text
  for id, node in query:iter_captures(tree:root(), bufnr, 0, -1) do
    local name = query.captures[id] -- name of the capture in the query
    -- log(node)
    if name == 'test_name' then
      table.insert(test_names, utils.get_node_text(node, bufnr))
    end
  end
  log('TS test names', test_names)
  return test_names
end

-- GUI to select test?
M.select_tests = function(args)
  local original_select = vim.ui.select

  vim.ui.select = _GO_NVIM_CFG.go_select()

  vim.defer_fn(function()
    vim.ui.select = original_select
  end, 500)

  local function onselect(item, idx)
    if not item then
      return
    end

    local uri = vim.uri_from_bufnr(0)
    local fpath = M.get_test_path()
    local cmd_args, optarg = cmd_builder(fpath, args)
    log(uri, item, idx)

    if optarg['F'] or _GO_NVIM_CFG.run_in_floaterm then
      table.insert(cmd_args, '-test.run=' .. format_test_name(item))

      local term = require('go.term').run
      log(cmd_args)
      term({ cmd = cmd_args, autoclose = false })
      return
    end

    vim.schedule(function()
      vim.lsp.buf.execute_command({
        command = 'gopls.run_tests',
        arguments = { { URI = uri, Tests = { item } } },
      })
    end)
  end
  local test_names = M.get_testfunc()
  vim.ui.select(test_names, {
    prompt = 'select test to run:',
    kind = 'codelensaction',
  }, onselect)
  return test_names
end

return M
