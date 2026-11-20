# Embedded components

Forever Dual Gathering includes the following library components or compatible implementations. The original addon license does not override third-party terms.

- **LibStub**: Public domain, as stated in the embedded source. Credits: Kaelten, Cladhaire, ckknight, Mikk, Ammo, Nevcairiel, and joshborke. Project: https://www.wowace.com/projects/libstub
- **CallbackHandler-1.0**: Callback-handling API from the WowAce library ecosystem. Upstream project and license: https://www.curseforge.com/wow/addons/callbackhandler
- **LibDataBroker-1.1**: Data-broker library by Tekkub and contributors. Upstream source and documentation: https://github.com/tekkub/libdatabroker-1-1
- **LibDBIcon-1.0**: The embedded source describes itself as a compatible minimap display following the established LibDBIcon convention. Upstream API/project: https://www.wowace.com/projects/libdbicon-1-0

- **LibDeflate 1.0.2-release**: Lossless zlib/DEFLATE decompression by Haoqian He. zlib License; full license is bundled at `Libs/LibDeflate/LICENSE.txt`. Unmodified upstream source pinned to commit `afc3b78d12fb3bcfa6b21e5332031ad3d7572e19`. Project: https://github.com/SafeteeWoW/LibDeflate

Gathering-node icons are referenced from the client's existing icon assets; Blizzard icon artwork is not bundled in this addon. The custom gathering logo's creation prompt is retained in `Media/GatheringIcon.prompt.txt` in the development folder.

Localized game-object name metadata was cross-checked against the GatherMate2 1.52.3 release and corroborating GatherLite/Gatherer name tables. Only relevant game-label facts are mapped to FDG's existing resource identities; no third-party addon implementation, artwork or skill assumptions are bundled by those label mappings. Sources: https://github.com/Nevcairiel/GatherMate2/releases/tag/1.52.3 , https://github.com/wuild/gatherlite , https://github.com/XiconQoo/Gatherer-TBC-FarmHud-Compatible . Per-alias research provenance is retained in the development evidence.

Additional exact node-label metadata was cross-checked against Krelock/NodeSight locale tables at commit aa31cad96db1b44561a0b27b3f8e6b883775149a: https://github.com/Krelock/NodeSight/tree/aa31cad96db1b44561a0b27b3f8e6b883775149a/Locales . Only relevant HERBS/ORE/TREASURE label facts are included. Its explicitly unconfirmed ITEM_HERBS entries, implementation, suffix classifiers, artwork, learning logic and location data are not bundled. NodeSight attributes its locale labels to Wowhead's Forever object lists; live-client confirmation remains pending.

FDG callback and minimap subsets use addon-specific LibStub identities and do not replace the shared CallbackHandler or LibDBIcon libraries. The standard LibDataBroker identity remains available for launcher displays. Research/WorldMap/CallbackHandler-1.0.lua is an unmodified OpenMap-bundled test dependency (revision 25); it is not packaged.

Imported herb/ore placement hints are converted from the Forever tables in **GatherMate2 Data Wowhead**, Martin Hagström (Marrtin), commit `d3138e979d91b45a13a75a0863c012c46efab6b5`. Source: https://gitlab.com/marhag87/gathermate2_data_wowhead . Upstream WTFPL v2 license is preserved verbatim in ImportedNodeLocations.lua. These Wowhead-derived coordinates are candidate locations, not measured centres or current spawn information. Conversion hashes and counts are retained in Evidence/ImportedNodeHints/conversion.json.

## OpenMap terrain tile metadata

`TerrainTiles.lua` adapts `OpenMap/Data/Forever/Minimap.lua` from https://github.com/openmap-world/openmap (exact commit in its header). Copyright and the complete MIT license are preserved in that file. Tile coordinate conventions were cross-checked against OpenMap's `Map/Close.lua`. Terrain textures remain Blizzard artwork loaded from the game; no terrain images are bundled. OpenMap is not required or modified.

`TerrainCaveTiles.lua` adapts OpenMap/Data/Forever/CaveMinimap.lua at commit `cea294cd7be86bc0bbedc078cdb48aa4b683bfef` under the complete MIT license preserved in its header. This contains WMO cave bounds, client texture IDs and transforms; no cave artwork is bundled.
