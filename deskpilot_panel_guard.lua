-- Only the main frame of this local panel may invoke native actions.
local M = {}
local actions = { ready=true, close=true, pause=true, resume=true, settings=true,
  missionControl=true, switch=true, move=true, rename=true, selectMonitor=true, organize=true, toggleFollow=true,
  enablePreviews=true, disablePreviews=true, selectSpace=true, selectWindow=true, refreshPreview=true }
local needsID = { switch=true, move=true, rename=true, selectMonitor=true,
  selectSpace=true, selectWindow=true, refreshPreview=true }
function M.localURL(url)
  if type(url) == 'table' then url = url.url end
  return url == 'about:blank'
end
function M.message(message, view)
  if type(message) ~= 'table' or not view or message.webView ~= view or message.name ~= 'deskpilot' then return nil end
  local frame = message.frameInfo
  if type(frame) ~= 'table' or frame.mainFrame ~= true or type(frame.request) ~= 'table'
      or not M.localURL(frame.request.URL) then return nil end
  local body = message.body
  if type(body) ~= 'table' or type(body.action) ~= 'string' or not actions[body.action] then return nil end
  if needsID[body.action] and (type(body.id) ~= 'string' or #body.id > 128
      or not body.id:match('^[%w_%-]+$')) then return nil end
  return { action=body.action, id=body.id }
end
return M
