# Bundled terminal fonts

The fallback fonts added for terminal glyph coverage are pinned to these
upstream releases. The committed files are the build inputs; the hashes make
source refreshes reviewable.

| Files | Source | SHA-256 |
| --- | --- | --- |
| `fonts/JetBrainsMonoNerdFontMono-Regular.ttf` | Nerd Fonts `v3.4.0`, `JetBrainsMono.tar.xz` | `f01031f40e48dc29e1112e6b0b0450a2c6cd097f3f35cfff05c55cb311f8034c` |
| `fonts/NotoSansJP-Regular.otf` | `notofonts/noto-cjk` commit `f8d157532fbfaeda587e826d4cd5b21a49186f7c` | `dff723ba59d57d136764a04b9b2d03205544f7cd785a711442d6d2d085ac5073` |
| `fonts/NotoSansKR-Regular.otf` | `notofonts/noto-cjk` commit `f8d157532fbfaeda587e826d4cd5b21a49186f7c` | `69975a0ac8472717870aefeab0a4d52739308d90856b9955313b2ad5e0148d68` |

All three use the SIL Open Font License 1.1. The corresponding license texts
are `fonts/OFL-NerdFonts.txt` and `fonts/OFL-NotoCJK.txt`.
