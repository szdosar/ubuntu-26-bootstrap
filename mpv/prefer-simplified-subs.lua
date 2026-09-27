-- Many releases label both simplified and traditional tracks as "chi".
-- Consult track titles too, and apply the preference once per file so saved
-- subtitle IDs cannot override it. Manual changes during playback are retained.
local function has_token(text, token)
    return (' ' .. text .. ' '):find('%f[%w]' .. token .. '%f[%W]') ~= nil
end

local function is_simplified(track)
    local lang = (track.lang or ''):lower():gsub('_', '-')
    local title = (track.title or ''):lower()
    return lang == 'zh-hans' or lang:match('^zh%-hans%-') or
        lang == 'zh-cn' or lang == 'zh-sg' or
        title:find('简体', 1, true) or title:find('简中', 1, true) or
        title:find('简英', 1, true) or title:find('簡體', 1, true) or
        title:find('簡中', 1, true) or title:find('簡英', 1, true) or
        title:find('zh-hans', 1, true) or title:find('zh-cn', 1, true) or
        has_token(title, 'chs') or has_token(title, 'simplified')
end

mp.register_event('file-loaded', function()
    local selected, best_score
    for _, track in ipairs(mp.get_property_native('track-list', {})) do
        if track.type == 'sub' and is_simplified(track) then
            -- Prefer a full subtitle track over one for forced dialogue only.
            local score = (track.forced and 0 or 10) + (track.default and 1 or 0)
            if not selected or score > best_score then
                selected, best_score = track, score
            end
        end
    end
    if selected then
        mp.set_property_number('sid', selected.id)
        mp.msg.info('Selected simplified Chinese subtitles: ' .. (selected.title or selected.lang or ''))
    end
end)
