local core = require("core")
local common = require("core.common")
local compat = require("plugins.recovery.compat")
local Engine = {}
Engine.__index = Engine
function Engine.new(store, options)
  options = options or {}
  return setmetatable(
    {
      store = store,
      entries = {},
      counter = 0,
      restored = {},
      open = options.open or function(doc)
        compat.open(doc)
      end,
      warn = options.warn or function(message)
        core.error("%s", message)
      end,
    },
    Engine
  )
end
function Engine:capture(doc)
  if not doc:is_dirty() then
    self:drop(doc)
    return false
  end
  local text = table.concat(doc.lines)
  local source = doc.abs_filename or doc._recovery and doc._recovery.source
  if not source and doc.filename then
    source = core.project_absolute_path(common.normalize_path(doc.filename))
  end
  local name = doc.filename or doc._recovery and doc._recovery.name
  local selection = table.concat(compat.selections(doc), ",")
  local entry = self.entries[doc]
  if
    entry
    and entry.text == text
    and entry.source == source
    and entry.name == name
    and entry.crlf == not not doc.crlf
    and entry.selection == selection
  then
    return false
  end
  if not entry then
    self.counter = self.counter + 1
    entry = { id = string.format("d%06d", self.counter), generation = 0, revision = 0 }
    entry.origin = doc._recovery and doc._recovery.origin or self.store.session .. "/" .. entry.id
    entry.revision = doc._recovery and doc._recovery.revision or 0
    self.entries[doc] = entry
  end
  local record = {
    origin = entry.origin,
    revision = entry.revision + 1,
    captured = os.time(),
    source = source,
    name = name,
    crlf = not not doc.crlf,
    selections = { table.unpack(compat.selections(doc)) },
    text = text,
  }
  local file = self.store:put(entry.id, entry.generation + 1, record)
  entry.generation, entry.revision = entry.generation + 1, record.revision
  entry.text, entry.source, entry.name, entry.crlf, entry.selection =
    text, source, name, record.crlf, selection
  entry.file = file
  return true
end
function Engine:drop(doc)
  local entry = self.entries[doc]
  if not entry then
    return
  end
  if entry.generation > 0 then
    self.store:ack(entry.origin, entry.revision)
    self.store:retire(self.store.path, entry.id)
    self.store:purge_handled(entry.origin, entry.revision)
  end
  self.entries[doc] = nil
  doc._recovery = nil -- A saved/reused buffer starts a fresh recovery origin.
end
function Engine:tick(docs)
  local active, errors = {}, {}
  for _, doc in ipairs(docs) do
    active[doc] = true
    local ok, message = pcall(self.capture, self, doc)
    if not ok then
      errors[#errors + 1] = tostring(message)
    end
  end
  local closed = {}
  for doc in pairs(self.entries) do
    if not active[doc] then
      closed[#closed + 1] = doc
    end
  end
  for _, doc in ipairs(closed) do
    local ok, message = pcall(self.drop, self, doc)
    if not ok then
      errors[#errors + 1] = tostring(message)
    end
  end
  return errors
end
function Engine:restore(candidate)
  if self.restored[candidate.origin] and self.restored[candidate.origin] >= candidate.revision then
    return nil, "Already restored in this instance"
  end
  local release, message = self.store:claim(candidate)
  if not release then
    return nil, message
  end
  local ok, result = pcall(function()
    local record = self.store:read(candidate)
    assert(
      record.origin == candidate.origin and record.revision == candidate.revision,
      "Recovery record changed; refresh the list"
    )
    local doc = core.open_doc()
    doc:insert(1, 1, record.text:sub(1, -2)) -- Doc already owns its final sentinel LF.
    doc.crlf = record.crlf
    doc._recovery = {
      origin = record.origin,
      revision = record.revision,
      source = record.source,
      name = record.name,
    }
    if record.source then
      doc.syntax = require("core.syntax").get(record.source, record.text:sub(1, 128))
      if doc.highlighter then
        doc.highlighter:soft_reset()
      end
    end
    compat.restore_selections(doc, record.selections)
    -- A recovered empty named buffer must also remain dirty after becoming unnamed.
    doc.new_file = false
    doc.clean_change_id = -1
    assert(self:capture(doc), "Cannot transfer recovered buffer")
    self.open(doc)
    self.store:ack(record.origin, record.revision)
    -- Keep source generations as a private archive after successful transfer.
    self.store:retire(candidate.path, candidate.id, true)
    self.restored[record.origin] = record.revision
    return doc
  end)
  local released, release_error = pcall(release)
  if not released then
    self.warn(tostring(release_error))
  end
  if not ok then
    error(result)
  end
  return result
end
function Engine:discard(candidate)
  local release, message = self.store:claim(candidate)
  if not release then
    return false, message
  end
  local ok, err = pcall(function()
    self.store:ack(candidate.origin, candidate.revision)
    self.store:retire(candidate.path, candidate.id)
    self.store:purge_handled(candidate.origin, candidate.revision)
  end)
  local released, release_error = pcall(release)
  if not released then
    self.warn(tostring(release_error))
  end
  if not ok then
    error(err)
  end
  return true
end
return Engine
