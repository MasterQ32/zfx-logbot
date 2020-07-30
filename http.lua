local http_headers = require "http.headers"
local http_util = require "http.util"

local get_chans_stmt = DB:prepare [[
	SELECT channel
		FROM chatlog
		GROUP BY channel
		ORDER BY channel
]]

local get_dates_stmt = DB:prepare [[
	SELECT date(timestamp)
		FROM chatlog
		WHERE channel = :channel
		GROUP BY date(timestamp)
		ORDER BY date(timestamp)
		DESC LIMIT 60
]]

local get_log_stmt = DB:prepare [[
	SELECT nick, message, timestamp
		FROM chatlog
		WHERE channel = :channel AND date(timestamp) = :date
		ORDER BY timestamp
]]

local function slurp(file)
	local f = assert(io.open(file, "r"))
	local c = f:read("*all")
	f:close()
	return c
end

local function patch(text, keys)
	return text:gsub("%$%((%w+)%)", function(i)
		return keys[i] or "$("..i..")"
	end), nil
end

function HTTP_reply(myserver, stream) -- luacheck: ignore 212
	-- Read in headers
	local req_headers = assert(stream:get_headers())
	local req_method = req_headers:get ":method"
	local req_url = http_util.decodeURIComponent(req_headers:get(":path"))

	-- Build response headers
	local res_headers = http_headers.new()
	res_headers:append(":status", "200")
	if req_method ~= "HEAD" then
		if req_url == "/style.css" then
			res_headers:append("content-type", "text/css")
			-- Send headers to client; end the stream immediately if this was a HEAD request
			assert(stream:write_headers(res_headers, false))
			assert(stream:write_chunk(slurp("./data/style.css"), true))
			return
		end
		if req_url == "/favicon.ico" then
			res_headers:append("content-type", "image/x-icon")
			-- Send headers to client; end the stream immediately if this was a HEAD request
			assert(stream:write_headers(res_headers, false))
			assert(stream:write_chunk(slurp("./data/favicon.ico"), true))
			return
		end

		local webprint = function(...)

			local t = table.pack(...)
			local r = ""
			for i=1,#t do
				r = r .. tostring(t[i])
			end
			assert(stream:write_chunk(r, false))
		end

		res_headers:append("content-type", "text/html")
		-- Send headers to client; end the stream immediately if this was a HEAD request
		assert(stream:write_headers(res_headers, req_method == "HEAD"))

		local vars = {
			title = "some page"
		}
		local printer = function()
			webprint "you forget to fill your page with content!\n"
		end
		local chan, date = req_url:match("^/(#%w+)/(%d+-%d+-%d+)/?$")
		if chan and date then
			-- DISPLAY THE LOGS HERE

			vars.title = "IRC Logs for " .. chan
			printer = function()
				webprint('<h2>', date, '</h2>\n')
				webprint "<p>\n"

				for row in get_log_stmt:bind{ channel=chan, date=date }:rows(query) do
					local ts = row["timestamp"]
					local message = row["message"]
					local nick = row["nick"]
					local year, month, day, hour, minute, second = ts:match("^(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)$")

					local id = ("%02d:%02d:%02d"):format(hour, minute, second)

					webprint(('<span class="time" id="%s"><a href="#%s">%02d:%02d:%02d</a></span>&nbsp;'):format(
							id,
							id,
							hour, minute, second
					))

					if nick == "*part" then
						webprint(('<span class="status">%s left the channel</span>'):format(
							message
						))
					elseif nick == "*join" then
						webprint(('<span class="status">%s joined the channel</span>'):format(
							message
						))
					elseif nick == "*topic" then
						webprint(('<span class="status">The topic was changed to: %s</span>'):format(
							message
						))
					else

						local action = message:match("^\001ACTION%s+(.*)\001$")
						if action then
							webprint(('<span class="action">%s %s</span>'):format(
								nick,
								action
							))
						else
							local function clamp(m)
								if m < 0.0 then
									return 0.0
								elseif m > 1.0 then
									return 1.0
								else
									return m
								end
							end

							local r = (nick:sub(1,1):byte() or 0xFF) / 255.0
							local g = (nick:sub(2,2):byte() or 0xFF) / 255.0
							local b = (nick:sub(3,3):byte() or 0xFF) / 255.0

							local s = 0.5 / (r + g + b);
							r  = clamp(r / s)
							g  = clamp(g / s)
							b  = clamp(1.0 - r * g)

							webprint(('<span class="nick" style="color: #%02X%02X%02X">%s</span>: '):format(
									math.floor(255.0 * r),
									math.floor(255.0 * g),
									math.floor(255.0 * b),
									nick
								))
							webprint(('<span class="text">%s</span>'):format(
									message
								))
						end
					end

					webprint "<br />\n"
				end
				webprint "</p>\n"
			end
		else
			chan = req_url:match("^/(#%w+)/?$")
			if chan then
				-- DISPLAY THE DAYS HERE
				vars.title = "IRC Logs for " .. chan
				printer = function()
					webprint "<ul>\n"
					for row in get_dates_stmt:bind{ channel = chan }:rows(query) do
						local date = assert(row["date(timestamp)"])

						local year, month, day = date:match("^(%d+)-(%d+)-(%d+)$")

						webprint(
							('<li><a href="/%s/%s/#end-of-text">%02d.%02d.%02d</a></li>'):format(
								http_util.encodeURIComponent(chan),
								http_util.encodeURIComponent(date),
								day, month, year
							) .. "\n")
					end
					webprint "</ul>\n"
				end
			else
				-- DISPLAY THE CHANNELS HERE
				vars.title = "IRC Logs on masterq32.de"
				printer = function()
					webprint "<ul>\n"
					for row in get_chans_stmt:rows(query) do
						webprint(
							('<li><a href="/%s/">%s</a></li>'):format(
								http_util.encodeURIComponent(row.channel),
								row.channel
							) .. "\n")
					end
					webprint "</ul>\n"
				end
			end
		end

		local function nav()
			local prefix = ""
			print("url=", req_url)
			webprint '<nav>'
			webprint '<span class="nav">Navigation: '
			webprint '<span>/</span>'
			webprint '<a href="/">overview</a>'
			webprint '<span>/</span>'

			local enc = http_util.encodeURIComponent

			if chan then
				webprint(
					('<a href="%s/">%s</a>'):format(
						"/" .. enc(chan),
						chan
				))
				webprint '<span>/</span>'
			end

			if date then
				webprint(
					('<a href="%s/">%s</a>'):format(
						"/" .. enc(chan) .. "/" .. enc(date) .. "/#end-of-text" ,
						date
				))
				webprint '<span>/</span>'
			end
			webprint '</nav>'
		end

		webprint(patch(slurp("./data/html-prefix.htm"), vars))
		webprint(('<!-- %s -->'):format(req_url))
		nav()
		webprint '<hr />'
		printer()
		webprint '<hr />'
		nav()
		webprint(patch(slurp("./data/html-postfix.htm"), vars))
		assert(stream:write_chunk("\n", true))
	end
end
