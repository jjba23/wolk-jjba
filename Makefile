# Makefile - installing and working with wolk-jjba

# Copyright (C) 2024 Josep Bigorra

# Author: Josep Bigorra <jjbigorra@gmail.com>
# Maintainer: Josep Bigorra <jjbigorra@gmail.com>
# URL: https://github.com/jjba23/wolk-jjba

# wolk-jjba is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# wolk-jjba is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with wolk-jjba.  If not, see <https://www.gnu.org/licenses/>.

# Commentary:

# TODO

# Code:


define wolk-jjba-log-complete
	@printf "\n\033[1m>>= $(shell date) - completed work on target %s\033[0m\n" $(1)
endef

define wolk-jjba-log-starting
	@printf "\n\033[1m>>= $(shell date) - begin working on target: %s...\033[0m\n" $(1)
endef

define wolk-jjba-log-info
	@printf "\n\033[1m>>= $(shell date) - info - %s\033[0m\n" $(1)
endef

define wolk-jjba-clone-repo
		@-sudo git clone "https://github.com/jjba23/${1}" "/var/log/byggsteg/job-clone/${1}/trunk"
		@-cd "/var/log/byggsteg/job-clone/${1}/trunk" && sudo git pull
endef

update:
	@guix pull --fallback
system-reconfigure:
	$(call wolk-jjba-log-starting,"system-reconfigure")
	@-git fetch --all
	@-git pull
	@sudo mkdir -p /srv/http/jointhefreeworld.org
	@sudo mkdir -p /srv/http/casadelcata.es
	@sudo mkdir -p /srv/http/carvoeirowaterfun.com
	@sudo mkdir -p /srv/http
	@sudo touch /srv/http/index.html
	@sudo guix system reconfigure config.scm --fallback
	$(call wolk-jjba-log-complete,"system-reconfigure")
joe-reconfigure:
	@-git fetch --all
	@-git pull
	$(call wolk-jjba-log-starting,"joe-reconfigure")
	@guix home reconfigure home/joe/home.scm --fallback
	$(call wolk-jjba-log-complete,"joe-reconfigure")
joe-sites-rebuild:
	$(call wolk-jjba-clone-repo,"rephs")
	@-make deploy-rephs
	$(call wolk-jjba-clone-repo,"carvoeiro-water-fun")
	@-make deploy-carvoeirowaterfun
	$(call wolk-jjba-clone-repo,"wikimusic-api")
	$(call wolk-jjba-clone-repo,"wikimusic-ssr")
	$(call wolk-jjba-clone-repo,"byggsteg")
	$(call wolk-jjba-clone-repo,"jjba")
full-rebuild:
	$(call wolk-jjba-log-starting,"full-rebuild")
	@make system-reconfigure
	@make joe-reconfigure
	$(call wolk-jjba-log-complete,"full-rebuild")

# Aliases section
jr:
	@make joe-reconfigure
sr:
	@make system-reconfigure
fr:
	@make full-rebuild
gc:
	@sudo guix system delete-generations 3d
store-gc:
	@sudo guix gc

# Website deploy
deploy-carvoeirowaterfun:
	cd /var/log/byggsteg/job-clone/carvoeiro-water-fun/trunk && sudo npm install
	cd /var/log/byggsteg/job-clone/carvoeiro-water-fun/trunk && sudo npm run build
	sudo rm -rf /srv/http/carvoeirowaterfun.com/*
	sudo cp -Rf /var/log/byggsteg/job-clone/carvoeiro-water-fun/trunk/build/* /srv/http/carvoeirowaterfun.com/

deploy-rephs:
	cd /var/log/byggsteg/job-clone/rephs/trunk && sudo nix --extra-experimental-features 'nix-command flakes' develop -c make casa-del-cata
	sudo rm -rf /srv/http/casadelcata.es/*
	sudo cp -Rf /var/log/byggsteg/job-clone/rephs/trunk/dist/casa-del-cata/* /srv/http/casadelcata.es/
