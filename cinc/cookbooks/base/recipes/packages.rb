# apache2-utils provides htpasswd, libcap2-bin provides setcap/getcap — both are
# used by base::traefik and neither is guaranteed on a minimal Ubuntu image.
%w(make jq curl wget htop tmux git unzip vim ripgrep
   zsh git-lfs fd-find direnv
   apache2-utils libcap2-bin).each do |pkg|
  package pkg
end
