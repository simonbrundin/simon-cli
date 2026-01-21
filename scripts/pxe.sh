#!/bin/bash

# Converted from pxe.nu

main_pxe_debug_dhcp() {
    ssh root@192.168.1.1 -t "sudo tcpdump -i any -n -e -tttt -vv port 67 or port 68"
}

main_backup_pxe() {
    # Installera PiShrink
    ssh simon@pxe -t '
        target="/usr/local/bin/pishrink.sh"
        if command -v pishrink.sh >/dev/null || [ -f "$target" ]; then
            echo "PiShrink är redan installerad. Skippar installation."
        else
            curl -fsSL https://raw.githubusercontent.com/Drewsif/PiShrink/master/pishrink.sh -o pishrink.sh
            chmod +x pishrink.sh
            sudo mv pishrink.sh /usr/local/bin/
            echo "PiShrink installerad till /usr/local/bin."
        fi
    '
    # Skapa Raw Backup Image
    os_disk='/dev/sda'
    backup_disk='/media/simon/writable'
    ssh simon@pxe -t "sudo dd if=$os_disk of=$backup_disk/pi_backup.img bs=1M status=progress"
    # Komprimera Image med PiShrink
    ssh simon@pxe -t "sudo pishrink.sh $backup_disk/pi_backup.img $backup_disk/pi_backup.img.gz; echo 'Backup klar!'"
}

main_pxe_debug_tftp() {
    ssh pxe -t '
        if sudo ss -tulnp | grep -q :69; then
            sudo tcpdump -i any -n -e -tttt -vv "port 69"
        else
            echo "TFTP-server körs inte"
        fi
    '
}

main_setup_pxe() {
    ssh pxe -t 'echo "$USER ALL=(ALL:ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/$USER'
    echo -e "\033[32mAnvändaren har nu sudo-rättigheter\033[0m"
    echo "----------------------------------------------"

    # Installera Brew
    if ssh pxe -T 'bash -c "if test -f /home/linuxbrew/.linuxbrew/bin/brew; then echo exists; else echo missing; fi"' | grep -q 'missing'; then
        echo "Installerar Brew"
        ssh pxe -T 'curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o /tmp/install.sh; chmod +x /tmp/install.sh; /tmp/install.sh'
    fi
    echo -e "\033[32mBrew installerat!\033[0m"
    echo "----------------------------------------------"

    # Installera Nushell (keep as is, since converting to Bash)
    if ! ssh pxe -T '/bin/bash -lc "PATH=/opt/homebrew/bin:/usr/local/bin:$PATH command -v nu"' | grep -q 'nu'; then
        echo "Installerar Nushell"
        ssh pxe -t '/home/linuxbrew/.linuxbrew/bin/brew install nushell'
    fi
    echo -e "\033[32mNushell installerat!\033[0m"
    echo "----------------------------------------------"

   # Bash som standardshell
   ssh pxe -t '/bin/bash -c "if [ \"$SHELL\" != \"/bin/bash\" ]; then chsh -s \"/bin/bash\"; fi"'
   echo -e "\033[32mBash är standardshell!\033[0m"
    echo "----------------------------------------------"

    # SSH-nyckel hos github
    ssh pxe -T '/bin/bash -lc "if [ ! -f ~/.ssh/id_github ]; then ssh-keygen -t ed25519 -C \"simonbrundin@gmail.com\" -f ~/.ssh/id_github; fi; cat ~/.ssh/id_github.pub"' | grep -E '^(ssh-(ed25519|rsa)|sk-ssh-(ed25519|ecdsa)@openssh.com) ' | head -n1
    ssh_output=$(ssh pxe -T 'ssh -i ~/.ssh/id_github -o IdentitiesOnly=yes -T git@github.com' 2>&1)
    if ! echo "$ssh_output" | grep -q 'successfully authenticated'; then
        xdg-open "https://github.com/settings/ssh/new"
    fi
    echo -e "\033[32mSSH-nyckel installerad på GitHub!\033[0m"
    echo "----------------------------------------------"

    # Klona infrastructure-repo
    echo "Klona/uppdatera infrastructure-repo"
    echo "----------------------------------------------"
    ssh pxe -t '
        if [ -d ~/infrastructure ]; then
            echo "Updaterar ~/infrastructure…"
            git -C ~/infrastructure pull
        else
            echo "Klonar repo till ~/infrastructure…"
            cd ~
            git clone git@github.com:simonbrundin/infrastructure.git
        fi
    '

    # Installera Docker
    ssh pxe -t 'curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg'
    ssh pxe -t 'sudo bash -c "echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable\" > /etc/apt/sources.list.d/docker.list"'
    ssh pxe -t 'sudo apt update'
    ssh pxe -t 'sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin'

    # Kör setupskript
    echo "Kör setup.nu"
    echo "----------------------------------------------"
    ssh pxe -t '/home/linuxbrew/.linuxbrew/bin/nu ~/infrastructure/pxe/setup.nu'
}