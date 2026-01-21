#!/usr/bin/env nu

# Install Brew package
def "main install" [package] {

    brew install $package
    brew upgrade
  brew bundle dump --file $"($env.dotfiles-path)/brew/.Brewfile" --force
}

# Kort: Install
def "main i" [package] {

    main install $package

}

# Uninstall Brew package
def "main uninstall" [package] {

    brew uninstall $package
    brew upgrade

  brew bundle dump --file $"($env.dotfiles-path)/brew/.Brewfile" --force
}

