#!/usr/bin/expect -f

spawn ssh-add "/tmp/evaluation"
expect "Enter passphrase for /tmp/evaluation:"
send "$env(EVALUATION_PASSPHRASE)\n";
interact
