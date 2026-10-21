# Stremio Roku Companion

The companion runs on the PC that has access to Stremio's Streaming Server. It serves the Roku app over your home LAN and handles add-on API calls, signed stream proxying, HTTP byte ranges, torrent URLs from the local Streaming Server, and optional FFmpeg HLS transcoding.

## Run

Requirements: Node.js 20+. Optional FFmpeg for torrent transcoding.

- Windows: run `start-windows.bat`.
- Linux: run `sh ./start-linux.sh` or `node server.mjs`.

No npm dependencies are required. Keep the terminal open. The service prints the dashboard address, LAN address, and PIN. Open the dashboard, enter that PIN, configure the Streaming Server URL (default `http://127.0.0.1:11470`), add trusted add-on manifest URLs, and save.

Use the LAN URL + PIN in the Roku app under Options → Connect to PC. Do not use `127.0.0.1` on the Roku: that would refer to the Roku itself, not the PC.

If FFmpeg is installed and HLS transcoding is enabled in the dashboard, torrent sources are converted to HLS for better Roku compatibility. This consumes CPU and disk space. Keep the PC running during playback.

The companion is for a trusted LAN only. Do not expose port 17890 or the Stremio server port to the public internet. Its current implementation is experimental and is not feature-parity with the official Stremio clients.
