script_name('LoginWalk')
script_version('1.0')
script_author('Charlie')
script_description('After login: walk forward 10s, then press Esc (pause menu)')

local sampev = require 'lib.samp.events'

-- Esc 通过 WinAPI 注入（keybd_event），比 CPad Start 键可靠
local ffi = require 'ffi'
ffi.cdef[[
    void keybd_event(unsigned char bVk, unsigned char bScan,
                     unsigned long dwFlags, unsigned long dwExtraInfo);
]]
local user32 = ffi.load('user32')
local VK_ESC, KEYEVENTF_KEYUP = 0x1B, 0x2

-- ==================== 配置 ====================
local LOGIN_DIALOG_ID = 12346   -- 登录对话框 ID（标题“密码”）
local WALK_SECONDS    = 10      -- 前进时长（秒）
local KEY_STICK_Y     = 1       -- CPad LeftStickY，负值 = 向前走
local ESC_HOLD_MS     = 150     -- Esc 按住时长
-- ==============================================

local phase     = 'idle'  -- idle -> waiting -> walking -> done
local walk_until = 0

-- 登录框弹出时布防（断线重连后会再次触发）
function sampev.onShowDialog(dialogId, style, title, button1, button2, text)
    if dialogId == LOGIN_DIALOG_ID then
        phase = 'waiting'
    end
end

function main()
    while not isSampAvailable() do wait(100) end
    sampAddChatMessage('[LoginWalk] loaded, trigger: dialog ' .. LOGIN_DIALOG_ID, -1)

    while true do
        wait(100)
        if phase == 'waiting' then
            -- 已出生且没有任何对话框在屏 → 登录完成
            if sampIsLocalPlayerSpawned() and not sampIsDialogActive() then
                phase = 'walking'
                walk_until = os.clock() + WALK_SECONDS
                sampAddChatMessage('[LoginWalk] login done, walking forward '
                                   .. WALK_SECONDS .. 's', -1)
            end
        elseif phase == 'walking' then
            while os.clock() < walk_until do
                setGameKeyState(KEY_STICK_Y, -255)
                wait(0)
            end
            setGameKeyState(KEY_STICK_Y, 0)
            sampAddChatMessage('[LoginWalk] walk done, pressing Esc', -1)
            user32.keybd_event(VK_ESC, 0, 0, 0)
            wait(ESC_HOLD_MS)
            user32.keybd_event(VK_ESC, 0, KEYEVENTF_KEYUP, 0)
            phase = 'done'
        end
    end
end
