sub init()
    m.grid = m.top.findNode("grid")
    m.video = m.top.findNode("video")
    m.status = m.top.findNode("status")
    m.footer = m.top.findNode("footer")
    m.grid.observeField("itemSelected", "onGridItemSelected")
    m.video.observeField("state", "onVideoStateChanged")

    m.items = []
    m.addons = loadAddons()
    m.currentType = "movie"
    m.currentQuery = ""
    m.contentMode = "catalog"
    m.activeTask = invalid
    m.dialogPurpose = ""
    m.availableStreams = []
    m.currentTitle = ""

    m.grid.SetFocus(true)
    loadCatalog("movie", "")
end sub

sub loadCatalog(mediaType as String, query as String)
    m.currentType = mediaType
    m.currentQuery = query
    m.contentMode = "catalog"
    m.status.text = "Loading " + mediaType + " catalog…"
    m.footer.text = "Press * for actions. Add-on URLs are managed locally on this Roku."
    task = createTask("catalog")
    if task = invalid then return
    task.mediaType = mediaType
    task.query = query
    runTask(task)
end sub

function createTask(action as String) as Object
    if m.activeTask <> invalid then
        m.status.text = "Please wait for the current request to finish."
        return invalid
    end if
    task = CreateObject("roSGNode", "StremioTask")
    task.action = action
    task.observeField("state", "onTaskStateChanged")
    m.activeTask = task
    m.top.AppendChild(task)
    return task
end function

sub runTask(task as Object)
    task.control = "RUN"
end sub

sub onTaskStateChanged()
    if m.activeTask = invalid then return
    if m.activeTask.state <> "done" then return
    task = m.activeTask
    result = task.result
    action = task.action
    m.top.RemoveChild(task)
    m.activeTask = invalid

    if result = invalid then
        m.status.text = "The request failed. Try again from the menu."
        return
    end if

    if action = "catalog" then
        if result.ok = true then
            populateGrid(result.metas, "catalog")
            if m.currentQuery <> "" then
                m.status.text = "Search results for: " + m.currentQuery
            else if m.currentType = "series" then
                m.status.text = "Series catalog"
            else
                m.status.text = "Movie catalog"
            end if
        else
            m.status.text = result.error
        end if

    else if action = "episodes" then
        if result.ok = true then
            populateGrid(result.episodes, "episodes")
            m.status.text = "Episodes — select an episode to find streams."
        else
            m.status.text = result.error
        end if

    else if action = "streams" then
        if result.ok = true and result.streams <> invalid and result.streams.Count() > 0 then
            m.availableStreams = result.streams
            openStreamPicker()
        else
            message = "No direct HTTP/HTTPS streams found. Add an add-on that provides direct URLs. Torrent-only streams are not supported by this build."
            showMessage("No playable stream", message)
            m.status.text = "No direct streams found for " + m.currentTitle
        end if

    else if action = "validateAddon" then
        if result.ok = true then
            addAddon(result.manifestUrl)
            showMessage("Add-on added", result.addonName + " was saved on this Roku.")
            m.status.text = "Add-on added: " + result.addonName
        else
            showMessage("Add-on not added", result.error)
            m.status.text = result.error
        end if
    end if
end sub

sub populateGrid(sourceItems as Object, mode as String)
    root = CreateObject("roSGNode", "ContentNode")
    m.items = []
    m.contentMode = mode

    if sourceItems <> invalid then
        for each itemData in sourceItems
            if itemData <> invalid then
                node = root.CreateChild("ContentNode")
                displayName = "Untitled"
                if itemData.name <> invalid then displayName = itemData.name
                if mode = "episodes" and itemData.title <> invalid then displayName = itemData.title
                node.Title = displayName
                node.ShortDescriptionLine1 = displayName
                if itemData.poster <> invalid then node.HDPosterUrl = itemData.poster
                if itemData.thumbnail <> invalid and itemData.poster = invalid then node.HDPosterUrl = itemData.thumbnail
                if itemData.year <> invalid then
                    year = itemData.year
                    if Type(year) = "Integer" or Type(year) = "Float" then year = Str(year)
                    node.ShortDescriptionLine2 = year
                end if
                m.items.Push(itemData)
            end if
        end for
    end if

    m.grid.content = root
    m.grid.visible = true
    m.video.visible = false
    m.grid.SetFocus(true)
    if m.items.Count() = 0 then m.status.text = "No items returned by the catalog."
end sub

sub onGridItemSelected()
    index = m.grid.itemSelected
    if index = invalid or index < 0 or index >= m.items.Count() then return
    item = m.items[index]

    if m.contentMode = "episodes" then
        if item.id = invalid then
            m.status.text = "This episode has no Stremio ID."
            return
        end if
        m.currentTitle = "Episode"
        if item.title <> invalid then m.currentTitle = item.title
        task = createTask("streams")
        if task = invalid then return
        task.mediaType = "series"
        task.mediaId = item.id
        task.addonUrls = m.addons
        runTask(task)
        m.status.text = "Finding streams for " + m.currentTitle + "…"
        return
    end if

    m.currentTitle = "Selected item"
    if item.name <> invalid then m.currentTitle = item.name
    if m.currentType = "series" then
        if item.id = invalid then return
        task = createTask("episodes")
        if task = invalid then return
        task.mediaId = item.id
        runTask(task)
        m.status.text = "Loading episodes for " + m.currentTitle + "…"
    else
        if item.id = invalid then return
        task = createTask("streams")
        if task = invalid then return
        task.mediaType = "movie"
        task.mediaId = item.id
        task.addonUrls = m.addons
        runTask(task)
        m.status.text = "Finding streams for " + m.currentTitle + "…"
    end if
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false

    if key = "options" then
        openMenu()
        return true
    end if

    if key = "back" then
        if m.video.visible then
            m.video.control = "stop"
            m.video.visible = false
            m.grid.visible = true
            m.grid.SetFocus(true)
            return true
        else if m.contentMode = "episodes" then
            loadCatalog("series", "")
            return true
        end if
    end if
    return false
end function

sub openMenu()
    if m.activeTask <> invalid then
        m.status.text = "Please wait for the current request to finish."
        return
    end if
    dialog = CreateObject("roSGNode", "Dialog")
    dialog.title = "Stremio for Roku"
    dialog.message = "Choose an action"
    dialog.buttons = ["Search", "Add Add-on", "Movies", "Series", "Cancel"]
    dialog.observeField("buttonSelected", "onMenuSelected")
    m.dialogPurpose = "menu"
    m.top.dialog = dialog
end sub

sub onMenuSelected()
    dialog = m.top.dialog
    if dialog = invalid then return
    selected = dialog.buttonSelected
    m.top.dialog = invalid
    if selected = 0 then
        openKeyboard("Search Stremio", "Search the current catalog type.", "search")
    else if selected = 1 then
        openKeyboard("Add Stremio Add-on", "Enter the add-on manifest URL, usually ending with /manifest.json.", "addon")
    else if selected = 2 then
        loadCatalog("movie", "")
    else if selected = 3 then
        loadCatalog("series", "")
    end if
end sub

sub openKeyboard(title as String, message as String, purpose as String)
    dialog = CreateObject("roSGNode", "KeyboardDialog")
    dialog.title = title
    dialog.message = message
    dialog.buttons = ["OK", "Cancel"]
    dialog.text = ""
    dialog.observeField("buttonSelected", "onKeyboardSelected")
    m.dialogPurpose = purpose
    m.top.dialog = dialog
end sub

sub onKeyboardSelected()
    dialog = m.top.dialog
    if dialog = invalid then return
    selected = dialog.buttonSelected
    value = Trim(dialog.text)
    purpose = m.dialogPurpose
    m.top.dialog = invalid
    if selected <> 0 or value = "" then return

    if purpose = "search" then
        loadCatalog(m.currentType, value)
    else if purpose = "addon" then
        task = createTask("validateAddon")
        if task = invalid then return
        task.addonUrl = value
        m.status.text = "Checking add-on manifest…"
        runTask(task)
    end if
end sub

sub openStreamPicker()
    if m.availableStreams.Count() = 1 then
        playStream(m.availableStreams[0])
        return
    end if

    buttons = []
    maxCount = m.availableStreams.Count()
    if maxCount > 5 then maxCount = 5
    for i = 0 to maxCount - 1
        stream = m.availableStreams[i]
        name = "Stream " + (i + 1).ToStr()
        if stream.name <> invalid then
            name = stream.name
        else if stream.title <> invalid then
            name = stream.title
        end if
        buttons.Push(Left(name, 42))
    end for
    buttons.Push("Cancel")

    dialog = CreateObject("roSGNode", "Dialog")
    dialog.title = "Choose stream"
    dialog.message = "Only direct HTTP/HTTPS streams can be played."
    dialog.buttons = buttons
    dialog.observeField("buttonSelected", "onStreamSelected")
    m.top.dialog = dialog
end sub

sub onStreamSelected()
    dialog = m.top.dialog
    if dialog = invalid then return
    selected = dialog.buttonSelected
    m.top.dialog = invalid
    if selected >= 0 and selected < m.availableStreams.Count() and selected < 5 then
        playStream(m.availableStreams[selected])
    end if
end sub

sub playStream(stream as Object)
    if stream = invalid or stream.url = invalid then return
    content = CreateObject("roSGNode", "ContentNode")
    content.Title = m.currentTitle
    content.Url = stream.url
    content.ContentType = "movie"
    urlLower = LCase(stream.url)
    if Instr(1, urlLower, ".m3u8") > 0 then
        content.StreamFormat = "hls"
    else if Instr(1, urlLower, ".mpd") > 0 then
        content.StreamFormat = "dash"
    else
        content.StreamFormat = "mp4"
    end if

    m.grid.visible = false
    m.video.visible = true
    m.video.content = content
    m.video.SetFocus(true)
    m.video.control = "play"
    streamName = "selected stream"
    if stream.name <> invalid then streamName = stream.name
    m.status.text = "Playing " + m.currentTitle + " — " + streamName
end sub

sub onVideoStateChanged()
    state = m.video.state
    if state = "finished" or state = "error" then
        m.video.visible = false
        m.grid.visible = true
        m.grid.SetFocus(true)
        if state = "error" then m.status.text = "Playback failed. The stream may use an unsupported codec or format."
    end if
end sub

sub showMessage(title as String, message as String)
    dialog = CreateObject("roSGNode", "Dialog")
    dialog.title = title
    dialog.message = message
    dialog.buttons = ["OK"]
    dialog.observeField("buttonSelected", "onMessageSelected")
    m.top.dialog = dialog
end sub

sub onMessageSelected()
    m.top.dialog = invalid
    if not m.video.visible then m.grid.SetFocus(true)
end sub

function loadAddons() as Object
    section = CreateObject("roRegistrySection", "StremioPort")
    raw = section.Read("addonUrls")
    if raw = invalid or Len(raw) = 0 then return []
    parsed = ParseJson(raw)
    if parsed = invalid then return []
    return parsed
end function

sub addAddon(url as String)
    for each existing in m.addons
        if LCase(existing) = LCase(url) then return
    end for
    m.addons.Push(url)
    section = CreateObject("roRegistrySection", "StremioPort")
    section.Write("addonUrls", FormatJson(m.addons))
    section.Flush()
end sub
