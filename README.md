# Subnautica 2 — Databank Site

Unofficial static site that lets people search and browse the in-game
**Databank** entries (the "Logs" and "Database" tabs in Subnautica 2).

All content is extracted from the game's local files. No game files are
redistributed — only the structured text data the player sees in-game.

## Cheat sheet

```powershell
# Rebuild databank.json + copy referenced textures into docs/images/
./scripts/build_data.ps1 `
    -FModelContent "<FModel Output Dir>\Exports\Subnautica2\Content" `
    -GameRoot      "C:\Program Files (x86)\Steam\steamapps\common\Subnautica 2"

# Serve the site locally (then open http://localhost:8000)
python -m http.server 8000 --directory docs
```

- `-FModelContent` is required — that's where the entry JSONs and texture
  PNGs live. Find the path in FModel under *Settings → General → Output
  Directory*, then append `\Exports\Subnautica2\Content`.
- `-GameRoot` is optional — used only to read `version.json` for the
  "Build CL-…" stamp on the site. Omit it and the stamp is just blank.

After running, build script prints counts so you can sanity-check; anything
missing on the image side gets listed in `docs/missing_images.txt`.

## Layout

```
.
├── .gitignore
├── README.md
├── scripts/
│   └── build_data.ps1    # FModel exports → docs/databank.json
└── docs/                 # What GitHub Pages serves
    ├── index.html
    ├── style.css
    ├── app.js
    ├── databank.json     # Generated; do not edit by hand
    ├── images/           # Generated; copied from FModel export tree
    └── missing_images.txt# Generated; lists textures still to be exported
```

FModel exports (`DatabankEntry/`, raw `.png` textures) and the game's
`version.json` live **outside** the repo — they're gitignored. The build
script reads them via the `-FModelContent` / `-GameRoot` arguments.

## One-time setup

1. **Install FModel** from <https://fmodel.app>.
2. **Get a mappings file (`.usmap`)** that matches the current game version —
   either generated via UE4SS, or grabbed from the FModel Discord / Nexus.
   Point FModel at it: *Settings → General → Local Mappings File*.
3. **Set FModel's Output Directory** (*Settings → General → Output
   Directory*). Remember this path — you pass it to the build script.
4. **Load the Subnautica 2 paks** in FModel:
   `<Steam install>\Subnautica2\Content\Paks`.

## Update workflow (after every game patch)

1. **Re-export entry text** in FModel.
   Right-click `Subnautica2/Content/Data/DatabankEntry` →
   *Save Folder's Packages Properties (.json)*.
   The exports land under
   `<FModel Output Dir>\Exports\Subnautica2\Content\Data\DatabankEntry`.
   Subfolders like `Fauna/`, `Investigations/OpenInvestigations/` etc.
   carry through and are used by the build script.

2. **Re-export entry textures** in FModel — three folders cover ~99% of
   referenced images:

   | Right-click in FModel | What it gives you |
   |---|---|
   | `Subnautica2/Content/UI/` → *Save Folder's Packages Textures* | UI icons, placeholders, Alterra logo |
   | `Subnautica2/Content/Utility/Editor/IconBaker/` → same | Per-creature scan icons (the real art) |
   | `Subnautica2/Content/Prototyping/Void/Textures/` → same | Axum / alien glyph placeholders |

3. **Run the build script** (see [Cheat sheet](#cheat-sheet)). It reads the
   entry JSONs and copies only the referenced textures into `docs/images/`.

4. **(optional) Preview locally** before pushing:

   ```powershell
   python -m http.server 8000 --directory docs
   ```

   Then open <http://localhost:8000>. Stop the server with `Ctrl+C`.

5. **Commit and push.** GitHub Pages picks up `docs/databank.json` and
   `docs/images/` automatically — the site is plain HTML/JS, no build step.

That's the full loop. New logs, renamed entries, new art — all flow through.

## How the build script handles edge cases

- **Section path.** Nested folders are joined with `/` (e.g.
  `Investigations/ClosedInvestigations`) so Open vs Closed Singh stay
  separate sections.
- **ID collisions.** When two entries share an asset name (e.g. the two
  `Singh` investigations), the script appends the parent folder to the ID so
  they remain individually addressable.
- **Images.** `EntryImage.AssetPathName` is translated to a relative PNG
  path under `docs/images/`. The build script copies only the images
  referenced by some entry — the rest of the FModel export tree is left
  alone. Entries whose referenced image isn't on disk render text-only.

## GitHub Pages setup

1. Push this repo to GitHub.
2. Repo → **Settings → Pages**.
3. *Source*: **Deploy from a branch**.
4. *Branch*: `main` (or whatever you push to), **/ folder**: `/docs`.
5. Save. First deploy takes a minute or two; your site appears at
   `https://<your-username>.github.io/<repo-name>/`.

## How the search works

Client-side, via [MiniSearch](https://github.com/lucaong/minisearch) loaded
from a CDN. Title matches are weighted highest, then categories, then body.
Prefix and small-typo (fuzzy) matching are on by default. Quoted `"phrase"`
queries do exact-substring matches across title/body/categories. No server,
no analytics, no tracking.

## Credits & legal

All databank text and images are © Unknown Worlds Entertainment / Krafton.
This site is an unofficial, fan-built reference and is not affiliated with
or endorsed by Unknown Worlds. If you represent Unknown Worlds and would
like this taken down, open an issue.
