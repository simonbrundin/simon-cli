#!/usr/bin/env nu

# Config Simon CLI
def "main config" [tool = "simon"] {
    match $tool {
        # Config Simon CLI
        "simon" => {
            exec $env.EDITOR /Users/simon/Repos/devenv/CLI/simon
        }
        # Config Nushell
        "nu" => {
            exec $env.EDITOR $"($env.nushell-path)/config.nu"
        }
        # Config Vim
        "vim" => {
            exec $env.EDITOR "/Users/simon/.vimrc"
        }
        # Config colorscheme
        "colorscheme" => {
            exec sh "/Users/simon/repos/devenv/.config/colorscheme/colorscheme-selector.sh"
        }
        # Config Ghostty
        "ghostty" => {
            exec $env.EDITOR $"($env.HOME)/Library/Application Support/com.mitchellh.ghostty/config"
        }
        # Config Brew packages
        "packages" => {
            exec $env.EDITOR $env.XDG_CONFIG_HOME/brew/Brewfile
        }
        # Config Karabiner-Elements keybindings
        "keys" => {
            exec $env.EDITOR $"($env.dotfiles-path)/karabiner/karabiner-config.ts"
        }
        # PXE-server Devbox packages
        "pxe packages" => {
            exec $env.EDITOR /Users/simon/Repos/infrastructure/pxe/devbox.json
        }
        # Config NeoVim
        "nvim" => {
            exec $env.EDITOR $env.XDG_CONFIG_HOME/nvim/lazyvim/
        }
    }
}

# Kort: Config
def "main c" [tool = "simon"] {
    main config $tool
}

# Source config files
def "main source" [tool = "nu"] {
    match $tool {
        # Source Nushell config
        "nu" => {
            config nu
        }
        # Config Karabiner-Elements keybindings
        "keys" => {
            deno run --allow-env --allow-read --allow-write $"($env.dotfiles-path)/karabiner/karabiner-config.ts"
        }
    }   
}

# Kort: Source
def "main s" [tool = "nu"] {
    main source $tool
}
