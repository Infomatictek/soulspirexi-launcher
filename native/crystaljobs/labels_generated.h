// AUTO-GENERATED FILE — DO NOT EDIT DIRECTLY.
// Source of truth: soulspirexi-src/registry/souls.json
// Registry version: 2026.11.22-foundation (schema 1.0.0)
// Regenerate with: python3 tools/registry_compiler.py --generate --launcher-repo <path>
#pragma once
#include <cstdint>

namespace crystaljobs {
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
                case 2: return full ? "Chi Weaver" : "CWV"; // mnk_healer
                case 3: return full ? "Black Belt" : "BLK"; // mnk_dps
                default: return nullptr;
            }
        case 3: // WHM
            switch (branch) {
                case 1: return full ? "Bishop" : "BSH"; // whm_healer
                case 2: return full ? "Zealot" : "ZEL"; // whm_dps
                case 3: return full ? "Valkyrie" : "VLK"; // whm_support
                default: return nullptr;
            }
        case 4: // BLM
            switch (branch) {
                case 1: return full ? "Astromancer" : "AST"; // blm_dps
                case 2: return full ? "Channeler" : "CHN"; // blm_support
                case 3: return full ? "Necromancer" : "NEC"; // blm_tank
                default: return nullptr;
            }
        case 5: // RDM
            switch (branch) {
                case 1: return full ? "Crimson Duelist" : "DLS"; // rdm_tank
                case 2: return full ? "Royal Tactician" : "RYT"; // rdm_support
                case 3: return full ? "Scarlet Weaver" : "SCW"; // rdm_dps
                default: return nullptr;
            }
        case 6: // THF
            switch (branch) {
                case 1: return full ? "Trickster" : "TRK"; // thf_support
                case 2: return full ? "Bandit" : "BND"; // thf_dps
                case 3: return full ? "Phantom" : "PHN"; // thf_tank
                default: return nullptr;
            }
        case 7: // PLD
            switch (branch) {
                case 1: return full ? "Templar" : "TMP"; // pld_healer
                case 2: return full ? "Aegis Templar" : "DFN"; // pld_tank
                case 3: return full ? "Oathbreaker" : "OTB"; // pld_dps
                default: return nullptr;
            }
        case 8: // DRK
            switch (branch) {
                case 1: return full ? "Reaper" : "RPR"; // drk_dps
                case 2: return full ? "Dreadnought" : "DRN"; // drk_tank
                case 3: return full ? "Scourge" : "SCR"; // drk_support
                default: return nullptr;
            }
        case 9: // BST
            switch (branch) {
                case 1: return full ? "Untamed" : "UNT"; // bst_dps
                case 2: return full ? "Alpha Warden" : "ALW"; // bst_tank
                case 3: return full ? "Beastspeaker" : "BSP"; // bst_support
                default: return nullptr;
            }
        case 10: // BRD
            switch (branch) {
                case 1: return full ? "Adventurer" : "ADV"; // brd_dps
                case 2: return full ? "Musician" : "MUS"; // brd_support
                case 3: return full ? "Minstrel" : "MIN"; // brd_tank
                default: return nullptr;
            }
        case 11: // RNG
            switch (branch) {
                case 1: return full ? "Sniper" : "SNP"; // rng_dps
                case 2: return full ? "Huntsman" : "HNT"; // rng_tank
                case 3: return full ? "Arcane Archer" : "ACA"; // rng_support
                default: return nullptr;
            }
        case 12: // SAM
            switch (branch) {
                case 1: return full ? "Ronin" : "RON"; // sam_tank
                case 2: return full ? "Imperial Archer" : "IMP"; // sam_ranged_dps
                case 3: return full ? "Warlord" : "WRL"; // sam_support
                default: return nullptr;
            }
        case 13: // NIN
            switch (branch) {
                case 1: return full ? "Shinobi" : "KRG"; // nin_dps
                case 2: return full ? "Kagemusha" : "KGM"; // nin_tank
                case 3: return full ? "Nightblade" : "NGB"; // nin_support
                default: return nullptr;
            }
        case 14: // DRG
            switch (branch) {
                case 1: return full ? "Lancer" : "LNC"; // drg_dps
                case 2: return full ? "Skyborn" : "SKY"; // drg_tank
                case 3: return full ? "Wyvernheart" : "WYV"; // drg_healer
                default: return nullptr;
            }
        case 15: // SMN
            switch (branch) {
                case 1: return full ? "Primalist" : "PRM"; // smn_dps
                case 2: return full ? "Celestial" : "CEL"; // smn_healer
                case 3: return full ? "Herald" : "HLD"; // smn_support
                default: return nullptr;
            }
        case 16: // BLU
            switch (branch) {
                case 1: return full ? "Warmage" : "WMG"; // blu_dps
                case 2: return full ? "Magus" : "MAG"; // blu_healer
                case 3: return full ? "Azure Bastion" : "AZB"; // blu_tank
                default: return nullptr;
            }
        case 17: // COR
            switch (branch) {
                case 1: return full ? "Flintlock" : "FLT"; // cor_ranged_dps
                case 2: return full ? "Gambler" : "GMB"; // cor_support
                case 3: return full ? "Buccaneer" : "BUC"; // cor_tank
                default: return nullptr;
            }
        case 18: // PUP
            switch (branch) {
                case 1: return full ? "Vanguard" : "VNG"; // pup_tank
                case 2: return full ? "Animist" : "ANM"; // pup_healer
                case 3: return full ? "Pugilist" : "PGL"; // pup_dps
                default: return nullptr;
            }
        case 19: // DNC
            switch (branch) {
                case 1: return full ? "Vampire" : "VMP"; // dnc_healer
                case 2: return full ? "Bladewheel" : "BLW"; // dnc_dps
                case 3: return full ? "Mirage Sentinel" : "MRS"; // dnc_tank
                default: return nullptr;
            }
        case 20: // SCH
            switch (branch) {
                case 1: return full ? "Medic" : "MDC"; // sch_healer
                case 2: return full ? "Sage" : "SAG"; // sch_dps
                case 3: return full ? "Archivist" : "ARC"; // sch_support
                default: return nullptr;
            }
        case 21: // GEO
            switch (branch) {
                case 1: return full ? "Diviner" : "DIV"; // geo_support
                case 2: return full ? "Verdant" : "VRD"; // geo_healer
                case 3: return full ? "Terramancer" : "TRM"; // geo_dps
                default: return nullptr;
            }
        case 22: // RUN
            switch (branch) {
                case 1: return full ? "Spellblade" : "SPB"; // run_dps
                case 2: return full ? "Lifebinder" : "LFB"; // run_healer
                case 3: return full ? "Inquisitor" : "INQ"; // run_tank
                default: return nullptr;
            }
        default: return nullptr;
    }
}
} // namespace crystaljobs
