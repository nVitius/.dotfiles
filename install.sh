#!/bin/bash
set -x

mkdir $HOME/.dotfiles/antigen && curl -L git.io/antigen > $HOME/.dotfiles/antigen/antigen.zsh

/usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"

brew install zsh antigen nvm httpie
brew cask install iterm2 beardedspice keybase gpg docker sizeup atom slack pass sshuttle

sudo echo "/usr/local/bin/zsh" >> /etc/shells
sudo chsh -s /usr/local/bin/zsh `whoami`

keybase login nvitius

(cd $HOME/.dotfiles/fonts && keybase pgp decrypt -i op_mono.tar.gz.pgp | tar -zxv)
(cd $HOME/.dotfiles/licenses && keybase pgp decrypt -i SizeUp.sizeuplicense.pgp -o SizeUp.sizeuplicense)
(cd $HOME/.dotfiles && keybase pgp decrypt -i ssh.tar.gz.pgp | tar -zxv)
(cd $HOME/.dotfiles/kube && keybase pgp decrypt -i config.pgp -o config)

ln -s $HOME/.dotfiles/zsh/zshrc $HOME/.zshrc
ln -s $HOME/.dotfiles/.ssh $HOME/.ssh
ln -s $HOME/.dotfiles/git/gitconfig $HOME/.gitconfig
ln -s $HOME/.dotfiles/git/gitignore $HOME/.gitignore
ln -s $HOME/.dotfiles/kube $HOME/.kube
mkdir $HOME/.gnupg && ln -s $HOME/.dotfiles/gpg/config/gpg.conf $HOME/.gnupg/gpg.conf

brew install bison oniguruma automake libtool
( cd /tmp && \
  git clone https://github.com/stedolan/jq.git && \
  cd jq && autoreconf -i && \
  PATH="/usr/local/opt/bison/bin:$PATH" ./configure && \
  PATH="/usr/local/opt/bison/bin:$PATH" make && \
  mv jq /usr/local/bin/
)

