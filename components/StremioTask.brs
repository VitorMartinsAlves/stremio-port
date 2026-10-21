sub init()
    m.top.functionName = "executeTask"
end sub

sub executeTask()
    action = m.top.action
    result = { ok: false, error: "Request failed." }

    if action = "catalog" then
        t = m.top.mediaType
        if t <> "series" then t = "movie"
        url = "https://v3-cinemeta.strem.io/catalog/" + t + "/top"
        q = m.top.query
        if q <> invalid and Len(q) > 0 then
            encoder = CreateObject("roUrlTransfer")
            url = url + "/search=" + encoder.Escape(q)
        end if
        url = url + ".json"
        payload = getJson(url)
        if payload <> invalid and payload.metas <> invalid then
            result = { ok: true, metas: payload.metas }
        else
            result = { ok: false, error: "Could not load the catalog. Check the Roku network connection." }
        end if

    else if action = "validateAddon" then
        url = normalizeManifestUrl(m.top.addonUrl)
        payload = getJson(url)
        if payload <> invalid and payload.id <> invalid and payload.name <> invalid then
            result = { ok: true, manifestUrl: url, addonName: payload.name }
        else
            result = { ok: false, error: "That URL did not return a valid Stremio add-on manifest." }
        end if

    else if action = "episodes" then
        url = "https://v3-cinemeta.strem.io/meta/series/" + m.top.mediaId + ".json"
        payload = getJson(url)
        meta = invalid
        if payload <> invalid then
            if payload.meta <> invalid then
                meta = payload.meta
            else
                meta = payload
            end if
        end if
        if meta <> invalid and meta.videos <> invalid then
            result = { ok: true, episodes: meta.videos }
        else
            result = { ok: false, error: "Episode information was not available for this series." }
        end if

    else if action = "streams" then
        allStreams = []
        addons = m.top.addonUrls
        if addons <> invalid then
            for each addonUrl in addons
                streamUrl = makeResourceUrl(addonUrl, "stream", m.top.mediaType, m.top.mediaId)
                payload = getJson(streamUrl)
                if payload <> invalid and payload.streams <> invalid then
                    for each stream in payload.streams
                        if stream <> invalid and stream.url <> invalid then
                            streamUrlValue = LCase(stream.url)
                            if Left(streamUrlValue, 7) = "http://" or Left(streamUrlValue, 8) = "https://" then
                                stream.addonSource = addonUrl
                                allStreams.Push(stream)
                            end if
                        end if
                    end for
                end if
            end for
        end if
        result = { ok: true, streams: allStreams }
        if allStreams.Count() = 0 then
            result.error = "No direct HTTP/HTTPS streams were found. Torrent-only streams require a compatible Stremio streaming server and are not played by this build."
        end if
    end if

    m.top.result = result
end sub

function getJson(url as String) as Dynamic
    transfer = CreateObject("roUrlTransfer")
    transfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
    transfer.SetUrl(url)
    transfer.AddHeader("User-Agent", "Stremio-Roku/0.1")
    body = transfer.GetToString()
    code = transfer.GetResponseCode()
    if body = invalid or Len(body) = 0 or code < 200 or code >= 300 then return invalid
    return ParseJson(body)
end function

function normalizeManifestUrl(rawUrl as String) as String
    url = Trim(rawUrl)
    if Len(url) = 0 then return ""

    query = ""
    queryAt = Instr(1, url, "?")
    if queryAt > 0 then
        query = Mid(url, queryAt)
        url = Left(url, queryAt - 1)
    end if

    if Right(LCase(url), 13) = "manifest.json" then return url + query
    if Right(url, 1) = "/" then return url + "manifest.json" + query
    return url + "/manifest.json" + query
end function

function makeResourceUrl(manifestUrl as String, resource as String, mediaType as String, mediaId as String) as String
    url = manifestUrl
    query = ""
    queryAt = Instr(1, url, "?")
    if queryAt > 0 then
        query = Mid(url, queryAt)
        url = Left(url, queryAt - 1)
    end if

    suffix = "/manifest.json"
    if Right(LCase(url), Len(suffix)) = suffix then
        url = Left(url, Len(url) - Len(suffix))
    else if Right(url, 1) = "/" then
        url = Left(url, Len(url) - 1)
    end if

    return url + "/" + resource + "/" + mediaType + "/" + mediaId + ".json" + query
end function
