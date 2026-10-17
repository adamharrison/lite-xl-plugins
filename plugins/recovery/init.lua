-- mod-version:4
local compat = require("plugins.recovery.compat")
local api = {}
local core = require("core")
if core._recovery_plugin then
  return core._recovery_plugin
end
local command = require("core.command")
local config = require("core.config")
local common = require("core.common")
local Doc = require("core.doc")
local DocView = require("core.docview")
local Store = require("plugins.recovery.store")
local Engine = require("plugins.recovery.engine")
config.plugins.recovery = common.merge(
  {
    enabled = true,
    interval = 5,
    generations = 3,
    max_bytes = 16777216,
    root = USERDIR .. PATHSEP .. "recovery-v1",
  },
  config.plugins.recovery
)
local settings = config.plugins.recovery
if not settings.enabled then
  return api
end
require("plugins.recovery.platform").check()
assert(
  type(settings.interval) == "number" and settings.interval >= 1 and settings.interval <= 3600,
  "Recovery interval must be 1–3600 seconds"
)
assert(
  type(settings.generations) == "number"
    and settings.generations % 1 == 0
    and settings.generations >= 1
    and settings.generations <= 20,
  "Recovery generations must be an integer from 1 to 20"
)
assert(
  type(settings.max_bytes) == "number"
    and settings.max_bytes % 1 == 0
    and settings.max_bytes >= 1
    and settings.max_bytes <= 268435456,
  "Recovery max_bytes must be an integer from 1 to 256 MiB"
)
local engine, last_error
local function report(message)
  message = tostring(message)
  if message ~= last_error then
    core.error("Recovery: %s", message)
    last_error = message
  end
end
local function run(fn)
  local ok, message = pcall(fn)
  if not ok then
    report(message)
  end
  return ok
end
local function ensure()
  if not engine then
    engine = Engine.new(
      Store.new({
        root = settings.root,
        max_bytes = settings.max_bytes,
        generations = settings.generations,
        warn = report,
      }),
      { warn = report }
    )
    api.engine = engine
  end
  return engine
end
local function inform(message)
  compat.nag():show("Recovery", message, { { text = "OK", default_yes = true, default_no = true } })
end
local function tick()
  local errors = ensure():tick(core.docs)
  if #errors > 0 then
    report(table.concat(errors, "\n"))
  else
    last_error = nil
  end
end
local function restore_all()
  local count = 0
  for _, candidate in ipairs(ensure().store:scan()) do
    local ok, message = pcall(function()
      local doc, reason = engine:restore(candidate)
      if doc then
        count = count + 1
      else
        report(reason)
      end
    end)
    if not ok then
      report(message)
    end
  end
  core.log("Recovered %d buffer(s) as unsaved copies", count)
end
local function review()
  local entries = {}
  for _, item in ipairs(ensure().store:scan()) do
    entries[#entries + 1] = {
      text = string.format(
        "%s — %s — %s",
        item.source or item.name or "Untitled",
        os.date("%Y-%m-%d %H:%M:%S", item.captured),
        item.session .. "/" .. item.id
      ),
      candidate = item,
    }
  end
  if #entries == 0 then
    inform("No inactive-session snapshots are available.")
    return
  end
  compat.commands():enter("Recovery snapshots", {
    suggest = function(text)
      local matches = {}
      for _, item in ipairs(entries) do
        local score = system.fuzzy_match(item.text, text)
        if score then
          matches[#matches + 1] = { text = item.text, candidate = item.candidate, score = score }
        end
      end
      table.sort(matches, function(a, b)
        return a.score > b.score
      end)
      return matches
    end,
    submit = function(_, item)
      if not item or not item.candidate then
        return
      end
      local candidate = item.candidate
      compat.nag():show("Recovery snapshot", candidate.source or candidate.name or "Untitled", {
        { text = "Cancel", default_yes = true, default_no = true },
        { text = "Restore Copy" },
        { text = "Discard Snapshot" },
      }, function(choice)
        core.add_thread(function()
          run(function()
            if choice.text == "Restore Copy" then
              local doc, message = ensure():restore(candidate)
              if not doc then
                inform(message)
              end
            elseif choice.text == "Discard Snapshot" then
              compat.nag():show(
                "Discard recovery snapshot",
                "Permanently discard all generations of this snapshot?",
                {
                  { text = "Cancel", default_yes = true, default_no = true },
                  { text = "Discard" },
                },
                function(answer)
                  if answer.text == "Discard" then
                    core.add_thread(function()
                      run(function()
                        local ok, err = ensure():discard(candidate)
                        if not ok then
                          inform(err)
                        end
                      end)
                    end)
                  end
                end
              )
            end
          end)
        end)
      end)
    end,
  })
end
command.add(nil, {
  ["recovery:snapshot-now"] = function()
    run(tick)
  end,
  ["recovery:review"] = function()
    run(review)
  end,
  ["recovery:restore-all"] = function()
    run(restore_all)
  end,
})
local get_name = Doc.get_name
function Doc:get_name()
  if not self.filename and self._recovery then
    return "Recovered "
      .. common.basename(self._recovery.source or self._recovery.name or "Untitled")
  end
  return get_name(self)
end
local save = Doc.save
function Doc:save(...)
  local result = table.pack(save(self, ...))
  if engine and not self:is_dirty() then
    run(function()
      engine:drop(self)
    end)
  end
  return table.unpack(result, 1, result.n)
end
local close = DocView.try_close
function DocView:try_close(do_close)
  local doc = self.doc
  return close(self, function()
    do_close()
    if engine and #core.get_views_referencing_doc(doc) == 0 then
      run(function()
        engine:drop(doc)
      end)
    end
  end)
end
local confirm_close = core.confirm_close_docs
function core.confirm_close_docs(docs, close_fn, ...)
  local targets = { table.unpack(docs or core.docs) }
  return confirm_close(docs, function(...)
    local result = table.pack(close_fn(...))
    if engine then
      for _, doc in ipairs(targets) do
        if
          core.quit_request
          or core.restart_request
          or #core.get_views_referencing_doc(doc) == 0
        then
          run(function()
            engine:drop(doc)
          end)
        end
      end
    end
    return table.unpack(result, 1, result.n)
  end, ...)
end
core.add_thread(function()
  local initialized = false
  while true do
    if not initialized then
      initialized = run(function()
        local candidates = ensure().store:scan()
        if #candidates > 0 then
          compat.nag():show(
            "Unsaved buffers available",
            string.format(
              "%d recovery buffer(s) are available. Restore as new unsaved copies?",
              #candidates
            ),
            {
              { text = "Later", default_yes = true, default_no = true },
              { text = "Restore All" },
              { text = "Review" },
            },
            function(choice)
              core.add_thread(function()
                run(function()
                  if choice.text == "Restore All" then
                    restore_all()
                  elseif choice.text == "Review" then
                    review()
                  end
                end)
              end)
            end
          )
        end
      end)
    end
    if initialized then
      run(tick)
    end
    coroutine.yield(settings.interval)
  end
end)

core._recovery_plugin = api
api.snapshot = function()
  return tick()
end
api.review = review
api.restore_all = restore_all
api.get_engine = ensure
return api
