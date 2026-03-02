if !CLIENT || !shaderlib then return end

local pp_ssgi     = CreateClientConVar("pp_ssgi",       "0", true, false, "Enable SSGI", 0, 1)
local pp_ssgi_dbg = CreateClientConVar("pp_ssgi_debug", "0", true, false, "Debug type",  0, 4)

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
                ["Debug: GI層のみ"]  = { [pp_ssgi_dbg:GetName()] = "1" },
                ["Debug: 法線"]      = { [pp_ssgi_dbg:GetName()] = "2" },
                ["Debug: Depth"]     = { [pp_ssgi_dbg:GetName()] = "4" },
            },
            ["CVars"] = { pp_ssgi_dbg:GetName() },
        })
    end,
})

local RT_FLAGS = bit.bor(4, 8, 16, 256, 512, 8388608)
local RT_W     = ScrW() * 0.5
local RT_H     = ScrH() * 0.5

local ssgi_rt_a = GetRenderTargetEx("_rt_SSGI_A", RT_W, RT_H,
    RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE,
    RT_FLAGS, 0, IMAGE_FORMAT_RGBA16161616F)

local ssgi_rt_b = GetRenderTargetEx("_rt_SSGI_B", RT_W, RT_H,
    RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE,
    RT_FLAGS, 0, IMAGE_FORMAT_RGBA16161616F)

local ssgi_mat = CreateMaterial("ssgi_effect", "screenspace_general", {
    ["$pixshader"]              = "ssgi_ps30",
    ["$basetexture"]            = "_rt_FullFrameFB",
    ["$texture1"]               = "_rt_WPDepth",
    ["$texture2"]               = "_rt_NormalsTangents",
    ["$c0_x"]                   = "3.0",
    ["$c0_y"]                   = "0.05",
    ["$c1_x"]                   = "0",
    ["$linearread_basetexture"] = "1",
    ["$linearread_texture1"]    = "1",
    ["$linearread_texture2"]    = "0",
    ["$ignorez"]                = "1",
    ["$vertextransform"]        = "1",
})

local atrous_mat = CreateMaterial("ssgi_atrous", "screenspace_general", {
    ["$pixshader"]              = "ssgi_atrous_ps30",
    ["$basetexture"]            = "_rt_SSGI_A",
    ["$texture1"]               = "_rt_WPDepth",
    ["$texture2"]               = "_rt_NormalsTangents",
    ["$c0_x"]                   = "1.0",
    ["$linearread_basetexture"] = "1",
    ["$linearread_texture1"]    = "1",
    ["$linearread_texture2"]    = "0",
    ["$ignorez"]                = "1",
    ["$vertextransform"]        = "1",
})

local ssgi_composite = CreateMaterial("ssgi_composite", "screenspace_general", {
    ["$pixshader"]              = "ssgi_composite_ps30",
    ["$basetexture"]            = "_rt_FullFrameFB",
    ["$texture1"]               = "_rt_SSGI_A",
    ["$c0_x"]                   = "1.0",  -- 強度を3.0→1.0に下げた
    ["$linearread_basetexture"] = "1",
    ["$linearread_texture1"]    = "1",
    ["$ignorez"]                = "1",
    ["$vertextransform"]        = "1",
})

local ATROUS_PASSES  = 4
local rt_ping_pong   = { ssgi_rt_a, ssgi_rt_b }

local function Draw()
    render.PushRenderTarget(ssgi_rt_a)
        render.Clear(0, 0, 0, 0)
        ssgi_mat:SetInt("$c1_x", pp_ssgi_dbg:GetInt())
        render.SetMaterial(ssgi_mat)
        render.DrawScreenQuad()
    render.PopRenderTarget()

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

    local final_rt = rt_ping_pong[(ATROUS_PASSES % 2) + 1]
    ssgi_composite:SetTexture("$texture1", final_rt)
    render.SetMaterial(ssgi_composite)
    render.DrawScreenQuad()
end

local function EnableSSGI()  hook.Add("PostDrawEffects",    "SSGI_Draw", Draw) end
local function DisableSSGI() hook.Remove("PostDrawEffects", "SSGI_Draw")       end

if pp_ssgi:GetBool() then EnableSSGI() end

cvars.AddChangeCallback(pp_ssgi:GetName(), function(_, _, new)
    if new == "1" then EnableSSGI() else DisableSSGI() end
end, "SSGI_toggle")