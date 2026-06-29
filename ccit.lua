-- ccit.lua - Pseudo package manager for Git on ComputerCraft
-- Usage: ccit <URL> [destination]
-- Supports GitHub repositories (raw files, directories via tree/blob URLs)

local args = { ... }
if #args < 1 then
    print("Usage: ccit <URL> [destination]")
    print("Examples:")
    print("  ccit https://raw.githubusercontent.com/user/repo/main/startup.lua")
    print("  ccit https://github.com/user/repo/tree/main/scripts/example")
    return
end

local url = args[1]
local dest = args[2] or "."
-- If dest is relative, make it absolute relative to current shell dir?
-- ComputerCraft's fs functions handle relative paths from the current working directory.

-- Helper: print error in red (if colors supported)
local function printError(msg)
    if term.isColor() then
        term.setTextColor(colors.red)
    end
    print("Error: " .. msg)
    if term.isColor() then
        term.setTextColor(colors.white)
    end
end

-- Helper: print success in green
local function printSuccess(msg)
    if term.isColor() then
        term.setTextColor(colors.green)
    end
    print(msg)
    if term.isColor() then
        term.setTextColor(colors.white)
    end
end

-- Helper: print info in yellow
local function printInfo(msg)
    if term.isColor() then
        term.setTextColor(colors.yellow)
    end
    print(msg)
    if term.isColor() then
        term.setTextColor(colors.white)
    end
end

-- Ensure destination directory exists
local function ensureDir(path)
    if not fs.exists(path) then
        fs.makeDir(path)
    elseif not fs.isDir(path) then
        error("Destination '" .. path .. "' exists and is not a directory.")
    end
end

-- Download a single file from a URL to a local path
-- Returns true on success, false on failure (with error message printed)
local function downloadFile(fileUrl, localPath)
    -- Check URL validity (ComputerCraft's http.checkURL)
    local ok, err = http.checkURL(fileUrl)
    if not ok then
        printError("Invalid or blocked URL: " .. fileUrl .. " (" .. err .. ")")
        return false
    end

    -- Ensure parent directory exists
    local parent = fs.getDir(localPath)
    if parent ~= "" and not fs.exists(parent) then
        fs.makeDir(parent)
    end

    printInfo("Downloading " .. fileUrl .. " -> " .. localPath)
    local response, errMsg = http.get(fileUrl, nil, true) -- binary mode for dfpwm
    if not response then
        printError("Failed to download: " .. tostring(errMsg))
        return false
    end

    local status = response.getResponseCode()
    if status ~= 200 then
        printError("HTTP error " .. status .. " for " .. fileUrl)
        response.close()
        return false
    end

    local content = response.readAll()
    response.close()

    local file = fs.open(localPath, "w")
    if not file then
        printError("Could not write to " .. localPath)
        return false
    end
    file.write(content)
    file.close()
    printSuccess("Downloaded " .. localPath)
    return true
end

-- Parse a GitHub URL and return a table with owner, repo, branch, path, type
-- Supported formats:
--   https://raw.githubusercontent.com/owner/repo/branch/path/file.lua
--   https://github.com/owner/repo/blob/branch/path/file.lua
--   https://github.com/owner/repo/tree/branch/path
--   https://api.github.com/repos/owner/repo/contents/path?ref=branch
-- Returns nil if not a GitHub URL
local function parseGitHubURL(url)
    local parsed = {}
    -- Try raw.githubusercontent.com
    local rawPattern = "https?://raw%.githubusercontent%.com/([^/]+)/([^/]+)/([^/]+)/(.+)"
    local owner, repo, branch, path = url:match(rawPattern)
    if owner and repo and branch and path then
        parsed.owner = owner
        parsed.repo = repo
        parsed.branch = branch
        parsed.path = path
        parsed.type = "file"  -- raw URLs are always a single file
        return parsed
    end

    -- Try github.com
    local githubPattern = "https?://github%.com/([^/]+)/([^/]+)/(blob|tree)/([^/]+)/(.+)"
    owner, repo, type_, branch, path = url:match(githubPattern)
    if owner and repo and type_ and branch and path then
        parsed.owner = owner
        parsed.repo = repo
        parsed.branch = branch
        parsed.path = path
        if type_ == "blob" then
            parsed.type = "file"
        elseif type_ == "tree" then
            parsed.type = "dir"
        else
            return nil
        end
        return parsed
    end

    -- Try API URL (just in case user supplies one directly)
    local apiPattern = "https?://api%.github%.com/repos/([^/]+)/([^/]+)/contents/(.+?)(?:%?ref=([^&]+))?"
    owner, repo, path, branch = url:match(apiPattern)
    if owner and repo and path then
        parsed.owner = owner
        parsed.repo = repo
        parsed.branch = branch or "main" -- default if not specified
        parsed.path = path
        parsed.type = "dir" -- API contents endpoint is for directories
        return parsed
    end

    return nil
end

-- Fetch directory contents from GitHub API, handling pagination
-- Returns a table of items (each with name, path, type, download_url)
-- On error, returns nil and prints error
local function fetchDirectoryContents(apiUrl, token)
    local allItems = {}
    local nextUrl = apiUrl

    while nextUrl do
        local headers = {}
        if token then
            headers["Authorization"] = "token " .. token
        end
        local response, errMsg = http.get(nextUrl, headers)
        if not response then
            printError("HTTP request failed: " .. tostring(errMsg))
            return nil
        end

        local status = response.getResponseCode()
        if status == 404 then
            printError("Path not found (404) – check repository and branch.")
            response.close()
            return nil
        elseif status == 403 then
            printError("API rate limit exceeded. Try using a GitHub token or wait.")
            response.close()
            return nil
        elseif status ~= 200 then
            printError("GitHub API error " .. status)
            response.close()
            return nil
        end

        local body = response.readAll()
        response.close()

        local ok, data = pcall(textutils.unserializeJSON, body)
        if not ok or not data then
            printError("Failed to parse JSON from API response.")
            return nil
        end

        -- data can be a table (array of items) or a single object (if path is a file)
        if type(data) == "table" and data.type then
            -- Single item (should not happen for directory, but handle)
            table.insert(allItems, data)
        elseif type(data) == "table" then
            for _, item in ipairs(data) do
                table.insert(allItems, item)
            end
        else
            printError("Unexpected API response format.")
            return nil
        end

        -- Check for next page in Link header
        -- ComputerCraft's http response doesn't expose headers directly.
        -- We need to parse the 'Link' header manually via response.getResponseHeaders()? 
        -- Actually, ComputerCraft's http.get returns a table with methods, but we can get headers with response.getResponseHeaders()
        -- But for simplicity, we'll assume we don't handle pagination, but we should.
        -- Let's implement pagination by checking the Link header if available.
        -- The 'Link' header might not be exposed; we can try to get it.
        -- However, we can also rely on the fact that GitHub API returns a 'next' URL in the 'Link' header.
        -- In ComputerCraft, you can call response.getResponseHeaders() which returns a table.
        -- We'll attempt to parse that.
        local headersTable = response.getResponseHeaders()
        if headersTable and headersTable["link"] then
            local link = headersTable["link"]
            -- Look for rel="next"
            local nextMatch = link:match('<([^>]+)>; rel="next"')
            if nextMatch then
                nextUrl = nextMatch
            else
                nextUrl = nil
            end
        else
            nextUrl = nil
        end
    end

    return allItems
end

-- Recursively fetch a directory from GitHub
local function recursiveFetch(owner, repo, branch, remotePath, localBase, token)
    -- Build API URL
    local apiUrl = "https://api.github.com/repos/" .. owner .. "/" .. repo .. "/contents/" .. remotePath
    if branch then
        apiUrl = apiUrl .. "?ref=" .. branch
    end

    printInfo("Fetching directory listing: " .. remotePath)
    local items = fetchDirectoryContents(apiUrl, token)
    if not items then
        return false
    end

    for _, item in ipairs(items) do
        if item.type == "file" then
            local name = item.name
            local ext = name:match("%.([^.]+)$")
            if ext and (ext == "lua" or ext == "dfpwm") then
                local relativePath = item.path
                -- Remove leading remotePath prefix if present
                local rel = relativePath:gsub("^" .. remotePath .. "/?", "")
                if rel == "" then rel = name end
                local localPath = fs.combine(localBase, rel)
                -- Ensure parent directory exists
                local parent = fs.getDir(localPath)
                if parent ~= "" and not fs.exists(parent) then
                    fs.makeDir(parent)
                end
                -- Download using the download_url from the item
                if not downloadFile(item.download_url, localPath) then
                    printError("Failed to download " .. name .. ", continuing...")
                end
            else
                -- Ignore non-lua/dfpwm files
                printInfo("Skipping " .. item.name .. " (not .lua or .dfpwm)")
            end
        elseif item.type == "dir" then
            local dirName = item.name
            local subRemote = item.path
            local subLocal = fs.combine(localBase, dirName)
            if not fs.exists(subLocal) then
                fs.makeDir(subLocal)
            end
            -- Recurse
            recursiveFetch(owner, repo, branch, subRemote, subLocal, token)
        else
            printInfo("Skipping unknown type: " .. item.type)
        end
    end
    return true
end

-- Main logic
local function main()
    -- Check internet
    if not http then
        printError("HTTP API is not enabled. Please enable it in the ComputerCraft config.")
        return
    end

    local githubInfo = parseGitHubURL(url)
    if not githubInfo then
        -- Not a GitHub URL, attempt single file download
        printInfo("Not a GitHub URL; attempting to download as a single file.")
        local fileName = fs.getName(url) or "downloaded_file"
        local targetPath = fs.combine(dest, fileName)
        if not downloadFile(url, targetPath) then
            printError("Download failed.")
        end
        return
    end

    -- Now we have a GitHub URL
    local owner = githubInfo.owner
    local repo = githubInfo.repo
    local branch = githubInfo.branch
    local path = githubInfo.path
    local type_ = githubInfo.type

    if type_ == "file" then
        -- Single file: construct raw URL and download
        local rawUrl = "https://raw.githubusercontent.com/" .. owner .. "/" .. repo .. "/" .. branch .. "/" .. path
        local fileName = fs.getName(path) or "file"
        local targetPath = fs.combine(dest, fileName)
        if not downloadFile(rawUrl, targetPath) then
            printError("Download failed.")
        end
    elseif type_ == "dir" then
        -- Create root folder: either use repo name or last segment of path
        local rootName = repo
        -- If user gave a specific destination, use that; otherwise create a folder named after the repo
        local rootDir
        if dest ~= "." and dest ~= "" then
            -- If destination is provided, use it as the root
            rootDir = dest
        else
            rootDir = repo
        end
        ensureDir(rootDir)

        -- Optional: use a GitHub token from environment variable? Could read from a file.
        local token = nil
        -- Attempt to read token from a file (e.g., /github.token) – optional
        if fs.exists("github.token") then
            local f = fs.open("github.token", "r")
            if f then
                token = f.readAll():gsub("%s+", "")
                f.close()
                printInfo("Using GitHub token from github.token")
            end
        end

        printInfo("Cloning directory " .. path .. " from " .. owner .. "/" .. repo .. " (branch " .. branch .. ") into " .. rootDir)
        local success = recursiveFetch(owner, repo, branch, path, rootDir, token)
        if success then
            printSuccess("All files downloaded successfully.")
        else
            printError("Some files may not have been downloaded.")
        end
    else
        printError("Unsupported URL type.")
    end
end

-- Run the script
local ok, err = pcall(main)
if not ok then
    printError("Unhandled error: " .. tostring(err))
end
