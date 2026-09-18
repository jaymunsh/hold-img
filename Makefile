.PHONY: build debug run

build:
	./Scripts/build-app.sh release

debug:
	./Scripts/build-app.sh debug

run: build
	open build/HoldImg.app
