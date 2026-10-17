-- Length-delimited data only. Recovery files are never executed as Lua.
local codec = {}
local function checksum(data)
  local a, b = 1, 0
  for first = 1, #data, 5552 do
    for i = first, math.min(first + 5551, #data) do
      a = a + data:byte(i)
      b = b + a
    end
    a, b = a % 65521, b % 65521
  end
  return b * 65536 + a
end
local function integer(text, limit)
  assert(text:match("^%d+$"), "Invalid recovery integer")
  local value = tonumber(text)
  assert(value and value <= limit and value % 1 == 0, "Recovery integer exceeds limit")
  return value
end
function codec.encode(record, max_bytes)
  assert(#record.text <= max_bytes, "Buffer exceeds recovery size limit")
  local selections = {}
  for _, value in ipairs(record.selections) do
    selections[#selections + 1] = tostring(value)
  end
  local fields = {
    record.origin,
    tostring(record.revision),
    tostring(record.captured),
    record.source or "",
    record.name or "",
    record.crlf and "1" or "0",
    table.concat(selections, ","),
    record.text,
  }
  local parts = {}
  for _, field in ipairs(fields) do
    parts[#parts + 1] = string.pack(">I4", #field) .. field
  end
  local body = table.concat(parts)
  return string.pack(">c4I4I4", "LXR1", #body, checksum(body)) .. body
end
function codec.decode(data, max_bytes)
  assert(#data >= 12 and #data <= max_bytes + 131072, "Invalid recovery file size")
  local magic, length, expected = string.unpack(">c4I4I4", data)
  assert(magic == "LXR1" and length == #data - 12, "Invalid recovery header")
  local body = data:sub(13)
  assert(checksum(body) == expected, "Recovery checksum mismatch")
  local position, fields = 1, {}
  for i = 1, 8 do
    assert(position + 3 <= #body, "Truncated recovery field")
    local size
    size, position = string.unpack(">I4", body, position)
    assert(
      size <= (i == 8 and max_bytes or 32768) and position + size - 1 <= #body,
      "Invalid recovery field length"
    )
    fields[i] = body:sub(position, position + size - 1)
    position = position + size
  end
  assert(position == #body + 1, "Trailing recovery bytes")
  assert(fields[1]:match("^s%d+%-%d+%-%d+/d%d+$"), "Invalid recovery origin")
  assert(not fields[4]:find("%z") and not fields[5]:find("%z"), "Invalid recovery source")
  assert(fields[6] == "0" or fields[6] == "1", "Invalid newline flag")
  local selections = {}
  assert(
    fields[7]:match("^%d+[,%d]*$")
      and not fields[7]:match(",$")
      and not fields[7]:find(",,", 1, true),
    "Invalid recovery selections"
  )
  for item in fields[7]:gmatch("%d+") do
    local value = integer(item, 2147483647)
    assert(value >= 1, "Invalid recovery selection")
    selections[#selections + 1] = value
  end
  assert(
    #selections >= 4 and #selections % 4 == 0 and #selections <= 1024,
    "Too many recovery selections"
  )
  assert(fields[8] ~= "" and fields[8]:sub(-1) == "\n", "Invalid document sentinel")
  return {
    origin = fields[1],
    revision = integer(fields[2], 2147483647),
    captured = integer(fields[3], 9007199254740991),
    source = fields[4] ~= "" and fields[4] or nil,
    name = fields[5] ~= "" and fields[5] or nil,
    crlf = fields[6] == "1",
    selections = selections,
    text = fields[8],
  }
end
return codec
