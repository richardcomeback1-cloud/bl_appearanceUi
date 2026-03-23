fx_version 'cerulean'
use_experimental_fxv2_oal 'yes'
game "gta5"
lua54 'yes'

author "Byte Labs"
version '1.3.5'
description 'Customize your virtual persona with precision using the Byte Labs Appearance Menu'
repository 'https://github.com/Byte-Labs-Studio/bl_appearance'

ui_page 'html/index.html'
-- ui_page 'http://localhost:3000/' --for dev

server_scripts {
    'config/config.lua',
    'config/commands.lua',
    'server/**/*.lua'
}

shared_scripts {
    '@ox_lib/init.lua',
    'shared/**/*.lua',
}

client_scripts {
    'config/blacklist.lua',
    'config/config.lua',
    'config/menus.lua',
    'config/models.lua',
    'config/tattoos.lua',
    'config/zones.lua',
    'client/**/*.lua'}

files {
    'html/**',
    'locale/*',
}

file_set 'locale' {
    'locale/*'
}
