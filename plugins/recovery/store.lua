local common = require("core.common")
local codec = require("plugins.recovery.codec")
local Store = {}
Store.__index = Store
local serial = 0
local platform = require("plugins.recovery.platform")
local chmod = platform.chmod
local function read(path, limit)
  local fp = assert(io.open(path, "rb"))
  local data, message = fp:read(limit + 1)
  local closed, err = fp:close()
  assert(data, message)
  assert(closed, err)
  assert(#data <= limit, "Recovery file too large")
  return data
end
local function directory(path)
  local info = system.get_file_info(path)
  if not info then
    assert(system.mkdir(path))
    info = assert(system.get_file_info(path))
  end
  assert(
    info.type == "dir" and system.absolute_path(path) == path,
    "Recovery directory must not be a symbolic-link alias"
  )
  chmod(path, "700")
end
local function write(path, data)
  serial = serial + 1
  local temporary = path .. ".pending-" .. system.get_process_id() .. "-" .. serial
  assert(not system.get_file_info(temporary), "Recovery temporary path exists")
  local fp
  local ok, message = pcall(function()
    fp = assert(io.open(temporary, "wb"))
    assert(fp:write(data))
    local handle = fp
    fp = nil
    assert(handle:close())
    chmod(temporary, "600")
    assert(read(temporary, #data) == data, "Recovery read-back mismatch")
    assert(os.rename(temporary, path))
  end)
  if fp then
    pcall(fp.close, fp)
  end
  if not ok then
    pcall(os.remove, temporary)
    error(message)
  end
end
local function owner(path)
  local ok, data = pcall(read, path, 128)
  if not ok then
    return nil
  end
  local pid = data:match("^LXO1\n(%d+)\n%d+\n$")
  pid = tonumber(pid)
  return pid and pid > 0 and pid <= 2147483647 and pid or nil
end
Store.alive = platform.alive
function Store.new(options)
  local root = common.normalize_path(options.root)
  assert(
    common.is_absolute_path(root) and root ~= PATHSEP and root ~= USERDIR and root ~= HOME,
    "Invalid recovery root"
  )
  assert(not root:match("/ws/") and not root:match("/ws$"), "ws is excluded from recovery storage")
  directory(root)
  directory(root .. "/claims")
  directory(root .. "/handled")
  local self = setmetatable(
    {
      root = root,
      pid = system.get_process_id(),
      max_bytes = options.max_bytes or 16777216,
      keep = options.generations or 3,
      alive = options.alive or Store.alive,
      warn = options.warn or function() end,
    },
    Store
  )
  assert(self.keep >= 1 and self.keep <= 20, "Invalid recovery generation count")
  for i = 1, 100 do
    local token =
      string.format("s%d-%d-%d", os.time(), self.pid, math.floor(system.get_time() * 1000000) + i)
    local path = root .. PATHSEP .. token
    if system.mkdir(path) then
      chmod(path, "700")
      self.session, self.path = token, path
      write(path .. "/owner", string.format("LXO1\n%d\n%d\n", self.pid, os.time()))
      return self
    end
  end
  error("Cannot allocate recovery session")
end
function Store:retired(path, id)
  local file = path .. "/" .. id .. ".retired"
  if not system.get_file_info(file) then
    return false
  end
  local ok, data = pcall(read, file, 64)
  if not ok or data ~= "LXR-RETIRED\n" then
    self.warn("Invalid recovery retirement marker: " .. file)
    return false
  end
  return true
end
local function versions(path, id)
  local found = {}
  for _, name in ipairs(assert(system.list_dir(path))) do
    local doc, generation = name:match("^(d%d+)%-v(%d+)%.rec$")
    if doc == id then
      found[#found + 1] = { name = name, generation = tonumber(generation) }
    end
  end
  table.sort(found, function(a, b)
    return a.generation > b.generation
  end)
  return found
end
function Store:put(id, generation, record)
  assert(
    id:match("^d%d+$") and generation >= 1 and generation % 1 == 0,
    "Invalid recovery identifier"
  )
  local name = string.format("%s-v%010d.rec", id, generation)
  assert(not system.get_file_info(self.path .. "/" .. name), "Recovery generation already exists")
  local data = codec.encode(record, self.max_bytes)
  codec.decode(data, self.max_bytes)
  write(self.path .. "/" .. name, data)
  local history = versions(self.path, id)
  for i = self.keep + 1, #history do
    local ok, err = os.remove(self.path .. "/" .. history[i].name)
    if not ok then
      self.warn("Cannot prune recovery generation: " .. tostring(err))
    end
  end
  return self.path .. "/" .. name
end
function Store:retire(path, id, keep_history)
  assert(id:match("^d%d+$"), "Invalid recovery identifier")
  write(path .. "/" .. id .. ".retired", "LXR-RETIRED\n")
  if keep_history then
    return
  end
  for _, item in ipairs(versions(path, id)) do
    local ok, err = os.remove(path .. "/" .. item.name)
    if not ok then
      self.warn("Cannot remove retired snapshot: " .. tostring(err))
    end
  end
end
function Store:read(candidate)
  assert(
    system.absolute_path(candidate.file) == candidate.file,
    "Snapshot must not be a symbolic link"
  )
  return codec.decode(read(candidate.file, self.max_bytes + 131072), self.max_bytes)
end
function Store:handled(origin)
  assert(origin:match("^s%d+%-%d+%-%d+/d%d+$"), "Invalid recovery origin")
  local path = self.root .. "/handled/" .. origin:gsub("/", "_") .. ".ack"
  if not system.get_file_info(path) then
    return -1
  end
  local ok, data = pcall(read, path, 64)
  local revision = ok and tonumber(data:match("^LXA1\n(%d+)\n$"))
  if not revision then
    self.warn("Invalid recovery acknowledgement: " .. path)
    return -1
  end
  return revision
end
function Store:ack(origin, revision)
  local latest = math.max(self:handled(origin), revision)
  write(
    self.root .. "/handled/" .. origin:gsub("/", "_") .. ".ack",
    string.format("LXA1\n%d\n", latest)
  )
end
function Store:purge_handled(origin, revision)
  -- Called only after a save/discard has been committed to our ledger.
  -- Other live instances retain exclusive ownership of their own files.
  for _, session in ipairs(assert(system.list_dir(self.root))) do
    if session:match("^s%d+%-%d+%-%d+$") then
      local path = self.root .. "/" .. session
      local pid = owner(path .. "/owner")
      local checked, active = false, true
      if path == self.path then
        checked, active = true, false
      elseif pid then
        checked, active = pcall(self.alive, pid)
      end
      if checked and not active and system.absolute_path(path) == path then
        for _, name in ipairs(system.list_dir(path) or {}) do
          if name:match("^d%d+%-v%d+%.rec$") then
            local candidate = { file = path .. "/" .. name }
            local valid, record = pcall(self.read, self, candidate)
            if valid and record.origin == origin and record.revision <= revision then
              local ok, err = os.remove(candidate.file)
              if not ok and system.get_file_info(candidate.file) then
                self.warn("Cannot remove handled recovery data: " .. tostring(err))
              end
            end
          end
        end
      end
    end
  end
end
function Store:scan()
  local by_origin = {}
  local sessions = assert(system.list_dir(self.root))
  table.sort(sessions)
  for _, session in ipairs(sessions) do
    if session ~= self.session and session:match("^s%d+%-%d+%-%d+$") then
      local path = self.root .. "/" .. session
      local pid = owner(path .. "/owner")
      local ok, active = false, true
      if pid then
        ok, active = pcall(self.alive, pid)
      end
      if not ok then
        self.warn("Cannot inspect recovery owner: " .. session)
      end
      if ok and not active and system.absolute_path(path) == path then
        local ids = {}
        for _, name in ipairs(system.list_dir(path) or {}) do
          local id = name:match("^(d%d+)%-v%d+%.rec$")
          if id then
            ids[id] = true
          end
        end
        for id in pairs(ids) do
          if not self:retired(path, id) then
            for _, item in ipairs(versions(path, id)) do
              local candidate =
                { session = session, path = path, id = id, file = path .. "/" .. item.name }
              local good, record = pcall(self.read, self, candidate)
              if good and record.revision > self:handled(record.origin) then
                candidate.origin, candidate.revision, candidate.captured =
                  record.origin, record.revision, record.captured
                candidate.source, candidate.name = record.source, record.name
                local previous = by_origin[record.origin]
                if
                  not previous
                  or candidate.revision > previous.revision
                  or candidate.revision == previous.revision
                    and candidate.captured > previous.captured
                then
                  by_origin[record.origin] = candidate
                end
                break
              elseif not good then
                self.warn(
                  "Unreadable recovery generation: " .. candidate.file .. ": " .. tostring(record)
                )
              end
            end
          end
        end
      end
    end
  end
  local list = {}
  for _, item in pairs(by_origin) do
    list[#list + 1] = item
  end
  table.sort(list, function(a, b)
    if a.captured == b.captured then
      return a.origin < b.origin
    end
    return a.captured > b.captured
  end)
  return list
end
function Store:claim(candidate)
  if
    self:retired(candidate.path, candidate.id)
    or self:handled(candidate.origin) >= candidate.revision
  then
    return nil, "Snapshot was already handled"
  end
  local lock = self.root .. "/claims/" .. candidate.origin:gsub("/", "_") .. ".claim"
  if system.get_file_info(lock) then
    assert(
      system.absolute_path(lock) == lock and system.get_file_info(lock).type == "dir",
      "Recovery claim must not be a symbolic-link alias"
    )
    local pid = owner(lock .. "/owner")
    if pid then
      local ok, active = pcall(self.alive, pid)
      if not ok or active then
        return nil, "Another instance is handling this snapshot"
      end
      assert(os.remove(lock .. "/owner"))
      assert(system.rmdir(lock))
    else
      local info = system.get_file_info(lock)
      if not info or os.time() - (info.modified or os.time()) < 60 then
        return nil, "Recovery claim is not ready; retry later"
      end
      assert(system.rmdir(lock))
    end
  end
  if not system.mkdir(lock) then
    return nil, "Another instance claimed this snapshot"
  end
  chmod(lock, "700")
  local ok, err =
    pcall(write, lock .. "/owner", string.format("LXO1\n%d\n%d\n", self.pid, os.time()))
  if not ok then
    pcall(system.rmdir, lock)
    error(err)
  end
  -- A previous restorer may have retired the record just before our claim.
  if
    self:retired(candidate.path, candidate.id)
    or self:handled(candidate.origin) >= candidate.revision
  then
    os.remove(lock .. "/owner")
    system.rmdir(lock)
    return nil, "Snapshot was already handled"
  end
  return function()
    local removed, message = os.remove(lock .. "/owner")
    assert(removed, message)
    assert(system.rmdir(lock))
  end
end
return Store
