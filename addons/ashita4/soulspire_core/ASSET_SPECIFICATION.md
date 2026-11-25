# SoulspireXI Core — UI Art & Asset Specification

This document tracks all visual art assets used by the approved Soulforge visual target presentation layer across `soulspire_core`, `soulspire_talents`, and `crystalsocket`, plus explicit generation specifications for optional future artwork.

---

## 1. Active Reused Assets (Already Shipped in Launcher Manifest)

| Addon | File(s) | Role in SoulspireXI Core |
|---|---|---|
| `soulspire_core` | `assets/soulspire_crest.png` | Top-left brand crest beside `SOULSPIREXI / CORE` |
| `soulspire_talents` | `assets/panel_browser.png` | Textured obsidian/gold backdrop for `ARSENAL` & `SOUL CRYSTALS` rails |
| `soulspire_talents` | `assets/panel_inspector.png` | Textured backdrop for `TALENT DETAILS` & `SOUL INSPECTOR` panels |
| `soulspire_talents` | `assets/ws_1.png`, `assets/ws_47.png` | Evolution Weapon Skill medallions (Combo, Sanguine Blade) |
| `soulspire_talents` | `assets/node_*.png` (20 icons) | Per-node circular medallions inside the Astral Ring & Talent Details |
| `crystalsocket` | `assets/<soul_key>.png` (42+ icons) | Framed Soul Crystal portrait medallions in The Soulforge banner & Character Sanctum |

---

## 2. Newly Added Bespoke Dark-Fantasy Assets (`soulspire_core/assets/`)

All assets are zero-text, D3D8-compatible 8-bit PNGs optimized for Ashita v4 `D3DXCreateTextureFromFileInMemoryEx` (`D3DPOOL_MANAGED`).

| Asset | Resolution | Purpose |
|---|---|---|
| `soulforge_backdrop.png` | `1280x720` | Full-screen dark obsidian cosmic crystal cavern backdrop behind Core modal |
| `soulforge_banner_bg.png` | `1280x240` | Panoramic glowing amethyst crystal peaks & cyan aurora skyline for `THE SOULFORGE`, `SOUL SANCTUM`, and `SOUL TALENTS` banners |
| `soulforge_chamber_center.png` | `960x720` | Symmetrical stone sanctum centerpiece with glowing vertical crystal broadsword, concentric gold Astral Ring, blue pillar braziers, and amethyst altar |
| `character_chamber_bg.png` | `960x720` | Dark-fantasy crystal arch sanctum with glowing violet pedestal aura for Character & Unavailable modules |

---

## 3. Procedural DrawList Art System (`core/foundations.lua`)

Vector primitives that scale cleanly across `1280x720`, `1920x1080`, `2560x1440`, and `3440x1440` with zero texture blur:
- **Ornate Gilded Panel Frames (`F.drawOrnatePanel`)**: Double antique-gold bevels, corner filigree L-brackets, cyan crystal diamond corner studs, and optional texture + scrim compositing.
- **Luminous Active Nav Pill & Gold CTA (`F.drawBeveledPill`, `F.drawBeveledCtaButton`)**: Beveled-hex tabs (Aether Cyan active tab; Antique Gold beveled primary CTA with hold-to-confirm luminous sweep and diamond finials).
- **Circular Talent Medallions (`F.drawNodeMedallion`)**: Path-themed metallic rims (`Offense` crimson/gold, `Mastery` violet/gold, `Utility` aether cyan), lock silhouettes for locked states, cardinal diamond pointers on selected/keystone nodes.
- **3-Layer Glowing Energy Conduits (`F.drawEnergyConduit`)**: Outer aura glow + colored energy core + specular white filament tracing real `reqKey` dependencies.
- **Mastery Diamond Sockets & Crystal Star (`F.drawDiamondSocket`, `F.drawCrystalStar`)**: 45° rotated mastery sockets and 8-point glowing Talent Points star.
- **Weapon Category Icons (`F.drawWeaponIcon`)**: Circular gilded weapon-family filter icons in the Arsenal bar.

---

## 4. Explicit Asset Specification List for Future Artwork Generation

These optional artwork packs can be generated later with Gemini/Antigravity and dropped directly into the existing asset folders with **zero Lua code changes** (both `art.lua` and `core/assets.lua` resolve them dynamically by ID/key):

1. **Per-Weapon-Skill Medallions (`soulspire_talents/assets/ws_<wsId>.png`)**
   - **Size / Format:** `128x128` RGBA PNG, transparent or circular dark-obsidian inset, zero text.
   - **Style:** Painterly dark-fantasy RPG skill icon matching FFXI weapon skills (e.g., `ws_42.png` Savage Blade crimson/gold diagonal slash, `ws_34.png` Red Lotus Blade magenta flame lotus, `ws_40.png` Vorpal Blade electric cyan arcs, `ws_41.png` Swift Blade radiant steel slashes, `ws_37.png` Seraph Blade golden light).
   - **Priority:** Top 25 most-used Lv.75 Weapon Skills first.

2. **Per-Node Talent Emblems (`soulspire_talents/assets/node_<nodeKey>.png`)**
   - **Size / Format:** `128x128` RGBA PNG, circular silhouette safe for 68% inset inside `F.drawNodeMedallion`, zero text.
   - **Style:** High-contrast crimson/gold (Offense), amethyst/gold (Mastery), or cyan/silver (Utility) rune/weapon sigils.

3. **Job / Archetype Banner Portraits (`soulspire_core/assets/job_<jobKey>.png`)**
   - **Size / Format:** `256x256` RGBA PNG, circular/bust portrait framed for the upper-left banner medallion, zero text.
   - **Style:** Semi-realistic dark-fantasy RPG job portrait with cool blue/violet rim lighting matching the approved Soulforge banner.

4. **9-Slice Ornate Corner Filigree Overlays (`soulspire_core/assets/frame_corner_gold.png`)**
   - **Size / Format:** `128x128` RGBA PNG with transparent background, antique hammered gold scrollwork + sapphire jewel stud.
   - **Purpose:** Optional high-detail replacement for procedural corner filigree brackets on high-DPI 1440p/4K displays.
