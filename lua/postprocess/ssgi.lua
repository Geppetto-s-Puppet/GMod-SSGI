--[[---------------------------------------------------------------------------
    Screen Space Global Illumination for Garry's Mod.

    Pipeline, per frame, driven from PostDrawReconstructionEffects so the
    framebuffer already holds the lit opaque pass:

        1. trace      low res     visibility bitmask horizon search
        2. temporal   low res     reproject last frame through its view-proj
        3. a-trous    low res     N edge avoiding wavelet iterations
        4. composite  full res    joint bilateral upsample + apply
        5. copyz      low res     snapshot depth for next frame's reprojection

    Requires the GShader library for the G-buffer (_rt_WPDepth,
    _rt_NormalsTangents) and its pp_vs30 vertex shader.
---------------------------------------------------------------------------]]

if not CLIENT then return end

local NAME = "SSGI"

local cv = {}
local function Def( key, name, default, min, max, help )
    cv[key] = CreateClientConVar( name, tostring( default ), true, false, help or "", min, max )
    return cv[key]
end

local enabled = Def( "enable", "pp_ssgi", 0, 0, 1, "Enable screen space global illumination." )

Def( "quality",   "pp_ssgi_quality",      2,    1,    4, "1 low, 2 medium, 3 high, 4 ultra." )
Def( "scale",     "pp_ssgi_scale",        1,    0,    2, "Trace resolution. 0 full, 1 half, 2 quarter." )
Def( "radius",    "pp_ssgi_radius",     160,   16, 1024, "Gather radius in world units." )
Def( "maxradius", "pp_ssgi_maxradius", 0.12, 0.02,  0.5, "Gather radius cap, as a fraction of trace height." )
Def( "minradius", "pp_ssgi_minradius",    4,    2,   32, "Gather radius floor in pixels. Keeps distant surfaces from losing the effect entirely." )
Def( "thickness", "pp_ssgi_thickness",   40,    1,  512, "Assumed occluder thickness in world units." )

Def( "gi",     "pp_ssgi_gi",     1.0, 0, 8, "Indirect light intensity." )
Def( "ao",     "pp_ssgi_ao",     1.0, 0, 4, "Occlusion intensity." )
Def( "albedo", "pp_ssgi_albedo", 0.5, 0, 1, "How much the bounce is tinted by the receiving surface." )
Def( "linear", "pp_ssgi_linear",   2, 0, 2, "Gather in linear space. 0 off, 1 on, 2 auto (off under HDR, where the framebuffer is already linear)." )

Def( "temporal",       "pp_ssgi_temporal",          1,     0,   1, "Accumulate over reprojected frames." )
Def( "temporal_alpha", "pp_ssgi_temporal_alpha", 0.08,  0.01,   1, "New frame weight. Lower is smoother and ghosts more." )
Def( "temporal_clamp", "pp_ssgi_temporal_clamp",  2.0,   0.5,   8, "History clamp width in neighbourhood std devs." )
Def( "temporal_tol",   "pp_ssgi_temporal_tol",   0.05, 0.005, 0.5, "Disocclusion depth tolerance, relative." )

Def( "denoise",      "pp_ssgi_denoise",        2,    0,   4, "A-trous iterations." )
Def( "denoise_wide", "pp_ssgi_denoise_wide",   0,    0,   1, "Use the 5x5 kernel instead of 3x3." )
Def( "denoise_z",    "pp_ssgi_denoise_z",    2.0,  0.1,  32, "Denoise depth tolerance." )
Def( "denoise_n",    "pp_ssgi_denoise_n",     32,    1, 256, "Denoise normal tolerance exponent." )
Def( "denoise_l",    "pp_ssgi_denoise_l",    4.0, 0.05,  64, "Denoise luminance tolerance." )

Def( "upsample_z", "pp_ssgi_upsample_z", 1.0, 0.1,  32, "Upsample depth tolerance." )
Def( "upsample_n", "pp_ssgi_upsample_n",  32,   1, 256, "Upsample normal tolerance exponent." )

Def( "ao_lightbias", "pp_ssgi_ao_lightbias", 0.6, 0,  4, "Fade occlusion out on brightly lit pixels. 0 occludes direct light too." )
Def( "split",        "pp_ssgi_split",        0.5, 0,  1, "Divider position for debug view 6." )
Def( "diffgain",     "pp_ssgi_diffgain",      12, 1, 64, "Amplification for debug view 7." )

local debugging = Def( "debug", "pp_ssgi_debug", 0, 0, 8,
    "0 off, 1 GI, 2 AO, 3 GI+AO, 4 normals, 5 depth, 6 A/B split, 7 difference, 8 coverage." )

--[[-------------------------------------------------------------------------
    Menu
---------------------------------------------------------------------------]]

local function Slider( panel, label, key, integer )
    panel:AddControl( "Slider", {
        Label   = label,
        Command = cv[key]:GetName(),
        Min     = tostring( cv[key]:GetMin() ),
        Max     = tostring( cv[key]:GetMax() ),
        Type    = integer and "Integer" or "Float",
        Help    = false,
    } )
end

list.Set( "PostProcess", "Screen Space Global Illumination", {
    icon     = "gui/postprocess/icon.jpg",
    convar   = enabled:GetName(),
    category = "#shaders_pp",
    cpanel   = function( panel )
        panel:Help( "Indirect lighting and occlusion traced against the depth buffer.\nRequires the GShader library." )

        local defaults, names = {}, {}
        for _, c in pairs( cv ) do
            defaults[c:GetName()] = c:GetDefault()
            names[#names + 1] = c:GetName()
        end

        panel:AddControl( "ComboBox", {
            MenuButton = 1,
            Folder     = "ssgi",
            Options    = { ["#preset.default"] = defaults },
            CVars      = names,
        } )

        panel:AddControl( "CheckBox", { Label = "Enable", Command = enabled:GetName() } )

        local quality = panel:AddControl( "combobox", {
            Label   = "Quality",
            Command = cv.quality:GetName(),
            Options = {},
            CVars   = { cv.quality:GetName() },
            Help    = false,
        } )
        quality:AddChoice( "Low (2 slices, 6 steps)",    { [cv.quality:GetName()] = "1" } )
        quality:AddChoice( "Medium (3 slices, 8 steps)", { [cv.quality:GetName()] = "2" } )
        quality:AddChoice( "High (4 slices, 12 steps)",  { [cv.quality:GetName()] = "3" } )
        quality:AddChoice( "Ultra (6 slices, 16 steps)", { [cv.quality:GetName()] = "4" } )
        quality:SetSortItems( false )
        quality:ChooseOptionID( math.Clamp( cv.quality:GetInt(), 1, 4 ) )

        local scale = panel:AddControl( "combobox", {
            Label   = "Trace resolution",
            Command = cv.scale:GetName(),
            Options = {},
            CVars   = { cv.scale:GetName() },
            Help    = false,
        } )
        scale:AddChoice( "Full",    { [cv.scale:GetName()] = "0" } )
        scale:AddChoice( "Half",    { [cv.scale:GetName()] = "1" } )
        scale:AddChoice( "Quarter", { [cv.scale:GetName()] = "2" } )
        scale:SetSortItems( false )
        scale:ChooseOptionID( math.Clamp( cv.scale:GetInt(), 0, 2 ) + 1 )

        panel:Help( "Gather" )
        Slider( panel, "Radius (units)",     "radius" )
        Slider( panel, "Radius cap",         "maxradius" )
        Slider( panel, "Radius floor (px)",  "minradius" )
        Slider( panel, "Occluder thickness", "thickness" )

        panel:Help( "Look" )
        Slider( panel, "GI intensity", "gi" )
        Slider( panel, "AO intensity", "ao" )
        Slider( panel, "Spare lit pixels from AO", "ao_lightbias" )
        Slider( panel, "Colour bleed", "albedo" )
        local lin = panel:AddControl( "combobox", {
            Label   = "Colour space",
            Command = cv.linear:GetName(),
            Options = {},
            CVars   = { cv.linear:GetName() },
            Help    = false,
        } )
        lin:AddChoice( "Auto (recommended)", { [cv.linear:GetName()] = "2" } )
        lin:AddChoice( "Gamma",              { [cv.linear:GetName()] = "0" } )
        lin:AddChoice( "Linear",             { [cv.linear:GetName()] = "1" } )
        lin:SetSortItems( false )

        panel:Help( "Temporal" )
        panel:AddControl( "CheckBox", { Label = "Temporal accumulation", Command = cv.temporal:GetName() } )
        Slider( panel, "New frame weight",        "temporal_alpha" )
        Slider( panel, "History clamp",           "temporal_clamp" )
        Slider( panel, "Disocclusion tolerance",  "temporal_tol" )

        panel:Help( "Denoise" )
        Slider( panel, "A-trous iterations", "denoise", true )
        panel:AddControl( "CheckBox", { Label = "Wide (5x5) kernel", Command = cv.denoise_wide:GetName() } )
        Slider( panel, "Depth tolerance",     "denoise_z" )
        Slider( panel, "Normal tolerance",    "denoise_n" )
        Slider( panel, "Luminance tolerance", "denoise_l" )

        panel:Help( "Upsample" )
        Slider( panel, "Depth tolerance",  "upsample_z" )
        Slider( panel, "Normal tolerance", "upsample_n" )

        panel:Help( "Debug" )
        local dbg = panel:AddControl( "combobox", {
            Label   = "View",
            Command = debugging:GetName(),
            Options = {},
            CVars   = { debugging:GetName() },
            Help    = false,
        } )
        local views = { "Off", "Indirect light", "Occlusion", "Indirect light + occlusion",
                        "World normals", "Linear depth", "A/B split", "Difference (amplified)",
                        "G-buffer coverage" }
        for i, label in ipairs( views ) do
            dbg:AddChoice( label, { [debugging:GetName()] = tostring( i - 1 ) } )
        end
        dbg:SetSortItems( false )
        dbg:ChooseOptionID( math.Clamp( debugging:GetInt(), 0, 8 ) + 1 )

        Slider( panel, "Split position", "split" )
        Slider( panel, "Difference gain", "diffgain" )
    end,
} )

--[[-------------------------------------------------------------------------
    Render targets and materials
---------------------------------------------------------------------------]]

local mats, rt = {}, {}
local traceMats, atrousMats = {}, {}

local rtW, rtH = 0, 0
local histIndex = 0
local frameIndex = 0
local prevViewProj
local pendingClear = false

-- Everything ssgi_diagnose needs to tell you which link in the chain broke.
local diag = { draws = 0, lastDraw = 0, setup = false, enabled = false, bail = "Draw has never run" }

-- No mips, no LOD, clamped. Point sampling is deliberately absent: both the
-- upsample and the reprojection want bilinear taps.
local RT_FLAGS = bit.bor( 4, 8, 256, 512, 32768, 8388608 )

local function BuildRenderTargets()
    local div = 2 ^ math.Clamp( cv.scale:GetInt(), 0, 2 )
    rtW = math.max( math.floor( ScrW() / div ), 16 )
    rtH = math.max( math.floor( ScrH() / div ), 16 )

    -- The size goes in the name: GetRenderTargetEx hands back the existing
    -- target for a name it already knows, whatever size you ask for.
    local tag = "_" .. rtW .. "x" .. rtH

    local function Make( name, format )
        return GetRenderTargetEx( name .. tag, rtW, rtH, RT_SIZE_LITERAL,
            MATERIAL_RT_DEPTH_NONE, RT_FLAGS, 0, format )
    end

    rt.raw   = Make( "_rt_ssgi_raw",   IMAGE_FORMAT_RGBA16161616F )
    rt.hist0 = Make( "_rt_ssgi_hist0", IMAGE_FORMAT_RGBA16161616F )
    rt.hist1 = Make( "_rt_ssgi_hist1", IMAGE_FORMAT_RGBA16161616F )
    rt.blur  = Make( "_rt_ssgi_blur",  IMAGE_FORMAT_RGBA16161616F )
    rt.prevz = Make( "_rt_ssgi_prevz", IMAGE_FORMAT_R32F )

    -- Clearing has to happen inside a render pass, and this can be called from
    -- a convar callback, so defer it to the next Draw.
    pendingClear = true
    prevViewProj = nil
end

local function LoadMaterials()
    traceMats = {
        Material( "pp/ssgi_trace_low" ),
        Material( "pp/ssgi_trace_medium" ),
        Material( "pp/ssgi_trace_high" ),
        Material( "pp/ssgi_trace_ultra" ),
    }
    atrousMats = {
        [0] = Material( "pp/ssgi_atrous_fast" ),
        [1] = Material( "pp/ssgi_atrous_wide" ),
    }

    mats.temporal  = Material( "pp/ssgi_temporal" )
    mats.copyz     = Material( "pp/ssgi_copyz" )
    mats.composite = Material( "pp/ssgi_composite" )
end

--[[-------------------------------------------------------------------------
    Draw
---------------------------------------------------------------------------]]

local function SetVec4( mat, reg, x, y, z, w )
    mat:SetFloat( "$c" .. reg .. "_x", x or 0 )
    mat:SetFloat( "$c" .. reg .. "_y", y or 0 )
    mat:SetFloat( "$c" .. reg .. "_z", z or 0 )
    mat:SetFloat( "$c" .. reg .. "_w", w or 0 )
end

local function Pass( target, mat )
    render.PushRenderTarget( target )
        render.SetMaterial( mat )
        render.DrawScreenQuad()
    render.PopRenderTarget()
end

local function Draw( viewSetup )
    if not shaderlib then                       diag.bail = "shaderlib global is nil"   return end
    if not shaderlib.CanDrawEffects then        diag.bail = "shaderlib.CanDrawEffects missing (reconstruction never initialised)" return end
    if not shaderlib.CanDrawEffects() then      diag.bail = "shaderlib.CanDrawEffects() returned false" return end
    if hook.Run( "ShouldDrawSSGI" ) == false then diag.bail = "a ShouldDrawSSGI hook returned false" return end
    if not rt.raw then                          diag.bail = "render targets not built"  return end

    diag.bail = nil
    diag.draws = diag.draws + 1
    diag.lastDraw = RealTime()

    viewSetup = viewSetup or render.GetViewSetup()
    local eye = EyePos()

    if pendingClear then
        pendingClear = false
        for _, t in pairs( rt ) do
            render.PushRenderTarget( t )
            render.Clear( 0, 0, 0, 0 )
            render.PopRenderTarget()
        end
    end

    local invW, invH = 1 / rtW, 1 / rtH
    local scrW, scrH = ScrW(), ScrH()

    frameIndex = ( frameIndex + 1 ) % 64

    -- Under HDR the framebuffer is still pre-tonemap linear, so squaring it
    -- again crushes the shadows and blows the highlights. Auto picks for you.
    local linearise = cv.linear:GetInt()
    if linearise == 2 then linearise = render.GetHDREnabled() and 0 or 1 end

    render.UpdateScreenEffectTexture()
    local screen = render.GetScreenEffectTexture()

    -- 1. trace ---------------------------------------------------------------
    local trace  = traceMats[ math.Clamp( cv.quality:GetInt(), 1, 4 ) ]
    local radius = cv.radius:GetFloat()
    -- Pixels per world unit at unit depth. GShader's projection puts
    -- ndc.x = cot(fov/2) * viewX / depth, and ndc spans rtW pixels.
    local projScale = 0.5 * rtW / math.tan( math.rad( viewSetup.fov ) * 0.5 )

    trace:SetTexture( "$basetexture", screen )
    SetVec4( trace, 0, invW, invH, rtW, rtH )
    SetVec4( trace, 1, radius, projScale, cv.thickness:GetFloat(), cv.minradius:GetFloat() )
    SetVec4( trace, 2, frameIndex, math.max( rtH * cv.maxradius:GetFloat(), 4 ), 0, 0 )
    SetVec4( trace, 3, eye.x, eye.y, eye.z, linearise )

    Pass( rt.raw, trace )

    local current = rt.raw

    -- 2. temporal ------------------------------------------------------------
    local viewProj = shaderlib.GetViewProjMatrix( viewSetup )

    if cv.temporal:GetBool() and prevViewProj then
        local prevHist = histIndex == 0 and rt.hist0 or rt.hist1
        local newHist  = histIndex == 0 and rt.hist1 or rt.hist0

        mats.temporal:SetTexture( "$basetexture", rt.raw )
        mats.temporal:SetTexture( "$texture2", prevHist )
        mats.temporal:SetTexture( "$texture3", rt.prevz )
        mats.temporal:SetMatrix( "$viewprojmat", prevViewProj )
        SetVec4( mats.temporal, 0, invW, invH, rtW, rtH )
        SetVec4( mats.temporal, 1, cv.temporal_alpha:GetFloat(),
                 cv.temporal_clamp:GetFloat(), cv.temporal_tol:GetFloat(), 0 )

        Pass( newHist, mats.temporal )

        histIndex = 1 - histIndex
        current = newHist
    end

    -- 3. a-trous -------------------------------------------------------------
    -- rt.blur and rt.raw are the scratch pair. The history target we just wrote
    -- is never used as scratch, so it survives to next frame.
    local iterations = cv.denoise:GetInt()
    if iterations > 0 then
        local atrous = atrousMats[ cv.denoise_wide:GetInt() ]
        local pool, slot = { rt.blur, rt.raw }, 1

        for i = 1, iterations do
            if pool[slot] == current then slot = 3 - slot end
            local dst = pool[slot]

            atrous:SetTexture( "$basetexture", current )
            SetVec4( atrous, 0, invW, invH, rtW, rtH )
            SetVec4( atrous, 1, 2 ^ ( i - 1 ), cv.denoise_z:GetFloat(),
                     cv.denoise_n:GetFloat(), cv.denoise_l:GetFloat() )

            Pass( dst, atrous )

            current = dst
            slot = 3 - slot
        end
    end

    -- 4. composite -----------------------------------------------------------
    mats.composite:SetTexture( "$basetexture", screen )
    mats.composite:SetTexture( "$texture3", current )
    SetVec4( mats.composite, 0, 1 / scrW, 1 / scrH, invW, invH )
    SetVec4( mats.composite, 1, cv.gi:GetFloat(), cv.ao:GetFloat(),
             cv.albedo:GetFloat(), debugging:GetInt() )
    SetVec4( mats.composite, 2, rtW, rtH, cv.upsample_z:GetFloat(), cv.upsample_n:GetFloat() )
    SetVec4( mats.composite, 3, cv.split:GetFloat(), cv.diffgain:GetFloat(),
             cv.ao_lightbias:GetFloat(), linearise )

    -- screenspace_general always writes depth, and this pass runs before
    -- translucents and the viewmodel, so pin depth writes off for it.
    render.OverrideDepthEnable( true, false )
        render.SetMaterial( mats.composite )
        render.DrawScreenQuad()
    render.OverrideDepthEnable( false, false )

    -- 5. depth snapshot for next frame's reprojection -------------------------
    if cv.temporal:GetBool() then
        SetVec4( mats.copyz, 0, invW, invH, rtW, rtH )
        Pass( rt.prevz, mats.copyz )
    end

    prevViewProj = viewProj
end

--[[-------------------------------------------------------------------------
    Lifecycle
---------------------------------------------------------------------------]]

local function Enable()
    if not shaderlib then
        MsgN( "[SSGI] GShader library not found. Subscribe to it and make sure it is enabled, then run ssgi_diagnose." )
        return
    end

    if not GetConVar( "r_shaderlib" ):GetBool() then RunConsoleCommand( "r_shaderlib", "1" ) end
    if not GetConVar( "r_shaderlib_depthbuffer" ):GetBool() then RunConsoleCommand( "r_shaderlib_depthbuffer", "1" ) end

    BuildRenderTargets()
    hook.Add( "PostDrawReconstructionEffects", NAME, Draw )
    diag.enabled = true
    MsgN( "[SSGI] enabled at " .. rtW .. "x" .. rtH )
end

local function Disable()
    hook.Remove( "PostDrawReconstructionEffects", NAME )
    diag.enabled = false
end

local function Setup()
    if diag.setup then return end

    LoadMaterials()

    cvars.AddChangeCallback( enabled:GetName(), function( _, _, new )
        if tobool( new ) then Enable() else Disable() end
    end, NAME )

    local function Rebuild()
        if enabled:GetBool() then BuildRenderTargets() end
    end
    cvars.AddChangeCallback( cv.scale:GetName(), Rebuild, NAME )
    hook.Add( "OnScreenSizeChanged", NAME, Rebuild )

    diag.setup = true
    INITED_SSGI = true

    if enabled:GetBool() then Enable() end
end

if INITED_SSGI then Setup() end

hook.Add( "InitPostShaderlib", NAME, function()
    timer.Simple( 1, Setup )
end )

-- InitPostShaderlib only fires if the library actually loaded. Set up anyway so
-- that ssgi_diagnose can report what is missing instead of silently doing
-- nothing, and so a late-loading library still gets picked up.
timer.Simple( 5, Setup )

--[[-------------------------------------------------------------------------
    Diagnostics
---------------------------------------------------------------------------]]

concommand.Add( "ssgi_diagnose", function()
    local function line( k, v ) MsgN( string.format( "  %-28s %s", k, tostring( v ) ) ) end

    MsgN( "" )
    MsgN( "===== SSGI diagnose =====" )

    line( "BRANCH", BRANCH )
    line( "DX level", render.GetDXLevel() )
    line( "screen", ScrW() .. "x" .. ScrH() )
    line( "mat_antialias", GetConVar( "mat_antialias" ):GetInt() ..
        ( GetConVar( "mat_antialias" ):GetInt() == 0 and ""
          or "  (recommended 0 - MRT and MSAA can conflict. Set it in Options > Video, not the console: it is not archived to a cfg and resets every launch)" ) )
    line( "mat_viewportscale", GetConVar( "mat_viewportscale" ):GetFloat() .. "  (must be 1)" )
    line( "HDR enabled", tostring( render.GetHDREnabled() ) .. "  (mat_hdr_level " .. GetConVar( "mat_hdr_level" ):GetInt() .. ")" )
    if render.GetHDREnabled() then
        MsgN( "  NOTE: with HDR on the framebuffer is pre-tonemap linear, so" )
        MsgN( "        pp_ssgi_linear 1 squares an already-linear value. Try pp_ssgi_linear 0." )
    end

    MsgN( "-- GShader library --" )
    line( "shaderlib global", shaderlib and "present" or "MISSING - addon not installed/enabled" )
    if shaderlib then
        line( "CanDrawEffects", shaderlib.CanDrawEffects and "present" or "MISSING" )
        line( "GetViewProjMatrix", shaderlib.GetViewProjMatrix and "present" or "MISSING" )
        line( "rt_WPDepth", shaderlib.rt_WPDepth and
            ( shaderlib.rt_WPDepth:GetName() .. " " .. shaderlib.rt_WPDepth:Width() .. "x" .. shaderlib.rt_WPDepth:Height() ) or "MISSING" )
        line( "rt_NormalsTangents", shaderlib.rt_NormalsTangents and shaderlib.rt_NormalsTangents:GetName() or "MISSING" )
    end
    for _, name in ipairs( { "r_shaderlib", "r_shaderlib_depthbuffer", "r_shaderlib_wn_format",
                             "r_shaderlib_wn_reconsruction", "r_shaderlib_3dskybox" } ) do
        local c = GetConVar( name )
        line( name, c and c:GetString() or "CONVAR MISSING" )
    end
    line( "reconstruction hook", hook.GetTable()["PreDrawTranslucentRenderables"]
        and hook.GetTable()["PreDrawTranslucentRenderables"]["shaderlib"] and "installed" or "NOT INSTALLED" )

    MsgN( "-- SSGI --" )
    line( "setup ran", diag.setup )
    line( "enabled", diag.enabled )
    line( "pp_ssgi", enabled:GetInt() )
    line( "draw hook", hook.GetTable()["PostDrawReconstructionEffects"]
        and hook.GetTable()["PostDrawReconstructionEffects"][NAME] and "installed" or "NOT INSTALLED" )
    line( "Draw calls", diag.draws )
    line( "last Draw", diag.draws > 0 and string.format( "%.2fs ago", RealTime() - diag.lastDraw ) or "never" )
    line( "bailed because", diag.bail or "not bailing" )
    line( "trace resolution", rtW .. "x" .. rtH )

    MsgN( "-- materials --" )
    local all = { composite = mats.composite, temporal = mats.temporal, copyz = mats.copyz,
                  atrous_fast = atrousMats[0], atrous_wide = atrousMats[1] }
    for i, q in ipairs( { "low", "medium", "high", "ultra" } ) do all["trace_" .. q] = traceMats[i] end
    for name, m in SortedPairs( all ) do
        line( name, not m and "NOT LOADED" or ( m:IsError() and "ERROR - vmt or vcs missing" or "ok" ) )
    end

    MsgN( "-- render targets --" )
    for name, t in SortedPairs( rt ) do
        line( name, t and ( t:GetName() .. " " .. t:Width() .. "x" .. t:Height() ) or "nil" )
    end

    MsgN( "=========================" )
    MsgN( "" )
end, nil, "Print SSGI pipeline state to the console." )

--[[-------------------------------------------------------------------------
    Validation presets

    Deliberately exaggerated configurations, each isolating one part of the
    pipeline so it can be judged by eye. See VALIDATION.md for what to look for.
---------------------------------------------------------------------------]]

local presets = {}

presets["default"] = { desc = "Ship defaults." }

presets["reference"] = {
    desc = "Converged ground truth. Full res, ultra, no spatial denoise, sticky history.\nStand still ~3 seconds before judging. Slow on purpose - this is the target.",
    pp_ssgi_scale = 0, pp_ssgi_quality = 4,
    pp_ssgi_denoise = 0,
    pp_ssgi_temporal = 1, pp_ssgi_temporal_alpha = 0.02, pp_ssgi_temporal_clamp = 8,
    pp_ssgi_debug = 0,
}

presets["ao"] = {
    desc = "Occlusion only, cranked, shown raw.\nCorners and contacts darken; flat open ground stays white.",
    pp_ssgi_gi = 0, pp_ssgi_ao = 2.5, pp_ssgi_ao_lightbias = 0,
    pp_ssgi_radius = 220, pp_ssgi_quality = 3, pp_ssgi_debug = 2,
}

presets["gi"] = {
    desc = "Colour bleed only, cranked. Stand close to a saturated wall.\nThe floor should pick up its hue and lose it as you back away.",
    pp_ssgi_ao = 0, pp_ssgi_gi = 4, pp_ssgi_albedo = 1,
    pp_ssgi_radius = 260, pp_ssgi_quality = 3, pp_ssgi_debug = 0,
}

presets["noise"] = {
    desc = "Worst case: quarter res, low quality, no temporal, no denoise.\nThis is the raw trace. Screenshot it, then run 'clean' from the same spot.",
    pp_ssgi_scale = 2, pp_ssgi_quality = 1,
    pp_ssgi_temporal = 0, pp_ssgi_denoise = 0, pp_ssgi_debug = 3,
}

presets["clean"] = {
    desc = "Same trace as 'noise' with the full denoise chain on.\nThe difference between the two screenshots is the denoiser's entire job.",
    pp_ssgi_scale = 2, pp_ssgi_quality = 1,
    pp_ssgi_temporal = 1, pp_ssgi_denoise = 3, pp_ssgi_denoise_wide = 1, pp_ssgi_debug = 3,
}

presets["ghost"] = {
    desc = "Temporal pushed until it fails. Strafe past a prop and watch for smears.\nSome trailing is expected; an imprint that never fades is a bug.",
    pp_ssgi_temporal = 1, pp_ssgi_temporal_alpha = 0.02, pp_ssgi_temporal_clamp = 8,
    pp_ssgi_temporal_tol = 0.5, pp_ssgi_debug = 3,
}

presets["halo"] = {
    desc = "Upsample guard rails removed at quarter res.\nBlocky haloes on silhouettes are the expected failure. 'default' should kill them.",
    pp_ssgi_scale = 2, pp_ssgi_upsample_z = 32, pp_ssgi_upsample_n = 1,
    pp_ssgi_ao = 2, pp_ssgi_ao_lightbias = 0, pp_ssgi_debug = 2,
}

presets["diff"] = {
    desc = "Amplified difference. Shows exactly which pixels the effect changed.",
    pp_ssgi_debug = 7, pp_ssgi_diffgain = 12,
}

presets["coverage"] = {
    desc = "Where SSGI can reach at all. Magenta means no G-buffer behind the pixel:\nreal sky, the 3D skybox, and anything past the reconstruction range.",
    pp_ssgi_debug = 8,
}

presets["ab"] = {
    desc = "A/B split. Left of the magenta line is untouched, right is the effect.",
    pp_ssgi_debug = 6, pp_ssgi_split = 0.5,
}

local function ApplyPreset( name )
    local p = presets[name]
    if not p then return false end

    -- Every preset starts from defaults so they cannot contaminate each other.
    for _, c in pairs( cv ) do
        if c ~= enabled then RunConsoleCommand( c:GetName(), c:GetDefault() ) end
    end
    for k, v in pairs( p ) do
        if k ~= "desc" then RunConsoleCommand( k, tostring( v ) ) end
    end

    MsgN( "" )
    MsgN( "[SSGI] preset: " .. name )
    for text in string.gmatch( p.desc, "[^\n]+" ) do MsgN( "       " .. text ) end
    MsgN( "" )
    return true
end

concommand.Add( "ssgi_preset", function( _, _, args )
    local name = string.lower( args[1] or "" )

    if not ApplyPreset( name ) then
        MsgN( "" )
        MsgN( "[SSGI] usage: ssgi_preset <name>" )
        for key in SortedPairs( presets ) do
            MsgN( string.format( "  %-10s %s", key, string.match( presets[key].desc, "^[^\n]*" ) ) )
        end
        MsgN( "" )
    end
end, function( _, argStr )
    local out = {}
    local partial = string.Trim( string.lower( argStr ) )
    for key in SortedPairs( presets ) do
        if string.find( key, partial, 1, true ) == 1 then out[#out + 1] = "ssgi_preset " .. key end
    end
    return out
end, "Apply a validation preset. Run with no argument to list them." )

concommand.Add( "ssgi_ab", function()
    RunConsoleCommand( "pp_ssgi_debug", debugging:GetInt() == 6 and "0" or "6" )
end, nil, "Toggle the A/B split view." )
