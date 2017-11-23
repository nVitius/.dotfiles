(
  cd $HOME/.dotfiles && \
  tar --exclude="known_hosts" -C $HOME -zcvf - .ssh | keybase pgp encrypt -o ssh.tar.gz.gpg nvitius
)
