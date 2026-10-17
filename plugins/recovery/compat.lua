-- Keep the editor's API differences out of the recovery file format/store.
local core = require("core")
local Doc = require("core.doc")
local view_selections = rawget(Doc, "set_selections") == nil
local compat = {}
function compat.root()
  return core.active_window and core.active_window().root_view or core.root_view
end
function compat.nag()
  return compat.root().nag_view or core.nag_view
end
function compat.commands()
  return compat.root().command_view or core.command_view
end
function compat.open(doc)
  return compat.root():open_doc(doc)
end
function compat.selection_target(doc)
  if not view_selections then
    return doc
  end
  local views = core.get_views_referencing_doc(doc)
  for _, view in ipairs(views) do
    if view == (compat.root().active_view or core.active_view) then
      return view
    end
  end
  return views[1] or compat.open(doc)
end
function compat.selections(doc)
  if not view_selections then
    return doc.selections
  end
  local views = core.get_views_referencing_doc(doc)
  if #views == 0 then
    return { 1, 1, 1, 1 }
  end
  local values = { table.unpack(compat.selection_target(doc).selections) }
  for i = 1, #values, 2 do
    local text = doc.lines[values[i]]
    values[i + 1] = utf8.offset(text, values[i + 1]) or #text
  end
  return values
end
function compat.restore_selections(doc, values)
  local target = compat.selection_target(doc)
  target.selections = {}
  local function position(line, col)
    line = math.max(1, math.min(line, #doc.lines))
    local text = doc.lines[line]
    col = math.max(1, math.min(col, #text))
    while col > 1 and text:byte(col) >= 0x80 and text:byte(col) < 0xc0 do
      col = col - 1
    end
    if view_selections then
      col = (utf8.len(text:sub(1, col - 1)) or col - 1) + 1
    end
    return line, col
  end
  for i = 1, #values, 4 do
    local l, c = position(values[i], values[i + 1])
    local l2, c2 = position(values[i + 2], values[i + 3])
    target:set_selections((i + 3) / 4, l, c, l2, c2)
  end
  target:merge_cursors()
end
return compat
