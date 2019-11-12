-- License: BSD 2 clause (see LICENSE.txt)
gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)

util.no_globals()

-- Start preloading images this many second before
-- they are displayed.
local PREPARE_TIME = 1 -- seconds

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
    local scaling = "preserve_aspect"

    local function set_scaling(new_scaling)
        scaling = new_scaling
    end

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

        local x1, y1, x2, y2
        if scaling == "preserve_aspect" then
            -- scale target into available screen space
            x1, y1, x2, y2 = util.scale_into(total_w, total_h, w, h)
        else
            x1, y1, x2, y2 = 0, 0, total_w, total_h
        end

        return {
            x1=x1-sx1, y1=y1-sy1, x2=x2-sx1, y2=y2-sy1
        }
    end

    return {
        set_grid_size = set_grid_size;
        set_grid_pos = set_grid_pos;
        set_scaling = set_scaling;

        fit = fit;
    }
end

local function Screen()
    local rotation = 0
    local is_portrait = false
    local gl_transform, video_transform

    local w, h = NATIVE_WIDTH, NATIVE_HEIGHT

    local function set_rotation(new_rotation)
        rotation = new_rotation
        is_portrait = rotation == 90 or rotation == 270

        gl.setup(w, h)
        gl_transform = util.screen_transform(rotation)

        if rotation == 0 then
            video_transform = matrix.identity()
        elseif rotation == 90 then
            video_transform = matrix.trans(w, 0) *
                              matrix.rotate(rotation)
        elseif rotation == 180 then
            video_transform = matrix.trans(w, h) *
                              matrix.rotate(rotation)
        elseif rotation == 270 then
            video_transform = matrix.trans(0, h) *
                              matrix.rotate(rotation)
        else
            return error(string.format("cannot rotate by %d degree", rotation))
        end
    end

    local function draw_video(vid, x1, y1, x2, y2)
        local tx1, ty1 = video_transform(x1, y1)
        local tx2, ty2 = video_transform(x2, y2)
        local x1, y1, x2, y2 = round(math.min(tx1, tx2)),
                               round(math.min(ty1, ty2)),
                               round(math.max(tx1, tx2)),
                               round(math.max(ty1, ty2))
        return vid:place(x1, y1, x2, y2, rotation)
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
        layout.set_grid_pos(1, 1)
        layout.set_scaling(config.scaling)
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
        screen.draw_image(self.obj, l.x1, l.y1, l.x2, l.y2)
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
        return self.duration
    end;
    prepare = function(self)
        self.obj = resource.load_video{
            file = self.file:copy();
            raw = true,
            paused = true;
            audio = audio;
        }
    end;
    tick = function(self, now)
        self.obj:start()
        local state, w, h = self.obj:state()

        if state ~= "loaded" and state ~= "finished" then
            print[[

.------------------------------------------------------------.
  WARNING: lost video frame. video is most likely out of sync.
'------------------------------------------------------------'
]]
        else
            local l = layout.fit(w, h)
            screen.draw_video(self.obj, l.x1, l.y1, l.x2, l.y2)
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
            if item.filetype == "image" then
                setmetatable(item, {__index = Image})
            elseif item.filetype == "video" then
                setmetatable(item, {__index = Video})
            else
                error "unsupported filetype"
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
            filetype = item.filetype,
            duration = item.duration,
        }
    else
        playlist[#playlist+1] = {
            filename = "blank.png",
            filetype = "image",
            duration = 2,
        }
        playlist[#playlist+1] = {
            filename = "blank.png",
            filetype = "image",
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
            audio = audio,
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
            screen.draw_video(vid, l.x1, l.y1, l.x2, l.y2)
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
    local function type_from_filename(filename)
        if filename:find "[.]jpeg$" or filename:find "[.]jpg$" or filename:find "[.]png$" then
            return "image"
        elseif filename:find "[.]mp4$" then
            return "video"
        else
            return error("unsupported filename " .. filename)
        end
    end
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
                filetype = type_from_filename(filename);
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
                filetype = item.file.type,
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
