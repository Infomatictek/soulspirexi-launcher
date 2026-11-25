-- COR Gambler Soul Registration
return function(registry)
    local CARD_TYPES = {
        [0] = 'None',
        [1] = 'Fire',
        [2] = 'Ice',
        [3] = 'Wind',
        [4] = 'Earth',
        [5] = 'Thunder',
        [6] = 'Water',
        [7] = 'Light',
        [8] = 'Dark',
    }

    registry.registerSoul({
        key         = 'gambler',
        name        = 'Gambler',
        jobId       = 17,
        jobAbr      = 'COR',
        branchId    = 2,
        accentColor = 0xFFD9C38C, -- Gold ABGR
        resources   = {
            {
                id         = 'active_rolls',
                label      = 'Phantom Rolls',
                shortLabel = 'Rolls',
                type       = 'stack',
                style      = 'segmented',
                min        = 0,
                max        = 3,
                serverKey  = 'rolls',
                color      = 0xFFD9C38C,
                compact    = true,
            },
            {
                id         = 'roll_state',
                label      = 'Current Roll',
                shortLabel = 'Roll',
                type       = 'combo',
                style      = 'pill',
                serverKey  = 'roll_tot',
                timerKey   = 'du_rem',
                subKey     = 'roll_lock',
                duration   = 45,
                color      = 0xFF66CC77,
                warnColor  = 0xFF5566EE,
                warnWhen   = function(_, st) return (tonumber(st.subValue) or 0) > 0 end,
                format     = function(st)
                    local lock = tonumber(st.subValue) or 0
                    if lock > 0 then
                        return string.format('LOCK %ds', math.ceil(lock))
                    end
                    local tot = tonumber(st.current) or 0
                    local rem = tonumber(st.remaining) or 0
                    if tot > 0 and rem > 0 then
                        return string.format('Roll %d (%ds)', tot, math.ceil(rem))
                    end
                    return 'Idle'
                end,
                compact    = true,
            },
            {
                id          = 'overdrive',
                label       = 'Lucky/XI Overdrive',
                shortLabel  = 'Overdrive',
                type        = 'toggle',
                style       = 'badge',
                serverKey   = 'overdrive',
                visibleWhen = function(_, st) return st.active == true end,
                color       = 0xFF22D4FF,
                format      = function(st) return st.active and '150% OVERDRIVE' or 'Normal' end,
                compact     = true,
            },
            {
                id         = 'ante',
                label      = 'Ante Wager',
                shortLabel = 'Ante',
                type       = 'counter',
                style      = 'pill',
                min        = 0,
                max        = 10,
                mapValue   = function(st, kv)
                    st.current = tonumber(kv.ante_n) or 0
                    st.anteHp  = tonumber(kv.ante_hp) or 0
                    st.anteTp  = tonumber(kv.ante_tp) or 0
                    st.active  = st.current > 0
                end,
                format     = function(st)
                    if (st.current or 0) <= 0 then
                        return '0x (0 HP / 0 TP)'
                    end
                    return string.format('%dx (%d HP / %d TP)', st.current, st.anteHp or 0, st.anteTp or 0)
                end,
                color      = 0xFFE0B060,
                compact    = true,
            },
            {
                id          = 'house_debt',
                label       = 'House Debt',
                shortLabel  = 'Debt',
                type        = 'timer',
                style       = 'pill',
                duration    = 12,
                timerKey    = 'debt_rem',
                visibleWhen = function(_, st) return (st.remaining or 0) > 0 end,
                warnMode    = 'active',
                warnWhen    = function(_, st) return (st.remaining or 0) > 0 end,
                color       = 0xFF4455EE,
                warnColor   = 0xFF4455EE,
                compact     = true,
            },
            {
                id          = 'jackpot_cdr',
                label       = 'Jackpot CDR',
                shortLabel  = 'Jackpot',
                type        = 'counter',
                style       = 'numeric',
                serverKey   = 'last_cdr',
                visibleWhen = function(_, st) return (st.current or 0) > 0 end,
                format      = function(st) return string.format('-%ds CD', st.current or 0) end,
                color       = 0xFF66CC77,
                compact     = false,
            },
            {
                id         = 'quick_draw',
                label      = 'Quick Draw',
                shortLabel = 'QD',
                type       = 'charges',
                style      = 'segmented',
                min        = 0,
                max        = 2,
                maxCharges = 2,
                chargeTime = 60,
                recastId   = 195,
                color      = 0xFFD9C38C,
                compact    = true,
            },
            {
                id          = 'deck_manip',
                label       = 'Card Counting',
                shortLabel  = 'Deck',
                type        = 'status',
                style       = 'pill',
                serverKey   = 'cc_type',
                timerKey    = 'cc_rem',
                duration    = 30,
                visibleWhen = function(_, st) return (st.remaining or 0) > 0 or (st.current or 0) > 0 end,
                format      = function(st)
                    local name = CARD_TYPES[tonumber(st.current) or 0] or ('Card #' .. tostring(st.current or 0))
                    if (st.remaining or 0) > 0 then
                        return string.format('%s (%ds)', name, math.ceil(st.remaining))
                    end
                    return name
                end,
                color       = 0xFFDDAA55,
                compact     = true,
            },
            {
                id         = 'snake_eye',
                label      = 'Snake Eye',
                shortLabel = 'SnakeEye',
                type       = 'cooldown',
                style      = 'radial',
                duration   = 300,
                recastId   = 197,
                activeKey  = 'snake_act',
                color      = 0xFF66CC77,
                compact    = true,
            },
            {
                id         = 'fold',
                label      = 'Fold',
                shortLabel = 'Fold',
                type       = 'cooldown',
                style      = 'linear',
                duration   = 20,
                recastId   = 198,
                color      = 0xFFB8A89C,
                compact    = false,
            },
            {
                id         = 'random_deal',
                label      = 'Random Deal',
                shortLabel = 'RndDeal',
                type       = 'cooldown',
                style      = 'linear',
                duration   = 300,
                recastId   = 196,
                color      = 0xFFD9C38C,
                compact    = false,
            },
            {
                id         = 'house_advantage',
                label      = 'House Advantage',
                shortLabel = 'HouseAdv',
                type       = 'cooldown',
                style      = 'linear',
                duration   = 30,
                recastId   = 168,
                color      = 0xFF44BBEE,
                compact    = false,
            },
            {
                id         = 'ace_in_the_hole',
                label      = 'Ace in the Hole',
                shortLabel = 'AceHole',
                type       = 'cooldown',
                style      = 'linear',
                duration   = 25,
                recastId   = 169,
                color      = 0xFF22D4FF,
                compact    = false,
            },
            {
                id         = 'wild_card',
                label      = 'Wild Card',
                shortLabel = 'WildCard',
                type       = 'cooldown',
                style      = 'radial',
                duration   = 3600,
                recastId   = 0,
                color      = 0xFFD9C38C,
                compact    = false,
            },
        },
    })
end
