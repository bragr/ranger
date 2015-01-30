-- includes
local http = require("resty.http") -- https://github.com/liseen/lua-resty-http
local cjson = require("cjson")
local bslib = require("bitset") -- https://github.com/bsm/bitset.lua

-- basic configuration
local block_size = 10 * 1024 * 1024
local chunk_size =  8192
if ngx.var.block_size and ngx.var.block_size ~= "" then
	block_size = tonumber(ngx.var.block_size) -- Block size 256k
end
local backend = "http://127.0.0.1:8080/" -- backend
local headbackend = "http://" .. ngx.var.origin 
local headhost = ngx.var.origin
local fcttl = 24 * 60 * 60 -- Time to cache HEAD requests
if ngx.var.fcttl and ngx.var.fcttl ~= "" then
	fcttl = tonumber(ngx.var.fcttl)
end
local ignore_querystring = false
if ngx.var.ignore_querystring and ngx.var.ignore_querystring ~= "" and ngx.var.ignore_querystring ~= "0" then
	ignore_querystring = true
end

local prefix_uri = ''
if ngx.var.prefix_uri then
	prefix_uri = ngx.var.prefix_uri
end

local bypass_headers = { 
	["Expires"] = "Expires",
	["Content-Type"] = "Content-Type",
	["Last-Modified"] = "Last-Modified",
	["Expires"] = "Expires",
	["Cache-Control"] = "Cache-Control",
	["Server"] = "Server",
	["Content-Length"] = "Content-Length",
	["p3p"] = "P3P",
	["Accept-Ranges"] = "Accept-Ranges"
}

local httpchead = http.new()
httpchead:connect(headhost, 80)
local httpc = http.new()
httpc:set_keepalive(3000, 10)
httpc:connect("127.0.0.1",8080)

local zone_id = ngx.var.zone_id
local cache_dict = ngx.shared["cache_dict" .. "_" .. zone_id]
local file_dict = ngx.shared["file_dict" .. "_" .. zone_id] 
local chunk_dict = ngx.shared["chunk_dict" .. "_" .. zone_id]

local sub = string.sub
local tonumber = tonumber
local ceil = math.ceil
local floor = math.floor
local error = error
local null = ngx.null
local match = ngx.re.match

local start = 0
local stop = -1

ngx.status = 206 -- Default HTTP status

-- register on_abort callback 
local ok, err = ngx.on_abort(function () 
	ngx.exit(499)
end)
if not ok then
	ngx.log(ngx.ERR, "Can't register on_abort function.")
	ngx.exit(500)
end

local uri = ngx.var.request_uri
local headuri = ngx.var.request_uri
if ignore_querystring then
	uri = ngx.var.uri
	headuri = ngx.var.uri
end
local host = ngx.var.host
local is_purge = false
local matches, err = match(headuri, "^/purge(/.*)")
if matches then
	headuri = prefix_uri .. matches[1]
	uri = prefix_uri .. "/purge" .. matches[1]
	is_purge = true
else
	headuri = prefix_uri ..headuri
	uri = prefix_uri .. uri
end

-- try reading values from dict, if not issue a HEAD request and save the value
local updating, flags = file_dict:get(headuri .. "-update")
repeat 
	updating, flags = file_dict:get(headuri .. "-update")
	ngx.sleep(0.1)
until not updating 

local origin_headers = {}
local origin_info = file_dict:get(headuri .. "-info")
if not origin_info then
        local url = headbackend .. headuri
	file_dict:set(headuri .. "-update", true, 5)
--	ngx.log(ngx.EMERG, "Going to make HEAD request ", url, ", ", headhost)
--	local ok, code, headers, status, body = httpc:request { 
--		url = url,
--              headers = {Host = headhost},
--		method = 'HEAD' 
--	}
        local head_req_params = {
		path = headuri,
		method = 'HEAD',
		headers = {Host = headhost}
        }
	local origin_request_headers = ngx.req.get_headers()
	for k, v in pairs(origin_request_headers) do
		if (k ~= 'host' and k ~= 'user-agent' and k ~= 'accept' and k ~= 'range' and k~= 'accept-encoding') then
			head_req_params['headers'][k] = v
		end
	end
	local res, err = httpchead:request(head_req_params)
	if not ok then
		ngx.log(ngx.EMERG, "Error performing HEAD request ", status, " ", code, " on url ", url)
		return ngx.exit(500)
	end
	local code = res.status
	local headers = res.headers
        if code > 299 then
                return ngx.exit(code)
        end
	for key, value in pairs(bypass_headers) do
		origin_headers[value] = headers[key]
	end
	origin_info = cjson.encode(origin_headers)
	file_dict:set(headuri .. "-info", origin_info, fcttl)
	file_dict:delete(headuri .. "-update")
end

origin_headers = cjson.decode(origin_info)

-- parse range header
local range_header = ngx.req.get_headers()["Range"]
if range_header then
	local matches, err = match(range_header, "^bytes=(\\d+)?-(\\d+)?", "joi")
	if matches then
		if matches[1] == nil and matches[2] then
			stop = (origin_headers["Content-Length"] - 1)
			start = (stop - matches[2]) + 1
		else
			start = matches[1] or 0
			stop = matches[2] or (origin_headers["Content-Length"] - 1)
		end
	else
		start = 0
		stop = (origin_headers["Content-Length"] - 1)
	end
else
	ngx.status = 200
	start = 0
	stop = (origin_headers["Content-Length"] - 1)
end

for header, value in pairs(origin_headers) do
	ngx.header[header] = value
end

local cl = origin_headers["Content-Length"]
ngx.header["Content-Length"] = (stop - (start - 1))
if range_header then
        ngx.header["Content-Range"] = "bytes " .. start .. "-" .. stop .. "/" .. cl
end

block_stop = (ceil(stop / block_size) * block_size)
block_start = (floor(start / block_size) * block_size)


-- hits / miss info
local chunk_info, flags = chunk_dict:get(headuri)
local chunk_map = bslib:new()
if chunk_info then
	chunk_map.nums = cjson.decode(chunk_info)
end

local bytes_miss, bytes_hit = 0, 0

for block_range_start = block_start, stop, block_size do
	local block_range_stop = (block_range_start + block_size) - 1
	local block_id = (floor(block_range_start / block_size))
	local content_start = 0
	local content_stop = block_size

	local block_status = chunk_map:get(block_id)

	if block_range_start == block_start then
		content_start = (start - block_range_start)
	end

	if (block_range_stop + 1) == block_stop then
		content_stop = (stop - block_range_start) + 1
	end

	if block_status then
		bytes_hit = bytes_hit + (content_stop - content_start)
	else
		bytes_miss = bytes_miss + (content_stop - content_start)
	end
end

if bytes_miss > 0 then
	ngx.var.ranger_cache_status = "MISS"
	ngx.header["X-Cache"] = "MISS"
else
	ngx.var.ranger_cache_status = "HIT"
	ngx.header["X-Cache"] = "HIT"
end
ngx.header["X-Bytes-Hit"] = bytes_hit
ngx.header["X-Bytes-Miss"] = bytes_miss
	
ngx.send_headers()

-- fetch the content from the backend
for block_range_start = block_start, stop, block_size do
	local block_range_stop = (block_range_start + block_size) - 1
	local block_id = (floor(block_range_start / block_size))
	local content_start = 0
	local content_stop = -1

	local req_params = {
		url = backend .. uri,
		method = 'GET',
		headers = {
			Range = "bytes=" .. block_range_start .. "-" .. block_range_stop,
			Host = host
		}
	}

	req_params["body_callback"] =	function(data, chunked_header, ...)
						if chunked_header then return end
							ngx.print(data)
							ngx.flush(true)
					end

	if block_range_start == block_start then
		req_params["body_callback"] = nil
		content_start = (start - block_range_start)
	end

	if (block_range_stop + 1) == block_stop then
		req_params["body_callback"] = nil
		content_stop = (stop - block_range_start) + 1
	else
		content_stop = block_size
	end

--	set body request http version to 1.0
        local res, err = httpc:request{
		version = 1.0,
                path = uri,
                headers = {
                        Range = "bytes=" .. block_range_start .. "-" .. block_range_stop,
                        Host = host
                }
        }

--	reconnect if connection closed
	if err == 'closed' then
		httpc:connect("127.0.0.1",8080)
--      set body request http version to 1.0
		res, err = httpc:request{
			version = 1.0,
                	path = uri,
                	headers = {
                        	Range = "bytes=" .. block_range_start .. "-" .. block_range_stop,
                	        Host = host
         	       }
        	}
	end

        local reader = res.body_reader

	local chunk_content_read = 0
        repeat
                local chunk, err = reader(chunk_size)
                if err then
--	http 1.0 will close the connection when reading the last chunck, so we still need to print the last chunk instead of exiting
                        if err ~= 'closed' then
				ngx.log(ngx.ERR, err)
                        	break
			end
                end

                if chunk then
			chunk_content_read = chunk_content_read + string.len(chunk)
			local chunk_content_start = 1
			local chunk_content_stop = -1
			if content_start > 0 and chunk_content_read > content_start and chunk_content_read <= content_start + chunk_size then
				chunk_content_start = content_start + 1 - (chunk_content_read - string.len(chunk))
			end
			if chunk_content_read >= content_stop then
				chunk_content_stop = content_stop - (chunk_content_read - string.len(chunk))
			end
			if chunk_content_read <= content_start or (chunk_content_read >= content_stop + chunk_size and content_stop ~= -1) then
--				do nothing
			elseif chunk_content_start == 1 and chunk_content_stop == -1 then
				ngx.print(chunk)
				ngx.flush(true)
			else 
				ngx.print(sub(chunk, chunk_content_start, chunk_content_stop))
				ngx.flush(true)
			end
             	end
      	until not chunk or chunk_content_read >= content_stop

        local code = res.status
	local headers = res.headers
--	local body = res.body

--	local ok, code, headers, status, body  = httpc:request(req_params)
--	if body then
--		ngx.print(sub(body, (content_start + 1), content_stop)) -- lua count from 1
--	end
        if headers["X-Cache"] then
		if ngx.re.match(headers["X-Cache"],"HIT") then
			chunk_map:set(block_id)
			cache_dict:incr("cache_hit", 1)
		else
			chunk_map:clear(block_id)
			cache_dict:incr("cache_miss", 1)
		end
	end
        if is_purge then
                chunk_map:clear(block_id)
        end
end
httpc:close()
httpchead:close()
chunk_dict:set(headuri,cjson.encode(chunk_map.nums))
ngx.eof()
return ngx.exit(ngx.status)
