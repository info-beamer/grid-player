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
local matrix = require "matrix"
local font = resource.load_font "silkscreen.ttf"
local min, max = math.min, math.max

local function clamp(v, min, max)
    return math.max(min, math.min(max, v))
end

local function round(v)
    return math.floor(v+.5)
end

local function Layout(screen)
    local grid_x, grid_y = 1, 1
    local grid_w, grid_h = 1, 1

    local function set_grid_size(w, h)
        grid_w, grid_h = w, h
    end

    local function set_grid_pos(x, y)
        grid_x, grid_y = clamp(x, 1, grid_w), clamp(y, 1, grid_h)
    end

    local function fit(w, h)
        local screen_w, screen_h = screen.size()
        local total_w, total_h = screen_w * grid_w, screen_h * grid_h

        -- get screen coordinates for the selected screen
        local sx1, sy1 = screen_w * (grid_x-1), screen_h * (grid_y-1)
        local sx2, sy2 = screen_w * grid_x, screen_h * grid_y

        -- scale target into available screen space
        local x1, y1, x2, y2 = util.scale_into(total_w, total_h, w, h)
        local fitted_w, fitted_h = x2 - x1, y2 - y1

        -- find out global coordinates for the current screen
        local px1, py1, px2, py2 = max(sx1, x1), max(sy1, y1), min(sx2, x2), min(sy2, y2)

        -- calculate texture coordinates into the source.
        local tx1, ty1, tx2, ty2 = 1/fitted_w*(px1-x1)*w, 1/fitted_h*(py1-y1)*h, 1/fitted_w*(px2-x1)*w, 1/fitted_h*(py2-y1)*h
        tx1 = clamp(tx1, 0, w)
        ty1 = clamp(ty1, 0, h)

        tx2 = clamp(tx2, 0, w)
        ty2 = clamp(ty2, 0, h)

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

        fit = fit;
    }
end

local function Screen()
    local rotation = 0
    local is_portrait = false
    local gl_transform, raw_transform

    local w, h = NATIVE_WIDTH, NATIVE_HEIGHT

    local function set_rotation(new_rotation)
        rotation = new_rotation
        is_portrait = rotation == 90 or rotation == 270

        gl.setup(w, h)
        gl_transform = util.screen_transform(rotation)

        if rotation == 0 then
            raw_transform = matrix.identity()
        elseif rotation == 90 then
            raw_transform = matrix.trans(w, 0) *
                            matrix.rotate(rotation)
        elseif rotation == 180 then
            raw_transform = matrix.trans(w, h) *
                            matrix.rotate(rotation)
        elseif rotation == 270 then
            raw_transform = matrix.trans(0, h) *
                            matrix.rotate(rotation)
        else
            return error(string.format("cannot rotate by %d degree", rotation))
        end
    end

    local function draw_video(vid, x1, y1, x2, y2)
        local tx1, ty1 = raw_transform(x1, y1)
        local tx2, ty2 = raw_transform(x2, y2)
        local x1, y1, x2, y2 = round(math.min(tx1, tx2)),
                               round(math.min(ty1, ty2)),
                               round(math.max(tx1, tx2)),
                               round(math.max(ty1, ty2))
        if x1 >= 0 and x2 <= w and
           y1 >= 0 and y2 <= h then
            return vid:target(x1, y1, x2, y2):rotate(rotation)
        else
            print "offscreen"
        end
    end

    local function draw_image(img, x1, y1, x2, y2)
        return img:draw(x1, y1, x2, y2)
    end

    local function frame_setup()
        return gl_transform()
    end

    local function size()
        if is_portrait then
            return h, w
        else
            return w, h
        end
    end

    set_rotation(0)

    return {
        set_rotation = set_rotation;
        frame_setup = frame_setup;
        draw_image = draw_image;
        draw_video = draw_video;
        size = size;
    }
end

local screen = Screen()
local layout = Layout(screen)
local audio = false

if CONTENTS['settings.json'] then
    util.file_watch("settings.json", function(raw)
        local settings = json.decode(raw)
        layout.set_grid_size(settings.grid.width, settings.grid.height)
        screen.set_rotation(settings.rotation or 0)
        audio = settings.audio or false
    end)

    local x = tonumber(sys.get_env "GRID_X" or error "INFOBEAMER_ENV_GRID_X unset")
    local y = tonumber(sys.get_env "GRID_Y" or error "INFOBEAMER_ENV_GRID_Y unset")
    layout.set_grid_pos(x, y)
elseif CONTENTS['config.json'] then
    print "loading settings from config.json"
    util.file_watch("config.json", function(raw)
        local config = json.decode(raw)
        layout.set_grid_size(config.grid_w, config.grid_h)
        screen.set_rotation(config.rotation)
        audio = config.audio

        local serial = sys.get_env "SERIAL"
        for idx = 1, #config.devices do
            local device = config.devices[idx]
            if device.serial == serial then
                layout.set_grid_pos(device.x, device.y)
            end
        end
    end)
else
    error "no settings.json found. Please consult STANDALONE.md"
end

local Image = {
    slot_time = function(self)
        return self.duration
    end;
    prepare = function(self)
        self.obj = resource.load_image(self.file:copy())
    end;
    tick = function(self, now)
        local state, w, h = self.obj:state()
        local l = layout.fit(w, h)
        screen.draw_image(self.obj, l.offset.x1, l.offset.y1, l.offset.x2, l.offset.y2)
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
            self.obj = resource.load_video{
                file = self.file:copy();
                raw = true,
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
            self.obj:source(l.source.x1, l.source.y1, l.source.x2, l.source.y2)
            screen.draw_video(self.obj, l.screen.x1, l.screen.y1, l.screen.x2, l.screen.y2)
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
                print(now, "preparing", item.file)
                item:prepare()
                item.state = "prepared"
            elseif item.t_start <= now and item.state == "prepared" then
                print(now, "running", item.file)
                item.state = "running"
            elseif item.t_end <= now and item.state == "running" then
                print(now, "resetting", item.file)
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
            item.file = resource.open_file(item.filename)
            total_duration = total_duration + item:slot_time()
        end

        stop_all()

        items = new_items
        for idx = 1, #new_items do
            calc_start(idx, now)
        end

        node.gc()
    end

    return {
        set = set;
        tick = tick;
    }
end

local playlist = Playlist()

local function prepare_playlist(playlist)
    if #playlist >= 2 then
        return playlist
    elseif #playlist == 1 then
        -- only a single item? Copy it
        local item = playlist[1]
        playlist[#playlist+1] = {
            filename = item.filename,
            duration = item.duration,
        }
    else
        playlist[#playlist+1] = {
            filename = "blank.png",
            duration = 2,
        }
        playlist[#playlist+1] = {
            filename = "blank.png",
            duration = 2,
        }
    end
    return playlist
end

local function Stream()
    local vid
    local url

    local function stop()
        if vid then
            vid:dispose()
        end
        vid = nil
    end

    local function start()
        vid = resource.load_video{
            file = url,
            raw = true,
            audio = true,
        }
    end

    local function set(stream_url)
        if stream_url == "" then
            url = nil
            stop()
            return
        end
        if stream_url == url then
            return
        end
        stop()
        url = stream_url
        start()
    end

    local function tick()
        if not vid then
            return
        end
        local state, w, h = vid:state()
        if state == "loaded" then
            local l = layout.fit(w, h)
            vid:source(l.source.x1, l.source.y1, l.source.x2, l.source.y2)
            screen.draw_video(vid, l.screen.x1, l.screen.y1, l.screen.x2, l.screen.y2)
        elseif state == "finished" or state == "error" then
            stop()
            start()
        end
    end

    local function has_stream()
        return not not url
    end

    return {
        set = set;
        tick = tick;
        has_stream = has_stream;
    }
end

local stream = Stream()

if CONTENTS['playlist.txt'] then
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
        playlist.set(prepare_playlist(items))
    end)
elseif CONTENTS['config.json'] then
    util.json_watch("config.json", function(config)
        local items = {}
        for idx = 1, #config.playlist do
            local item = config.playlist[idx]
            items[#items+1] = {
                filename = item.file.asset_name,
                duration = item.duration,
            }
        end
        playlist.set(prepare_playlist(items))
        stream.set(config.stream)
    end)
else
    error "no playlist.txt found. Please consult STANDALONE.md"
end

function node.render()
    screen.frame_setup()
    if stream.has_stream() then
        stream.tick()
    else
        playlist.tick(os.time())
    end
end
