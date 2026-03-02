if !CLIENT || !shaderlib then return end

-- ============================================================
--  ConVars
-- ============================================================
local pp_ssgi     = CreateClientConVar("pp_ssgi",       "0", true, false, "Enable SSGI", 0, 1)
local pp_ssgi_dbg = CreateClientConVar("pp_ssgi_debug", "0", true, false, "Debug type",  0, 4)

-- ============================================================
--  PostProcess メニュー登録
-- ============================================================
list.Set("PostProcess", "SSGI", {
    ["icon"]     = "gui/postprocess/ssgi.jpg",
    ["convar"]   = pp_ssgi:GetName(),
    ["category"] = "#shaders_pp",
    ["cpanel"]   = function(panel)
        panel:AddControl("CheckBox", { Label = "Enable SSGI", Command = pp_ssgi:GetName() })
        panel:AddControl("ComboBox", {
            ["MenuButton"] = 1,
            ["Folder"]     = "SSGI",
            ["Options"] = {
                ["通常 (SSGI)"]      = { [pp_ssgi_dbg:GetName()] = "0" },
                -- ["Debug: GI層のみ"]  = { [pp_ssgi_dbg:GetName()] = "1" },
                -- ["Debug: 法線"]      = { [pp_ssgi_dbg:GetName()] = "2" },
                -- ["Debug: geo範囲"]   = { [pp_ssgi_dbg:GetName()] = "3" },
                -- ["Debug: Depth差分"] = { [pp_ssgi_dbg:GetName()] = "4" },
            },
            ["CVars"] = { pp_ssgi_dbg:GetName() },
        })
    end,
})

-- ============================================================
--  レンダーターゲット（半解像度 × RGBA16F）
-- ============================================================
local RT_FLAGS = bit.bor(4, 8, 16, 256, 512, 8388608)
local RT_W     = ScrW() * 0.5
local RT_H     = ScrH() * 0.5

local ssgi_rt_a = GetRenderTargetEx("_rt_SSGI_A", RT_W, RT_H,
    RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE,
    RT_FLAGS, 0, IMAGE_FORMAT_RGBA16161616F)

local ssgi_rt_b = GetRenderTargetEx("_rt_SSGI_B", RT_W, RT_H,
    RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE,
    RT_FLAGS, 0, IMAGE_FORMAT_RGBA16161616F)

-- ============================================================
--  マテリアル
-- ============================================================

-- 1) GI 本体シェーダー
local ssgi_mat = CreateMaterial("ssgi_effect", "screenspace_general", {
    ["$pixshader"]              = "ssgi_ps20b",
    ["$basetexture"]            = "_rt_FullFrameFB",   -- s0: 光源色
    ["$texture1"]               = "_rt_WPDepth",       -- s1: ワールド座標 + 深度
    ["$texture2"]               = "_rt_NormalsTangents", -- s2: 法線
    ["$c0_x"]                   = "3.0",   -- サンプル半径
    ["$c0_y"]                   = "0.05",  -- 深度バイアス
    ["$c1_x"]                   = "0",     -- デバッグタイプ（後でConVarと連動させる）
    ["$linearread_basetexture"] = "1",
    ["$linearread_texture1"]    = "1",
    ["$linearread_texture2"]    = "0",
    ["$ignorez"]                = "1",
    ["$vertextransform"]        = "1",
})

-- 2) À-Trous デノイザー
local atrous_mat = CreateMaterial("ssgi_atrous", "screenspace_general", {
    ["$pixshader"]              = "ssgi_atrous_ps20b",
    ["$basetexture"]            = "_rt_SSGI_A",         -- s0: GI入力（動的に差し替え）
    ["$texture1"]               = "_rt_WPDepth",        -- s1: エッジ停止用 depth
    ["$texture2"]               = "_rt_NormalsTangents", -- s2: エッジ停止用 法線
    ["$c0_x"]                   = "1.0",   -- stepWidth（パスごとに更新）
    ["$linearread_basetexture"] = "1",
    ["$linearread_texture1"]    = "1",
    ["$linearread_texture2"]    = "0",
    ["$ignorez"]                = "1",
    ["$vertextransform"]        = "1",
})

-- 3) 合成シェーダー
local ssgi_composite = CreateMaterial("ssgi_composite", "screenspace_general", {
    ["$pixshader"]              = "ssgi_composite_ps20b",
    ["$basetexture"]            = "_rt_FullFrameFB",   -- s0: 元画像
    ["$texture1"]               = "_rt_SSGI_A",        -- s1: デノイズ済みGI（動的に差し替え）
    ["$c0_x"]                   = "3.0",   -- GI強度
    ["$linearread_basetexture"] = "1",
    ["$linearread_texture1"]    = "1",
    ["$ignorez"]                = "1",
    ["$vertextransform"]        = "1",
})

-- ============================================================
--  描画ループ
-- ============================================================
local ATROUS_PASSES = 4  -- 増やすほど滑らか、重くなる

local rt_ping_pong = { ssgi_rt_a, ssgi_rt_b }

local function Draw()
    -- ① 生SSGIを rt_a に書く
    render.PushRenderTarget(ssgi_rt_a)
        render.Clear(0, 0, 0, 0)
        ssgi_mat:SetInt("$c1_x", pp_ssgi_dbg:GetInt())  -- デバッグモード反映
        render.SetMaterial(ssgi_mat)
        render.DrawScreenQuad()
    render.PopRenderTarget()

    -- ② À-Trous デノイズ（ping-pong）
    local stepWidth = 1.0
    for i = 1, ATROUS_PASSES do
        local src = rt_ping_pong[((i - 1) % 2) + 1]
        local dst = rt_ping_pong[(      i  % 2) + 1]

        atrous_mat:SetTexture("$basetexture", src)
        atrous_mat:SetFloat("$c0_x", stepWidth)

        render.PushRenderTarget(dst)
            render.Clear(0, 0, 0, 0)
            render.SetMaterial(atrous_mat)
            render.DrawScreenQuad()
        render.PopRenderTarget()

        stepWidth = stepWidth * 2.0
    end

    -- ③ 合成（最終パスの出力RTを使う）
    local final_rt = rt_ping_pong[(ATROUS_PASSES % 2) + 1]
    ssgi_composite:SetTexture("$texture1", final_rt)
    render.SetMaterial(ssgi_composite)
    render.DrawScreenQuad()
end

-- ============================================================
--  有効化 / 無効化
-- ============================================================
local function EnableSSGI()  hook.Add("PostDrawEffects",    "SSGI_Draw", Draw) end
local function DisableSSGI() hook.Remove("PostDrawEffects", "SSGI_Draw")       end

if pp_ssgi:GetBool() then EnableSSGI() end

cvars.AddChangeCallback(pp_ssgi:GetName(), function(_, _, new)
    if new == "1" then EnableSSGI() else DisableSSGI() end
end, "SSGI_toggle")