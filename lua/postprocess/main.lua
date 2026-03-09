
if !CLIENT || !shaderlib then return end -- CTRL+H and change the ID: 0000
local enabled   = CreateClientConVar("pp_0000_enable", "0", true, false, "")
local debugging = CreateClientConVar("pp_0000_debug",  "0", true, false, "")

-- メニュー登録用
list.Set("PostProcess", "シェーダータイトル", {
    ["icon"]     = "gui/postprocess/icon.jpg",
    ["convar"]   = enabled:GetName(),
    ["category"] = "#shaders_pp",
    ["cpanel"]   = function(panel)
        panel:AddControl("CheckBox", {
            Label   = "Enable",
            Command = enabled:GetName(),
        })
        panel:AddControl("ComboBox", {
            ["MenuButton"] = 1,
            ["Folder"]     = "PP_0000",
            ["Options"]    = {
                ["ノーマルモード"] = { [debugging:GetName()] = "0" },
                ["デバッグモード"] = { [debugging:GetName()] = "1" },
            },
            ["CVars"] = { debugging:GetName() },
        })
    end,
})

-- 描画パイプライン
local mat = CreateMaterial("VMT_0000", "screenspace_general", {
    ["$pixshader"]       = "build_single_ps30",
    ["$basetexture"]     = "_rt_FullFrameFB",
    ["$texture1"]        = "_rt_WPDepth",
    ["$texture2"]        = "_rt_NormalsTangents",
    -- ["$c1"]              = "[0 0 0]",
    ["$ignorez"]         = "1",
    ["$vertextransform"] = "1",
})
local function Draw()
    local vel = LocalPlayer():GetVelocity()
    mat:SetFloat("$c1_x", ScrW()); mat:SetFloat("$c1_y", ScrH())
    mat:SetFloat("$c2_x", CurTime()); mat:SetFloat("$c2_y", FrameTime()); mat:SetFloat("$c2_z", debugging:GetInt())
    mat:SetFloat("$c3_x", vel.x); mat:SetFloat("$c3_y", vel.y); mat:SetFloat("$c3_z", vel.z); mat:SetFloat("$c3_w", vel:Length())
    render.UpdateScreenEffectTexture()
    render.SetMaterial(mat)
    render.DrawScreenQuad()
end

-- 初回起動時フック
if enabled:GetBool() then
    hook.Add("PostDrawEffects", "DRAW_0000", Draw)
end

-- 切替コールバック
cvars.AddChangeCallback(enabled:GetName(), function(_, _, new)
    if new == "1" then
        hook.Add("PostDrawEffects", "DRAW_0000", Draw)
    else
        hook.Remove("PostDrawEffects", "DRAW_0000")
    end
end, "TOGGLE_0000")