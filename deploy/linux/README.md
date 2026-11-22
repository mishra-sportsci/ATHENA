# Linux Desktop Integration

This directory contains optional Linux desktop launchers and systemd service configurations for ATHENA.

### Installation
To add ATHENA to your Linux application menu (KDE Plasma, GNOME, XFCE):

```bash
mkdir -p ~/.local/share/applications
cp deploy/linux/*.desktop ~/.local/share/applications/
chmod +x ~/.local/share/applications/Launch_ATHENA*.desktop
```

### Systemd User Service (Optional)
To run ATHENA continuously in the background as a user service:

```bash
mkdir -p ~/.config/systemd/user
cp deploy/linux/athena.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now athena.service
```
