local core = require("core")
local compat = require("plugins.recovery.compat")
local Store = require("plugins.recovery.store")
local Engine = require("plugins.recovery.engine")
local codec = require("plugins.recovery.codec")
local root = assert(os.getenv("RECOVERY_FIXTURE"))
local results, failures, counter = {}, 0, 0
local function eq(a, b)
  assert(a == b, tostring(a) .. " ~= " .. tostring(b))
end
local function write(p, t)
  local f = assert(io.open(p, "wb"))
  assert(f:write(t))
  assert(f:close())
end
local function read(p)
  local f = assert(io.open(p, "rb"))
  local t = f:read("*a")
  f:close()
  return t
end
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  results[#results + 1] = (ok and "PASS " or "FAIL ") .. name .. (ok and "" or "\n" .. err)
  if not ok then
    failures = failures + 1
  end
end
local function folder()
  counter = counter + 1
  local p = root .. "/case-" .. counter
  assert(system.mkdir(p))
  return p
end
local function stores(o)
  local p = folder()
  local a = Store.new({ root = p, max_bytes = o and o.max_bytes or 16777216, generations = 3 })
  return a, Store.new({
    root = p,
    alive = function()
      return false
    end,
  }), p
end
local function doc(t)
  local d = core.open_doc()
  compat.open(d)
  d:insert(1, 1, t)
  return d
end
local function record(s, t, r)
  return {
    origin = s.session .. "/d000001",
    revision = r or 1,
    captured = os.time(),
    source = root .. "/source.tex",
    name = "source.tex",
    crlf = true,
    selections = { 1, 1, 1, 1 },
    text = t or "日本語🙂\n",
  }
end
local function engine(s)
  return Engine.new(s)
end
test("native owner PID checks identify running and absent processes", function()
  assert(Store.alive(system.get_process_id()))
  local child = assert(process.start({ "/usr/bin/true" }))
  local pid = child:pid()
  while child:running() do
    system.sleep(0.001)
  end
  assert(not Store.alive(pid))
end)
test("codec round-trips Unicode NUL newlines paths and selections", function()
  local a = stores()
  local r = record(a, "日本語\0🙂\n\n")
  r.source = root .. "/quotes ' \" ;\n.tex"
  r.selections = { 1, 4, 1, 1, 2, 1, 2, 1 }
  local decoded = codec.decode(codec.encode(r, 1000), 1000)
  eq(decoded.text, r.text)
  eq(decoded.source, r.source)
  eq(decoded.crlf, true)
  eq(#decoded.selections, 8)
end)
test("codec refuses truncation checksum changes executable Lua and bad limits", function()
  local a = stores()
  local data = codec.encode(record(a), 1000)
  assert(not pcall(codec.decode, data:sub(1, -2), 1000))
  assert(not pcall(codec.decode, data:sub(1, -2) .. "x", 1000))
  assert(not pcall(codec.decode, 'return os.execute("bad")', 1000))
  assert(not pcall(codec.decode, data, 1))
  assert(not pcall(codec.encode, record(a), 1))
end)
test("untitled and named dirty buffers snapshot without writing source", function()
  local a, b = stores()
  local e = engine(a)
  local unnamed = doc("未保存🙂")
  write(root .. "/named.txt", "disk")
  local named = core.open_doc(root .. "/named.txt")
  named:insert(1, 1, "edited")
  eq(#e:tick({ unnamed, named }), 0)
  eq(#b:scan(), 2)
  eq(read(root .. "/named.txt"), "disk")
end)
test("unchanged buffers do not generate new snapshots", function()
  local a = stores()
  local e = engine(a)
  local d = doc("same")
  assert(e:capture(d))
  assert(not e:capture(d))
  eq(e.entries[d].generation, 1)
end)
test("cursor source and newline changes update snapshot metadata", function()
  local a = stores()
  local e = engine(a)
  local d = doc("abc")
  e:capture(d)
  compat.selection_target(d):set_selection(1, 2)
  assert(e:capture(d))
  d.crlf = true
  assert(e:capture(d))
  d:set_filename("new.txt", root .. "/new.txt")
  assert(e:capture(d))
  eq(e.entries[d].generation, 4)
end)
test("successful snapshots retain only the latest three generations", function()
  local a, b = stores()
  local e = engine(a)
  local d = doc("one")
  for i = 1, 6 do
    d:insert(1, 1, tostring(i))
    assert(e:capture(d))
  end
  local count = 0
  for _, name in ipairs(system.list_dir(a.path)) do
    if name:match("%.rec$") then
      count = count + 1
    end
  end
  eq(count, 3)
  local found = b:scan()
  eq(#found, 1)
  eq(b:read(found[1]).revision, 6)
end)
test("corrupt latest generation falls back to previous valid generation", function()
  local a, b = stores()
  local e = engine(a)
  local d = doc("old")
  e:capture(d)
  d:insert(1, 1, "new")
  e:capture(d)
  write(e.entries[d].file, "broken")
  local found = b:scan()
  eq(#found, 1)
  eq(b:read(found[1]).text, "old\n")
end)
test("pending and unrelated files are never treated as recovery data", function()
  local a, b = stores()
  write(a.path .. "/d000001-v0000000001.rec.pending-1", "partial")
  write(a.path .. "/payload.lua", 'error("should not execute")')
  eq(#b:scan(), 0)
end)
test("active-session snapshots are skipped", function()
  local a = Store.new({ root = folder() })
  a:put("d000001", 1, record(a))
  local b = Store.new({ root = a.root })
  eq(#b:scan(), 0)
end)
test("unknown owners are skipped without removing snapshots", function()
  local a, b = stores()
  local file = a:put("d000001", 1, record(a))
  b.alive = function()
    error("owner state unavailable")
  end
  eq(#b:scan(), 0)
  assert(system.get_file_info(file))
end)
test("independent sessions use distinct directories and files", function()
  local a, b = stores()
  assert(a.path ~= b.path)
  a:put("d000001", 1, record(a, "first\n"))
  b:put("d000001", 1, record(b, "second\n"))
  local c = Store.new({
    root = a.root,
    alive = function()
      return false
    end,
  })
  eq(#c:scan(), 2)
end)
test("cross-instance claim prevents a second restorer", function()
  local a, b = stores()
  a:put("d000001", 1, record(a))
  local candidate = b:scan()[1]
  local release = assert(b:claim(candidate))
  local c = Store.new({
    root = a.root,
    alive = function()
      return true
    end,
  })
  local second = c:claim(candidate)
  eq(second, nil)
  release()
end)
test("stale claims can be reclaimed after owner death", function()
  local a, b = stores()
  a:put("d000001", 1, record(a))
  local candidate = b:scan()[1]
  assert(b:claim(candidate))
  local c = Store.new({
    root = a.root,
    alive = function()
      return false
    end,
  })
  local release = assert(c:claim(candidate))
  release()
end)
test("restore opens a new unsaved copy and leaves original and open doc intact", function()
  local a, b = stores()
  local r = record(a, "回復🙂\n")
  write(r.source, "original disk")
  local existing = core.open_doc(r.source)
  compat.open(existing)
  a:put("d000001", 1, r)
  local e = engine(b)
  local restored = assert(e:restore(b:scan()[1]))
  eq(restored.filename, nil)
  eq(restored.abs_filename, nil)
  assert(restored:is_dirty())
  eq(table.concat(restored.lines), r.text)
  eq(restored.crlf, true)
  eq(read(r.source), "original disk")
  eq(table.concat(existing.lines), "original disk\n")
  assert(restored:get_name():match("Recovered"))
  eq(restored._recovery.source, r.source)
end)
test("restore preserves blank lines multicursor and UTF8 boundaries", function()
  local a, b = stores()
  local r = record(a, "日本語\n\nend\n")
  r.selections = { 1, 2, 1, 1, 3, 2, 3, 2 }
  a:put("d000001", 1, r)
  local d = assert(engine(b):restore(b:scan()[1]))
  eq(table.concat(d.lines), r.text)
  eq(#compat.selections(d), 8)
  eq(compat.selections(d)[2], 1)
end)
test("empty named new-file buffer recovers as an unsaved empty copy", function()
  local a, b = stores()
  local r = record(a, "\n")
  a:put("d000001", 1, r)
  local restored = assert(engine(b):restore(b:scan()[1]))
  eq(restored.filename, nil)
  eq(table.concat(restored.lines), "\n")
  assert(restored:is_dirty())
end)
test("restored buffer is persisted before source acknowledgement", function()
  local a, b = stores()
  a:put("d000001", 1, record(a))
  local candidate = b:scan()[1]
  local e = engine(b)
  local d = assert(e:restore(candidate))
  assert(system.get_file_info(e.entries[d].file))
  assert(b:retired(a.path, "d000001"))
  eq(b:handled(candidate.origin), 1)
end)
test("a crash after restoration produces one recoverable newer copy", function()
  local a, b = stores()
  a:put("d000001", 1, record(a))
  assert(engine(b):restore(b:scan()[1]))
  local c = Store.new({
    root = a.root,
    alive = function()
      return false
    end,
  })
  local list = c:scan()
  eq(#list, 1)
  eq(list[1].revision, 2)
end)
test("save or discard retires transferred archives as well as the current copy", function()
  local a, b = stores()
  local original = a:put("d000001", 1, record(a))
  local e = engine(b)
  local d = assert(e:restore(b:scan()[1]))
  assert(system.get_file_info(original))
  local current = e.entries[d].file
  e:drop(d)
  assert(not system.get_file_info(original))
  assert(not system.get_file_info(current))
end)
test("archive cleanup never deletes another running instance's files", function()
  local a, b = stores()
  local original = a:put("d000001", 1, record(a))
  b.alive = function()
    return true
  end
  b:ack(a.session .. "/d000001", 1)
  b:purge_handled(a.session .. "/d000001", 1)
  assert(system.get_file_info(original))
end)
test("saved restored buffers use a fresh origin when edited again", function()
  local a, b = stores()
  a:put("d000001", 1, record(a))
  local e = engine(b)
  local d = assert(e:restore(b:scan()[1]))
  local old = e.entries[d].origin
  d:save("saved-again.txt", root .. "/saved-again.txt")
  e:drop(d)
  assert(not d._recovery)
  d:insert(1, 1, "later")
  e:capture(d)
  assert(e.entries[d].origin ~= old)
  local c = Store.new({
    root = a.root,
    alive = function()
      return false
    end,
  })
  local list = c:scan()
  eq(#list, 1)
  eq(list[1].origin, e.entries[d].origin)
end)
test("acknowledgements suppress older duplicate origins across sessions", function()
  local a, b = stores()
  local r = record(a)
  a:put("d000001", 1, r)
  b:put("d000002", 1, r)
  local c = Store.new({
    root = a.root,
    alive = function()
      return false
    end,
  })
  eq(#c:scan(), 1)
  assert(engine(c):restore(c:scan()[1]))
  local d = Store.new({
    root = a.root,
    alive = function(pid)
      return pid == system.get_process_id()
    end,
  })
  eq(#d:scan(), 0)
end)
test("write failures retain previous committed snapshot and dirty buffer", function()
  local a, b = stores()
  local e = engine(a)
  local d = doc("old")
  e:capture(d)
  d:insert(1, 1, "changed")
  local open = io.open
  io.open = function(path, mode)
    if mode == "wb" and path:find(".pending-", 1, true) then
      return nil, "injected open failure"
    end
    return open(path, mode)
  end
  local ok = pcall(e.capture, e, d)
  io.open = open
  assert(not ok)
  assert(d:is_dirty())
  eq(e.entries[d].generation, 1)
  eq(b:read(b:scan()[1]).text, "old\n")
end)
test("close and rename failures never publish or prune the previous generation", function()
  for _, kind in ipairs({ "close", "rename" }) do
    local a, b = stores()
    local e = engine(a)
    local d = doc("old")
    e:capture(d)
    d:insert(1, 1, "changed")
    local open, rename = io.open, os.rename
    if kind == "close" then
      io.open = function(path, mode)
        local fp, err = open(path, mode)
        if fp and mode == "wb" and path:find(".pending-", 1, true) then
          return {
            write = function(_, data)
              return fp:write(data)
            end,
            close = function()
              fp:close()
              return nil, "injected close failure"
            end,
          }
        end
        return fp, err
      end
    else
      os.rename = function()
        return nil, "injected rename failure"
      end
    end
    local ok = pcall(e.capture, e, d)
    io.open, os.rename = open, rename
    assert(not ok)
    eq(b:read(b:scan()[1]).text, "old\n")
    eq(e.entries[d].generation, 1)
  end
end)
test("oversized buffers fail without losing an earlier valid snapshot", function()
  local a, b = stores({ max_bytes = 32 })
  local e = engine(a)
  local d = doc("old")
  e:capture(d)
  d:insert(1, 1, string.rep("x", 40))
  local errors = e:tick({ d })
  eq(#errors, 1)
  eq(b:read(b:scan()[1]).text, "old\n")
end)
test("a failed restored-copy write leaves the source available", function()
  local a, b = stores()
  a:put("d000001", 1, record(a))
  local e = engine(b)
  local candidate = b:scan()[1]
  b.put = function()
    error("injected transfer failure")
  end
  assert(not pcall(e.restore, e, candidate))
  assert(not b:retired(a.path, "d000001"))
  eq(b:handled(candidate.origin), -1)
end)
test("retirement failure leaves data available for retry", function()
  local a, b = stores()
  local e = engine(a)
  local d = doc("data")
  e:capture(d)
  local ack = a.ack
  a.ack = function()
    error("injected acknowledgement failure")
  end
  d:clean()
  d.new_file = false
  assert(not pcall(e.drop, e, d))
  a.ack = ack
  assert(e.entries[d])
  eq(#b:scan(), 1)
end)

local global = require("plugins.recovery").get_engine()
test("stock save hook immediately retires a saved snapshot", function()
  local d = doc("save hook")
  global:capture(d)
  local path = root .. "/hook-save.txt"
  d:save(path, path)
  eq(global.entries[d], nil)
  eq(read(path), "save hook\n")
end)
test("failed stock save retains dirty buffer and snapshot", function()
  local d = doc("unsaved")
  global:capture(d)
  local original = io.open
  io.open = function(path, mode)
    if path == root .. "/failed-save.txt" then
      return nil, "injected save failure"
    end
    return original(path, mode)
  end
  local ok = pcall(d.save, d, root .. "/failed-save.txt", root .. "/failed-save.txt")
  io.open = original
  assert(not ok and d:is_dirty() and global.entries[d])
end)
test("stock Close cancellation preserves snapshot; confirmed last Close retires it", function()
  local d = doc("close")
  global:capture(d)
  local dv = compat.selection_target(d)
  if dv == d then
    dv = core.get_views_referencing_doc(d)[1]
  end
  local commands = compat.commands()
  local enter = commands.enter
  local pending
  commands.enter = function(_, _, options)
    pending = options
  end
  local references = core.get_views_referencing_doc
  local open = true
  core.get_views_referencing_doc = function(x)
    if x == d then
      return open and { dv } or {}
    end
    return references(x)
  end
  dv:try_close(function()
    open = false
  end)
  assert(pending and global.entries[d])
  assert(open) -- dismissing the prompt invokes no submit
  pending.submit("c", { text = "Close Without Saving" })
  eq(global.entries[d], nil)
  core.get_views_referencing_doc = references
  commands.enter = enter
end)
test("stock closing a second view does not retire shared document", function()
  local d = doc("shared")
  global:capture(d)
  local dv = core.get_views_referencing_doc(d)[1]
  local refs = core.get_views_referencing_doc
  core.get_views_referencing_doc = function(x)
    if x == d then
      return { dv, dv }
    end
    return refs(x)
  end
  dv:try_close(function() end)
  assert(global.entries[d])
  core.get_views_referencing_doc = refs
end)
test("stock shutdown confirmation No preserves; Yes retires after removal callback", function()
  local d = doc("quit")
  global:capture(d)
  local nag = compat.nag()
  local show = nag.show
  local pending
  local refs = core.get_views_referencing_doc
  local removed = false
  core.get_views_referencing_doc = function(x)
    if x == d and removed then
      return {}
    end
    return refs(x)
  end
  nag.show = function(_, _, _, options, callback)
    pending = callback
  end
  core.confirm_close_docs({ d }, function()
    removed = true
  end)
  pending({ text = "No" })
  assert(global.entries[d] and not removed)
  core.confirm_close_docs({ d }, function()
    removed = true
  end)
  pending({ text = "Yes" })
  eq(global.entries[d], nil)
  nag.show = show
  core.get_views_referencing_doc = refs
end)
test("failed shutdown callback retains snapshot", function()
  local d = doc("failed quit")
  global:capture(d)
  local nag = compat.nag()
  local show = nag.show
  local pending
  nag.show = function(_, _, _, _, callback)
    pending = callback
  end
  core.confirm_close_docs({ d }, function()
    error("injected shutdown failure")
  end)
  assert(not pcall(pending, { text = "Yes" }))
  assert(global.entries[d])
  nag.show = show
end)
test("platform adapter rejects unsupported Windows before file commands", function()
  local old = PLATFORM
  PLATFORM = "Windows"
  local ok = pcall(require("plugins.recovery.platform").check)
  PLATFORM = old
  assert(not ok)
end)

test("claim symlink aliases are rejected without deleting external files", function()
  local a, b = stores()
  a:put("d000001", 1, record(a))
  local candidate = b:scan()[1]
  local outside = folder()
  write(outside .. "/owner", "LXO1\n2147483646\n1\n")
  local lock = b.root .. "/claims/" .. candidate.origin:gsub("/", "_") .. ".claim"
  local child = assert(process.start({ "/bin/ln", "-s", outside, lock }))
  while child:running() do
    system.sleep(0.001)
  end
  eq(child:returncode(), 0)
  assert(not pcall(b.claim, b, candidate))
  eq(read(outside .. "/owner"), "LXO1\n2147483646\n1\n")
end)
test("symlink snapshot files are never decoded", function()
  local a, b = stores()
  local source = root .. "/outside-record.rec"
  write(source, codec.encode(record(a), 1000))
  local child =
    assert(process.start({ "/bin/ln", "-s", source, a.path .. "/d000001-v0000000001.rec" }))
  while child:running() do
    system.sleep(0.001)
  end
  eq(child:returncode(), 0)
  eq(#b:scan(), 0)
  assert(system.get_file_info(source))
end)
test("module reload does not stack save or close hooks", function()
  local Doc = require("core.doc")
  local DocView = require("core.docview")
  local save, close = Doc.save, DocView.try_close
  local again = dofile(USERDIR .. "/plugins/recovery/init.lua")
  eq(again, require("plugins.recovery"))
  eq(Doc.save, save)
  eq(DocView.try_close, close)
end)

write(
  root .. "/unit-results.txt",
  table.concat(results, "\n") .. "\n" .. (#results - failures) .. "/" .. #results .. " passed\n"
)
assert(failures == 0, tostring(failures) .. " unit tests failed")
