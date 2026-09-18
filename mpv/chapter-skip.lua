-- Skip clearly labelled opening and ending chapters in local media.
-- Files without suitable chapter titles play normally.
local enabled = true
local last_path = nil
local last_chapter = nil

local function classify(title)
    if type(title) ~= "string" then return nil end
    local value = title:lower():gsub("^%s+", ""):gsub("%s+$", "")
    if value == "op" or value == "opening" or value == "intro" or
       value:match("^opening[%s%p]") or value:match("^intro[%s%p]") or
       value:find("片头", 1, true) or value:find("前情", 1, true) then
        return "intro"
    end
    if value == "ed" or value == "ending" or value == "outro" or
       value == "credits" or value:match("^ending[%s%p]") or
       value:match("^outro[%s%p]") or value:match("^credits[%s%p]") or
       value:find("片尾", 1, true) or value:find("演职员", 1, true) then
        return "outro"
    end
end

local function skip_current_chapter()
    if not enabled then return end
    local chapter = mp.get_property_number("chapter", -1)
    local chapters = mp.get_property_native("chapter-list", {})
    local path = mp.get_property("path", "")
    if chapter < 0 or not chapters[chapter + 1] then return end
    if path == last_path and chapter == last_chapter then return end

    local title = chapters[chapter + 1].title
    local kind = classify(title)
    if not kind then return end
    last_path, last_chapter = path, chapter

    if kind == "intro" and chapters[chapter + 2] then
        mp.osd_message("跳过片头：" .. title, 2)
        mp.commandv("seek", chapters[chapter + 2].time, "absolute+exact")
    elseif kind == "outro" then
        mp.osd_message("跳过片尾：" .. title, 2)
        mp.commandv("playlist-next", "force")
    end
end

mp.register_event("file-loaded", skip_current_chapter)
mp.observe_property("chapter", "number", function() skip_current_chapter() end)
mp.add_key_binding("Ctrl+i", "toggle-chapter-skip", function()
    enabled = not enabled
    mp.osd_message("自动跳片头片尾：" .. (enabled and "开启" or "关闭"), 2)
end)
