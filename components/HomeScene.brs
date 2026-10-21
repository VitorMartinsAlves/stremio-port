sub init()
    m.grid = m.top.findNode("grid")
    m.video = m.top.findNode("video")
    m.status = m.top.findNode("status")
    m.footer = m.top.findNode("footer")
    m.grid.observeField("itemSelected", "onGridItemSelected")
    m.video.observeField("state", "onVideoStateChanged")

    m.items = []
    m.currentType = "movie"
    m.currentQuery = ""
    m.contentMode = "catalog"
    m.activeTask = invalid
    m.dialogPurpose = ""
    m.availableStreams = []
    m.currentTitle = ""
    m.pendingBridgeUrl = ""
    m.bridgeUrl = ""
    m.bridgeToken = ""

    section = CreateObject("roRegistrySection", "StremioRoku")
    storedUrl = section.Read("bridgeUrl")
    storedToken = section.Read("bridgeToken")
    if storedUrl <> invalid then m.bridgeUrl = storedUrl
    if storedToken <> invalid then m.bridgeToken = storedToken

    m.grid.SetFocus(true)
    if Len(m.bridgeUrl) > 0 and Len(m.bridgeToken) > 0 then
        loadCatalog("movie", "")
    else
        m.status.text = "Conecte ao PC: pressione * e escolha Conectar ao PC."
        m.footer.text = "O companion roda no PC e usa o Stremio Streaming Server local."
    end if
end sub

sub loadCatalog(mediaType as String, query as String)
    m.currentType = mediaType
    m.currentQuery = query
    m.contentMode = "catalog"
    if Len(m.bridgeToken) = 0 or Len(m.bridgeUrl) = 0 then
        m.status.text = "Configure o companion do PC em Opções > Conectar ao PC."
        return
    end if
    m.status.text = "Carregando catálogo de " + mediaType + "…"
    m.footer.text = "Pressione * para buscar, trocar categoria, conectar ao PC ou ver o estado do servidor."
    task = createTask("catalog")
    if task = invalid then return
    task.mediaType = mediaType
    task.query = query
    runTask(task)
end sub

function createTask(action as String) as Object
    if m.activeTask <> invalid then
        m.status.text = "Aguarde a operação atual terminar."
        return invalid
    end if
    task = CreateObject("roSGNode", "StremioTask")
    task.action = action
    if action = "pair" then
        task.bridgeUrl = m.pendingBridgeUrl
        task.pin = m.pendingPin
    else
        task.bridgeUrl = m.bridgeUrl
        task.bridgeToken = m.bridgeToken
    end if
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
        m.status.text = "A operação falhou. Verifique a conexão com o PC."
        return
    end if

    if action = "pair" then
        if result.ok = true and result.token <> invalid then
            m.bridgeUrl = m.pendingBridgeUrl
            m.bridgeToken = result.token
            section = CreateObject("roRegistrySection", "StremioRoku")
            section.Write("bridgeUrl", m.bridgeUrl)
            section.Write("bridgeToken", m.bridgeToken)
            section.Flush()
            m.status.text = "Conectado ao companion. Carregando catálogo…"
            showMessage("PC conectado", "Companion pareado em " + m.bridgeUrl + ". Os add-ons são configurados no painel web do PC.")
            loadCatalog("movie", "")
        else
            message = "Não foi possível parear com o companion."
            if result.error <> invalid then message = result.error
            showMessage("Falha ao conectar", message)
            m.status.text = message
        end if
        return
    end if

    if result.ok = false then
        message = "A solicitação falhou."
        if result.error <> invalid then message = result.error
        m.status.text = message
        if action = "playback" or action = "serverStatus" then showMessage("Stremio for Roku", message)
        return
    end if

    if action = "catalog" then
        if result.metas <> invalid then
            populateGrid(result.metas, "catalog")
            if m.currentQuery <> "" then
                m.status.text = "Resultados de busca: " + m.currentQuery
            else if m.currentType = "series" then
                m.status.text = "Séries"
            else
                m.status.text = "Filmes"
            end if
        else
            m.status.text = "O catálogo retornou vazio."
        end if
    else if action = "episodes" then
        if result.episodes <> invalid then
            populateGrid(result.episodes, "episodes")
            m.status.text = "Episódios — selecione um para buscar as fontes."
        else
            m.status.text = "Não foi possível obter os episódios desta série."
        end if
    else if action = "streams" then
        m.availableStreams = []
        if result.streams <> invalid then
            for each stream in result.streams
                if stream <> invalid and stream.unavailable <> true and stream.url <> invalid and stream.playbackId <> invalid then
                    m.availableStreams.Push(stream)
                end if
            end for
        end if
        if m.availableStreams.Count() > 0 then
            openStreamPicker()
        else
            m.status.text = "Nenhuma fonte reproduzível encontrada. Cadastre add-ons no painel do companion no PC."
            showMessage("Nenhuma fonte", "O PC consultou os add-ons configurados, mas não encontrou streams compatíveis. Confira os add-ons no painel web e tente novamente.")
        end if
    else if action = "playback" then
        if result.url <> invalid then
            playResolvedStream(result)
        else
            m.status.text = "O PC não conseguiu preparar esta fonte."
            showMessage("Falha na reprodução", "O companion não retornou uma URL de reprodução.")
        end if
    else if action = "serverStatus" then
        if result.connected = true then
            m.status.text = "Stremio Streaming Server conectado."
            showMessage("Streaming Server", "Conectado: " + m.bridgeUrl + Chr(10) + "Streaming Server: " + result.streamingServerUrl + Chr(10) + "Add-ons configurados: " + result.addonCount.ToStr() + Chr(10) + "Transcodificação HLS, quando FFmpeg está disponível, é iniciada pelo PC.")
        else
            m.status.text = "Stremio Streaming Server não encontrado."
            errorText = "Abra o Stremio Desktop/Service no PC e confira a URL configurada no painel."
            if result.error <> invalid then errorText = result.error
            showMessage("Servidor indisponível", errorText)
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
                displayName = "Sem título"
                if itemData.name <> invalid then displayName = itemData.name
                if mode = "episodes" and itemData.title <> invalid then displayName = itemData.title
                node.Title = displayName
                node.ShortDescriptionLine1 = displayName
                if itemData.poster <> invalid then node.HDPosterUrl = itemData.poster
                if itemData.thumbnail <> invalid and itemData.poster = invalid then node.HDPosterUrl = itemData.thumbnail
                if itemData.year <> invalid then
                    year = itemData.year
                    if Type(year) = "Integer" or Type(year) = "Float" then year = Mid(Str(year), 2)
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
    if m.items.Count() = 0 then m.status.text = "Nenhum item retornado pelo catálogo."
end sub

sub onGridItemSelected()
    index = m.grid.itemSelected
    if index = invalid or index < 0 or index >= m.items.Count() then return
    item = m.items[index]

    if m.contentMode = "episodes" then
        if item.id = invalid then return
        m.currentTitle = "Episódio"
        if item.title <> invalid then m.currentTitle = item.title
        task = createTask("streams")
        if task = invalid then return
        task.mediaType = "series"
        task.mediaId = item.id
        runTask(task)
        m.status.text = "Buscando fontes para " + m.currentTitle + "…"
        return
    end if

    m.currentTitle = "Título selecionado"
    if item.name <> invalid then m.currentTitle = item.name
    if m.currentType = "series" then
        if item.id = invalid then return
        task = createTask("episodes")
        if task = invalid then return
        task.mediaId = item.id
        runTask(task)
        m.status.text = "Carregando episódios de " + m.currentTitle + "…"
    else
        if item.id = invalid then return
        task = createTask("streams")
        if task = invalid then return
        task.mediaType = "movie"
        task.mediaId = item.id
        runTask(task)
        m.status.text = "Buscando fontes para " + m.currentTitle + "…"
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
        m.status.text = "Aguarde a operação atual terminar."
        return
    end if
    dialog = CreateObject("roSGNode", "Dialog")
    dialog.title = "Stremio for Roku"
    dialog.message = "Escolha uma ação"
    dialog.buttons = ["Buscar", "Filmes", "Séries", "Conectar ao PC", "Estado do servidor", "Painel de add-ons"]
    dialog.observeField("buttonSelected", "onMenuSelected")
    m.top.dialog = dialog
end sub

sub onMenuSelected()
    dialog = m.top.dialog
    if dialog = invalid then return
    selected = dialog.buttonSelected
    m.top.dialog = invalid
    if selected = 0 then
        openKeyboard("Buscar no Stremio", "Digite o título para pesquisar.", "search")
    else if selected = 1 then
        loadCatalog("movie", "")
    else if selected = 2 then
        loadCatalog("series", "")
    else if selected = 3 then
        openKeyboard("Conectar ao PC", "Digite o endereço do companion, incluindo a porta. Ex.: http://192.168.15.10:17890", "bridgeUrl")
    else if selected = 4 then
        task = createTask("serverStatus")
        if task <> invalid then runTask(task)
    else if selected = 5 then
        if Len(m.bridgeUrl) > 0 then
            showMessage("Painel do companion", "Abra no navegador do PC: " + m.bridgeUrl + "/")
        else
            showMessage("Painel do companion", "Inicie companion/start-windows.bat ou companion/start-linux.sh no PC e abra o endereço mostrado no terminal.")
        end if
    end if
end sub

sub openKeyboard(title as String, message as String, purpose as String)
    dialog = CreateObject("roSGNode", "KeyboardDialog")
    dialog.title = title
    dialog.message = message
    dialog.buttons = ["OK", "Cancelar"]
    dialog.text = ""
    dialog.observeField("buttonSelected", "onKeyboardSelected")
    m.dialogPurpose = purpose
    m.top.dialog = dialog
end sub

sub onKeyboardSelected()
    dialog = m.top.dialog
    if dialog = invalid then return
    selected = dialog.buttonSelected
    value = stripOuterSpaces(dialog.text)
    purpose = m.dialogPurpose
    m.top.dialog = invalid
    if selected <> 0 or value = "" then return

    if purpose = "search" then
        loadCatalog(m.currentType, value)
    else if purpose = "bridgeUrl" then
        m.pendingBridgeUrl = value
        if Left(LCase(value), 7) <> "http://" and Left(LCase(value), 8) <> "https://" then
            showMessage("Endereço inválido", "Use o formato http://IP-DO-PC:17890")
            return
        end if
        openKeyboard("PIN do companion", "Digite o PIN de seis dígitos exibido no terminal do PC.", "bridgePin")
    else if purpose = "bridgePin" then
        m.pendingPin = value
        task = createTask("pair")
        if task <> invalid then
            m.status.text = "Pareando com o PC…"
            runTask(task)
        end if
    end if
end sub

sub openStreamPicker()
    if m.availableStreams.Count() = 1 then
        startPlayback(m.availableStreams[0])
        return
    end if
    buttons = []
    maxCount = m.availableStreams.Count()
    if maxCount > 4 then maxCount = 4
    for i = 0 to maxCount - 1
        stream = m.availableStreams[i]
        name = "Fonte " + Mid(Str(i + 1), 2)
        if stream.name <> invalid then name = stream.name
        if stream.addon <> invalid then name = Left(name + " · " + stream.addon, 42)
        buttons.Push(Left(name, 54))
    end for
    buttons.Push("Cancelar")
    dialog = CreateObject("roSGNode", "Dialog")
    dialog.title = "Escolher fonte"
    dialog.message = "O PC prepara a fonte e pode converter torrents para HLS se o FFmpeg estiver instalado."
    dialog.buttons = buttons
    dialog.observeField("buttonSelected", "onStreamSelected")
    m.top.dialog = dialog
end sub

sub onStreamSelected()
    dialog = m.top.dialog
    if dialog = invalid then return
    selected = dialog.buttonSelected
    m.top.dialog = invalid
    if selected >= 0 and selected < m.availableStreams.Count() and selected < 4 then startPlayback(m.availableStreams[selected])
end sub

sub startPlayback(stream as Object)
    if stream = invalid or stream.playbackId = invalid then return
    task = createTask("playback")
    if task = invalid then return
    task.mediaId = stream.playbackId
    m.currentTitle = stream.name
    if m.currentTitle = invalid then m.currentTitle = "Stremio"
    m.status.text = "Preparando a reprodução no PC…"
    runTask(task)
end sub

sub playResolvedStream(result as Object)
    if result.url = invalid then return
    content = CreateObject("roSGNode", "ContentNode")
    content.Title = m.currentTitle
    content.Url = result.url
    content.ContentType = "movie"
    format = "mp4"
    if result.streamFormat <> invalid then format = LCase(result.streamFormat)
    if format <> "hls" and format <> "dash" then format = "mp4"
    content.StreamFormat = format

    m.grid.visible = false
    m.video.visible = true
    m.video.content = content
    m.video.SetFocus(true)
    m.video.control = "play"
    m.status.text = "Reproduzindo " + m.currentTitle
    if result.transcoded = true then m.status.text = "Reproduzindo " + m.currentTitle + " (HLS convertido pelo PC)"
    if result.warning <> invalid then showMessage("Transcodificação não iniciada", result.warning + Chr(10) + "A reprodução direta será tentada.")
end sub

sub onVideoStateChanged()
    state = m.video.state
    if state = "finished" or state = "error" then
        m.video.visible = false
        m.grid.visible = true
        m.grid.SetFocus(true)
        if state = "error" then m.status.text = "Falha na reprodução. O formato/codec pode não ser compatível com este Roku."
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

function stripOuterSpaces(value as String) as String
    first = 1
    last = Len(value)
    while first <= last
        if Mid(value, first, 1) <> " " then exit while
        first = first + 1
    end while
    while last >= first
        if Mid(value, last, 1) <> " " then exit while
        last = last - 1
    end while
    if last < first then return ""
    return Mid(value, first, last - first + 1)
end function
