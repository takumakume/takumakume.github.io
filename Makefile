build:
	hugo

new:
ifndef NAME
	@echo 'NAME を環境変数に設定して下さい。'
	@exit 1
endif
	hugo new content/blog/`date '+%Y-%m-%d'`-$(NAME).md

default: build
