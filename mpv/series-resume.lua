-- Build/resume playlists only for explicitly numbered episodes of one series.
-- Native autocreate-playlist must be disabled: a shared folder is not a series.
local utils = require 'mp.utils'
local checked = false

local function episode(name)
    -- Require a title and an unambiguous S01E02 token, not just digits/year.
    local title, season, number, suffix = name:lower():match('^(.-)s(%d+)e(%d+)(.*)$')
    if not title or (suffix ~= '' and not suffix:match('^[%s%p]')) then return end
    if not title:match('[%s%p]$') then return end
    title = title:gsub('[%s%._%-]+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if title == '' then return end
    return title, tonumber(season), tonumber(number)
end

mp.add_hook('on_load', 50, function()
    if checked then return end
    checked = true
    local playlist = mp.get_property_native('playlist', {})
    -- Preserve explicitly supplied playlists and multi-file selections.
    if #playlist ~= 1 then return end
    local current_path = mp.get_property('path', '')
    if current_path == '' or current_path:match('://') then return end
    if not current_path:match('^/') then
        current_path = utils.join_path(mp.get_property('working-directory'), current_path)
    end
    local directory, filename = utils.split_path(current_path)
    local title, season = episode(filename)
    if not title then return end

    local extensions = {}
    for _, ext in ipairs(mp.get_property_native('video-exts', {})) do
        extensions[ext:lower()] = true
    end
    local current_ext = filename:match('%.([^%.]+)$')
    if not current_ext or not extensions[current_ext:lower()] then return end
    local episodes = {}
    for _, name in ipairs(utils.readdir(directory, 'files') or {}) do
        local other_title, other_season, number = episode(name)
        local ext = name:match('%.([^%.]+)$')
        if other_title == title and other_season == season and
           ext and extensions[ext:lower()] then
            episodes[#episodes + 1] = {filename = utils.join_path(directory, name), number = number}
        end
    end
    if #episodes < 2 then return end
    table.sort(episodes, function(a, b)
        if a.number == b.number then return a.filename < b.filename end
        return a.number < b.number
    end)
    for _, entry in ipairs(episodes) do
        if entry.filename ~= current_path then
            mp.commandv('loadfile', entry.filename, 'append')
        end
    end
    -- Move entries from right to left so the target index is unambiguous.
    for index, entry in ipairs(episodes) do
        playlist = mp.get_property_native('playlist', {})
        for position, item in ipairs(playlist) do
            local path = item.filename
            if not path:match('^/') then
                path = utils.join_path(mp.get_property('working-directory'), path)
            end
            if path == entry.filename then
                if position ~= index then mp.commandv('playlist-move', position - 1, index - 1) end
                break
            end
        end
    end
    if not mp.get_property_native('resume-playback') then return end
    playlist = mp.get_property_native('playlist', {})

    local state = mp.get_property('watch-later-dir', '')
    if state == '' then state = '~~state/watch_later' end
    state = mp.command_native({'expand-path', state})
    local current = mp.get_property_number('playlist-pos', 0)
    local selected, newest = current, -1
    for index, entry in ipairs(playlist) do
        local path = entry.filename
        if not path:match('://') then
            if not path:match('^/') then
                path = utils.join_path(mp.get_property('working-directory'), path)
            end
            local parent = utils.split_path(path)
            if parent == directory then
                local key_path = path
                if mp.get_property_native('ignore-path-in-watch-later-config') then
                    local _, name = utils.split_path(path)
                    key_path = name
                end
                local hash = utils.subprocess({args = {'md5sum'}, stdin_data = key_path})
                local key = hash.status == 0 and hash.stdout:match('^%x+')
                if key then
                    local saved = utils.join_path(state, key:upper())
                    local info = utils.file_info(saved)
                    local file = info and io.open(saved, 'r')
                    if file then
                        local content = file:read('*a')
                        file:close()
                        -- Parent-directory marker files contain no start value.
                        if content:match('start=') and info.mtime > newest then
                            selected, newest = index - 1, info.mtime
                        end
                    end
                end
            end
        end
    end
    if selected ~= current then
        mp.msg.info('Resuming saved episode: ' .. playlist[selected + 1].filename)
        mp.commandv('playlist-play-index', selected)
    end
end)
