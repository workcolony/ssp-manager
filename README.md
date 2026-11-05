# ssp-manager

macOS SwiftUI app to manage the Percussa SSP over SSH (USB-ethernet, key auth).
Companion CLI: `../serendipity-ssp/scripts/ssp`. Spec: `../serendipity-ssp/docs/PATCH-TOOL.md`.

    swift run                    # dev
    ./scripts/make_app.sh        # build/SSPManager.app

## Sections

- **Files** — browse /media/BOOT: navigate, mkdir, rename, upload/download
  (files+dirs), delete→.trash (safe), trash browse/empty.
- **Plugins** — installed .so on card vs local staging dir
  (`Percussa SSP/thirdparty-plugins`); select + install, restart SYNTHOR.
- **Presets** — list .pbp, backup all → Documents, push files back
  (remote snapshot first). .pbp is closed binary — backup/restore only.
- **Device** — host IP, ping, card space, SYNTHOR restart.

Env: host defaults 192.168.1.6, key ~/.ssh/id_ed25519 (already installed on SSP).

## Roadmap

- .pbp decode → real patch editing (see PATCH-TOOL.md notes; TRAX presets
  may be the practical near-term patch vehicle)
- preset naming/organization, patch "recipes"
- Butter sidecar sync (--analyze locally for files lacking sidecars)
