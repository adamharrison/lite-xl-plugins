-- POSIX implementation. Unsupported platforms fail before hooks are installed.
local platform = {}
function platform.check()
  assert(
    PLATFORM ~= "Windows",
    "Recovery currently requires POSIX chmod and ps; Windows is not supported"
  )
end
-- Poll the common native API without yielding: save/quit acknowledgements must
-- finish before the editor exits, including when called from a Lua coroutine.
local function wait(child)
  local deadline = system.get_time() + 5
  while child:running() do
    if system.get_time() >= deadline then
      pcall(child.kill, child)
      error("Recovery helper timed out")
    end
    system.sleep(0.001)
  end
  return child:returncode()
end
function platform.chmod(path, mode)
  platform.check()
  local child = assert(
    process.start(
      { "/bin/chmod", mode, path },
      { stdout = process.REDIRECT_DISCARD, stderr = process.REDIRECT_PIPE }
    )
  )
  local code = wait(child)
  assert(code == 0, "Cannot protect recovery permissions: " .. path)
end
function platform.alive(pid)
  platform.check()
  assert(
    type(pid) == "number" and pid % 1 == 0 and pid > 0 and pid <= 2147483647,
    "Invalid recovery owner PID"
  )
  local child = assert(
    process.start(
      { "/bin/ps", "-p", tostring(pid), "-o", "pid=" },
      { stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_PIPE }
    )
  )
  local code = wait(child)
  local diagnostic = child:read_stderr() or ""
  if code == 1 then
    assert(diagnostic == "", "Cannot determine recovery owner state: " .. diagnostic)
    return false
  end
  assert(code == 0, "Cannot determine recovery owner state")
  local output = child:read_stdout() or ""
  assert(tonumber(output:match("%d+")) == pid, "Cannot determine recovery owner identity")
  return true
end
return platform
