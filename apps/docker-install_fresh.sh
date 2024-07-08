#!/bin/bash

# Install packages
sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Create group and alter user
sudo groupadd docker >/dev/null 2>$1 && sudo usermod -aG docker debian && newgrp docker

# Verify installation
sudo -u debian bash -c "docker run hello world"