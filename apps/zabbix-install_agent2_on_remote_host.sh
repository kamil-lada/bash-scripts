#!/bin/bash

# Check if the correct number of arguments is provided
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <host_list_file> <private_key>"
    exit 1
fi

# Assign parameters to variables
HOST_LIST_FILE="$1"
PRIVATE_KEY="$2"

# Check if the host list file exists
if [ ! -f "$HOST_LIST_FILE" ]; then
    echo "Host list file not found: $HOST_LIST_FILE"
    exit 1
fi

# Check if the private key file exists
if [ ! -f "$PRIVATE_KEY" ]; then
    echo "Private key file not found: $PRIVATE_KEY"
    exit 1
fi

# Loop through each host in the host list file
while IFS= read -r HOST; do
    if [ -n "$HOST" ]; then
        echo "Connecting to $HOST..."

        ssh -i "$PRIVATE_KEY" -o StrictHostKeyChecking=no zabbix@$HOST 'bash -s' <<'EOF'
#!/bin/bash

# Create required directory and set permissions
sudo mkdir -p /var/lib/zabbix
sudo chown -R zabbix:zabbix /var/lib/zabbix

# Remove old config files
sudo rm -rf /etc/zabbix/zabbix_agent2.conf
sudo rm -rf /etc/zabbix/zabbix-agent2.conf

# Create new Zabbix Agent 2 config file
cat <<EOL | sudo tee /etc/zabbix/zabbix_agent2.conf
# General Parameters
BufferSend=5
BufferSize=100
EnablePersistentBuffer=1
HostMetadata=linux
HostnameItem=system.hostname

# Persistent Buffer
PersistentBufferFile=/var/lib/zabbix/zabbix_agent2.db
PersistentBufferPeriod=30d

# Socket Settings
ControlSocket=/run/zabbix/agent.sock
PluginSocket=/run/zabbix/agent.plugin.sock

# Include Additional Config Files
Include=/etc/zabbix/zabbix_agent2.d/*.conf
Include=/etc/zabbix/zabbix_agent2.d/plugins.d/*.conf

# Logging
LogFile=/var/log/zabbix/zabbix_agent2.log
LogFileSize=0
PidFile=/var/run/zabbix/zabbix_agent2.pid

# Server Settings
Server=example.com
ServerActive=example.com

# Additional Common Settings
Timeout=3
DebugLevel=3
EOL

sudo systemctl restart zabbix-agent2
if [ $? -eq 0 ]; then
    echo "Zabbix Agent restarted successfully on $HOST."
else
    echo "Failed to restart Zabbix Agent on $HOST."
fi
EOF

        if [ $? -eq 0 ]; then
            echo "Script executed successfully on $HOST."
        else
            echo "Failed to execute script on $HOST."
        fi
    fi
done < "$HOST_LIST_FILE"

echo "Done."
