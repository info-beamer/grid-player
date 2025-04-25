-- License: BSD 2 clause (see LICENSE.txt)
gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)

util.no_globals()

local need_hevc_workaround = not sys.provides "kms"

-- Target latency between incoming stream package pts and pts of video
-- frame on the display. For low latency streams like rtp multicast this
-- will eventually sync up all displays.
--
-- Example ffmpeg cmd:
--
-- ffmpeg -s 1280x720 -f x11grab -i :0.0+0,0 -vcodec libx264 \
--    -preset ultrafast -f mpegts -pix_fmt yuv420p udp://236.0.0.1:2000
local TARGET_LATENCY = 0.3

-- Start preloading images/videos this many second before
-- they are displayed.
local PREPARE_TIME = 1.5 -- seconds

-- There is only one HEVC decoder slot. So videos
-- cannot be preloaded. Instead we reserve the
-- following number of seconds at each play slot
-- for loading the video.
local HEVC_LOAD_TIME = 0.5 -- seconds

-------------------------------------------------------------

local json = require "json"
local matrix = require "matrix"
local min, max = math.min, math.max

local font = resource.load_font "silkscreen.ttf"
local overlay
local loaded_overlay

local function clamp(v, min, max)
    return math.max(min, math.min(max, v))
end

local function round(v)
    return math.floor(v+.5)
end

local function printf(fmt, ...)
    return print(string.format(fmt, ...))
end

local function expand_schedule(config, schedule)
    if schedule == 'always' or schedule == 'never' then
        return schedule
    end
    return config.__schedules.expanded[schedule+1]
end

local function is_schedule_active_at(schedule, probe_time)
    if schedule == "always" then
        return true
    elseif schedule == "never" then
        return false
    end
    local probe_time = os.time()
    if probe_time < 10000000 then
        return false -- no valid system time, don't schedule
    end
    for _, range in ipairs(schedule) do
        local starts, duration = unpack(range)
        if starts > probe_time then
            break
        elseif probe_time < starts + duration then
            return true
        end
    end
    return false
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
                if device.overlay.asset_id == "empty" then
                    overlay = nil
                else
                    local asset_name = device.overlay.asset_name
                    if not overlay or loaded_overlay ~= asset_name then
                        overlay = resource.load_image(asset_name)
                        loaded_overlay = asset_name
                    end
                end
            end
        end
    end)
else
    error "no settings.json found. Please consult STANDALONE.md"
end

local Image = {
    prepare = function(self)
        self.obj = resource.load_image(self.file:copy())
    end;
    tick = function(self)
        local state, w, h = self.obj:state()
        if state == "loading" then
            print "WARNING: lost image frame. image not loaded in time."
        elseif state == "error" then
            font:write(10, HEIGHT-18, w, 8, 1,1,1,.3)
            printf("Cannot load image: %s", w)
        else
            local l = layout.fit(w, h)
            screen.draw_image(self.obj, l.x1, l.y1, l.x2, l.y2)
        end
    end;
    stop = function(self)
        if self.obj then
            self.obj:dispose()
            self.obj = nil
        end
    end;
}

local Video = {
    prepare = function(self)
        self.obj = resource.load_video{
            file = self.file:copy(),
            raw = true,
            paused = true,
            looped = true,
            audio = audio,
        }
    end;
    tick = function(self, now)
        self.obj:start()
        local state, w, h = self.obj:state()

        if state == "loading" then
            print "WARNING: lost video frame. video is most likely out of sync."
        elseif state == "error" then
            font:write(10, HEIGHT-18, w, 8, 1,1,1,.3)
            printf("Cannot load video: %s", w)
        else
            local l = layout.fit(w, h)
            self.obj:layer(-1)
            screen.draw_video(self.obj, l.x1, l.y1, l.x2, l.y2)
        end
    end;
    stop = function(self)
        if self.obj then
            self.obj:layer(-2)
            self.obj:dispose()
            self.obj = nil
        end
    end;
}

local VideoHEVC = {
    prepare = function(self)
    end;
    tick = function(self, now)
        if not self.obj then
            self.obj = resource.load_video{
                file = self.file:copy(),
                raw = true,
                paused = true,
                looped = true,
                audio = audio,
            }
        end
        if now < self.t_start + HEVC_LOAD_TIME then
            return
        end

        self.obj:start()
        local state, w, h = self.obj:state()

        if state == "loading" then
            print "WARNING: lost video frame. video is most likely out of sync."
        elseif state == "error" then
            font:write(10, HEIGHT-18, w, 8, 1,1,1,.3)
            printf("Cannot load video: %s", w)
        else
            local l = layout.fit(w, h)
            self.obj:layer(-1)
            screen.draw_video(self.obj, l.x1, l.y1, l.x2, l.y2)
        end
    end;
    stop = function(self)
        if self.obj then
            self.obj:layer(-2)
            self.obj:dispose()
            self.obj = nil
        end
    end;
}

local function Playlist()
    local all_items = {}
    local function set(new_items)
        all_items = new_items
    end

    local function make_instance(item)
        local instance = {}
        for k, v in pairs(item) do
            instance[k] = v
        end
        setmetatable(instance, {__index = ({
            image = Image,
            video = Video,
            video_hevc = VideoHEVC,
        })[instance.filetype]})
        return instance
    end

    local function get_next(test_t, back)
        local scheduled_items = {}
        for idx, item in ipairs(all_items) do
            if is_schedule_active_at(item.schedule, test_t) then
                scheduled_items[#scheduled_items+1] = item
            end
        end

        if #scheduled_items == 0 then
            scheduled_items[1] = {
                file = resource.open_file "blank.png",
                filetype = "image",
                duration = 2,
                schedule = "always",
            }
        end

        local total_duration = 0
        for idx, item in ipairs(scheduled_items) do
            item.epoch_offset = total_duration
            local duration = item.duration
            total_duration = total_duration + item.duration
        end

        local epoch_offset = test_t % total_duration
        local epoch_start = test_t - epoch_offset

        local next_start, next_idx
        for idx, item in ipairs(scheduled_items) do
            local start_t = epoch_start + item.epoch_offset
            if start_t >= test_t then
                next_start = start_t
                next_idx = idx
                break
            end
        end

        if not next_start then
            -- None matched. This only happens if the test
            -- time is after the last item's start time (so
            -- the item is playing right now). In that
            -- case the next item will be the first again.
            next_start = epoch_start + total_duration
            next_idx = 1
        end

        -- If requested, walk backwards in time, adjusting start
        -- time and item.
        back = back or 0
        while back > 0 do
            next_idx = (next_idx - 2) % #scheduled_items + 1
            next_start = next_start - scheduled_items[next_idx].duration
            back = back - 1
        end

        return next_start, make_instance(scheduled_items[next_idx])
    end

    return {
        set = set;
        get_next = get_next;
    }
end

local function PlaylistPlayer(playlist)
    local cur, nxt
    local switch
    local reschedule = os.time()

    local function tick(now)
        if not nxt and now >= reschedule then
            if not cur then
                -- While starting, check if the currently playing item
                -- would be an image. If so, allow scheduling it late.
                local past_switch, maybe_nxt = playlist.get_next(reschedule, 1)
                if maybe_nxt.filetype == "image" then
                    printf('late starting image. missed %.3fs', now - past_switch)
                    switch = past_switch
                    nxt = maybe_nxt
                end
            end
            if not nxt then
                switch, nxt = playlist.get_next(reschedule)
            end
            printf('next in %.5fs', switch - now)
            pp(nxt)
            nxt:prepare()
        end

        if nxt and switch and now >= switch then
            print('switch to')
            pp(nxt)
            local old = cur
            cur = nxt
            nxt = nil
            reschedule = switch + cur.duration - PREPARE_TIME
            if old then
                old:stop()
            end
        end

        if cur then
            cur:tick(now)
        else
            local wait = switch - now
            font:write(10, HEIGHT-30, ("Waiting for sync %.1f"):format(wait), 24, 1,1,1,.5)
        end
    end

    return {
        tick = tick;
    }
end

local playlist = Playlist()
local playlist_player = PlaylistPlayer(playlist)


local function Stream()
    local vid, url, latency, speed

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
        latency = 0
        speed = 1
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

            if vid.buffer then
                latency = 0.98 * latency + 0.02 * vid:buffer()
                if (speed > 1 and latency < TARGET_LATENCY) or
                   (speed < 1 and latency > TARGET_LATENCY) then
                   speed = 1
                elseif latency > TARGET_LATENCY * 1.1 then
                    speed = 1.01
                elseif latency < TARGET_LATENCY * 0.9 then
                    speed = 0.99
                end
                printf(
                    "latency=%.5fs, target=%7.3f%% => speed %4.2fx",
                    latency, 100 / TARGET_LATENCY * latency, speed
                )
                vid:speed(speed)
            end
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
                file = resource.open_file(filename),
                filetype = type_from_filename(filename),
                duration = tonumber(duration),
                schedule = "always",
            }
        end
        playlist.set(items)
        stream.set("")
    end)
elseif CONTENTS['config.json'] then
    util.json_watch("config.json", function(config)
        local items = {}
        local configured_playlist = config.playlist or {}
        for idx, item in ipairs(configured_playlist) do
            -- Older Pi4 based players could only have a single HEVC
            -- decoder instance. This workaround uses a special player
            -- that delays decoding by 0.5 seconds to allow a potential
            -- ealier decoder to shut down first. This is no longer
            -- needed on 2024 OS releases.
            local hevc_workaround = (
                need_hevc_workaround and
                item.file.metadata and
                item.file.metadata.format == "hevc"
            )
            if item.duration > 0 then
                items[#items+1] = {
                    file = resource.open_file(item.file.asset_name),
                    filetype = hevc_workaround and "video_hevc" or item.file.type,
                    duration = max(1, item.duration) + (hevc_workaround and HEVC_LOAD_TIME or 0),
                    schedule = expand_schedule(config, item.schedule),
                }
            end
        end
        playlist.set(items)
        stream.set(config.stream or "")
    end)
else
    error "no playlist.txt found. Please consult STANDALONE.md"
end

function node.render()
    gl.clear(0, 0, 0, 0)
    screen.frame_setup()
    if stream.has_stream() then
        stream.tick()
    else
        playlist_player.tick(os.time())
    end
    if overlay then
        overlay:draw(0, 0, WIDTH, HEIGHT)
    end
end
