# Third-party components

The MIT license at the repository root covers this project's own installer,
wrapper and build scripts. It does not relicense bundled dependencies, the game,
the official launcher, or artwork. Official launcher executables and artwork are
obtained during installation, not included in the distribution.

| Component | Pinned version / source | License |
| --- | --- | --- |
| Wine | CodeWeavers CrossOver 26.3.0 source, wine-11.0 | LGPL-2.1-or-later; individual files retain their notices |
| FineWine patches | `a62d906c18e790acad3603ea639a3baba4e201ad` | Upstream license and individual patch notices |
| DXMT | 0.80 builtin package | MIT (license at this tag) |
| DXMT NGX backport | 0.80 + `50102f994b406f58f56d5d09f2ad20f9b90390a2`, separate `dxmt-metalfx` backend | MIT base; LGPL-2.1-or-later patch; see `licenses/DXMT-NGX-patch.txt` and `licenses/Wine-LGPL-2.1.txt` |
| NVIDIA NVAPI headers | `d08488fcc82eef313b0464db37d2955709691e94`; used to build DXMT's own NVAPI implementation with a local logical GPU query patch | MIT; see `licenses/NVAPI-headers.txt` |
| MoltenVK | 1.4.2, FineWine 1.2.4 patched distribution | Apache-2.0 and incorporated dependency notices |
| KosmicKrisp (experimental) | Sikarugir 20261017 x86_64; Mesa `b23137f730fa90577bcfc7aa12c2a1fc1e49f1c7` | MIT core and individual component licenses; see `licenses/KosmicKrisp/` |
| 7-Zip | 26.04 standalone 7zz, built from source with `DISABLE_RAR_COMPRESS=1`, macOS 14 target | LGPL-2.1-or-later / BSD; see included license |
| GnuTLS, libtasn1, libidn2, libunistring, libiconv, gettext runtime, GMP, Nettle | Versions and hashes in `macports.lock.json` | Applicable LGPL / GPL alternatives; see component sources |
| Brotli, libffi, p11-kit | Versions and hashes in `macports.lock.json` | Permissive licenses |
| FreeType | 2.14.3 | FreeType License or GPL-2.0; acknowledge the FreeType Project |
| SDL2, zlib, libpng | Versions and hashes in `macports.lock.json` | zlib / libpng licenses |
| libpcap, bzip2, Zstandard | Versions and hashes in `macports.lock.json` | BSD-style licenses / applicable alternatives |
| Vulkan loader | 1.4.363.0 | Apache-2.0 |
| CA certificate bundle | curl-ca-bundle 8.23.0 | Certificate data and curl/Mozilla notices |

Runtime dependencies are dynamically linked. Users may replace them; this
project's wrapper adds no restriction on modification or reverse engineering for
debugging modifications to those libraries.

## Source locations and build records

- Wine: https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz
- Local Wine desktop patch: `Patches/wine-session-dock.patch`, applied after FineWine by `swift run zmd-dev wine`; modifications to LGPL-2.1-or-later Wine files retain that license.
- FineWine patch tree: https://github.com/Lunarchy107/Endfield_FineWine/tree/a62d906c18e790acad3603ea639a3baba4e201ad
- DXMT 0.80: https://github.com/3Shain/dxmt/tree/v0.80
- DXMT NGX backport: https://github.com/3Shain/dxmt/pull/235 ; exact patch in `Patches/`, rebuild command `swift run zmd-dev metalfx`, installed module hash in `renderers/dxmt-metalfx/provenance.json`.
- Local NVAPI fix: `Patches/dxmt-nvapi-logical-gpu.patch` (MIT), separate from upstream #235. Header source: https://github.com/NVIDIA/nvapi/tree/d08488fcc82eef313b0464db37d2955709691e94 .
- MoltenVK source and patch commits: see bundled `runtime/renderers/moltenvk/SOURCE.txt` and `provenance.json`.
- KosmicKrisp: pinned binary and build/Mesa commits in `kosmickrisp.lock.json`; sources in `licenses/sources.json`. The Sikarugir build recipe uses the shadexternals Mesa fork. We relocate/sign the binary and reuse our pinned Vulkan loader; runtime hashes are in `renderers/kosmickrisp/provenance.json`. No upstream SDK installer is distributed or required.
- MacPorts package URLs, versions, SHA-256 values: `macports.lock.json`.
- Build tool bottle URLs, versions, SHA-256 values: `dependencies.lock.json`. 7-Zip source URL and SHA-256: `licenses/sources.json`; build recipe: `Sources/Development/Build.swift`.

The package retains the Wine license, MoltenVK notices and component
license texts under `licenses/`. The build retains upstream source inputs and
patches separately. A binary redistribution must preserve applicable notices and
provide the corresponding sources/build materials required by its dependencies.
The CI artifact is not a notarized or officially supported game client.
The signed NGX discovery file is copied locally from the user's installed game
only when selecting MetalFX. It is not included in any distributed artifact.
