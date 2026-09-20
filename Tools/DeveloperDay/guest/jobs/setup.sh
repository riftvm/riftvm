# Test machines only: let the suites install and remove packages without a
# password prompt. A real user types their password instead.
password=${RIFTVM_TEST_PASSWORD:?set RIFTVM_TEST_PASSWORD}
echo "$password" | sudo -S -p '' sh -c \
  'echo "omarchy ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/99-riftvm-test && chmod 440 /etc/sudoers.d/99-riftvm-test'
sudo -n true && echo sudo-ok
echo "--- shared folders"; ls -a /mnt/mac
echo "--- build tools"; make --version | head -1; patch --version | head -1
