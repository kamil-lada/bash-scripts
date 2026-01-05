wget -q https://repo.zabbix.com/zabbix/7.0/debian/pool/main/z/zabbix-release/zabbix-release_latest+debian12_all.deb && dpkg -i zabbix-release_latest+debian12_all.deb
apt update > /dev/null 2>&1 && apt install -y jq curl wget net-tools htop tcpdump zabbix-agent2 zabbix-agent2-plugin-* > /dev/null 2>&1
rm zabbix-release_latest+debian12_all.deb > /dev/null 2>&1
sudo mkdir -p /var/lib/zabbix > /dev/null 2>&1 && sudo touch /var/lib/zabbix/zabbix_agent2.db > /dev/null 2>&1 && sudo chown -R zabbix:zabbix /var/lib/zabbix  > /dev/null 2>&1
sudo mv /etc/zabbix/zabbix_agent2.conf /etc/zabbix/zabbix_agent2.conf.bak > /dev/null 2>&1
cat <<EOL | sudo tee /etc/zabbix/zabbix_agent2.conf  > /dev/null 2>&1
BufferSend=5
BufferSize=100
EnablePersistentBuffer=1
HostMetadata=linux
HostnameItem=system.hostname
PersistentBufferFile=/var/lib/zabbix/zabbix_agent2.db
PersistentBufferPeriod=30d
ControlSocket=/run/zabbix/agent.sock
Include=/etc/zabbix/zabbix_agent2.d/*.conf
Include=/etc/zabbix/zabbix_agent2.d/plugins.d/*.conf
LogFile=/var/log/zabbix/zabbix_agent2.log
LogFileSize=10
PidFile=/var/run/zabbix/zabbix_agent2.pid
PluginSocket=/run/zabbix/agent.plugin.sock
Timeout=10
DebugLevel=3
Server=0.0.0.0/0
ServerActive=10.0.10.10

EOL

systemctl restart zabbix-agent2 && systemctl enable zabbix-agent2