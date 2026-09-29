# Farside social launch kit (source)

Everything in `~/Downloads/farside-social/` is rendered from this folder with headless Google Chrome and ffmpeg. No generative AI, no npm dependencies. Research that shaped the kit: `SOCIAL-RESEARCH.md`.

```bash
bun design/social/render.ts all              # stills, videos, copy, index.html, then verify
bun design/social/render.ts stills post-03   # one still (ids in content.mjs; prefixes work: post, c1, avatar)
bun design/social/render.ts videos v04       # one video + its cover (v04-x is the 16:9 X cut)
bun design/social/render.ts frames v01 0,1.3 # debug PNG frames into $FS_TMP/frames, with safe-zone report
bun design/social/render.ts copy             # copy/*.md + index.html from copy.mjs
bun design/social/render.ts verify           # sizes, codecs, durations, <20 MB, decode, safe zones
```

Env: `FS_OUT` (default `~/Downloads/farside-social`), `FS_TMP` (Chrome profile and debug frames), `FS_JOBS` (parallel pages, default 3), `CHROME`, `FFMPEG`.

| File | What |
|---|---|
| `content.mjs` | Every output: id, size, path, video length and cover frame |
| `copy.mjs` | Bios, handles, captions, hashtags, alt text, sound notes, calendar, launch thread |
| `build-copy.mjs` | Writes the markdown and the contact sheet; checks character limits (X weighted) |
| `stills.html` + `stills*.js` | Avatar, X header, 15 posts, 3 carousels, cheat sheet (one builder per id) |
| `videos/video.html` + `v0*.js` | One deterministic `seek(t)` per video; `?w=1920&h=1080` gives the X layout |
| `lib/farside.js` | Tokens, the 21-reach halftone field, hand, pointer, mark, dither, pairing-code art |
| `lib/fonts/` | Doto, Geist, Geist Mono, Instrument Serif (SIL OFL 1.1, licences alongside) |

Preview in a browser: open `videos/video.html?id=v01` (plays in real time) or `stills.html?id=post-01&w=1080&h=1350`.

Rules the renderer enforces: key video text inside x 65–960, y 270–1440 on 1080×1920 (x 90–1830, y 70–960 on 1920×1080), checked every third frame; frames are captured at 1× with sRGB colour and encoded H.264 High, yuv420p, BT.709, 30 fps, with a silent AAC track.
