# Evergreen

Evergreen is a fork of [KOReader](https://github.com/koreader/koreader) for
jailbroken Kindles. It keeps KOReader's reading engine and replaces the parts
you look at most: a home screen, a cover-grid library, and Bookie sync.

## What's different from KOReader

- **Home screen** (`plugins/evergreen.koplugin`): continue reading, recent
  books, and app tiles (Library, Bookie, History, Notes, Terminal, Wi-Fi, SSH…).
  Shown at start and whenever a book is closed.
- **Library**: a paged grid with uniform, crop-filled covers, one type style,
  no paths or folders; filters (All / Reading / Unread / Finished) and sorting
  (Recent / Title / Author).
- **Bookie sync** (`plugins/bookiesync.koplugin`): reading position and
  highlights synced with a self-hosted Bookie server.
- The in-app OTA updater is hidden: updates come through KPM.

Evergreen started from KOReader v2026.07.1 and is developed independently.

## Install (Kindle with KPM)

Type these in the Kindle home-screen search bar:

```
;kpm add-repo https://nolanvo5894.github.io/evergreen/manifest.v2.json
;kpm update
;kpm install evergreen
```

Evergreen installs to `/mnt/us/evergreen` next to (not over) KOReader, and adds
an "Evergreen" item to the Kindle library.

### Boot straight into Evergreen (optional)

`boot/kshell.conf` is an upstart job that launches Evergreen once per boot, with the Amazon framework stopped. It lives on the
read-only root filesystem:

```
mntroot rw && cp kshell.conf /etc/upstart/kshell.conf && mntroot ro
```

Create an empty `NO_AUTOSTART` file at the root of the Kindle's USB drive to
skip it; exiting Evergreen always returns to the Amazon UI.

## Build

```
evergreen/build.py
```

Downloads the official KOReader release named in `BASE`, lays this checkout's
Lua (`frontend/`, `plugins/`, top-level `*.lua`) over it, and writes
`dist/evergreen_<VERSION>_kindlehf.kpkg` plus a ready-to-host KPM repository in
`dist/repo/`. Native code is not rebuilt, so `BASE` must stay the release
Evergreen was forked from.

## Release

Bump `VERSION`, commit, then:

```
evergreen/release.sh
```

It builds on top of the published repository (the `gh-pages` branch, so older
versions stay installable), pushes it, and tags the source `evergreen-v<VERSION>`.
Kindles pick it up with `;kpm update` then `;kpm upgrade`.

## Native engine

Evergreen is developed independently. Its native code (rendering engine and
libraries) is taken unchanged from the KOReader release named in `BASE`; all
Evergreen development happens in the Lua tree.

## License

AGPL-3.0, like KOReader. See `COPYING`.
