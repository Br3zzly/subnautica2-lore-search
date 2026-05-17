# Subnautica 2 — Databank Site

Unofficial static site that lets people search and browse the in-game
**Databank** entries (the "Logs" and "Database" tabs in Subnautica 2),
plus **Item Descriptions** (every item's in-game name + description text,
grouped by the same fabricator/builder/processor tabs the game uses).

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

1. **Re-export entry text** in FModel. For complete coverage (including
   dev/WIP prototype entries), right-click `Subnautica2/Content` →
   *Save Folder's Packages Properties (.json)*. The build script walks
   the whole Content tree looking for objects with
   `Type == "UWEDatabankEntry"` (databank pages) and
   `Type == "UWEItemType"` (item descriptions), plus reading
   `Data/CraftingRecipes/` to assemble the fabricator/builder tab
   structure for the Item Descriptions tree. Anything outside
   `Data/DatabankEntry` or `Data/ItemType` is picked up automatically
   and grouped under a separate **Prototypes** root.
   If you only want released content, exporting just
   `Subnautica2/Content/Data/DatabankEntry`,
   `Subnautica2/Content/Data/ItemType`, and
   `Subnautica2/Content/Data/CraftingRecipes` still works.

2. **Re-export entry textures** in FModel — these folders cover ~99% of
   referenced images:

   | Right-click in FModel | What it gives you |
   |---|---|
   | `Subnautica2/Content/UI/` → *Save Folder's Packages Textures* | UI icons, placeholders, Alterra logo |
   | `Subnautica2/Content/Utility/Editor/IconBaker/` → same | Per-creature scan icons + item thumbnails (the real art) |
   | `Subnautica2/Content/Prototyping/Void/Textures/` → same | Axum / alien glyph placeholders |
   | `Subnautica2/Content/Blueprints/UI/Fabricator/Icons/` → same | Tadpole upgrade module icons (used by item descriptions) |

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
- **Prototypes root.** Any `UWEDatabankEntry` or `UWEItemType` found
  outside its respective `Data/DatabankEntry` / `Data/ItemType` root
  gets a synthetic top-level category prepended:
  `Prototypes (DEV/WIP Content - not ingame)`. So dev/test entries are
  visible but segregated from the released tree.
- **Uncategorized root.** Released databank entries with an empty
  `Categories[]` array (some `[PLACEHOLDER]` entries don't have
  categories set yet) land under a synthetic `Uncategorized` root
  rather than rendering as bare leaves at the top of the tree.
- **Item Descriptions root.** Every `UWEItemType` is filed under
  `Item Descriptions`. When the item is the output of a recipe in
  `Data/CraftingRecipes/`, its recipe Category chain becomes the
  sub-tree (e.g. `Fabricator / Sustenance / Cooked Food`). Otherwise
  (raw resources, creatures, deprecated items), the source subfolder
  under `Data/ItemType/` becomes the bucket.
- **Images.** `EntryImage.AssetPathName` (databank) and
  `Thumbnail.AssetPathName` (items) are both translated to relative PNG
  paths under `docs/images/`. The build script copies only the images
  referenced by some entry — the rest of the FModel export tree is left
  alone. Entries whose referenced image isn't on disk render text-only.

## Credits & legal

All databank text and images are © Unknown Worlds Entertainment / Krafton.
This site is an unofficial, fan-built reference and is not affiliated with
or endorsed by Unknown Worlds. If you represent Unknown Worlds and would
like this taken down, open an issue.
