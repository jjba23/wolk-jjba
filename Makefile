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

update:
	@guix pull --fallback
system-reconfigure:
	$(call wolk-jjba-log-starting,"system-reconfigure")
	@git fetch --all
	@git pull
	@sudo mkdir -p /srv/http/jointhefreeworld.org
	@sudo mkdir -p /srv/http/casadelcata.es
	@sudo mkdir -p /srv/http/carvoeirowaterfun.com
	@sudo mkdir -p /srv/http/certbot
	@sudo touch /srv/http/certbot/index.html
	@sudo guix system reconfigure config.scm --fallback
	$(call wolk-jjba-log-complete,"system-reconfigure")
joe-reconfigure:
	@git fetch --all
	@git pull
	$(call wolk-jjba-log-starting,"joe-reconfigure")
	@guix home reconfigure home/joe/home.scm --fallback
	$(call wolk-jjba-log-complete,"joe-reconfigure")
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

carvoeirowaterfun:
	pushd ~/Ontwikkeling/Perssoonlijk/carvoeiro-water-fun
	npm install
	npm run build
	cp -Rf build /srv/http/carvoeirowaterfun.com
	popd
