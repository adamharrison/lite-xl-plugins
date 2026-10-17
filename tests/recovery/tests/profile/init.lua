local core = require("core")
if core._recovery_test_boot then
  return
end
core._recovery_test_boot = true
local config = require("core.config")
config.plugins.compatibility3 = false
config.plugins.recovery = {
  root = USERDIR .. (os.getenv("RECOVERY_MODE") == "unit" and "/unit-recovery" or "/recovery-v1"),
  interval = 1,
}
core.add_thread(function()
  local fixture = assert(os.getenv("RECOVERY_FIXTURE"))
  local function publish(name, text)
    local f = assert(io.open(fixture .. "/" .. name, "wb"))
    assert(f:write(text))
    assert(f:close())
  end
  local ok, err = xpcall(function()
    local api = require("plugins.recovery")
    assert(not core._personal_init_state, "Personal config loaded")
    local mode = assert(os.getenv("RECOVERY_MODE"))
    local compat = require("plugins.recovery.compat")
    local function wait(fn)
      local start = system.get_time()
      while not fn() do
        assert(system.get_time() - start < 20, "Timeout in " .. mode)
        coroutine.yield(0.025)
      end
    end
    wait(function()
      return api.engine
    end)
    if mode == "unit" then
      dofile(assert(os.getenv("RECOVERY_SUITE")))
      publish("unit.done", "PASS")
      os.exit(0)
    end
    if mode == "writer" then
      local named = core.open_doc(fixture .. "/source.tex")
      compat.open(named)
      named:insert(1, 1, "EDIT-")
      named.crlf = true
      compat.restore_selections(named, { 1, 3, 1, 3 })
      local unnamed = core.open_doc()
      compat.open(unnamed)
      unnamed:insert(1, 1, "日本語🙂\n\nsecond")
      compat.restore_selections(unnamed, { 1, 10, 1, 1, 3, 2, 3, 2 })
      wait(function()
        return api.engine.entries[named] and api.engine.entries[unnamed]
      end)
      publish("writer.ready", "PASS periodic snapshots for named and unnamed documents")
      while true do
        coroutine.yield(1)
      end
    elseif mode == "observer" or mode == "probe" then
      assert(#api.engine.store:scan() == 0, "Unexpected recovery candidates")
      publish(mode .. ".done", "PASS no inactive recovery candidates")
      os.exit(0)
    else
      local list = api.engine.store:scan()
      assert(#list == 2, "Expected two recoverable buffers, got " .. #list)
      local nag = compat.nag()
      assert(nag.title == "Unsaved buffers available" and nag.options[1].text == "Later")
      assert(nag.options[1].default_yes and nag.options[1].default_no)
      nag.on_selected({ text = "Restore All" })
      nag:next()
      wait(function()
        local count = 0
        for _, d in ipairs(core.docs) do
          if d._recovery then
            count = count + 1
          end
        end
        return count == 2
      end)
      local restored = {}
      for _, doc in ipairs(core.docs) do
        if doc._recovery then
          assert(not doc.filename and doc:is_dirty())
          local text = table.concat(doc.lines)
          if doc._recovery.source then
            assert(text == "EDIT-BASE\n" and doc.crlf)
          else
            assert(text == "日本語🙂\n\nsecond\n")
            local s = compat.selections(doc)
            assert(#s == 8 and s[2] == 10, "Cursor byte position changed")
          end
          restored[#restored + 1] = doc
        end
      end
      assert(#restored == 2, "Unexpected duplicate restored buffers")
      if mode == "discard" then
        core.quit()
        local nag = compat.nag()
        assert(nag.title == "Unsaved Changes")
        nag.on_selected({ text = "No" })
        nag:next()
        assert(not core.quit_request)
        for _, doc in ipairs(restored) do
          assert(api.engine.entries[doc])
        end
        core.quit()
        nag = compat.nag()
        nag.on_selected({ text = "Yes" })
        publish(
          "discard.done",
          "PASS actual stock Quit No preserves and Yes retires before process exit"
        )
        return
      end
      if mode == "save" then
        for i, doc in ipairs(restored) do
          local path = fixture .. "/saved-" .. i .. ".txt"
          doc:save(path, path)
          assert(not doc:is_dirty() and not api.engine.entries[doc])
        end
        publish("save.done", "PASS restored copies saved with stock Doc.save")
        core.quit(true)
      else
        publish(
          "restore.ready",
          "PASS exact content CRLF UTF8 selections and two independent dirty copies"
        )
        while true do
          coroutine.yield(1)
        end
      end
    end
  end, debug.traceback)
  if not ok then
    publish("FAIL.txt", tostring(err))
    os.exit(1)
  end
end)
