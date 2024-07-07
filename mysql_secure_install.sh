#!/usr/bin/expect -f

set timeout 10
set password [lindex $argv 0]

spawn mysql_secure_installation

expect "Enter current password for root (enter for none):"
send "$password\r"

expect "Set root password? \[Y/n\]"
send "y\r"

expect "New password:"
send "$password\r"

expect "Re-enter new password:"
send "$password\r"

expect "Remove anonymous users? \[Y/n\]"
send "y\r"

expect "Disallow root login remotely? \[Y/n\]"
send "n\r"

expect "Remove test database and access to it? \[Y/n\]"
send "y\r"

expect "Reload privilege tables now? \[Y/n\]"
send "y\r"

expect eof