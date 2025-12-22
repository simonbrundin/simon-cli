#!/usr/bin/env nu

# Felsök DHCP: Se DHCP-meddelanden till Cloud Gateway Ultra
def "main pxe debug dhcp" [] {

    ssh root@192.168.1.1 -t "sudo tcpdump -i any -n -e -tttt -vv port 67 or port 68"

}

# Gör backup på PXE-server
def "main backup pxe" [] {
    # Installera PiShrink
    ssh simon@pxe -t '''
  let target = "/usr/local/bin/pishrink.sh"
  let has_cmd = (which pishrink.sh | length) > 0
  let has_path = ($target | path exists)

  if $has_cmd or $has_path {
    print "PiShrink är redan installerad. Skippar installation."
  } else {
    # Hämta med Nushells inbyggda http istället för extern wget
    http get "https://raw.githubusercontent.com/Drewsif/PiShrink/master/pishrink.sh" | save -f "pishrink.sh"
    chmod +x "pishrink.sh"
    sudo mv "pishrink.sh" "/usr/local/bin/"
    print "PiShrink installerad till /usr/local/bin."
  }
'''
    # Skapa Raw Backup Image
  let os_disk = '/dev/sda'
  let backup_disk = '/media/simon/writable'
    ssh simon@pxe -t $"sudo dd if=($os_disk) of=($backup_disk)/pi_backup.img bs=1M status=progress"
    # Komprimera Image med PiShrink
    ssh simon@pxe -t $"sudo pishrink.sh ($backup_disk)/pi_backup.img ($backup_disk)/pi_backup.img.gz ; print 'Backup klar!'"

}

# Felsök TFTP: Se TFTP-meddelanden till PXE-server
def "main pxe debug tftp" [] {
    ssh pxe -t 'do -i {
        ^sudo ss -tulnp | ^grep -q 69
        if $env.LAST_EXIT_CODE == 0 {
            ^sudo tcpdump -i any -n -e -tttt -vv "port 69"
        } else {
            echo "TFTP-server körs inte"
        }
    }'
}


# TODO: Installera om PXE-server
def "main setup pxe" [] {
  # # VPN:a till datacenter
  # networksetup -connectpppoeservice "UniFi Teleport"
  # print $"VPN status: ((networksetup -showpppoestatus 'UniFi Teleport' | lines | get 0))"
  # print "----------------------------------------------"
  # Ge användaren sudo-rättigheter

  ssh pxe -t 'echo "$USER ALL=(ALL:ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/$USER'

  print $"(ansi green)Användaren har nu sudo-rättigheter(ansi reset)"
  print "----------------------------------------------"
  # Installera Brew
  if (ssh pxe -T 'bash -c "if test -f /home/linuxbrew/.linuxbrew/bin/brew; then echo exists; else echo missing; fi"' | str trim) == 'missing' {
    print "Installerar Brew"
    ssh pxe -T 'curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o /tmp/install.sh ; chmod +x /tmp/install.sh ; /tmp/install.sh'
  }
  print $"(ansi green)Brew installerat!(ansi reset)"
  print "----------------------------------------------"




  # Installera Nushell
  if (ssh pxe -T '/bin/bash -lc "PATH=/opt/homebrew/bin:/usr/local/bin:$PATH command -v nu"' | str trim | is-empty) {
    print "Installerar Nushell"
    ssh pxe -t '/home/linuxbrew/.linuxbrew/bin/brew install nushell'
  }
  print $"(ansi green)Nushell installerat!(ansi reset)"
  print "----------------------------------------------"

  # Nushell som standardshell
  ssh pxe -t '/bin/bash -c "if ! grep -q \"/home/linuxbrew/.linuxbrew/bin/nu\" /etc/shells; then echo \"/home/linuxbrew/.linuxbrew/bin/nu\" | sudo tee -a /etc/shells; fi"'
  ssh pxe -t '/bin/bash -c "if [ \"$SHELL\" != \"/home/linuxbrew/.linuxbrew/bin/nu\" ]; then chsh -s \"/home/linuxbrew/.linuxbrew/bin/nu\"; fi"'
  print $"(ansi green)Nushell är standardshell!(ansi reset)"
  print "----------------------------------------------"

  # SSH-nyckel hos github
  ssh pxe -T '/bin/bash -lc "if [ ! -f ~/.ssh/id_github ]; then ssh-keygen -t ed25519 -C "simonbrundin@gmail.com" -f ~/.ssh/id_github; fi; cat ~/.ssh/id_github.pub"' |  grep -E '^(ssh-(ed25519|rsa)|sk-ssh-(ed25519|ecdsa)@openssh.com) ' | head -n1
  let ssh_output = (ssh pxe -T 'ssh -i ~/.ssh/id_github -o IdentitiesOnly=yes -T git@github.com' | complete)
  if ($ssh_output.stderr !~ 'successfully authenticated') { start "https://github.com/settings/ssh/new" }
  # ssh pxe -t '/home/linuxbrew/.linuxbrew/bin/brew install gh'
  print $"(ansi green)SSH-nyckel installerad på GitHub!(ansi reset)"
  print "----------------------------------------------"

  # Klona infrastructure-repo
  print "Klona/uppdatera infrastructure-repo"
  print "----------------------------------------------"
  ssh pxe -t 'if ("~/infrastructure" | path exists) {
  print "Updaterar ~/infrastructure…"
  git -C ~/infrastructure pull
  } else {
  echo "Klonar repo till ~/infrastructure…"
  cd ~
  git clone git@github.com:simonbrundin/infrastructure.git
  }'

   # Installera Docker
   ssh pxe -t 'curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg'
   ssh pxe -t 'sudo bash -c "echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable\" > /etc/apt/sources.list.d/docker.list"'
   ssh pxe -t 'sudo apt update'
   ssh pxe -t 'sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin'



   # Kör setupskript
   print "Kör setup.nu"
   print "----------------------------------------------"
   ssh pxe -t '/home/linuxbrew/.linuxbrew/bin/nu ~/infrastructure/pxe/setup.nu'

}
