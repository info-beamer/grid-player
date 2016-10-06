-- License: BSD 2 clause (see LICENSE.txt)

gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)

util.noglobals()

-- Start preloading images this many second before
-- they are displayed.
local PREPARE_TIME = 1 -- seconds

-- must be enough time to load a video and have it
-- ready in the paused state. Normally 500ms should
-- be enough.
local VIDEO_PRELOAD_TIME = .5 -- seconds

-------------------------------------------------------------

local json = require "json"
local font = resource.load_font "silkscreen.ttf"
local raw = sys.get_ext "raw_video"
local min, max = math.min, math.max

if not CONTENTS['settings.json'] then
    error "settings.json missing. Please consult README.txt"
end

if not CONTENTS['playlist.txt'] then
    error "playlist.txt missing. Please consult README.txt"
end

local function Layout()
    local grid_x, grid_y = 1, 1
    local grid_w, grid_h = 1, 1
    local screen_w, screen_h = 1920, 1080

    local function set_grid_size(w, h)
        grid_w, grid_h = w, h
    end

    local function set_grid_pos(x, y)
        if x < 1 or x > grid_w or y < 1 or y > grid_h then
            error(("invalid grid position %d,%d. It's outside the grid defined in settings.json"):format(x, y))
        end
        grid_x, grid_y = x, y
    end

    local function set_resolution(w, h)
        screen_w, screen_h = w, h
    end

    local function fit(w, h)
        local total_w, total_h = screen_w * grid_w, screen_h * grid_h

        -- get screen coordinates for the selected screen
        local sx1, sy1 = screen_w * (grid_x-1), screen_h * (grid_y-1)
        local sx2, sy2 = screen_w * grid_x, screen_h * grid_y

        -- scale target into available screen space
        local x1, y1, x2, y2 = util.scale_into(total_w, total_h, w, h)
        local fitted_w, fitted_h = x2 - x1, y2 - y1

        -- find out global coordinates for the current screen
        local px1, py1, px2, py2 = max(sx1, x1), max(sy1, y1), min(sx2, x2), min(sy2, y2)
        local partial_w, partial_h = px2 - px1, py2 - py1

        -- calculate texture coordinates into the source.
        local tx1, ty1, tx2, ty2 = 1/fitted_w*(px1-x1)*w, 1/fitted_h*(py1-y1)*h, 1/fitted_w*(px2-x1)*w, 1/fitted_h*(py2-y1)*h

        return {
            -- for drawing raw videos
            screen = {x1=px1-sx1, y1=py1-sy1, x2=px2-sx1, y2=py2-sy1};
            source = {x1=tx1, y1=ty1, x2=tx2, y2=ty2};

            -- for drawing textures
            offset = {x1=x1-sx1, y1=y1-sy1, x2=x2-sx1, y2=y2-sy1};
        }
    end

    return {
        set_grid_size = set_grid_size;
        set_grid_pos = set_grid_pos;
        set_resolution = set_resolution;

        fit = fit;
    }
end

local layout = Layout()

local audio = false

util.file_watch("settings.json", function(raw)
    local settings = json.decode(raw)
    layout.set_grid_size(settings.grid.width, settings.grid.height)
    layout.set_resolution(settings.screen.width, settings.screen.height)
    audio = settings.audio
end)

local x = tonumber(sys.get_env "GRID_X" or error "INFOBEAMER_ENV_GRID_X unset")
local y = tonumber(sys.get_env "GRID_Y" or error "INFOBEAMER_ENV_GRID_Y unset")
layout.set_grid_pos(x, y)

local Image = {
    slot_time = function(self)
        return self.duration
    end;
    prepare = function(self)
        self.obj = resource.load_image(self.filename)
    end;
    tick = function(self, now)
        local state, w, h = self.obj:state()
        local l = layout.fit(w, h)
        self.obj:draw(l.offset.x1, l.offset.y1, l.offset.x2, l.offset.y2, 0.9)
    end;
    stop = function(self)
        if self.obj then
            self.obj:dispose()
            self.obj = nil
        end
    end;
}

local Video = {
    slot_time = function(self)
        return VIDEO_PRELOAD_TIME + self.duration
    end;
    prepare = function(self)
    end;
    tick = function(self, now)
        if not self.obj then
            self.obj = raw.load_video{
                file = self.filename;
                paused = true;
                audio = audio;
            }
        end

        if now < self.t_start + VIDEO_PRELOAD_TIME then
            return
        end

        self.obj:start()
        local state, w, h = self.obj:state()

        if state ~= "loaded" and state ~= "finished" then
            print[[

.--------------------------------------------.
  WARNING:
  lost video frame. video is most likely out
  of sync. increase VIDEO_PRELOAD_TIME (on all
  devices)
'--------------------------------------------'
]]
        else
            local l = layout.fit(w, h)
            self.obj:target(l.screen.x1, l.screen.y1, l.screen.x2, l.screen.y2)
            self.obj:source(l.source.x1, l.source.y1, l.source.x2, l.source.y2)
        end
    end;
    stop = function(self)
        if self.obj then
            self.obj:dispose()
            self.obj = nil
        end
    end;
}

local function Playlist()
    local items = {}
    local total_duration = 0

    local function calc_start(idx, now)
        local item = items[idx]
        local epoch_offset = now % total_duration
        local epoch_start = now - epoch_offset

        item.t_start = epoch_start + item.epoch_offset
        if item.t_start - PREPARE_TIME < now then
            item.t_start = item.t_start + total_duration
        end
        item.t_prepare = item.t_start - PREPARE_TIME
        item.t_end = item.t_start + item:slot_time()
        -- pp(item)
    end

    local function tick(now)
        local num_running = 0
        local next_running = 99999999999999

        for idx = 1, #items do
            local item = items[idx]
            if item.t_prepare <= now and item.state == "waiting" then
                print(now, "preparing " .. item.filename)
                item:prepare()
                item.state = "prepared"
            elseif item.t_start <= now and item.state == "prepared" then
                print(now, "running " .. item.filename)
                item.state = "running"
            elseif item.t_end <= now and item.state == "running" then
                print(now, "resetting " .. item.filename)
                item:stop()
                calc_start(idx, now)
                item.state = "waiting"
            end

            next_running = min(next_running, item.t_start)

            if item.state == "running" then
                item:tick(now)
                num_running = num_running + 1
            end
        end

        if num_running == 0 then
            local wait = next_running - now
            font:write(10, HEIGHT-30, ("Waiting for sync %.1f"):format(wait), 24, 1,1,1,.5)
        end
    end

    local function stop_all()
        for idx = 1, #items do
            local item = items[idx]
            item:stop()
        end
    end

    local function set(new_items)
        local now = os.time()

        total_duration = 0
        for idx = 1, #new_items do
            local item = new_items[idx]
            local filename = item.filename:lower()
            if filename:find "[.]jpg$" or filename:find "[.]png$" then
                setmetatable(item, {__index = Image})
            elseif filename:find "[.]mp4$" then
                setmetatable(item, {__index = Video})
            else
                return error("unsupported filename " .. filename)
            end
            item.epoch_offset = total_duration
            item.state = "waiting"
            total_duration = total_duration + item:slot_time()
        end

        stop_all()

        items = new_items
        for idx = 1, #new_items do
            calc_start(idx, now)
        end
    end

    return {
        set = set;
        tick = tick;
    }
end

local playlist = Playlist()

util.file_watch("playlist.txt", function(raw)
    local items = {}
    for filename, duration in raw:gmatch("([^,]+),([^\n]+)\n") do
        local duration = tonumber(duration)
        local min_duration = 2 * PREPARE_TIME
        if duration < min_duration then
            error(string.format(
                "duration for item %s is too short. must be at least %d",
                filename, min_duration
            ))
        end
        items[#items+1] = {
            filename = filename;
            duration = tonumber(duration);
        }
    end
    if #items == 1 then
        error "please add at least 2 items to your playlist"
    end
    playlist.set(items)
end)

function node.render()
    playlist.tick(os.time())
end
