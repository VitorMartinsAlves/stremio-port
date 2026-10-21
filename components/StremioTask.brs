sub init()
    m.top.functionName = "executeTask"
end sub

sub executeTask()
    action = m.top.action
    base = trimOuterSpaces(m.top.bridgeUrl)
    if Len(base) = 0 then
        m.top.result = { ok: false, error: "Configure o endereço do companion no PC." }
        return
    end if
    while Right(base, 1) = "/"
        base = Left(base, Len(base) - 1)
    end while

    if action = "probe" then
        m.top.result = requestJson(base + "/api/setup/status", "", "GET", invalid)
        return
    end if

    if action = "pair" then
        m.top.result = requestJson(base + "/api/pair", "", "POST", { pin: m.top.pin })
        return
    end if

    token = m.top.bridgeToken
    if Len(token) = 0 then
        m.top.result = { ok: false, error: "Roku não pareado com o companion. Use Opções > Conectar ao PC." }
        return
    end if

    transfer = CreateObject("roUrlTransfer")
    transfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
    transfer.AddHeader("Authorization", "Bearer " + token)
    transfer.AddHeader("Accept", "application/json")
    transfer.SetUrl(base + "/api/health")
    ' A light health request distinguishes an unreachable companion from an API failure.
    healthText = transfer.GetToString()
    healthCode = transfer.GetResponseCode()
    if healthCode < 200 or healthCode >= 300 or healthText = invalid then
        m.top.result = { ok: false, error: "Não foi possível acessar o companion. Confira o IP/porta e se o PC está ligado." }
        return
    end if

    path = ""
    if action = "catalog" then
        path = "/api/catalog?type=" + urlEscape(m.top.mediaType)
        if Len(m.top.query) > 0 then path = path + "&search=" + urlEscape(m.top.query)
    else if action = "episodes" then
        path = "/api/episodes?id=" + urlEscape(m.top.mediaId)
    else if action = "streams" then
        path = "/api/streams?type=" + urlEscape(m.top.mediaType) + "&videoId=" + urlEscape(m.top.mediaId)
    else if action = "playback" then
        path = "/api/playback?id=" + urlEscape(m.top.mediaId)
    else if action = "serverStatus" then
        path = "/api/server/status"
    else if action = "accountStatus" then
        path = "/api/account/status"
    else if action = "accountLibrary" then
        path = "/api/account/library"
        if Len(m.top.mediaType) > 0 then path = path + "?mode=" + urlEscape(m.top.mediaType)
    else if action = "accountLinkStart" then
        path = "/api/account/link/start"
    else if action = "accountLinkCheck" then
        path = "/api/account/link/check"
    else if action = "accountSync" then
        path = "/api/account/sync"
    else if action = "accountLogout" then
        path = "/api/account/logout"
    else
        m.top.result = { ok: false, error: "Ação não reconhecida." }
        return
    end if

    if action = "accountLinkStart" or action = "accountSync" or action = "accountLogout" then
        m.top.result = requestJson(base + path, token, "POST", {})
    else if action = "accountLinkCheck" then
        m.top.result = requestJson(base + path, token, "POST", { code: m.top.mediaId })
    else
        m.top.result = requestJson(base + path, token, "GET", invalid)
    end if
end sub

function requestJson(url as String, token as String, method as String, payload as Dynamic) as Object
    transfer = CreateObject("roUrlTransfer")
    transfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
    transfer.SetUrl(url)
    transfer.AddHeader("Accept", "application/json")
    if Len(token) > 0 then transfer.AddHeader("Authorization", "Bearer " + token)
    response = invalid
    if method = "POST" or method = "PUT" then
        transfer.SetRequest(method)
        transfer.AddHeader("Content-Type", "application/json")
        body = "{}"
        if payload <> invalid then body = FormatJson(payload)
        response = transfer.PostFromString(body)
    else
        response = transfer.GetToString()
    end if
    code = transfer.GetResponseCode()
    if response = invalid or Len(response) = 0 then
        return { ok: false, error: "O companion não retornou uma resposta. HTTP " + Str(code) }
    end if
    parsed = ParseJson(response)
    if parsed = invalid then return { ok: false, error: "Resposta JSON inválida do companion." }
    if code < 200 or code >= 300 then
        message = "Falha HTTP " + Str(code)
        if parsed.error <> invalid then message = parsed.error
        parsed.ok = false
        parsed.error = message
    end if
    return parsed
end function

function urlEscape(value as String) as String
    transfer = CreateObject("roUrlTransfer")
    return transfer.Escape(value)
end function

function trimOuterSpaces(value as String) as String
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
