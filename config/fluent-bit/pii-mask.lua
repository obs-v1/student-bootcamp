-- Fluent Bit Lua filter — masks PII in log fields before shipping to Loki.
-- Defensive layer: services should already mask, but we double-mask just in case.

local function mask_account(s)
  if s == nil or #s < 5 then return s end
  return string.rep("X", #s - 4) .. string.sub(s, -4)
end

local function mask_aadhaar(s)
  if s == nil then return s end
  local digits = string.gsub(s, "[^0-9]", "")
  if #digits ~= 12 then return s end
  return "XXXX-XXXX-" .. string.sub(digits, -4)
end

local function mask_pan(s)
  if s == nil or #s ~= 10 then return s end
  return "XXXXX" .. string.sub(s, 6)
end

local function mask_mobile(s)
  if s == nil then return s end
  local digits = string.gsub(s, "[^0-9]", "")
  if #digits ~= 10 then return s end
  return string.sub(digits, 1, 2) .. "XXXXX" .. string.sub(digits, 8)
end

local function mask_email(s)
  if s == nil then return s end
  local local_part, domain = string.match(s, "^([^@]+)(@.*)$")
  if local_part == nil then return s end
  if #local_part <= 2 then return local_part .. "****" .. domain end
  return string.sub(local_part, 1, 2) .. "****" .. domain
end

local function mask_vpa(s)
  if s == nil then return s end
  local handle, suffix = string.match(s, "^([^@]+)(@.*)$")
  if handle == nil then return s end
  return "XXXX" .. suffix
end

local function mask_ip(s)
  if s == nil then return s end
  return (string.gsub(s, "^(%d+%.%d+%.%d+)%.%d+$", "%1.0"))
end

local function mask_inline(text)
  if type(text) ~= "string" then return text end
  -- Aadhaar 12-digit sequences
  text = string.gsub(text, "(%d%d%d%d)(%d%d%d%d)(%d%d%d%d)", "XXXX-XXXX-%3")
  -- PAN: 5 letters + 4 digits + 1 letter
  text = string.gsub(text, "([A-Z][A-Z][A-Z][A-Z][A-Z])(%d%d%d%d)([A-Z])", "XXXXX%2%3")
  -- Indian 10-digit mobile (98XXX, 99XXX, ...)
  text = string.gsub(text, "([6-9]%d)(%d%d%d%d%d)(%d%d%d)", "%1XXXXX%3")
  return text
end

function mask_pii(tag, ts, record)
  record["account_id"]     = mask_account(record["account_id"])
  record["account_number"] = mask_account(record["account_number"])
  record["aadhaar"]        = mask_aadhaar(record["aadhaar"])
  record["pan"]            = mask_pan(record["pan"])
  record["mobile"]         = mask_mobile(record["mobile"])
  record["email"]          = mask_email(record["email"])
  record["upi_vpa"]        = mask_vpa(record["upi_vpa"])
  record["ip_address"]     = mask_ip(record["ip_address"])
  record["message"]        = mask_inline(record["message"])
  record["pii_masked"]     = true
  return 1, ts, record
end
