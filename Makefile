# Makefile - installing and working with wolk-jjba

# Copyright (C) 2024 Josep Bigorra

# Author: Josep Bigorra <jjbigorra@gmail.com>
# Maintainer: Josep Bigorra <jjbigorra@gmail.com>
# URL: https://codeberg.org/jjba23/wolk-jjba

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
		@-sudo git clone "https://codeberg.org/jjba23/${1}" "/etc/byggsteg/job-clone/${1}/trunk"
		@-cd "/etc/byggsteg/job-clone/${1}/trunk" && sudo git pull
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
	@echo "Hello World! (from wolk-jjba)" | sudo tee /srv/http/index.html
	@sudo guix system reconfigure config.scm --fallback
	$(call wolk-jjba-log-complete,"system-reconfigure")

joe-reconfigure:
	$(call wolk-jjba-log-starting,"joe-reconfigure")
	@-git fetch --all
	@-git pull
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

# Performs a full garbage collection across Guix and Nix stores.
full-gc:
	-guix home delete-generations
	-sudo guix system delete-generations
	-sudo guix gc
	-nix-store --gc
	-nix-store --gc --print-roots | egrep -v "^(/nix/var|/run/\w+-system|\{memory|/proc)"

fmt:
	-find . -maxdepth 6 -name "*.scm" -type f -exec guix style -f {} \;

# install-nix-packages: Installs Nix packages using a custom script.
install-nix-packages:
	$(call wolk-jjba-log-info,"Installing Nix packages for Wolk JJBA")
	guile --fresh-auto-compile scripts/install-nix-packages.scm
# update-nix-packages: Updates Nix packages using a custom script.
update-nix-packages:
	$(call wolk-jjba-log-info,"Updating Nix packages for Wolk JJBA")
	guile --fresh-auto-compile scripts/update-nix-packages.scm

BACKUP_BUCKET:="wolk-jjba-backups"

define fetch-latest-s3-backup
	@OBJECT=$$(aws s3 ls $(BACKUP_BUCKET)/$(1)/ | sort | tail -n 1 | awk '{print $$4}'); \
	echo "fetching latest $(1) database: $$OBJECT"; \
	aws s3 cp "s3://$(BACKUP_BUCKET)/$(1)/$$OBJECT" . ; \
	mkdir -p $(2) ; \
	tar -xvf "$$OBJECT" -C $(2) ; \
	rm "$$OBJECT"
endef

fetch-backup-wikimusic-db:
	$(call fetch-latest-s3-backup,wikimusic,/etc/byggsteg/job-clone/wikimusic/trunk/)
fetch-backup-lucidplan-db:
	$(call fetch-latest-s3-backup,lucidplan,/etc/byggsteg/job-clone/lucidplan/trunk/)
fetch-backup-byggsteg-db:
	$(call fetch-latest-s3-backup,byggsteg,/etc/byggsteg/job-clone/byggsteg/trunk/)
fetch-backup-static-sites:
	$(call fetch-latest-s3-backup,static-sites,/srv/http/)
fetch-backup-minecraft:
	$(call fetch-latest-s3-backup,minecraft,/srv/games/minecraft/)
