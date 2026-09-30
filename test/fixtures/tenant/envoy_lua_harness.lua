-- envoy_lua_harness.lua — run a real Envoy Lua HTTP filter under LuaJIT.
--
-- Executes envoy_on_request from the filter source against a minimal stub of
-- Envoy's request handle, so tests assert the Lua that ships in
-- d2-infra/components/ingress/tenant-filter-policy.yaml, not a copy of it.
--
-- Usage: luajit envoy_lua_harness.lua [--body] <filter.lua> [name=value ...]
--   value is percent-decoded (%0D%0A for CRLF). A repeated name is a duplicate
--   header; get() joins duplicates with "," as Envoy documents.
-- Output: action=continue|respond, status=, resp.<h>=, req.<h>= (final request
--   headers), log.<level>= — values with control/non-ASCII bytes percent-encoded.
--   --body prints only the raw local-reply body.
--
-- The stub is strict: any handle/header method it does not model, or any call
-- after respond(), raises — a filter drifting onto unmodelled API fails loudly.

local args = { ... }
local body_only = false
if args[1] == "--body" then
  body_only = true
  table.remove(args, 1)
end
local src = assert(args[1], "usage: envoy_lua_harness.lua [--body] <filter.lua> [name=value ...]")

local function pct_decode(s)
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end
local function pct_encode(s)
  return (s:gsub("[%c%%\128-\255]", function(c) return string.format("%%%02X", c:byte()) end))
end

local req = {} -- ordered { name, value } pairs, names lowercased as Envoy stores them
for i = 2, #args do
  local name, value = args[i]:match("^([^=]+)=(.*)$")
  assert(name, "bad header spec: " .. args[i])
  req[#req + 1] = { name:lower(), pct_decode(value) }
end

local responded, reply_status, reply_headers, reply_body = false, nil, {}, nil
local logs = {}

local function guard()
  if responded then error("filter called the request handle after respond()", 2) end
end

local function strict(t, what)
  return setmetatable(t, { __index = function(_, k) error(what .. ":" .. tostring(k) .. " is not modelled by the harness", 2) end })
end

local header_map = strict({
  get = function(_, k)
    guard()
    local vals = {}
    for _, h in ipairs(req) do if h[1] == k:lower() then vals[#vals + 1] = h[2] end end
    if #vals == 0 then return nil end
    return table.concat(vals, ",")
  end,
  remove = function(_, k)
    guard()
    for i = #req, 1, -1 do if req[i][1] == k:lower() then table.remove(req, i) end end
  end,
  add = function(_, k, v)
    guard()
    req[#req + 1] = { k:lower(), v }
  end,
}, "headers")
header_map.replace = function(self, k, v)
  self:remove(k)
  self:add(k, v)
end

local handle = { headers = function() guard(); return header_map end }
handle.respond = function(_, h, body)
  guard()
  responded, reply_body = true, body or ""
  for k, v in pairs(h) do
    if k == ":status" then reply_status = v else reply_headers[k] = v end
  end
end
for _, level in ipairs({ "Trace", "Debug", "Info", "Warn", "Err", "Critical" }) do
  handle["log" .. level] = function(_, msg) logs[#logs + 1] = { level:lower(), msg } end
end
strict(handle, "handle")

local chunk = assert(loadfile(src))
local env = setmetatable({}, { __index = _G })
setfenv(chunk, env)
chunk()
assert(type(env.envoy_on_request) == "function", "filter defines no envoy_on_request")
env.envoy_on_request(handle)

if body_only then
  io.write(reply_body or "")
  return
end

local function sorted_keys(t)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = k end
  table.sort(ks)
  return ks
end
print("action=" .. (responded and "respond" or "continue"))
print("status=" .. (reply_status or ""))
for _, k in ipairs(sorted_keys(reply_headers)) do print("resp." .. k .. "=" .. pct_encode(reply_headers[k])) end
local final = {}
for _, h in ipairs(req) do final[h[1]] = final[h[1]] and (final[h[1]] .. "," .. h[2]) or h[2] end
for _, k in ipairs(sorted_keys(final)) do print("req." .. k .. "=" .. pct_encode(final[k])) end
for _, l in ipairs(logs) do print("log." .. l[1] .. "=" .. pct_encode(l[2])) end
