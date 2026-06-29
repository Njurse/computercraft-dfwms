-- CCIT: CC Git installer (fixed version)
-- supports /tree/ and /blob/ GitHub URLs

local BASE_RAW = "https://raw.githubusercontent.com"

-- ---------- utility ----------
local function split(str, sep)
    local t = {}
    for part in string.gmatch(str, "([^" .. sep .. "]+)") do
        t[#t+1] = part
    end
    return t
end

local function trimSlash(s)
    return (s:gsub("^/", ""):gsub("/$", ""))
end

local function ensureDir(path)
    if not fs.exists(path) then
        fs.makeDir(path)
    elseif fs.isDir(path) == false then
        error("Path exists as file but should be directory: " .. path)
    end
end

-- ---------- github parsing ----------
local function parseGitHub(url)
    -- https://github.com/user/repo/tree/branch/path
    local user, repo, branch, subpath =
        url:match("github%.com/([^/]+)/([^/]+)/tree/([^/]+)/?(.*)")

    if user then
        return user, repo, branch, subpath or "", true
    end

    -- https://github.com/user/repo/blob/branch/path/file.lua
    user, repo, branch, subpath =
        url:match("github%.com/([^/]+)/([^/]+)/blob/([^/]+)/(.+)")

    if user then
        return user, repo, branch, subpath, false
    end

    error("Invalid GitHub URL format")
end

local function toRaw(user, repo, branch, path)
    return string.format("%s/%s/%s/%s", BASE_RAW, user, repo, branch, path)
end

-- ---------- file ops ----------
local function downloadFile(url, path)
    local res = http.get(url)
    if not res then
        error("Failed to download: " .. url)
    end

    local content = res.readAll()
    res.close()

    local dir = fs.getDir(path)
    if dir and dir ~= "" then
        ensureDir(dir)
    end

    local f = fs.open(path, "w")
    f.write(content)
    f.close()
end

-- ---------- recursive tree fetch ----------
local function fetchTree(user, repo, branch, path)
    local api =
        string.format("https://api.github.com/repos/%s/%s/contents/%s?ref=%s",
            user, repo, path, branch)

    local res = http.get(api, {
        ["User-Agent"] = "CCIT"
    })

    if not res then
        error("Failed to fetch repo tree: " .. api)
    end

    local data = textutils.unserializeJSON(res.readAll())
    res.close()

    if type(data) == "table" and data.type == "file" then
        return { data }
    end

    return data
end

local function installTree(user, repo, branch, path, target)
    local items = fetchTree(user, repo, branch, path)

    for _, item in ipairs(items) do
        local rel = item.path
        local out = fs.combine(target, rel)

        if item.type == "dir" then
            ensureDir(out)
            installTree(user, repo, branch, item.path, target)

        elseif item.type == "file" then
            downloadFile(item.download_url, out)
        end
    end
end

-- ---------- main ----------
local function main(url)
    local user, repo, branch, path, isTree = parseGitHub(url)

    branch = branch or "main"
    path = trimSlash(path or "")

    if isTree then
        -- folder install
        ensureDir(path == "" and repo or fs.getName(path))
        installTree(user, repo, branch, path, "")
    else
        -- single file install
        local raw = toRaw(user, repo, branch, path)
        downloadFile(raw, fs.getName(path))
    end
end

-- ---------- entry ----------
local args = {...}
if #args < 1 then
    print("Usage: ccit <github url>")
    return
end

main(args[1])
