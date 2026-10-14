# QFXBeggar

World of Warcraft Retail addon for Encounter Journal gear wishlists and configurable Mythic+ and raid loot requests.

Current addon version: **1.0.26**. Interface: **12.1.5** (`120105`).

- Track desired items in the native Encounter Journal.
- Configure Mythic+ wishlist, item-level upgrade and raid wishlist whisper rules independently.
- Preserve separate Mythic+ and raid whisper templates.
- Respect account chat restrictions, combat chat lockdown and secret values.
- Keep the addon's own character SavedVariables and standalone feature windows.

Install this repository's runtime files under `Interface/AddOns/QFXBeggar/`. Open the addon with `/beggar` or `/qfxbeggar`.

中文功能说明与命令见 [README.txt](README.txt)。

This repository contains addon source only. Existing local release snapshots and source artwork are kept outside the repository. Creating the repository does not change the addon version.

## Releases

Push a numeric X.Y.Z tag matching QFXBeggar.toc to validate Lua and chat safety, then publish QFXBeggar_X.Y.Z.zip to GitHub and CurseForge project 1679863. The repository secret is CF_API_TOKEN. Tests and developer files are excluded from the ZIP.
