#!/bin/sh
# Prints the sudo password that `deploy.sh secrets` handed to the Ansible container over
# stdin (R29). Used only as `ansible-playbook --become-password-file` inside that
# container: the password never travels as an argument or lands in a file.
printf '%s\n' "${INFRA_BECOME_PASSWORD-}"
