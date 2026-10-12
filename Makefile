.PHONY: build test dev help clean
build:
	bash build/build.sh
test:
	bash tests/smoke.sh
dev:
	bash src/main.sh
help:
	bash src/main.sh help
clean:
	rm -f dist/vps-toolbox.sh
