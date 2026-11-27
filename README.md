M3U Studio lets you browse, edit, filter, clean, and export large TV/IPTV playlists (even 10,000+ channels) right in your browser. 
Everything is processed locally on your device: your files are never uploaded to any server.

* How to use

### 1. Online (browser)
Open `index.html` (or the GitHub Pages URL). Everything runs 100 % locally in your browser.

### 2. Mode Windows 11 (Without CORS + FFprobe + VLC/MPV direct)
1. Download the repo (Code → Download ZIP) and unzip it.
2. Double click on **`Launch-M3U-Studio.bat`** (automatically open in your favorite browser).
3. *(Optional)* Install FFmpeg to activate the real video test (`ffprobe`) :
   ```powershell
   winget install Gyan.FFmpeg  


* Last update changes
1. Windows Launcher

* Dual User-Agent fallback in the relay: tries `VLC/3.0.20`, and if the server responds with HTTP 400 or 403, automatically retries with a Chrome/Windows browser User-Agent.
* Accurate labeling: in Windows Mode, 400/401/403 codes are displayed as `Refused · HTTP 400` (rather than `Blocked / CORS`, since CORS no longer applies).
* Direct VLC / MPV launch: if `vlc.exe` or `mpv.exe` is detected on your PC, the button changes to `Launch in VLC` (or `MPV`) and opens the channel directly without downloading an `.m3u` file (automatically falling back to `.m3u` otherwise).

2. Automatically integrated ffprobe / FFmpeg option

* At startup, the launcher checks whether `ffprobe.exe` is installed on your PC.
* If detected, a `Real Test (FFprobe)` button appears and becomes active: `Test streams` then analyzes the actual video/audio stream (compatible with http, https, rtmp, rtsp, udp, raw TS, etc.) and displays real stream info (e.g., `Active · 1920×1080 h264`).
* If ffprobe is not yet installed on your PC, everything still works automatically using the improved Option 1. (To install FFmpeg on Windows 11 in 1 command: open Terminal and type `winget install Gyan.FFmpeg`, then restart `Lancer-M3U-Studio.bat`.)
