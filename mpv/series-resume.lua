-- Resume the most recently saved video in an automatically created playlist.
-- Uses mpv's own watch_later files; no separate viewing-history database.
local utils = require 'mp.utils'
local checked = false

mp.add_hook('on_load', 50, function()
    if checked then return end
    local playlist = mp.get_property_native('playlist', {})
    if #playlist < 2 then return end
    checked = true
    if not mp.get_property_native('resume-playback') then return end
    if mp.get_property('autocreate-playlist') == 'no' then return end

    local state = mp.get_property('watch-later-dir', '')
    if state == '' then state = '~~state/watch_later' end
    state = mp.command_native({'expand-path', state})
    local current = mp.get_property_number('playlist-pos', 0)
    local selected, newest = current, -1
    local current_path = mp.get_property('path', '')
    if not current_path:match('^/') then
        current_path = utils.join_path(mp.get_property('working-directory'), current_path)
    end
    local directory = utils.split_path(current_path)
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
