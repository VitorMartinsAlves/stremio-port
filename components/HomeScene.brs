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
    m.pendingPin = ""
    m.bridgeUrl = ""
    m.bridgeToken = ""
    m.probePurpose = ""
    m.pendingAccountCode = ""
    m.accountEmail = ""
    m.previousGridMode = "catalog"
    m.previousGridType = "movie"
    m.pendingLibraryMode = "all"

    section = CreateObject("roRegistrySection", "StremioRoku")
    storedUrl = section.Read("bridgeUrl")
    storedToken = section.Read("bridgeToken")
    storedCode = section.Read("accountLinkCode")
    if storedUrl <> invalid then m.bridgeUrl = storedUrl
    if storedToken <> invalid then m.bridgeToken = storedToken
    if storedCode <> invalid then m.pendingAccountCode = storedCode

    m.grid.SetFocus(true)
    m.footer.text = "Stremio para Roku · pressione * para opções."
    if Len(m.bridgeUrl) > 0 and Len(m.bridgeToken) > 0 then
        m.pendingBridgeUrl = m.bridgeUrl
        m.probePurpose = "startup"
        task = createTask("probe")
        if task <> invalid then runTask(task)
        m.status.text = "Verificando a conexão salva…"
    else
        m.status.text = "Configure a conexão com o PC para carregar os catálogos."
        openWelcomeDialog()
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
    if action = "pair" or action = "probe" then
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

    if action = "probe" then
        if result.ok <> true or result.service <> "Stremio Roku Bridge" then
            m.status.text = "Companion não encontrado neste endereço."
            showProbeFailure("Companion não encontrado", "O endereço não foi reconhecido como Stremio Roku Companion. Confira o IP e a porta exibidos no terminal do PC. O PIN não será solicitado.", false)
            return
        end if
        m.accountEmail = ""
        if result.account <> invalid and result.account.email <> invalid then m.accountEmail = result.account.email
        if result.streamingServer = invalid or result.streamingServer.reachable <> true then
            serverError = "O Companion está acessível, mas o Stremio Streaming Server não respondeu." + Chr(10) + "Endereço configurado no PC: "
            if result.streamingServer <> invalid and result.streamingServer.url <> invalid then
                serverError = serverError + result.streamingServer.url
            else
                serverError = serverError + "http://127.0.0.1:11470"
            end if
            serverError = serverError + Chr(10) + Chr(10) + "Inicie o Stremio Streaming Server no PC e tente novamente. Se continuar sem servidor, você pode optar por vincular mesmo assim, mas a reprodução ficará indisponível."
            if result.streamingServer <> invalid and result.streamingServer.error <> invalid then serverError = serverError + Chr(10) + result.streamingServer.error
            m.status.text = "Companion encontrado; Streaming Server indisponível."
            showProbeFailure("Streaming Server indisponível", serverError, true)
            return
        end if
        if m.probePurpose = "startup" then
            m.status.text = "PC e Streaming Server validados. Carregando catálogo…"
            loadCatalog("movie", "")
        else
            m.status.text = "Endereço validado. Agora informe o PIN."
            openKeyboard("PIN do Companion", "O Companion e o Streaming Server responderam. Digite o PIN de seis dígitos exibido no terminal do PC.", "bridgePin")
        end if
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

    if action = "accountLinkStart" then
        if result.ok = true and result.code <> invalid and Len(result.code) > 0 then
            m.pendingAccountCode = result.code
            section = CreateObject("roRegistrySection", "StremioRoku")
            section.Write("accountLinkCode", m.pendingAccountCode)
            section.Flush()
            showAccountLinkDialog(result)
            m.status.text = "Aguardando a autorização da conta Stremio."
        else
            message = "Não foi possível iniciar a vinculação da conta."
            if result.error <> invalid then message = result.error
            showMessage("Conta Stremio", message)
        end if
        return
    end if
    if action = "accountLinkCheck" then
        if result.ok = true and result.linked = true then
            m.accountEmail = ""
            if result.account <> invalid and result.account.email <> invalid then m.accountEmail = result.account.email
            m.pendingAccountCode = ""
            section = CreateObject("roRegistrySection", "StremioRoku")
            section.Delete("accountLinkCode")
            section.Flush()
            message = "Conta vinculada com sucesso."
            if Len(m.accountEmail) > 0 then message = message + Chr(10) + m.accountEmail
            if result.addonCount <> invalid then message = message + Chr(10) + "Add-ons sincronizados: " + Mid(Str(result.addonCount), 2)
            if result.libraryCount <> invalid then message = message + Chr(10) + "Itens na biblioteca: " + Mid(Str(result.libraryCount), 2)
            if result.warnings <> invalid and result.warnings.Count() > 0 then message = message + Chr(10) + Chr(10) + "Aviso: " + result.warnings[0]
            m.status.text = "Conta Stremio vinculada."
            showMessage("Conta vinculada", message)
        else
            message = "O código ainda não foi autorizado. Abra o link no celular/PC, conclua o vínculo e tente novamente."
            if result.message <> invalid then message = result.message
            if result.error <> invalid then message = result.error
            showMessage("Vínculo pendente", message)
            m.status.text = "Aguardando autorização pelo navegador."
        end if
        return
    end if
    if action = "accountStatus" then
        if result.authenticated = true then
            m.accountEmail = ""
            if result.account <> invalid and result.account.email <> invalid then m.accountEmail = result.account.email
            message = "Conta conectada."
            if Len(m.accountEmail) > 0 then message = message + Chr(10) + m.accountEmail
            if result.addonCount <> invalid then message = message + Chr(10) + "Add-ons da conta: " + Mid(Str(result.addonCount), 2)
            showMessage("Conta Stremio", message)
            m.status.text = "Conta Stremio conectada."
        else
            m.accountEmail = ""
            showMessage("Conta Stremio", "Nenhuma conta vinculada. Escolha Conta Stremio → Vincular conta.")
            m.status.text = "Entre na conta para sincronizar sua biblioteca."
        end if
        return
    end if
    if action = "accountSync" then
        if result.ok = true then
            if result.account <> invalid and result.account.email <> invalid then m.accountEmail = result.account.email
            message = "Sincronização concluída."
            if Len(m.accountEmail) > 0 then message = message + Chr(10) + m.accountEmail
            if result.addonCount <> invalid then message = message + Chr(10) + "Add-ons da conta: " + Mid(Str(result.addonCount), 2)
            if result.libraryCount <> invalid then message = message + Chr(10) + "Itens na biblioteca: " + Mid(Str(result.libraryCount), 2)
            if result.warnings <> invalid and result.warnings.Count() > 0 then message = message + Chr(10) + Chr(10) + "Aviso: " + result.warnings[0]
            showMessage("Conta Stremio", message)
        else
            message = "Não foi possível sincronizar a conta."
            if result.error <> invalid then message = result.error
            showMessage("Conta Stremio", message)
        end if
        return
    end if
    if action = "accountLogout" then
        if result.ok = true then
            m.accountEmail = ""
            showMessage("Sessão encerrada", "A conta foi desconectada deste Companion.")
        else
            message = "Não foi possível sair da conta."
            if result.error <> invalid then message = result.error
            showMessage("Conta Stremio", message)
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

    if action = "accountLibrary" then
        if result.items <> invalid then
            if m.pendingLibraryMode = "continue" then
                continueItems = []
                for each libraryItem in result.items
                    if libraryItem.progress <> invalid and libraryItem.progress > 0.01 and libraryItem.progress < 0.7 then continueItems.Push(libraryItem)
                end for
                populateGrid(continueItems, "continue")
                m.status.text = "Continuar assistindo · " + Mid(Str(m.items.Count()), 2) + " itens"
            else
                populateGrid(result.items, "library")
                m.status.text = "Minha biblioteca · " + Mid(Str(m.items.Count()), 2) + " itens"
            end if
        else
            m.status.text = "Não foi possível carregar sua biblioteca."
            showMessage("Minha biblioteca", "Verifique se a conta Stremio está vinculada e tente Atualizar conta.")
        end if
    else if action = "catalog" then
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
            showMessage("Streaming Server", "Conectado: " + m.bridgeUrl + Chr(10) + "Streaming Server: " + result.streamingServerUrl + Chr(10) + "Add-ons configurados: " + Mid(Str(result.addonCount), 2) + Chr(10) + "Transcodificação HLS, quando FFmpeg está disponível, é iniciada pelo PC.")
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
    if m.contentMode = "library" or m.contentMode = "continue" then
        m.previousGridMode = m.contentMode
        if item.type <> invalid then m.currentType = item.type
    else
        m.previousGridMode = "catalog"
    end if
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
        task.mediaType = m.currentType
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
            if m.previousGridMode = "library" then
                loadLibrary("all")
            else if m.previousGridMode = "continue" then
                loadLibrary("continue")
            else
                loadCatalog("series", "")
            end if
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
    dialog.buttons = ["Buscar", "Filmes", "Séries", "Mais opções"]
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
        openMoreMenu()
    end if
end sub

sub openWelcomeDialog()
    dialog = CreateObject("roSGNode", "Dialog")
    dialog.title = "Stremio para Roku"
    dialog.message = "Para começar, inicie o Companion no PC. A TV valida o serviço e o Streaming Server antes de solicitar o PIN."
    dialog.buttons = ["Configurar PC", "Tentar conexão salva", "Fechar"]
    dialog.observeField("buttonSelected", "onWelcomeSelected")
    m.top.dialog = dialog
end sub

sub onWelcomeSelected()
    dialog = m.top.dialog
    if dialog = invalid then return
    selected = dialog.buttonSelected
    m.top.dialog = invalid
    if selected = 0 then
        openKeyboard("Endereço do PC", "Digite a URL do Companion mostrada no terminal, por exemplo http://192.168.1.50:17890. O app validará o serviço antes de pedir o PIN.", "bridgeUrl")
    else if selected = 1 then
        if Len(m.bridgeUrl) = 0 then
            openKeyboard("Endereço do PC", "Digite a URL do Companion, por exemplo http://192.168.1.50:17890.", "bridgeUrl")
        else
            m.pendingBridgeUrl = m.bridgeUrl
            m.probePurpose = "connect"
            task = createTask("probe")
            if task <> invalid then runTask(task)
            m.status.text = "Validando Companion e Streaming Server…"
        end if
    end if
end sub

sub openMoreMenu()
    dialog = CreateObject("roSGNode", "Dialog")
    dialog.title = "Stremio para Roku"
    dialog.message = "Conta, biblioteca e configurações"
    dialog.buttons = ["Conectar ao PC", "Conta Stremio", "Minha biblioteca", "Mais opções", "Voltar"]
    dialog.observeField("buttonSelected", "onMoreMenuSelected")
    m.top.dialog = dialog
end sub

sub onMoreMenuSelected()
    dialog = m.top.dialog
    if dialog = invalid then return
    selected = dialog.buttonSelected
    m.top.dialog = invalid
    if selected = 0 then
        openKeyboard("Endereço do PC", "Digite a URL do Companion, por exemplo http://192.168.1.50:17890. O serviço será validado antes de pedir o PIN.", "bridgeUrl")
    else if selected = 1 then
        openAccountMenu()
    else if selected = 2 then
        loadLibrary("all")
    else if selected = 3 then
        openToolsMenu()
    end if
end sub

sub openAccountMenu()
    dialog = CreateObject("roSGNode", "Dialog")
    dialog.title = "Conta Stremio"
    dialog.message = "Vincule a conta por código usando um celular ou PC; não precisa digitar a senha na TV."
    dialog.buttons = ["Vincular conta", "Verificar vínculo", "Atualizar conta", "Sair da conta", "Voltar"]
    dialog.observeField("buttonSelected", "onAccountMenuSelected")
    m.top.dialog = dialog
end sub

sub onAccountMenuSelected()
    dialog = m.top.dialog
    if dialog = invalid then return
    selected = dialog.buttonSelected
    m.top.dialog = invalid
    if selected = 0 then
        task = createTask("accountLinkStart")
        if task <> invalid then runTask(task)
    else if selected = 1 then
        if Len(m.pendingAccountCode) = 0 then
            showMessage("Conta Stremio", "Nenhum código pendente. Escolha Vincular conta para gerar um código.")
        else
            task = createTask("accountLinkCheck")
            if task <> invalid then
                task.mediaId = m.pendingAccountCode
                runTask(task)
            end if
        end if
    else if selected = 2 then
        task = createTask("accountSync")
        if task <> invalid then runTask(task)
    else if selected = 3 then
        task = createTask("accountLogout")
        if task <> invalid then runTask(task)
    end if
end sub

sub openToolsMenu()
    dialog = CreateObject("roSGNode", "Dialog")
    dialog.title = "Mais opções"
    dialog.message = "Diagnóstico e progresso"
    dialog.buttons = ["Continuar assistindo", "Estado do servidor", "Painel do Companion", "Voltar"]
    dialog.observeField("buttonSelected", "onToolsMenuSelected")
    m.top.dialog = dialog
end sub

sub onToolsMenuSelected()
    dialog = m.top.dialog
    if dialog = invalid then return
    selected = dialog.buttonSelected
    m.top.dialog = invalid
    if selected = 0 then
        loadLibrary("continue")
    else if selected = 1 then
        task = createTask("serverStatus")
        if task <> invalid then runTask(task)
    else if selected = 2 then
        if Len(m.bridgeUrl) > 0 then
            showMessage("Painel do Companion", "Abra no PC: " + m.bridgeUrl + "/")
        else
            showMessage("Painel do Companion", "Inicie companion/start-linux.sh no CachyOS e abra o endereço LAN mostrado no terminal.")
        end if
    end if
end sub

sub loadLibrary(mode as String)
    if Len(m.bridgeToken) = 0 or Len(m.bridgeUrl) = 0 then
        showMessage("Minha biblioteca", "Conecte primeiro ao Companion do PC.")
        return
    end if
    m.pendingLibraryMode = mode
    task = createTask("accountLibrary")
    if task = invalid then return
    task.mediaType = mode
    runTask(task)
    m.status.text = "Carregando sua biblioteca Stremio…"
end sub

sub showProbeFailure(title as String, message as String, serverDown as Boolean)
    dialog = CreateObject("roSGNode", "Dialog")
    dialog.title = title
    dialog.message = message
    if serverDown then
        dialog.buttons = ["Tentar de novo", "Vincular mesmo assim", "Cancelar"]
        m.dialogPurpose = "probeServerDown"
    else
        dialog.buttons = ["Tentar outro endereço", "Cancelar"]
        m.dialogPurpose = "probeInvalid"
    end if
    dialog.observeField("buttonSelected", "onProbeFailureSelected")
    m.top.dialog = dialog
end sub

sub onProbeFailureSelected()
    dialog = m.top.dialog
    if dialog = invalid then return
    selected = dialog.buttonSelected
    purpose = m.dialogPurpose
    m.top.dialog = invalid
    if purpose = "probeServerDown" then
        if selected = 0 then
            task = createTask("probe")
            if task <> invalid then runTask(task)
            m.status.text = "Verificando novamente…"
        else if selected = 1 then
            openKeyboard("PIN do Companion", "O Companion respondeu, mas o Streaming Server não. Você pode vincular a conta, mas a reprodução pode falhar. Digite o PIN do PC.", "bridgePin")
        else
            openWelcomeDialog()
        end if
    else if purpose = "probeInvalid" then
        if selected = 0 then
            openKeyboard("Endereço do PC", "Confira o endereço LAN e a porta do Companion no terminal do PC.", "bridgeUrl")
        else
            openWelcomeDialog()
        end if
    end if
    m.dialogPurpose = ""
end sub

sub showAccountLinkDialog(result as Object)
    link = "Link de vinculação não retornado."
    if result.link <> invalid and Len(result.link) > 0 then link = result.link
    message = "1. No celular ou PC, abra:" + Chr(10) + link + Chr(10) + Chr(10) + "2. Entre na conta Stremio e conclua a vinculação." + Chr(10) + "3. Código: " + m.pendingAccountCode + Chr(10) + Chr(10) + "Depois volte à TV e escolha Conta Stremio → Verificar vínculo."
    dialog = CreateObject("roSGNode", "Dialog")
    dialog.title = "Vincular conta Stremio"
    dialog.message = message
    dialog.buttons = ["Verificar vínculo", "Fechar"]
    dialog.observeField("buttonSelected", "onAccountLinkDialogSelected")
    m.top.dialog = dialog
end sub

sub onAccountLinkDialogSelected()
    dialog = m.top.dialog
    if dialog = invalid then return
    selected = dialog.buttonSelected
    m.top.dialog = invalid
    if selected = 0 and Len(m.pendingAccountCode) > 0 then
        task = createTask("accountLinkCheck")
        if task <> invalid then
            task.mediaId = m.pendingAccountCode
            runTask(task)
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
            showMessage("Endereço inválido", "Use uma URL como http://192.168.1.50:17890")
            return
        end if
        if Instr(1, value, " ") > 0 or Instr(1, value, "@") > 0 then
            showMessage("Endereço inválido", "Informe apenas IP/nome do PC e porta do Companion; não inclua credenciais.")
            return
        end if
        m.probePurpose = "connect"
        task = createTask("probe")
        if task <> invalid then
            m.status.text = "Validando Companion e Streaming Server antes do PIN…"
            runTask(task)
        end if
    else if purpose = "bridgePin" then
        m.pendingPin = value
        if Len(value) < 6 or Len(value) > 16 then
            showMessage("PIN inválido", "Digite o PIN mostrado no terminal do PC e tente novamente.")
            return
        end if
        task = createTask("pair")
        if task <> invalid then
            m.status.text = "Validando PIN e pareando com o PC…"
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
    if maxCount > 3 then maxCount = 3
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
    if selected >= 0 and selected < m.availableStreams.Count() and selected < 3 then startPlayback(m.availableStreams[selected])
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
