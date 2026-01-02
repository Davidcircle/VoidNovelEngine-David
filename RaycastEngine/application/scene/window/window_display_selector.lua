-- 显示器选择窗口
-- 用于选择预览窗口显示在哪个显示器上
-- 使用方法: 按 F12 或通过菜单 视图->显示器选择 打开

local module = {}

local sdl = Engine.SDL
local rl = Engine.Raylib
local imgui = Engine.ImGUI

local GlobalContext = require("application.framework.global_context")
local ScreenManager = require("application.framework.screen_manager")

-- 配置文件路径
local CONFIG_FILE = "preview_display_config.txt"

-- 状态
local state = {
    displays = {},
    display_count = 0,
    selected_display = 0,
    window_borderless = true,
    window_fullscreen = false,
    preview_window = nil,
    preview_renderer = nil,
    preview_texture = nil,
    is_preview_open = false,
    show_selector = false,
    last_error = nil,
    config_loaded = false,
}

-- 加载配置
local function load_config()
    if state.config_loaded then return end
    
    local file = io.open(CONFIG_FILE, "r")
    if file then
        for line in file:lines() do
            local key, value = line:match("^(%w+)=(.+)$")
            if key == "display_index" then
                state.selected_display = tonumber(value) or 0
            elseif key == "window_mode" then
                if value == "fullscreen" then
                    state.window_fullscreen = true
                    state.window_borderless = false
                elseif value == "borderless" then
                    state.window_fullscreen = false
                    state.window_borderless = true
                else
                    state.window_fullscreen = false
                    state.window_borderless = false
                end
            end
        end
        file:close()
        state.config_loaded = true
    end
end

-- 保存配置
local function save_config()
    local file = io.open(CONFIG_FILE, "w")
    if file then
        file:write("display_index=" .. state.selected_display .. "\n")
        local mode = "windowed"
        if state.window_fullscreen then
            mode = "fullscreen"
        elseif state.window_borderless then
            mode = "borderless"
        end
        file:write("window_mode=" .. mode .. "\n")
        file:close()
        return true
    end
    return false
end

-- 刷新显示器列表
local function refresh_displays()
    state.displays = {}
    state.last_error = nil
    state.display_count = sdl.GetNumVideoDisplays()
    
    for i = 0, state.display_count - 1 do
        local display_info = {
            index = i,
            name = "显示器 " .. (i + 1),
            x = 0,
            y = 0,
            width = 1920,
            height = 1080,
            refresh_rate = 60,
        }
        
        -- 获取显示器边界
        local bounds = sdl.Rect()
        if sdl.GetDisplayBounds(i, bounds) == 0 then
            display_info.x = bounds.x
            display_info.y = bounds.y
            display_info.width = bounds.w
            display_info.height = bounds.h
        end
        
        -- 获取显示器名称
        local name = sdl.GetDisplayName(i)
        if name and name ~= "" then
            display_info.name = name
        end
        
        -- 获取刷新率
        local mode = sdl.DisplayMode()
        if sdl.GetCurrentDisplayMode(i, mode) == 0 then
            display_info.refresh_rate = mode.refresh_rate or 60
        end
        
        table.insert(state.displays, display_info)
    end
end

-- 创建预览窗口
local function create_preview_window()
    if state.is_preview_open then
        return true
    end
    
    local display = state.displays[state.selected_display + 1]
    if not display then
        state.last_error = "无效的显示器索引"
        return false
    end
    
    local width = GlobalContext.width_game_window
    local height = GlobalContext.height_game_window
    
    local flags = sdl.WindowFlags.SHOWN
    if state.window_borderless then
        flags = flags | sdl.WindowFlags.BORDERLESS
    end
    
    local x, y
    if state.window_fullscreen then
        flags = flags | sdl.WindowFlags.FULLSCREEN_DESKTOP
        x = display.x
        y = display.y
        width = display.width
        height = display.height
    elseif state.window_borderless then
        x = display.x
        y = display.y
        width = display.width
        height = display.height
    else
        x = display.x + math.floor((display.width - width) / 2)
        y = display.y + math.floor((display.height - height) / 2)
    end
    
    state.preview_window = sdl.CreateWindow(
        "VoidNovelEngine - 预览",
        x, y, width, height,
        flags
    )
    
    if not state.preview_window then
        state.last_error = "无法创建窗口: " .. (sdl.GetError() or "未知错误")
        return false
    end
    
    state.preview_renderer = sdl.CreateRenderer(
        state.preview_window, -1,
        sdl.RendererFlags.ACCELERATED | sdl.RendererFlags.PRESENTVSYNC
    )
    
    if not state.preview_renderer then
        state.last_error = "无法创建渲染器"
        sdl.DestroyWindow(state.preview_window)
        state.preview_window = nil
        return false
    end
    
    -- 创建纹理用于接收预览内容
    state.preview_texture = sdl.CreateTexture(
        state.preview_renderer,
        sdl.PixelFormat.ABGR8888,
        sdl.TextureAccess.STREAMING,
        GlobalContext.width_game_window, GlobalContext.height_game_window
    )
    sdl.SetTextureScaleMode(state.preview_texture, sdl.ScaleMode.BEST)
    
    state.is_preview_open = true
    
    -- 更新全局状态
    GlobalContext.is_preview_in_editor = false
    GlobalContext.external_preview_window = state.preview_window
    GlobalContext.external_preview_renderer = state.preview_renderer
    GlobalContext.external_preview_texture = state.preview_texture
    
    return true
end

-- 销毁预览窗口
local function destroy_preview_window()
    if state.preview_texture then
        sdl.DestroyTexture(state.preview_texture)
        state.preview_texture = nil
    end
    if state.preview_renderer then
        sdl.DestroyRenderer(state.preview_renderer)
        state.preview_renderer = nil
    end
    if state.preview_window then
        sdl.DestroyWindow(state.preview_window)
        state.preview_window = nil
    end
    state.is_preview_open = false
    
    -- 更新全局状态
    GlobalContext.external_preview_window = nil
    GlobalContext.external_preview_renderer = nil
    GlobalContext.external_preview_texture = nil
end

-- 切换回编辑器内预览
local function switch_to_editor_preview()
    destroy_preview_window()
    GlobalContext.is_preview_in_editor = true
end

-- 初始化
module.on_enter = function()
    load_config()
    refresh_displays()
    
    -- 验证选择的显示器索引
    if state.selected_display >= state.display_count then
        state.selected_display = 0
    end
end

-- 更新
module.on_update = function(self, delta)
    -- F12 快捷键切换显示器选择窗口
    if imgui.IsKeyPressed(imgui.ImGuiKey.F12, false) then
        module.toggle()
    end
    
    if not state.show_selector then return end
    
    local open = imgui.Bool(true)
    imgui.SetNextWindowSize(imgui.ImVec2(420, 380), imgui.Cond.FirstUseEver)
    
    if imgui.Begin("显示器选择 - 预览窗口", open) then
        -- 错误提示
        if state.last_error then
            imgui.TextColored(imgui.ImVec4(1, 0.3, 0.3, 1), "错误: " .. state.last_error)
            imgui.Spacing()
        end
        
        -- 刷新按钮
        if imgui.Button("刷新显示器列表") then
            refresh_displays()
        end
        imgui.SameLine()
        imgui.TextDisabled("(" .. state.display_count .. " 个显示器)")
        
        imgui.Separator()
        imgui.Spacing()
        
        -- 显示器列表
        imgui.Text("选择目标显示器:")
        imgui.Spacing()
        
        if imgui.BeginChild("##DisplayList", imgui.ImVec2(0, 130), true) then
            for i, display in ipairs(state.displays) do
                local is_selected = (state.selected_display == display.index)
                local label = string.format("%d. %s (%dx%d @ %dHz)", 
                    i, display.name, display.width, display.height, display.refresh_rate)
                
                if imgui.Selectable(label, is_selected) then
                    state.selected_display = display.index
                end
                
                if imgui.IsItemHovered() then
                    imgui.BeginTooltip()
                    imgui.Text("位置: (" .. display.x .. ", " .. display.y .. ")")
                    imgui.EndTooltip()
                end
            end
            imgui.EndChild()
        end
        
        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()
        
        -- 选项
        imgui.Text("窗口选项:")
        
        local borderless = imgui.Bool(state.window_borderless)
        if imgui.Checkbox("无边框窗口", borderless) then
            state.window_borderless = borderless.value
        end
        
        imgui.SameLine()
        
        local fullscreen = imgui.Bool(state.window_fullscreen)
        if imgui.Checkbox("全屏模式", fullscreen) then
            state.window_fullscreen = fullscreen.value
        end
        
        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()
        
        -- 状态和操作按钮
        if state.is_preview_open then
            imgui.TextColored(imgui.ImVec4(0.2, 0.9, 0.2, 1), "● 独立预览窗口已打开")
            
            if imgui.Button("关闭预览窗口") then
                switch_to_editor_preview()
            end
            
            imgui.SameLine()
            if imgui.Button("移动到选中显示器") then
                destroy_preview_window()
                create_preview_window()
            end
        else
            imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1), "○ 使用编辑器内预览")
            
            imgui.Spacing()
            
            if imgui.Button("在选中显示器上打开预览", imgui.ImVec2(220, 28)) then
                create_preview_window()
            end
        end
        
        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()
        
        -- 保存配置
        if imgui.Button("保存配置") then
            if save_config() then
                state.last_error = nil
            else
                state.last_error = "保存配置失败"
            end
        end
        imgui.SameLine()
        imgui.TextDisabled("(快捷键: F12)")
    end
    imgui.End()
    
    if not open.value then
        state.show_selector = false
    end
end

-- 渲染预览内容到独立窗口
module.render_preview = function()
    if not state.is_preview_open or not state.preview_renderer or not state.preview_texture then 
        return 
    end
    
    -- 从Raylib渲染缓冲拷贝内容到SDL纹理
    local image = rl.LoadImageFromTexture(ScreenManager.get_texture())
    local result = sdl.LockResult()
    sdl.LockTexture(state.preview_texture, result)
    Engine.Util.Memcpy(result.data, image.data, result.pitch * GlobalContext.height_game_window)
    sdl.UnlockTexture(state.preview_texture)
    rl.UnloadImage(image)
    
    -- 渲染到预览窗口
    sdl.RenderClear(state.preview_renderer)
    
    -- 计算缩放以保持宽高比
    local win_w, win_h = 0, 0
    local size = sdl.GetWindowSize(state.preview_window)
    if size then
        win_w, win_h = size.w, size.h
    else
        win_w = GlobalContext.width_game_window
        win_h = GlobalContext.height_game_window
    end
    
    local scale = math.min(win_w / GlobalContext.width_game_window, win_h / GlobalContext.height_game_window)
    local dst_w = math.floor(GlobalContext.width_game_window * scale)
    local dst_h = math.floor(GlobalContext.height_game_window * scale)
    local dst_x = math.floor((win_w - dst_w) / 2)
    local dst_y = math.floor((win_h - dst_h) / 2)
    
    local dst_rect = sdl.Rect()
    dst_rect.x = dst_x
    dst_rect.y = dst_y
    dst_rect.w = dst_w
    dst_rect.h = dst_h
    
    sdl.RenderCopyEx(state.preview_renderer, state.preview_texture, nil, dst_rect, 0, nil, sdl.RendererFlip.VERTICAL)
    sdl.RenderPresent(state.preview_renderer)
end

-- 公开接口
module.show = function()
    state.show_selector = true
    refresh_displays()
end

module.hide = function()
    state.show_selector = false
end

module.toggle = function()
    if state.show_selector then
        module.hide()
    else
        module.show()
    end
end

module.is_visible = function()
    return state.show_selector
end

module.is_preview_in_window = function()
    return state.is_preview_open
end

module.close_preview = function()
    destroy_preview_window()
end

module.open_preview_on_display = function(display_index)
    if display_index then
        state.selected_display = display_index
    end
    return create_preview_window()
end

module.get_state = function()
    return state
end

return module
