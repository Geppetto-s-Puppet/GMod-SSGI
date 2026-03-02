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
                ["通常 (SSGI)"]          = { [pp_ssgi_dbg:GetName()] = "0" },
                -- ["Debug: GI層のみ"]      = { [pp_ssgi_dbg:GetName()] = "1" },
                -- ["Debug: 法線"]          = { [pp_ssgi_dbg:GetName()] = "2" },
                -- ["Debug: geo範囲"]       = { [pp_ssgi_dbg:GetName()] = "3" },
                -- ["Debug: Depth差分"]     = { [pp_ssgi_dbg:GetName()] = "4" },
            },
            ["CVars"] = { pp_ssgi_dbg:GetName() },
        })
    end,
})

local ssgi_mat = CreateMaterial("ssgi_effect", "screenspace_general", {
    ["$pixshader"]              = "ssgi_ps20b",
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

local ssgi_composite = CreateMaterial("ssgi_composite", "screenspace_general", {
    ["$pixshader"]           = "ssgi_composite_ps20b",
    ["$basetexture"]         = "_rt_FullFrameFB",
    ["$texture1"]            = "_rt_SSGI",
    ["$c0_x"]                = "3.0",  -- intensity
    ["$linearread_basetexture"] = "1",
    ["$linearread_texture1"]    = "1",
    ["$ignorez"]             = "1",
    ["$vertextransform"]     = "1",
})

local ssgi_rt = GetRenderTargetEx("_rt_SSGI", ScrW()*0.5, ScrH()*0.5,
    RT_SIZE_LITERAL,
    MATERIAL_RT_DEPTH_NONE,
    bit.bor(4,8,16,256,512,8388608),
    0,
    IMAGE_FORMAT_RGBA16161616F
)

local function Draw()
    render.PushRenderTarget(ssgi_rt)
    render.Clear(0,0,0,0)
    render.SetMaterial(ssgi_mat)
    render.DrawScreenQuad()
    render.PopRenderTarget()

    render.SetMaterial(ssgi_composite)
    render.DrawScreenQuad()
end

local function EnableSSGI()  hook.Add("PostDrawEffects",    "SSGI_Draw", Draw) end
local function DisableSSGI() hook.Remove("PostDrawEffects", "SSGI_Draw")       end

if pp_ssgi:GetBool() then EnableSSGI() end

cvars.AddChangeCallback(pp_ssgi:GetName(), function(_, _, new)
    if new == "1" then EnableSSGI() else DisableSSGI() end
end, "SSGI_toggle")