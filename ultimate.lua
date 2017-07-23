--[[

Ultimate Intervalometer v4.6

Licence: GPL (c) 2013, 2014, 2015, 2016, 2017 waterwingz
thx to msl for code adapted for dawn_and_dusk() and tv2seconds()

  Please check for the latest version (and documentation) at :
     http://chdk.wikia.com/wiki/Ultimate_Intervalometersl ult

@title Ultimate v4.6
@chdk_version 1.4

# shot_interval      3     "Shot Interval" { 10sec 20sec 30sec 1min 2min 5min 10min 15min 20min 30min 1hr 2hr 4hr }
# zoom_setpoint      0     "Zoom position" { Off 0% 10% 20% 30% 40% 50% 60% 70% 80% 90% 100% }
# focus_at_infinity  false "Focus @ Infinity?"
# min_Tv             0     "Shoot when shutter speed >" { Off 2sec 1sec 1/2 1/4 1/8 1/30 1/60 }

@subtitle Start and Stop Times
# start_stop_mode    true  "Enable timed start/stop?"
# start_hr           9     "Starting hour (24 Hr)" [0 23]
# start_min          0     "..and starting minute" [0 59]
# dawn_mode          false " ..or start at dawn?"
# end_hr             17    "Ending hour (24 Hr)"   [0 23]
# end_min            0     " ..and ending minute"  [0 60]
# dusk_mode          false " ..and end at dusk?"
# dow_mode           0     "Enable on days"  { All Mon-Fri Sat&Sun }

@subtitle Location for Dawn/Dusk Calc
# latitude           449   "Latitude"
# longitude          -931  "Longitude"
# utc                -6    "UTC"
# time_offset        0     "Start/stop offset [min]"

@subtitle HDR / Exposure Bracketing
# hdr_mode           0     "Mode" { Off Ev Tv Sv Av Burst }
# hdr_offset         5     "Offset (f-stops)" { 0.3 0.6 1.0 1.3 1.6 2.0 2.3 2.6 3.0 3.3 3.6 4.0 }
# hdr_shots          0     "Shots" { 3 5 7 9 }

@subtitle Script Setup
# file_delete        0     "Action if card full?" { Quit Delete }
# start_delay        0     "Delay start (Days)" [0 1000]
# maximum_days       0     "End after days (0=infinite)" [0 1000]
# reboot_counter     3     "Days between resets" [1 365]
# reboot_hour        2     "Reset hour (24 Hr)" [1 23]
# day_display_mode   1     "Display off mode (day)"   { None LCD BKLite DispKey PlayKey ShrtCut }
# night_display_mode 4     "Display off mode (night)" { None LCD BKLite DispKey PlayKey ShrtCut }
# low_batt_trip      0     "Low battery shutdown mV" [0 12000]
# day_status_led     0     "Status LED (day)"   { Off 0 1 2 3 4 5 6 7 8 }
# night_status_led   0     "Status LED (night)" { Off 0 1 2 3 4 5 6 7 8 }
# ptp_enable         false "Pause when USB connected?"
# theme              0     "Theme" { Color Mono }
# log_mode           2     "Logging" { Off Screen SDCard Both }
# debug_mode         false "Debug mode?"

--]]

require("drawings")
props = require("propcase")

-- translate some of the user parameters into more usable values
start_time = start_hr * 3600 + start_min * 60
stop_time = end_hr * 3600 + end_min * 60
reboot_time = reboot_hour * 3600 - 600
interval_table = { 10, 20, 30, 60, 120, 300, 600, 900, 1200, 1800, 3600, 7200, 14400 }
shot_interval = interval_table[shot_interval + 1]
speed_table = { 9999, -96, 0, 96, 192, 288, 480, 576 }
min_Tv = speed_table[min_Tv + 1]
hdr_shots = (hdr_shots * 2 + 3) / 2
if (zoom_setpoint == 0) then
    zoom_setpoint = nil
else
    zoom_setpoint = (zoom_setpoint - 1) * 10
end

-- configure HDR shooting
hdr_offset = (hdr_offset + 1) * 32
if (hdr_mode == 2) then
    tv_offset = hdr_offset
else
    tv_offset = 0
end
if (hdr_mode == 3) then
    sv_offset = hdr_offset
else
    sv_offset = 0
end
if (hdr_mode == 4) then
    av_offset = hdr_offset
else
    av_offset = 0
end

-- constants
SHORTCUT_KEY = "print" -- edit this if using shortcut key to enter sleep mode
NIGHT = 0 --
DAY = 1 --
INFINITY = 60000 -- focus lock distance in mm (approximately 55 yards)
DEBUG_SPEED = 2 -- clock multiplier when running fast in debug mode
PLAYBACK = 0 --
SHOOTING = 1 --
propset = get_propset()
pTV = props.TV
if (propset > 3) then
    pTV2 = props.TV2
end
pAV = props.AV
pSV = props.SV

-- camera configuration global variables
dawn = start_time
dusk = stop_time
shooting_mode = DAY
display_mode = day_display_mode
display_active = true
display_hold_timer = 0
led_state = 0
led_timer = 0
shot_counter = 0
sd_card_full = false
elapsed_days = 0
jpg_count = nil

-- restore : called when script shuts down for good
function restore()
    set_draw_title_line(true)
    set_exit_key("shoot_full")
    set_config_value(121, 0) -- USB remote disable
    if (day_status_led > 0) then
        set_led(day_status_led - 1, 0)
    end
    if (night_status_led > 0) then
        set_led(night_status_led - 1, 0)
    end
    unlock_focus()
    set_backlight(true)
    set_lcd_display(true)
    activate_display(10)
    pline(1, "restore")
end

function get_current_time()
    local rs = get_day_seconds()
    if debug_mode == true then
        if starting_tick_count == nil then
            starting_tick_count = get_tick_count()
        end
        rs = (((reboot_time * 1000) + get_tick_count() - starting_tick_count) * DEBUG_SPEED) % 86400
    end
    return rs
end

function get_next_shot_time()
    return (((get_current_time() + shot_interval) / shot_interval) * shot_interval)
end

function lprintf(...)
    if (log_mode > 1) then
        local str = string.format(...)
        local logname = "A/ultimate.log"
        local retry = 0
        repeat
            log = io.open(logname, "a")
            if (log ~= nil) then
                local ss = "Day " .. tostring(elapsed_days) .. " "
                if (elapsed_days == 0) then
                    ss = "Day -- "
                end
                if (debug_mode == false) then
                    ss = string.format(ss .. os.date() .. " ")
                else
                    local ts = get_current_time()
                    ss = string.format(ss .. " %02d:%02d ", ts / 3600, ts % 3600 / 60)
                end
                log:write(ss .. string.format(...), "\n")
                log:close()
                return
            end
            sleep(250)
            retry = retry + 1
        until (retry > 7)
        print("Error : log file open fault!")
    end
end

function printf(...)
    if (log_mode ~= 0) then
        local str = string.format(...)
        if ((log_mode == 1) or (log_mode == 3)) then
            print(string.sub(str, 1, 88))
        end
        lprintf(...)
    end
end

function pline(line, message) -- print line function
    if (theme == 1) then
        if (line == 1) then
            fg = 258
            bg = 257
        elseif (line == 6) then
            fg = 258
            bg = 257
        else
            fg = 257
            bg = 258
        end
    else
        if (line == 1) then
            fg = 271
            bg = 265
        elseif (line == 6) then
            fg = 258
            bg = 265
        else
            fg = 265
            bg = 258
        end
    end
    draw_string(24, line * 16, string.sub(message .. "                          ", 0, 34), fg, bg)
end

tv_ref = {    -- note : tv_ref values set 1/2 way between shutter speed values
    -608, -560, -528, -496, -464, -432, -400, -368, -336, -304,
    -272, -240, -208, -176, -144, -112,  -80,  -48,  -16,   16,
    48,   80,  112,  144,  176,  208,  240,  272,  304,  336,
    368,  400,  432,  464,  496,  528,  560,  592,  624,  656,
    688,  720,  752,  784,  816,  848,  880,  912,  944,  976,
    1008, 1040, 1072, 1096, 1129, 1169, 1192, 1225, 1265, 1376  }

tv_str = {
    ">64",
    "64",    "50",    "40",    "32",    "25",    "20",    "16",    "12",     "10",   "8.0",
    "6.0",   "5.0",   "4.0",   "3.2",   "2.5",   "2.0",   "1.6",   "1.3",    "1.0",   "0.8",
    "0.6",   "0.5",   "0.4",   "0.3",   "1/4",   "1/5",   "1/6",   "1/8",   "1/10",  "1/13",
    "1/15",  "1/20",  "1/25",  "1/30",  "1/40",  "1/50",  "1/60",  "1/80",  "1/100", "1/125",
    "1/160", "1/200", "1/250", "1/320", "1/400", "1/500", "1/640", "1/800", "1/1000","1/1250",
    "1/1600","1/2000","1/2500","1/3200","1/4000","1/5000","1/6400","1/8000","1/10000","hi" }

function tv2seconds(tv_val)
    local i = 1
    while (i <= #tv_ref) and (tv_val > tv_ref[i] - 1) do
        i = i + 1
    end
    return tv_str[i]
end

function show_box_titles()
    local ts = get_current_time()
    pline(1, string.format("  Ultimate Intervalometer %02d:%02d", ts / 3600, ts % 3600 / 60))
    if (get_raw() == true) then
        pline(6, string.format("       Press MENU to Exit   [RAW]"))
    else
        pline(6, string.format("       Press MENU to Exit"))
    end
end

function show_status_box()
    local start_string
    local end_string
    local halt_string
    show_box_titles()
    local ts = next_shot_time - now
    if (ts < 0) then
        ts = 0
    end
    pline(2, string.format(" Shots:%d  Next:%02d:%02d:%02d  Day:%d ", shot_counter, ts / 3600, (ts % 3600) / 60, ts % 60, elapsed_days))
    local rboot = "today"
    if (reboot_counter == 1) then
        rboot = "tomorrow"
    elseif (reboot_counter > 1) then
        rboot = string.format("%d days", reboot_counter)
    end
    pline(3, string.format(" Tv=%s [%s]  Reboot:%s", tv2seconds(tv96current), tv2seconds(min_Tv), rboot))
    if (start_stop_mode == true) then
        start_string = string.format(" Start:%02d:%02d", day_time_start / 3600, day_time_start % 3600 / 60)
        end_string = string.format(" End:%02d:%02d", day_time_stop / 3600, day_time_stop % 3600 / 60)
    else
        start_string = string.format(" Start:always")
        end_string = string.format(" End:never")
    end
    if (maximum_days > 0) then
        halt_string = string.format(" Halt:%d", maximum_days)
    else
        halt_string = " "
    end
    pline(4, start_string .. end_string .. halt_string)
    local ts = display_hold_timer
    if (ts < 0) then
        ts = 0
    end
    local dt = "Delayed"
    if (start_delay == 0) then
        if (shooting_mode == DAY) then
            dt = "Day"
        else
            dt = "Night"
        end
    end
    if (jpg_count == "nil") then
        sd_space = "???"
    else
        sd_space = tostring(jpg_count)
    end
    pline(5, string.format(" Free:%s Disp:%d  Mode:%s", sd_space, ts, dt))
end

function show_msg_box(msg)
    show_box_titles()
    local st = "        "
    pline(2, st)
    pline(3, msg)
    pline(4, st)
    pline(5, st)
end

function log_user_params()
    lprintf(" int:" .. shot_interval .. " zoom:" .. tostring(zoom_setpoint) .. " inf:" .. tostring(focus_at_infinity) .. " minTV:" .. min_Tv .. " mode:" .. tostring(start_stop_mode))
    lprintf(" startHr:" .. start_hr .. " startMin:" .. start_min .. " dawn:" .. tostring(dawn_mode))
    lprintf(" endHr:" .. end_hr .. " endMin" .. end_min .. " dusk:" .. tostring(dusk_mode) .. " dow:" .. dow_mode)
    lprintf(" lat:" .. latitude .. " lon:" .. longitude .. " utc:" .. utc .. " toffset" .. time_offset)
    lprintf(" HDR:" .. hdr_mode .. " offset:" .. hdr_offset .. " shots:" .. hdr_shots .. " delay:" .. start_delay .. " max:" .. maximum_days)
    lprintf(" reboot:" .. reboot_counter .. " rebootHr:" .. reboot_hour .. " LCD day:" .. day_display_mode .. " LCD nit:" .. night_display_mode .. " Batt:" .. low_batt_trip)
    lprintf(" DLed:" .. day_status_led .. " NLed:" .. night_status_led .. " ptp:" .. tostring(ptp_enable) .. " theme:" .. theme .. " log:" .. log_mode)
    lprintf(" del:" .. file_delete .. " debug:" .. tostring(debug_mode))
end

-- wait for a CHDK function to be true/false with a timeout
function wait_timeout(func, state, interval, msg)
    local tstamp = get_tick_count()
    local timeout = false
    repeat
        sleep(50)
        timeout = get_tick_count() > tstamp + interval
    until (func() == state) or timeout
    if timeout and (msg ~= nil) then
        printf(msg)
    end
    return timeout
end

-- set zoom position
function update_zoom(zpos)
    local count = 0
    if (zpos ~= nil) then
        zstep = ((get_zoom_steps() - 1) * zpos) / 100
        printf("setting zoom to " .. zpos .. " percent step=" .. zstep)
        sleep(200)
        set_zoom(zstep)
        sleep(2000)
        press("shoot_half")
        wait_timeout(get_shooting, true, 5000, "unable to focus after zoom")
        release("shoot_half")
    end
end

-- change between shooting and playback modes
function switch_mode(psmode)
    if (psmode == SHOOTING) then
        if (get_mode() == false) then
            set_record(true) -- switch to shooting mode
            wait_timeout(get_mode, true, 10000, "fault on switch to shooting mode")
            sleep(4000) -- a little extra delay so things like set_LCD_display() don't crash on some cameras
        end
    else
        if (get_mode() == true) then
            set_record(false) -- switch to playback mode
            wait_timeout(get_mode, false, 10000, "fault on switch to playback mode")
            sleep(4000) -- a little extra delay so things like set_LCD_display() don't crash on some cameras
        end
    end
end

-- click display key to get to desire LCD display mode
function toggle_display_key(mode)
    local count = 5
    local clicks = 0
    local dmode = 0
    if (mode == false) then
        dmode = 2
    end
    sleep(200)
    repeat
        disp = get_prop(props.DISPLAY_MODE)
        if (disp ~= dmode) then
            click("display")
            clicks = clicks + 1
            sleep(500)
        end
        count = count - 1
    until ((disp == dmode) or (count == 0))
    if (clicks > 0) then
        if (count > 0) then
            printf("display changed")
        else
            printf("unable to change display")
        end
    end
    sleep(500)
end

-- click display key to turn off LCD (works for OVF cameras only)
function restore_display()
    local disp = get_prop(props.DISPLAY_MODE)
    local clicks = 0
    repeat
        click("display")
        clicks = clicks + 1
        sleep(500)
    until ((disp == get_prop(props.DISPLAY_MODE)) or (clicks > 5))
end

--  press user shortcut key to toggle sleep mode
function sleep_mode()
    printf("toggling sleep mode")
    press(SHORTCUT_KEY)
    sleep(1000)
    release(SHORTCUT_KEY)
    sleep(2000)
end

-- routine to control the on/off state of the LCD
function activate_display(seconds) -- seconds=0 for turn off display, >0 turn on for seconds (extends time if display hold timer is running)
    if (display_mode > 0) then -- display control enable?
        if (display_hold_timer > 0) then -- do nothing until display hold timer expires
            display_hold_timer = display_hold_timer + seconds
        else
            if (seconds == 0) then -- request to turn display off ?
                newstate = false
                st = "off"
            else -- if not then it's on
                display_hold_timer = seconds
                newstate = true
                st = "on"
            end

            if (display_mode == 2) then -- backlight on/off  (allow to happen every time called)
                if (display_active ~= newstate) then
                    printf("set backlight %s", st)
                end
                sleep(1000)
                set_backlight(newstate)
            elseif (display_active ~= newstate) then
                if (display_mode == 1) then -- LCD on/off only
                    printf("set LCD %s", st)
                    set_lcd_display(newstate)
                    if (newstate == true) then -- reset focus if display being re-enabled
                        lock_focus()
                    end
                elseif (display_mode == 3) then -- press DISP key to turn off display
                    printf("DISP key %s", st)
                    toggle_display_key(newstate)
                elseif (display_mode == 4) then -- switch to PLAYBACK and turn off display
                    printf("shooting mode %s", st)
                    if (newstate == true) then
                        switch_mode(SHOOTING)
                    else
                        switch_mode(PLAYBACK)
                    end
                    set_lcd_display(newstate)
                    if (newstate == true) then -- reset zoom and focus if display being re-enabled
                        update_zoom(zoom_setpoint)
                        lock_focus()
                    end
                elseif (display_mode == 5) then -- use the shortcut key to enter idle mode
                    printf("toggling sleep mode")
                    sleep_mode()
                    if (newstate == true) then -- reset zoom and focus if display being re-enabled
                        update_zoom(zoom_setpoint)
                        lock_focus()
                    end
                end
            end
            display_active = newstate
        end
    end
end

-- blink LED's to indicate script running in day or night mode, change rate when SD card almost full
function led_blinker()
    local tk = get_tick_count()
    if (tk > led_timer) then
        if (led_state == 0) then
            led_state = 1
            led_timer = tk + 100
        else
            led_state = 0
            if (sd_card_full == false) then
                if (shooting_mode == DAY) then
                    led_timer = tk + 3000
                else
                    led_timer = tk + 6000
                end
            else
                led_timer = tk + 400
            end
        end
        if (shooting_mode == DAY) then
            if (day_status_led > 0) then
                set_led(day_status_led - 1, led_state)
            end
            if (night_status_led > 0) then
                set_led(night_status_led - 1, 0)
            end
        else
            if (day_status_led > 0) then
                set_led(day_status_led - 1, 0)
            end
            if (night_status_led > 0) then
                set_led(night_status_led - 1, led_state)
            end
        end
    end
end


-- routine to reboot the camera and restart this script
function camera_reboot()
    activate_display(90)
    switch_mode(PLAYBACK)
    local ts = 70 -- allow 70 seconds in case camera not setup to retract immediately
    if (debug_mode) then
        ts = 5
    end
    printf("=== Scheduled reboot ===")
    printf("lens retraction wait")
    repeat
        show_msg_box(string.format("   rebooting in %d", ts))
        ts = ts - 1
        sleep(1000)
    until (ts == 0)

    -- save the elapsed day count. oldest image number and its DCIM folder
    local f = io.open("A/ucount.txt", "w")
    if (f ~= nil) then
        if ((oldest_img_num ~= nil) and (oldest_img_dir ~= nil)) then
            f:write(elapsed_days .. "\n" .. oldest_img_num .. "\n" .. oldest_img_dir .. "\n")
        else
            f:write(elapsed_days .. "\n0\n0\n")
        end
        f:flush()
        f:close()
    end

    -- time to restart or shutdown?
    if (elapsed_days ~= maximum_days) then
        set_autostart(2) -- autostart once
        printf("rebooting now\n\n")
        sleep(2000)
        reboot()
    else
        printf("shutting down - maximum day count limit exceeded\n\n")
        sleep(2000)
        post_levent_to_ui('PressPowerButton')
        sleep(10000)
    end
end

-- scan all A/DCIM directories for the next sequential image
function locate_next_file(inum, idir)
    local current_imgnum = get_exp_count()
    local folders = 0
    local folder_names = {}

    --fill a table with A/DCIM subdirectory names
    local dcim, ud = os.idir('A/DCIM', false)
    repeat
        dname = dcim(ud)
        if ((dname ~= nil) and (tonumber(string.sub(dname, 1, 3)) ~= nil)) then
            folders = folders + 1
            folder_names[folders] = dname
        end
    until not dname
    dcim(ud, false) -- ensure directory handle is closed

    -- find a folder where the first three digits have incremented by one and look for next image there
    dir_num = tonumber(string.sub(idir, 1, 3)) + 1
    if (dir_num > 999) then
        dir_num = 100
    end
    for folder = 1, folders, 1 do
        test_num = tonumber(string.sub(folder_names[folder], 1, 3))
        if (test_num ~= nil) then
            if (test_num == dir_num) then
                local f = io.open(string.format("A/DCIM/%s/IMG_%04d.JPG", folder_names[folder], inum), "r")
                if (f ~= nil) then
                    printf("image found in next directory %s", folder_names[folder])
                    io.close(f) -- ensure file handle is closed
                    return inum, folder_names[folder] -- return the found file & folder name
                end
            end
        end
    end

    -- scan for next oldest image
    repeat
        for folder = 1, folders, 1 do
            local f = io.open(string.format("A/DCIM/%s/IMG_%04d.JPG", folder_names[folder], inum), "r")
            if (f ~= nil) then
                printf("image found in directory %s", folder_names[folder])
                io.close(f) -- ensure file handle is closed
                return inum, folder_names[folder] -- return the found file & folder name
            end
        end
        inum = inum + 1
        if (inum > 9999) then
            inum = 1
        end
    until (inum == current_imgnum)

    return nil, nil -- didn't find any image ?
end

-- remove next oldest image
function remove_next_old_image(imgnum, imgdir)
    local current_imgnum = get_exp_count()
    if (current_imgnum ~= imgnum) then -- don't remove the current image
        local found = false
        local image_name = string.format("A/DCIM/%s/IMG_%04d.JPG", imgdir, imgnum)
        local f = io.open(image_name, "r") -- see if image exists
        if (f ~= nil) then
            found = true -- got lucky - it's there
            io.close(f) -- close the file handle
        else -- not luckly so scan for image assuming sequential numbering scheme
            imgnum, imgdir = locate_next_file(imgnum, imgdir)
            if (imgdir ~= nil) then
                found = true
                image_name = string.format("A/DCIM/%s/IMG_%04d.JPG", imgdir, imgnum)
            end
        end
        if (found == true) then -- if image found then delete it
            printf("removing " .. image_name)
            os.remove(image_name)
            -- f=io.open(image_name,"wb") ; f:close() -- create a small dummy file so camera does not get confused by the missing image
            return imgnum, imgdir
        end
    end
    return nil, nil
end

-- delete multiple oldest images
function remove_oldest_images(num)
    local dcount = 0
    local shooting_flag = false
    if (oldest_img_num ~= nil) then
        if (get_mode() == true) then
            switch_mode(PLAYBACK)
            shooting_flag = true
        end
        for i = 1, num, 1 do
            result1, result2 = remove_next_old_image(oldest_img_num, oldest_img_dir)
            if (result1 == nil) then
                break
            end -- failed so run away
            oldest_img_num = result1 + 1
            if oldest_img_num > 9999 then
                oldest_img_num = 1
            end
            oldest_img_dir = result2
            dcount = i
        end
        if (shooting_flag == true) then
            switch_mode(SHOOTING)
        end
    end
    return dcount
end

-- manage SD card space
function check_SD_card_space()
    if (jpg_count ~= nil) then
        if (jpg_count < 10) then
            if (sd_card_full == false) then
                printf("Warning : SD card space = " .. jpg_count .. " images.")
                sd_card_full = true
            end
            if (file_delete == 1) then
                remove_oldest_images(5) -- remove 5 oldest images
                jpg_count = nil -- set the jpg_count invalid (until next shot)
            end
        else
            sd_card_full = false -- SD card space okay
        end
    end
    return
end

-- check current exposure values
function get_exposure()
    tv96current = get_tv96()
    av96current = get_av96()
    sv96current = get_sv96()
    bv96current = get_bv96()
    ev96current = get_ev()
    return
end

function check_exposure()
    press("shoot_half")
    wait_timeout(get_shooting, true, 4000, "unable to check exposure")
    get_exposure()
    release("shoot_half")
    wait_timeout(get_shooting, false, 2000, "unable to released shoot half")
    return
end

function check_dow()
    local dow = tonumber(os.date("%w"))
    if (dow_mode == 1) then
        if ((dow > 0) and (dow < 6)) then
            return true
        else
            return false
        end
    elseif (dow_mode == 2) then
        if ()(dow == 0) or (dow == 6) then
            return true
        else
            return false
        end
    end
    return true
end

function dawn_and_dusk(year, month, day, lat, lng, utc) --- props to msl
    local day_of_year = 0
    local feb = 28
    if ((year % 4 == 0) and (year % 100 ~= 0 or year % 400 == 0)) then
        feb = 29
    end
    local days_in_month = { 31, feb, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    for i = 1, month - 1 do
        day_of_year = day_of_year + days_in_month[i]
    end
    local doy = day_of_year + day
    local lat = lat * 100
    local D = imath.muldiv(imath.sinr(imath.muldiv(16906, doy * 1000 - 80086, 1000000)), 4095, 10000)
    local time_equation = (imath.mul(imath.sinr(((337 * doy) + (465 * 10)) / 10), -171)) - (imath.mul(imath.sinr(((1787 * doy) - (168 * 100)) / 100), 130))
    local h = -6000 --civil twilight h=-6°   -- h=-833 --sunset/sunrise h=-50'
    local time_diff = 12 * imath.scale * imath.acosr(imath.div((imath.sind(h) - imath.mul(imath.sind(lat), imath.sinr(D))), imath.mul(imath.cosd(lat), imath.cosr(D)))) / imath.pi
    local top = (12 + utc) * imath.scale - imath.div(lng * 100, 15 * imath.scale) - time_equation
    local sunup = (top - time_diff) * 3600 / 1000
    local sundown = (top + time_diff) * 3600 / 1000
    return sunup, sundown
end

function get_start_stop_times()
    dawn, dusk = dawn_and_dusk(os.date("%Y"), os.date("%m"), os.date("%d"), latitude, longitude, utc)
    if ((dawn_mode) and (start_time > dawn)) then
        day_time_start = dawn - (time_offset * 60)
    else
        day_time_start = start_time
    end
    if ((dusk_mode) and (stop_time < dusk)) then
        day_time_stop = dusk + (time_offset * 60)
    else
        day_time_stop = stop_time
    end
    printf("start time : %02d:%02d stop time : %02d:%02d", day_time_start / 3600, day_time_start % 3600 / 60, day_time_stop / 3600, day_time_stop % 3600 / 60)
end

function update_day_or_night_mode() -- Day or Night mode ?
    if (start_stop_mode == true) then
        if ((start_delay == 0) and check_dow() and -- start delay ? enabled today ?
                (((day_time_start < day_time_stop) and ((now >= day_time_start) and (now < day_time_stop))) -- inverted start & stop times ?
                        or ((day_time_start > day_time_stop) and ((now >= day_time_start) or (now < day_time_stop)))
                        or (tv96current >= min_Tv + 24))) then -- tv above minimum threshold ?
            if (shooting_mode == NIGHT) then
                activate_display(4) -- turn the display on for 4 seconds
                display_mode = day_display_mode -- set new display power saving mode
                printf("switching to day mode")
                shooting_mode = DAY
            end
        else
            if ((shooting_mode == DAY) and (tv96current <= min_Tv)) then
                activate_display(4) -- turn the display on for four seconds
                display_mode = night_display_mode -- set new display power saving mode
                printf("switching to night mode")
                shooting_mode = NIGHT
            end
        end
    else
        shooting_mode = DAY
    end
end

-- focus at infinity lock and unlock

function lock_focus()
    if (focus_at_infinity) then -- focus lock at infinity requested ?
        local sd_modes = get_sd_over_modes() -- get camera's available MF modes - use AFL if possible, else MF if available
        if (bitand(sd_modes, 0x02) ~= 0) then
            set_aflock(true)
        elseif (bitand(sd_modes, 0x04) ~= 0) then
            set_mf(true)
            if (get_prop(props.FOCUS_MODE) ~= 1) then
                printf("Warning:MF enable failed***")
            end
        end
        if (sd_modes > 0) then
            sleep(1000)
            set_focus(INFINITY)
            sleep(1000)
        end
    end
end

function unlock_focus()
    if (focus_at_infinity) then -- focus lock at infinity requested ?
        local sd_modes = get_sd_over_modes() -- get camera's available MF modes
        if (bitand(sd_modes, 0x02) ~= 0) then
            set_aflock(false)
        elseif (bitand(sd_modes, 0x04) ~= 0) then
            set_mf(false)
        end
    end
end

--[[ ========================== Main Program ========================================================================= --]]

set_console_layout(0, 1, 48, 6)
now = get_current_time()
printf("=== Ultimate v4.6 : %02d:%02d ===", now / 3600, now % 3600 / 60)
bi = get_buildinfo()
printf("%s %s %s %s %s", bi.version, bi.build_number, bi.platform, bi.platsub, bi.build_date)
version = tonumber(string.sub(bi.build_number, 1, 1)) * 100 + tonumber(string.sub(bi.build_number, 3, 3)) * 10 + tonumber(string.sub(bi.build_number, 5, 5))

if (version < 140) then
    printf("Error : script needs CHDK 1.4.0 or higher")
    return
end

-- initial run tracking data
elapsed_days = 1
oldest_img_num = nil
oldest_img_dir = nil

-- test is this is regular start or a reboot ?
if (autostarted()) then
    printf("Autostarted.  Next reboot:%d days", reboot_counter)
    sleep(1000)
    start_delay = 0 -- disable start delay if autostarted
    local f = io.open("A/ucount.txt", "r")
    if (f ~= nil) then
        local edays = f:read("*l")
        local old_img = f:read("*l")
        local old_img_dir = f:read("*l")
        f:close()
        if (edays ~= nil) then
            elapsed_days = tonumber(edays)
            printf("Elapsed days = %d", elapsed_days)
        else
            printf("Error - missing elapsed day count read")
        end
        if (old_img ~= nil) then
            oldest_img_num = tonumber(old_img)
            printf("Oldest image number = %d", oldest_img_num)
        else
            printf("Error - missing oldest image number")
        end
        if (old_img_dir ~= nil) then
            oldest_img_dir = old_img_dir
            printf("Oldest DCIM folder = %s", oldest_img_dir)
        else
            printf("Error - missing oldest folder")
        end
    end
else
    log_user_params() -- log user params only if regular start
end


if (maximum_days > 0) then
    printf("Shutdown scheduled in %d days", maximum_days - elapsed_days)
end

-- switch to shooting mode as script start defaults to DAY mode
switch_mode(SHOOTING)
show_msg_box("...starting")

-- set zoom position
update_zoom(zoom_setpoint)

-- lock focus if enabled
lock_focus()

-- check initial exposure
check_exposure()

-- disable flash, image stabilization and AF assist lamp
set_prop(props.FLASH_MODE, 2) -- flash off
set_prop(props.IS_MODE, 3) -- IS_MODE off
set_prop(props.AF_ASSIST_BEAM, 0) -- AF assist off if supported for this camera
if (ptp_enable == 1) then
    set_config_value(121, 1) -- make sure USB remote is enabled if we are going to be using PTP
end

-- disable script exit via the shutter button
set_exit_key("no_key")
set_draw_title_line(0)
show_msg_box("...starting")

-- set timing
timestamp = get_current_time()
ticsec = 0
ticmin = 0
next_shot_time = get_next_shot_time()
get_start_stop_times()
update_day_or_night_mode()
activate_display(60) -- activate the display for 60 seconds
sleep(500)

if (start_delay > 0) then
    printf("startup delay begins")
end
show_msg_box("...starting")

repeat
    repeat
        -- get time of day and check for midnight roll-over
        now = get_current_time()
        if (now < timestamp) then
            printf("starting a new day")
            next_shot_time = 0 -- midnight is alway a valid shot time if in ACTIVE mode
            ticsec = 0
            ticmin = 0
            reboot_counter = reboot_counter - 1 -- update reboot counter
            if (start_delay > 0) then -- update start delay
                start_delay = start_delay - 1
                if (start_delay == 0) then
                    printf("startup delay complete")
                end
            end
            elapsed_days = elapsed_days + 1 -- elapsed day count  - shutdown if we are done
            if (elapsed_days == maximum_days) then
                camera_reboot()
            end
            get_start_stop_times() -- recalculate start & stop times
            update_day_or_night_mode() -- check if day or night mode has changed
        end
        timestamp = now

        -- process things that happen once per second
        if (ticsec <= now) then
            ticsec = now + 1
            -- console_redraw()
            if (display_active) then
                show_status_box()
            end
            if (display_hold_timer > 0) then
                display_hold_timer = display_hold_timer - 1
                if (display_hold_timer == 0) then
                    activate_display(0)
                end -- display off
            end

            -- check SD card space
            check_SD_card_space()

            -- check if the USB port connected and switch to playback to allow image downloading?
            if ((ptp_enable == 1) and (get_usb_power(1) == 1)) then
                printf("**PTP mode requested")
                switch_mode(PLAYBACK)
                set_config_value(121, 0) -- USB remote disable
                sleep(1000)
                repeat
                    sleep(100)
                until (get_usb_power(1) == 0)
                printf("**PTP mode released")
                sleep(2000)
                set_config_value(121, 1) -- USB remote enable
                sleep(2000)
                switch_mode(SHOOTING)
                sleep(1000)
            end
        end

        -- process things that happen once every 30 seconds
        if (ticmin <= now) then
            ticmin = now + 30
            activate_display(0) -- display off called periodically in case backlit comes back on after a shot
            collectgarbage()
            -- check battery voltage
            local vbatt = get_vbatt()
            if (vbatt < low_batt_trip) then
                batt_trip_count = batt_trip_count + 1
                if (batt_trip_count > 3) then
                    printf("low battery shutdown : " .. vbatt)
                    sleep(2000)
                    post_levent_to_ui('PressPowerButton')
                    sleep(10000)
                end
            else
                batt_trip_count = 0
            end
            update_day_or_night_mode() -- check if day or night mode has changed so log shows time of change over
        end

        -- blink status LED  - slow (normal) or fast(error or SD card full)
        led_blinker()

        -- time for a reboot ?
        if ((reboot_counter < 1) and (now > reboot_time)) then
            camera_reboot()
        end

        -- time for the next shot ?
        if (now >= next_shot_time) then
            next_shot_time = get_next_shot_time()

            -- check the required shutter speed if Tv detect mode is enabled
            if (min_Tv < 9990) then
                if ((not display_active) and ((display_mode == 4) or (display_mode == 5))) then
                    activate_display(1) -- restore display in playback or suspend modes so lens opens
                    sleep(4000)
                end
                check_exposure()
                if (tv96current >= min_Tv + 24) then
                    shotstring = string.format("day mode : %s > [%s]", tv2seconds(tv96current), tv2seconds(min_Tv))
                else
                    shotstring = string.format("night mode : %s < [%s]", tv2seconds(tv96current), tv2seconds(min_Tv))
                end
                fstop = av96_to_aperture(av96current)
                printf('exposure check = %s f: %d.%d ISO: %d bv: %d ', shotstring, fstop / 1000, (fstop % 1000) / 100, sv96_to_iso(sv96_real_to_market(sv96current)), bv96current)
            end

            -- verify current shooting mode
            update_day_or_night_mode()

            -- shoot if in day mode
            if (shooting_mode == DAY) then
                -- restore display if using sleep mode or playback mode to save power/backlight
                if ((not display_active) and ((display_mode == 4) or (display_mode == 5))) then
                    activate_display(1)
                end

                -- and finally SHOOT
                if (hdr_mode == 0) then -- single shot mode
                    shoot()
                    get_exposure()
                    shotstring = string.format('IMG_%04d.JPG', get_exp_count())
                else -- HDR bracketing mode
                    if (hdr_mode == 5) then -- burst mode ?
                        shotstring = ""
                        press("shoot_half")
                        repeat
                            sleep(50)
                        until get_shooting() == true
                        sleep(500)
                        get_exposure()
                        for i = 0 - hdr_shots, hdr_shots, 1 do
                            ecnt = get_exp_count()
                            tv = tv96current + hdr_offset * i
                            set_prop(pTV, tv)
                            if (propset > 3) then
                                set_prop(pTV2, tv)
                            end
                            press("shoot_full_only")
                            repeat
                                sleep(20)
                            until (get_exp_count() ~= ecnt)
                            release("shoot_full_only")
                            shotstring = string.format('%s IMG_%04d.JPG', shotstring, get_exp_count())
                        end
                        release("shoot_half")
                        sleep(500)
                    else
                        shoot()
                        shotstring = string.format('IMG_%04d.JPG', get_exp_count())
                        get_exposure()
                        for i = 0 - hdr_shots, hdr_shots, 1 do
                            if (i ~= 0) then
                                if (hdr_mode == 1) then
                                    sleep(500)
                                    set_ev(ev96current + hdr_offset * i)
                                else
                                    set_tv96_direct(tv96current + tv_offset * i)
                                    set_av96_direct(av96current + av_offset * i)
                                    set_sv96(sv96current + sv_offset * i)
                                end
                                sleep(200)
                                shoot()
                                sleep(200)
                                shotstring = string.format('%s IMG_%04d.JPG', shotstring, get_exp_count())
                            end
                        end
                        if (hdr_mode == 1) then
                            set_ev(ev96current)
                        end
                    end
                end
                jpg_count = get_jpg_count() -- jpeg count only valid after a shot has been taken
                if ((oldest_img_num == nil) or (oldest_img_dir == nil)) then -- get first image/DCIM folder from this run (slightly wrong by two if HDR mode - oh well)
                    oldest_img_num = get_exp_count()
                    oldest_img_dir = string.sub(get_image_dir(), 8, 15)
                    printf(string.format("Oldest image set to : %s/IMG_%04d.JPG", oldest_img_dir, oldest_img_num))
                end
                shot_counter = shot_counter + 1
                fstop = av96_to_aperture(av96current)
                shotstring = string.format('%s tv: %s f: %d.%d ISO: %d bv: %d ', shotstring, tv2seconds(tv96current), fstop / 1000, (fstop % 1000) / 100, sv96_to_iso(sv96_real_to_market(sv96current)), bv96current)
            else
                shotstring = "<no shot>" -- camera is in night mode
            end
            local bvolts = get_vbatt()
            printf("V: %d.%3.3d T: %d %s", bvolts / 1000, bvolts % 1000, get_temperature(0), shotstring)
        end

        -- shut down camera if SD card is full
        if (jpg_count ~= nil) then
            if (jpg_count < 2 ) then
                printf("SD card full - shutting down")
                sleep(5000)
                post_levent_to_ui('PressPowerButton')
                sleep(10000)
            end
        end

        -- check for user input from the keypad
        wait_click(100)

    until not( is_key("no_key"))
    printf("key pressed")
    activate_display(30)                                -- reactivate display for 30 seconds
until is_key("menu")

printf("menu key exit")
restore()

-- eof --
