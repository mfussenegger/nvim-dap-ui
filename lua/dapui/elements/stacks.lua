local M = {}
local api = vim.api
local listener_id = "dapui_stack"

local Element = {
  config = {},
  render_receivers = {},
  threads = {},
  thread_frames = {},
  current_frame_id = nil,
  line_frame_map = {}
}

function Element:render_frames(frames, render_state, indent)
  for _, frame in pairs(frames or {}) do
    local line_no = render_state:length() + 1
    self.line_frame_map[line_no] = frame

    local new_line = string.rep(" ", indent)

    render_state:add_match("DapUIFrameName", line_no, #new_line + 1, #frame.name)
    new_line = new_line .. frame.name .. " "

    local source_name = vim.fn.fnamemodify(frame.source.path, ":.")
    if vim.startswith(source_name, ".") then
      source_name = frame.source.path
    end
    render_state:add_match("DapUIFrameSource", line_no, #new_line + 1, #source_name)
    new_line = new_line .. source_name .. ":"

    render_state:add_match("DapUILineNumber", line_no, #new_line + 1, #tostring(frame.line))
    new_line = new_line .. frame.line

    render_state:add_line(new_line)
  end
end

function Element:render_threads(match_group, threads, render_state)
  local ordered_keys = {}

  for k in pairs(threads) do
    table.insert(ordered_keys, k)
  end
  table.sort(ordered_keys)

  for i = 1, #ordered_keys, 1 do
    local thread = threads[ordered_keys[i]]
    render_state:add_match(match_group, render_state:length() + 1, 1, #thread.name)
    render_state:add_line(thread.name .. ":")
    self:render_frames(self.thread_frames[thread.id], render_state, 1)
    if i < #ordered_keys then
      render_state:add_line()
    end
  end
end

function Element:fill_render_state(render_state, stopped_thread)
  if not self.threads then
    return
  end
  local secondary_threads = {}
  for k, thread in pairs(self.threads) do
    if thread.id ~= stopped_thread then
      secondary_threads[k] = thread
    end
  end
  self:render_threads("DapUIStoppedThread", {self.threads[stopped_thread]}, render_state)
  render_state:add_line()
  self:render_threads("DapUIThread", secondary_threads, render_state)
end

function Element:should_render(session)
  return session and session.current_frame and not vim.tbl_isempty(self.render_receivers)
end

function Element:render(session)
  if not self:should_render(session) then
    return
  end
  self.current_frame_id = session.current_frame.id
  local render_state = require("dapui.render").init_state()
  self:fill_render_state(render_state, session.stopped_thread_id)
  for buf, reciever in pairs(self.render_receivers) do
    vim.api.nvim_buf_set_option(buf, "modifiable", true)
    reciever(render_state)
    vim.api.nvim_buf_set_option(buf, "modifiable", false)
  end
end

function _G.stacks_open_frame()
  local cur_line = vim.fn.line(".")
  local current_frame = Element.line_frame_map[cur_line]
  if not current_frame then
    return
  end
  require("dapui.util").jump_to_frame(current_frame)
end

function M.setup(user_config)
  Element.config = user_config
  local dap = require("dap")

  dap.listeners.after.threads[listener_id] = function(session, err, response)
    if err then
      return
    end
    for _, thread in pairs(response.threads) do
      Element.threads[thread.id] = thread
      if not Element.thread_frames[thread.id] then
        session:request(
          "stackTrace",
          {threadId = thread.id},
          function()
          end
        )
      end
    end
    Element:render(session)
  end

  dap.listeners.after.stackTrace[listener_id] = function(session, err, response, request)
    if err then
      return
    end
    Element.thread_frames[request.threadId] = response.stackFrames
    Element:render(session)
  end

  dap.listeners.after.event_stopped[listener_id] = function(session)
    session:request(
      "threads",
      {},
      function()
      end
    )
  end
end

M.name = "DAP Stacks"

function M.on_open(buf, render_receiver)
  vim.api.nvim_buf_set_option(buf, "filetype", "dapui_stacks")
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  pcall(vim.api.nvim_buf_set_name,buf, M.name)
  api.nvim_buf_set_keymap(
    buf,
    "n",
    Element.config.mappings.open,
    "<Cmd>call v:lua.stacks_open_frame()<CR>",
    {}
  )
  Element.render_receivers[buf] = render_receiver
  Element:render(require("dap").session())
end

function M.on_close(info)
  Element.render_receivers[info.buffer] = nil
end

return M
