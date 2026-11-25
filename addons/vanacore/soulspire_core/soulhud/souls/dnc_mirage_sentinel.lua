-- DNC Mirage Sentinel Soul Registration
return function(registry)
    registry.registerSoul({
        key         = 'mirage_sentinel',
        name        = 'Mirage Sentinel',
        jobId       = 19,
        jobAbr      = 'DNC',
        branchId    = 2,
        accentColor = 0xFFDD88CC, -- Rose/Violet ABGR
        resources   = {
            {
                id            = 'finishing_moves',
                label         = 'Finishing Moves',
                shortLabel    = 'FM',
                type          = 'stack',
                style         = 'segmented',
                min           = 0,
                max           = 5,
                serverKey     = 'fm',
                builder       = 'Steps / Parry',
                spender       = 'Flourishes',
                warnThreshold = 0,
                warnMode      = 'low',
                color         = 0xFFDD88CC,
                warnColor     = 0xFF5566EE,
                compact       = true,
            },
            {
                id         = 'fan_dance_dt',
                label      = 'Fan Dance Mitigation',
                shortLabel = 'Fan DT',
                type       = 'gauge',
                style      = 'bar',
                min        = 0,
                max        = 45,
                serverKey  = 'fan_dt',
                activeKey  = 'fan_act',
                format     = function(st)
                    return st.active and string.format('-%d%% DT', st.current or 0) or 'Inactive'
                end,
                color      = 0xFF66CC77,
                compact    = true,
            },
            {
                id         = 'fan_dance_state',
                label      = 'Fan Dance Timer',
                shortLabel = 'FanDance',
                type       = 'timer',
                style      = 'pill',
                duration   = 300,
                activeKey  = 'fan_act',
                timerKey   = 'fan_rem',
                recastId   = 224,
                format     = function(st)
                    if st.active then
                        return (st.remaining or 0) > 0 and string.format('Active (%ds)', math.ceil(st.remaining)) or 'Active'
                    end
                    return (st.remaining or 0) > 0 and string.format('CD %ds', math.ceil(st.remaining)) or 'Ready'
                end,
                color      = 0xFF66CC77,
                compact    = true,
            },
            {
                id         = 'pirouette_deflect',
                label      = 'Pirouette Deflect',
                shortLabel = 'Pirouette',
                type       = 'cooldown',
                style      = 'radial',
                duration   = 20,
                recastId   = 152,
                subKey     = 'issek_rem',
                format     = function(st)
                    local issek = tonumber(st.subValue) or 0
                    if issek > 0 then
                        return string.format('PARRY %ds', math.ceil(issek))
                    end
                    if (st.remaining or 0) > 0 then
                        return string.format('%ds', math.ceil(st.remaining))
                    end
                    return 'READY'
                end,
                color      = 0xFF44BBEE,
                compact    = true,
            },
            {
                id         = 'parry_fm',
                label      = 'Parry FMs Earned',
                shortLabel = 'Parry FM',
                type       = 'counter',
                style      = 'numeric',
                serverKey  = 'parry_fm',
                format     = function(st) return string.format('+%d FM', st.current or 0) end,
                color      = 0xFFD9C38C,
                compact    = false,
            },
            {
                id         = 'flourish_shield',
                label      = 'Aegis Waltz Shield',
                shortLabel = 'Shield',
                type       = 'gauge',
                style      = 'bar',
                min        = 0,
                max        = 1000,
                serverKey  = 'aegis_hp',
                timerKey   = 'aegis_rem',
                recastId   = 221,
                format     = function(st)
                    local hp = tonumber(st.current) or 0
                    local rem = tonumber(st.remaining) or 0
                    if hp > 0 and rem > 0 then
                        return string.format('%d HP (%ds)', hp, math.ceil(rem))
                    end
                    return st.ready and 'Flourish Ready' or 'Flourish CD'
                end,
                color      = 0xFFE0B060,
                compact    = true,
            },
        },
    })
end
