# Makefile - installing and working with wolk-jjba - Supreme Sexp System

# Copyright (C) 2024 Josep Bigorra

# Version: 0.1.0
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
	@printf "\n>>= $(shell date) - success - target %s was completed!\n" $(1)
endef

define wolk-jjba-log-info
	@printf "\n>>= $(shell date) - info - %s \n" $(1)
endef

update:
	@guix pull
system-reconfigure:
	$(call wolk-jjba-log-info,"begin working on system-reconfigure target")
	@sudo guix system reconfigure config.scm
	$(call wolk-jjba-log-complete,"system-reconfigure")
joe-reconfigure:
	$(call wolk-jjba-log-info,"begin working on joe-reconfigure target")
	@guix home reconfigure home/joe/home.scm
	$(call wolk-jjba-log-complete,"joe-reconfigure")
full-rebuild:
	@make system-reconfigure
	@make joe-reconfigure
	@sudo fc-cache -r
	@fc-cache -r
	$(call wolk-jjba-log-complete,"full-rebuild")

# Aliases section
jr:
	@make joe-reconfigure
mr:
	@make manon-reconfigure
sr:
	@make system-reconfigure
fr:
	@make full-rebuild
gc:
	@sudo guix system delete-generations 3d
store-gc:
	@sudo guix gc
