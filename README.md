# Stremio for Roku (experimental)

A native Roku SceneGraph/BrightScript client prototype for browsing Cinemeta catalogs and playing direct HTTP/HTTPS streams returned by user-configured Stremio add-ons.

## Current scope

- Movie and series catalogs from Cinemeta.
- Search in the currently selected catalog type.
- Series episode selection.
- Add-on manifest URLs can be added from the Roku remote; URLs are saved in Roku Registry.
- Requests use the Stremio Add-on Protocol (`catalog`, `meta`, `stream`).
- Direct HTTP/HTTPS streams are sent to Roku's native `Video` node.
- A sideload ZIP is produced by the GitHub Actions workflow and can also be built locally.

## Important limitations

This is **not a full Stremio runtime**. Roku cannot run the desktop/Android Stremio application, Stremio's torrent engine, arbitrary browser code, or all Stremio add-ons. This prototype only tries add-on stream URLs beginning with `http://` or `https://`. Streams that rely on `infoHash`, `magnet:` URLs, or the Stremio streaming server are skipped. Roku also supports only certain codecs, containers, and streaming formats; a direct URL is not a guarantee of successful playback. Add-ons requiring special configuration, authentication, DRM, headers, or subtitles may not work.

The app does not collect Stremio account credentials and does not automatically sync add-ons from a Stremio account. You enter each add-on's manifest URL on the Roku itself. Only add-ons you trust should be configured.

## Install via sideload

1. On the Roku, open **Settings → System → Advanced system settings → Developer mode** (wording may differ by Roku OS), enable the installer, and note the device IP address.
2. Download `stremio-roku-sideload.zip` from the latest successful **Build sideload ZIP** GitHub Actions run, or create it locally with `./scripts/package.sh`.
3. On a computer on the same network, open `http://ROKU-IP` and sign in to the Development Application Installer (`rokudev` and the password you configured on the Roku).
4. Upload `stremio-roku-sideload.zip`.
5. On the Roku app, press `*` to open the menu. Choose **Add Add-on** and enter the full add-on manifest URL. Then return to a title and select it to query playable streams.

## Build locally

```sh
./scripts/package.sh
```

This creates `dist/stremio-roku-sideload.zip`. The ZIP contains the Roku app root files (`manifest`, `source/`, `components/`, and `images/`) and is intended for the Roku Development Application Installer.

## Controls

- Arrow keys: navigate posters.
- OK: open a title or episode.
- `*` (Options): Search, Add Add-on, Movies, or Series.
- Back: return from episodes to the series catalog or stop playback where the Roku Video node allows the event through.

## Technical notes

Catalogs are read from `https://v3-cinemeta.strem.io`. Add-on requests follow the Stremio Add-on Protocol. Network calls run in SceneGraph `Task` nodes to avoid blocking rendering. The package has not been tested on a physical Roku device in this environment; test playback with a compatible direct stream before relying on it.
