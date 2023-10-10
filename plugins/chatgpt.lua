-- mod-version:3

local core = require "core"
local json = require "libraries.json"
local www = require "libraries.www"
local command = require "core.command"
local keymap = require "core.keymap"
local config = require "core.config"
local common = require "core.common"
local DocView = require "core.docview"

config.plugins.chatgpt = common.merge({
  model = "gpt-3.5-turbo",
  endpoint = "https://api.openai.com/v1/chat/completions",
  temperature = 1,
  top_p = 1,
  completions = 1,
  timeout = 60,
  max_tokens = 1000,
  prompt = "You are a helpful code-completion chatbot. Please do not reply with anything other than code and comments.",
  token = os.getenv("OPENAI_API_KEY")
}, config.plugins.chatgpt)

if not config.plugins.chatgpt.token then core.error("No ChatGPT token found; please specify one in config.plugins.chatgpt.token or OPENAI_API_KEY.") end

local ChatGPT = common.merge({}, config.plugins.chatgpt)

function ChatGPT:request_completion(doc, line, col, on_done)
  local text = doc:get_text(1,1, line, col)
  core.add_thread(function()
    local res = www.request({
      timeout = self.timeout,
      verbose = 2,
      url = self.endpoint,
      headers = { ["Content-Type"] = "application/json", ["Authorization"] = "Bearer " .. self.token },
      body = json.encode({
        model = self.model,
        messages = {
          { role = "system", content = self.prompt },
          { role = "user", content = text }
        },
        max_tokens = self.max_tokens
      })
    })
    print(json.encode(res))
    local body = json.decode(res.body)
    on_done(body["choices"][1])
  end)
end


command.add(DocView, {
  ["chatgpt:complete"] = function()
    local doc = core.active_view.doc
    local line, col = doc:get_selection()
    ChatGPT:request_completion(doc, line, col, function(completion)
      doc:insert(line, col, completion.message.content)
    end)
  end
})

keymap.add {
  ["alt+/"] = "chatgpt:complete"
}


return ChatGPT
