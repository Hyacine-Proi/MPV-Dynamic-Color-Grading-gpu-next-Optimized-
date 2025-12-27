local mp = require 'mp'
local msg = require 'mp.msg'
local utils = require 'mp.utils'

-- === 状态管理 ===
local state = {
    red = 1.0,
    green = 1.0,
    blue = 1.0
}

-- 脏标记：记录是否需要更新
local is_dirty = false

-- 垃圾回收队列 (内存中暂存的文件名)
local trash_queue = {} 

-- 记录当前正在生效的文件名
local current_active_file = nil

local counter = 0 
-- 获取 shaders 文件夹绝对路径
local shader_dir = mp.command_native({"expand-path", "~~/shaders/"})

-- 1. 生成 GLSL 内容
local function generate_glsl_content(r, g, b)
    if r < 0.01 then r = 1.0 end
    if g < 0.01 then g = 1.0 end
    if b < 0.01 then b = 1.0 end

    return string.format([[
//!HOOK MAIN
//!BIND HOOKED
//!DESC Dynamic Color Gen (v%d)

vec4 hook() {
    vec4 color = HOOKED_tex(HOOKED_pos);
    color.rgb = max(color.rgb, vec3(0.0));

    float r = %.4f;
    float g = %.4f;
    float b = %.4f;

    color.r = pow(color.r, 1.0 / r);
    color.g = pow(color.g, 1.0 / g);
    color.b = pow(color.b, 1.0 / b);
    
    return color;
}
]], counter, r, g, b)
end

-- 2. 运行时垃圾回收 (保留最近 2 个)
local function process_trash()
    while #trash_queue > 2 do
        local file_to_delete = table.remove(trash_queue, 1)
        local path = shader_dir .. file_to_delete
        os.remove(path)
    end
end

-- 3. 核心：执行更新 (昂贵操作)
local function perform_update()
    counter = counter + 1
    
    local new_filename = string.format("tmp_color_%d_%d.glsl", os.time(), counter)
    local new_abs_path = shader_dir .. new_filename
    local new_mpv_path = "~~/shaders/" .. new_filename
    
    -- 写入新文件
    local file = io.open(new_abs_path, "w")
    if not file then return end
    file:write(generate_glsl_content(state.red, state.green, state.blue))
    file:flush()
    file:close()
    
    -- 更新 current_active_file 引用
    current_active_file = new_filename
    
    -- 原子化替换 Shader 列表
    local current_shaders = mp.get_property_native("glsl-shaders") or {}
    local clean_shaders = {}
    
    for _, path in ipairs(current_shaders) do
        -- 如果不是临时文件，则保留
        if not string.find(path, "tmp_color_") then
            table.insert(clean_shaders, path)
        end
        -- 如果是临时文件，记录名字以便放入垃圾队列
        if string.find(path, "tmp_color_") then
             local name = path:match("([^/]+)$")
             if name then table.insert(trash_queue, name) end
        end
    end
    
    -- 挂载新的
    table.insert(clean_shaders, new_mpv_path)
    mp.set_property_native("glsl-shaders", clean_shaders)
    
    -- 清理旧文件
    process_trash()
end

-- 4. 节流定时器 (20FPS)
mp.add_periodic_timer(0.05, function()
    if is_dirty then
        perform_update()
        is_dirty = false
    end
end)

-- === 交互接口 ===

local function handle_adjust(channel, delta)
    state[channel] = state[channel] + tonumber(delta)
    if state[channel] < 0.1 then state[channel] = 0.1 end
    
    is_dirty = true
    
    mp.osd_message(string.format("R: %.2f | G: %.2f | B: %.2f", 
        state.red, state.green, state.blue), 1)
end

local function handle_reset()
    state.red = 1.0
    state.green = 1.0
    state.blue = 1.0
    is_dirty = true
    mp.osd_message("Color Reset")
end

mp.register_script_message("color-gen", handle_adjust)
mp.register_script_message("reset-gen", handle_reset)

-- === 退出清理 (Final Clean) ===
mp.register_event("shutdown", function()
    msg.info("Cleaning up temporary shaders...")

    -- 方法A：清理内存中已知的
    if current_active_file then
        os.remove(shader_dir .. current_active_file)
    end
    for _, f in ipairs(trash_queue) do
        os.remove(shader_dir .. f)
    end

    -- 方法B：扫描硬盘，清理漏网之鱼 (使用 MPV 原生 API，稳！)
    local files = utils.readdir(shader_dir, "files")
    if files then
        for _, file in ipairs(files) do
            -- 只要是以 tmp_color_ 开头，且是 glsl 文件，统统删掉
            if string.find(file, "^tmp_color_") and string.find(file, "%.glsl$") then
                os.remove(shader_dir .. file)
            end
        end
    end
end)