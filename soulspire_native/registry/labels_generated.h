// AUTO-GENERATED FILE — DO NOT EDIT DIRECTLY.
// Source of truth: soulspirexi-src/registry/souls.json
// Registry version: 2026.11.22-66-souls-approved (schema 1.0.0, hash cf86aa59ff8d16c6)
// Regenerate with: python3 tools/registry_compiler.py --generate --launcher-repo <path>
#pragma once
#include <cstdint>

namespace soulspire::native {
constexpr const char* kRegistryHash = "cf86aa59ff8d16c6";
inline const char* generated_label_for(uint8_t job, uint8_t branch, bool full = false) noexcept {
    switch (job) {
        case 1: // WAR
            switch (branch) {
                case 1: return full ? "Commander" : "CDR"; // war_support
                case 2: return full ? "Berserker" : "BRZ"; // war_dps
                case 3: return full ? "Spartan" : "SPT"; // war_tank
                default: return nullptr;
            }
        case 2: // MNK
            switch (branch) {
                case 1: return full ? "Sensei" : "SEN"; // mnk_tank
                case 2: return full ? "Stillwater" : "STW"; // mnk_healer
                case 3: return full ? "Wayfarer" : "WAY"; // mnk_dps
                default: return nullptr;
            }
        case 3: // WHM
            switch (branch) {
                case 1: return full ? "Bishop" : "BSP"; // whm_healer
                case 2: return full ? "Penitent" : "PEN"; // whm_dps
                case 3: return full ? "Intercessor" : "INC"; // whm_support
                default: return nullptr;
            }
        case 4: // BLM
            switch (branch) {
                case 1: return full ? "Goetist" : "GOE"; // blm_dps
                case 2: return full ? "Channeler" : "CNL"; // blm_support
                case 3: return full ? "Necromancer" : "NEC"; // blm_tank
                default: return nullptr;
            }
        case 5: // RDM
            switch (branch) {
                case 1: return full ? "Thornveil" : "TVL"; // rdm_tank
                case 2: return full ? "Arbiter" : "ARB"; // rdm_support
                case 3: return full ? "Conflux" : "CFL"; // rdm_dps
                default: return nullptr;
            }
        case 6: // THF
            switch (branch) {
                case 1: return full ? "Trickster" : "TRK"; // thf_support
                case 2: return full ? "Opportunist" : "OPP"; // thf_dps
                case 3: return full ? "Phantom" : "PTM"; // thf_tank
                default: return nullptr;
            }
        case 7: // PLD
            switch (branch) {
                case 1: return full ? "Lightkeeper" : "LTK"; // pld_healer
                case 2: return full ? "Martyr" : "MRT"; // pld_tank
                case 3: return full ? "Oathbreaker" : "OTB"; // pld_dps
                default: return nullptr;
            }
        case 8: // DRK
            switch (branch) {
                case 1: return full ? "Harbinger" : "HRB"; // drk_dps
                case 2: return full ? "Dreadnought" : "DRN"; // drk_tank
                case 3: return full ? "Maleficar" : "MLF"; // drk_support
                default: return nullptr;
            }
        case 9: // BST
            switch (branch) {
                case 1: return full ? "Packmate" : "PKM"; // bst_dps
                case 2: return full ? "Alpha Warden" : "ALW"; // bst_tank
                case 3: return full ? "Wildsavant" : "WSV"; // bst_support
                default: return nullptr;
            }
        case 10: // BRD
            switch (branch) {
                case 1: return full ? "Skald" : "SKL"; // brd_dps
                case 2: return full ? "Cantor" : "CNT"; // brd_support
                case 3: return full ? "Provocateur" : "PRV"; // brd_tank
                default: return nullptr;
            }
        case 11: // RNG
            switch (branch) {
                case 1: return full ? "Sniper" : "SNP"; // rng_dps
                case 2: return full ? "Fangbound" : "FGB"; // rng_tank
                case 3: return full ? "Spellfletcher" : "SFL"; // rng_support
                default: return nullptr;
            }
        case 12: // SAM
            switch (branch) {
                case 1: return full ? "Ronin" : "RON"; // sam_tank
                case 2: return full ? "Amatsu" : "AMT"; // sam_ranged_dps
                case 3: return full ? "Kensei" : "KEN"; // sam_support
                default: return nullptr;
            }
        case 13: // NIN
            switch (branch) {
                case 1: return full ? "Shinobi" : "SNI"; // nin_dps
                case 2: return full ? "Kagemusha" : "KGM"; // nin_tank
                case 3: return full ? "Fuin" : "FUI"; // nin_support
                default: return nullptr;
            }
        case 14: // DRG
            switch (branch) {
                case 1: return full ? "Highlancer" : "HLC"; // drg_dps
                case 2: return full ? "Drachenward" : "DRW"; // drg_tank
                case 3: return full ? "Wyvernheart" : "WYV"; // drg_healer
                default: return nullptr;
            }
        case 15: // SMN
            switch (branch) {
                case 1: return full ? "Eidolarch" : "EID"; // smn_dps
                case 2: return full ? "Celestial" : "CEL"; // smn_healer
                case 3: return full ? "Accordant" : "ACD"; // smn_support
                default: return nullptr;
            }
        case 16: // BLU
            switch (branch) {
                case 1: return full ? "Assimilator" : "ASM"; // blu_dps
                case 2: return full ? "Magus" : "MAG"; // blu_healer
                case 3: return full ? "Chrysalis" : "CRY"; // blu_tank
                default: return nullptr;
            }
        case 17: // COR
            switch (branch) {
                case 1: return full ? "Flintlock" : "FLT"; // cor_ranged_dps
                case 2: return full ? "Gambler" : "GMB"; // cor_support
                case 3: return full ? "Blackwake" : "BKW"; // cor_tank
                default: return nullptr;
            }
        case 18: // PUP
            switch (branch) {
                case 1: return full ? "Ironlink" : "IRN"; // pup_tank
                case 2: return full ? "Patchwork" : "PTW"; // pup_healer
                case 3: return full ? "Tandem" : "TDM"; // pup_dps
                default: return nullptr;
            }
        case 19: // DNC
            switch (branch) {
                case 1: return full ? "Revel" : "RVL"; // dnc_healer
                case 2: return full ? "Bladewheel" : "BLW"; // dnc_dps
                case 3: return full ? "Dervish" : "DRV"; // dnc_tank
                default: return nullptr;
            }
        case 20: // SCH
            switch (branch) {
                case 1: return full ? "Chirurgeon" : "CRG"; // sch_healer
                case 2: return full ? "Heliarch" : "HEL"; // sch_dps
                case 3: return full ? "Archivist" : "ARC"; // sch_support
                default: return nullptr;
            }
        case 21: // GEO
            switch (branch) {
                case 1: return full ? "Meridian" : "MRD"; // geo_support
                case 2: return full ? "Verdant" : "VRD"; // geo_healer
                case 3: return full ? "Seismancer" : "SEI"; // geo_dps
                default: return nullptr;
            }
        case 22: // RUN
            switch (branch) {
                case 1: return full ? "Spellblade" : "SPB"; // run_dps
                case 2: return full ? "Lifebinder" : "LFB"; // run_healer
                case 3: return full ? "Runeweft" : "RNW"; // run_tank
                default: return nullptr;
            }
        default: return nullptr;
    }
}
} // namespace soulspire::native
