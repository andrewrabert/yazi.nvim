-- A subset of plenary.nvim's `plenary.path`, ported to remove the dependency.
-- Behavior must match plenary's exactly.
-- https://github.com/nvim-lua/plenary.nvim/blob/master/lua/plenary/path.lua

local bit = require("bit")
local uv = vim.uv

local S_IF = {
  -- S_IFDIR  = 0o040000  # directory
  DIR = 0x4000,
  -- S_IFREG  = 0o100000  # regular file
  REG = 0x8000,
}

local path = {}
path.home = uv.os_homedir()

path.sep = (function()
  if jit then
    local os = string.lower(jit.os)
    if os ~= "windows" then
      return "/"
    else
      return "\\"
    end
  else
    return package.config:sub(1, 1)
  end
end)()

path.root = (function()
  if path.sep == "/" then
    return function()
      return "/"
    end
  else
    return function(base)
      base = base or uv.cwd()
      return base:sub(1, 1) .. ":\\"
    end
  end
end)()

path.S_IF = S_IF

local band = function(reg, value)
  return bit.band(reg, value) == reg
end

local concat_paths = function(...)
  return table.concat({ ... }, path.sep)
end

local function is_root(pathname)
  if path.sep == "\\" then
    return string.match(pathname, "^[A-Z]:\\?$")
  end
  return pathname == "/"
end

local _split_by_separator = (function()
  local formatted = string.format("([^%s]+)", path.sep)
  return function(filepath)
    local t = {}
    for str in string.gmatch(filepath, formatted) do
      table.insert(t, str)
    end
    return t
  end
end)()

local is_uri = function(filename)
  return string.match(filename, "^%a[%w+-.]*://") ~= nil
end

local is_absolute = function(filename, sep)
  if sep == "\\" then
    return string.match(filename, "^[%a]:[\\/].*$") ~= nil
  end
  return string.sub(filename, 1, 1) == sep
end

local function _normalize_path(filename, cwd)
  if is_uri(filename) then
    return filename
  end

  -- handles redundant `./` in the middle
  local redundant = path.sep .. "%." .. path.sep
  if filename:match(redundant) then
    filename = filename:gsub(redundant, path.sep)
  end

  local out_file = filename

  local has = string.find(filename, path.sep .. "..", 1, true)
    or string.find(filename, ".." .. path.sep, 1, true)

  if has then
    local is_abs = is_absolute(filename, path.sep)
    local split_without_disk_name = function(filename_local)
      local parts = _split_by_separator(filename_local)
      -- Remove disk name part on Windows
      if path.sep == "\\" and is_abs then
        table.remove(parts, 1)
      end
      return parts
    end

    local parts = split_without_disk_name(filename)
    local idx = 1
    local initial_up_count = 0

    repeat
      if parts[idx] == ".." then
        if idx == 1 then
          initial_up_count = initial_up_count + 1
        end
        table.remove(parts, idx)
        table.remove(parts, idx - 1)
        if idx > 1 then
          idx = idx - 2
        else
          idx = idx - 1
        end
      end
      idx = idx + 1
    until idx > #parts

    local prefix = ""
    if is_abs or #split_without_disk_name(cwd) == initial_up_count then
      prefix = path.root(filename)
    end

    out_file = prefix .. table.concat(parts, path.sep)
  end

  return out_file
end

local clean = function(pathname)
  if is_uri(pathname) then
    return pathname
  end

  -- Remove double path seps, it's annoying
  pathname = pathname:gsub(path.sep .. path.sep, path.sep)

  -- Remove trailing path sep if not root
  if not is_root(pathname) and pathname:sub(-1) == path.sep then
    return pathname:sub(1, -2)
  end
  return pathname
end

---@class Path
---@field filename string
local Path = {
  path = path,
}

Path.__index = function(t, k)
  local raw = rawget(Path, k)
  if raw then
    return raw
  end

  if k == "_cwd" then
    local cwd = uv.fs_realpath(".")
    t._cwd = cwd
    return cwd
  end

  if k == "_absolute" then
    local absolute = uv.fs_realpath(t.filename)
    t._absolute = absolute
    return absolute
  end
end

Path.__div = function(self, other)
  assert(Path.is_path(self))
  assert(Path.is_path(other) or type(other) == "string")

  return self:joinpath(other)
end

Path.__tostring = function(self)
  return clean(self.filename)
end

Path.__concat = function(self, other)
  return self.filename .. other
end

Path.is_path = function(a)
  return getmetatable(a) == Path
end

---@return Path
function Path:new(...)
  local args = { ... }

  if type(self) == "string" then
    table.insert(args, 1, self)
    self = Path -- luacheck: ignore
  end

  local path_input
  if #args == 1 then
    path_input = args[1]
  else
    path_input = args
  end

  -- If we already have a Path, it's fine.
  --   Just return it
  if Path.is_path(path_input) then
    return path_input
  end

  local sep = path.sep
  if type(path_input) == "table" then
    sep = path_input.sep or path.sep
    path_input.sep = nil
  end

  local path_string
  if type(path_input) == "table" then
    local path_objs = {}
    for _, v in ipairs(path_input) do
      if Path.is_path(v) then
        table.insert(path_objs, v.filename)
      else
        assert(type(v) == "string")
        table.insert(path_objs, v)
      end
    end

    path_string = table.concat(path_objs, sep)
  else
    assert(type(path_input) == "string", vim.inspect(path_input))
    path_string = path_input
  end

  local obj = {
    filename = path_string,

    _sep = sep,
  }

  setmetatable(obj, Path)

  return obj
end

function Path:_fs_filename()
  return self:absolute() or self.filename
end

function Path:_stat()
  return uv.fs_stat(self:_fs_filename()) or {}
end

function Path:_st_mode()
  return self:_stat().mode or 0
end

function Path:joinpath(...)
  return Path:new(self.filename, ...)
end

function Path:absolute()
  if self:is_absolute() then
    return _normalize_path(self.filename, self._cwd)
  else
    return _normalize_path(
      self._absolute or table.concat({ self._cwd, self.filename }, self._sep),
      self._cwd
    )
  end
end

function Path:exists()
  return not vim.tbl_isempty(self:_stat())
end

function Path:make_relative(cwd)
  if is_uri(self.filename) then
    return self.filename
  end

  self.filename = clean(self.filename)
  if cwd == nil then
    cwd = self._cwd
  end
  cwd = clean(cwd)
  if self.filename == cwd then
    self.filename = "."
  else
    if cwd:sub(#cwd, #cwd) ~= path.sep then
      cwd = cwd .. path.sep
    end

    if self.filename:sub(1, #cwd) == cwd then
      self.filename = self.filename:sub(#cwd + 1, -1)
    end
  end

  return self.filename
end

function Path:is_dir()
  return band(S_IF.DIR, self:_st_mode())
end

function Path:is_absolute()
  return is_absolute(self.filename, self._sep)
end

local _get_parent = (function()
  local formatted = string.format("^(.+)%s[^%s]+", path.sep, path.sep)
  return function(abs_path)
    local parent = abs_path:match(formatted)
    if parent ~= nil and not parent:find(path.sep) then
      return parent .. path.sep
    end
    return parent
  end
end)()

---@return Path
function Path:parent()
  return Path:new(_get_parent(self:absolute()) or path.root(self:absolute()))
end

function Path:parents()
  local results = {}
  local cur = self:absolute()
  repeat
    cur = _get_parent(cur)
    table.insert(results, cur)
  until not cur
  table.insert(results, path.root(self:absolute()))
  return results
end

function Path:is_file()
  return self:_stat().type == "file" and true or nil
end

function Path:_split()
  return vim.split(self:absolute(), self._sep)
end

function Path:mkdir(opts)
  opts = opts or {}

  local mode = opts.mode or 448 -- 0700 -> decimal
  local parents = vim.F.if_nil(opts.parents, false)
  local exists_ok = vim.F.if_nil(opts.exists_ok, true)

  local exists = self:exists()
  if not exists_ok and exists then
    error("FileExistsError:" .. self:absolute())
  end

  -- fs_mkdir returns nil if folder exists
  if not uv.fs_mkdir(self:_fs_filename(), mode) and not exists then
    if parents then
      local dirs = self:_split()
      local processed = ""
      for _, dir in ipairs(dirs) do
        if dir ~= "" then
          local joined = concat_paths(processed, dir)
          if processed == "" and self._sep == "\\" then
            joined = dir
          end
          local stat = uv.fs_stat(joined) or {}
          local file_mode = stat.mode or 0
          if band(S_IF.REG, file_mode) then
            error(
              string.format("%s is a regular file so we can't mkdir it", joined)
            )
          elseif band(S_IF.DIR, file_mode) then
            processed = joined
          else
            if uv.fs_mkdir(joined, mode) then
              processed = joined
            else
              error("We couldn't mkdir: " .. joined)
            end
          end
        end
      end
    else
      error("FileNotFoundError")
    end
  end

  return true
end

return Path
